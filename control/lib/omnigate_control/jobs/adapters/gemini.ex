defmodule OmnigateControl.Jobs.Adapters.Gemini do
  @moduledoc """
  Gemini's native API, for its image and speech models: one synchronous
  `POST /v1beta/models/{model}:generateContent` with an `x-goog-api-key`
  header. Generated files come back inline, base64-encoded, as `inlineData`
  parts. (Google's OpenAI-compatible endpoint does not serve these models,
  which is why this adapter exists; Gemini's text models go through the
  data plane as an `openai` upstream with `v1_path`.)

  Job `input`, either:

    * `prompt` (or `text`), and for speech a `voice` (e.g. `"Kore"`), which
      also asks for audio output; or
    * `contents` (and optionally `generationConfig`) exactly as Gemini's API
      takes them, sent through untouched, for anything the short form does
      not cover (reference images, several speakers, ...).

  Raw PCM audio (`audio/L16`), which some speech models return, is wrapped in
  a WAV header so the stored file plays as it is.

  Checked against the real service with `gemini-3.1-flash-lite-image` and
  `gemini-3.8-flash-lite-tts` (November 2026).
  """
  @behaviour OmnigateControl.Jobs.Adapter

  import OmnigateControl.Jobs.Adapter, only: [decode: 1, describe: 1]
  alias OmnigateControl.Http

  @impl true
  def submit(up, model, input, ctx) do
    with true <- model =~ ~r/^[A-Za-z0-9._-]+$/ || {:error, "invalid_input: bad model name"},
         {:ok, body} <- request_body(input) do
      url = "#{up.base_url}/v1beta/models/#{model}:generateContent"

      case Http.request(:post, url, [{"x-goog-api-key", ctx.api_key}], JSON.encode!(body), timeout: ctx.timeout_ms) do
        {:ok, %{status: 200, body: resp}} -> outputs(decode(resp))
        other -> {:error, describe(other)}
      end
    end
  end

  @doc false
  def request_body(%{"contents" => contents} = input) when is_list(contents) do
    {:ok, Map.take(input, ["contents", "generationConfig", "systemInstruction", "safetySettings"])}
  end

  def request_body(input) do
    case input["prompt"] || input["text"] do
      text when is_binary(text) and text != "" ->
        body = %{"contents" => [%{"parts" => [%{"text" => text}]}]}

        case input["voice"] do
          voice when is_binary(voice) and voice != "" ->
            {:ok,
             Map.put(body, "generationConfig", %{
               "responseModalities" => ["AUDIO"],
               "speechConfig" => %{"voiceConfig" => %{"prebuiltVoiceConfig" => %{"voiceName" => voice}}}
             })}

          _ ->
            {:ok, body}
        end

      _ ->
        {:error, "invalid_input: prompt (or text, or contents) is required"}
    end
  end

  @doc false
  def outputs(response) do
    parts = for c <- List.wrap(response["candidates"]), p <- List.wrap(get_in(c, ["content", "parts"])), do: p

    files =
      for %{"inlineData" => %{"data" => b64} = data} <- parts,
          {:ok, bytes} <- [Base.decode64(b64, ignore: :whitespace)],
          byte_size(bytes) > 0 do
        file(bytes, data["mimeType"] || "application/octet-stream")
      end

    case files do
      [] -> {:error, "no_output: " <> why_empty(response)}
      _ -> {:done, files}
    end
  end

  # Why Gemini answered 200 without a file: a safety block or an early stop.
  defp why_empty(response) do
    block = get_in(response, ["promptFeedback", "blockReason"])
    finish = response["candidates"] |> List.wrap() |> List.first() |> then(&(&1 && &1["finishReason"]))

    cond do
      is_binary(block) -> "prompt blocked (#{block})"
      is_binary(finish) and finish != "STOP" -> "generation stopped (#{finish})"
      true -> "the model returned no file"
    end
  end

  @doc """
  One generated file as a job output. "audio/L16;codec=pcm;rate=24000" is
  headerless 16-bit mono PCM and is wrapped as WAV; everything else is kept.
  """
  def file(bytes, "audio/L16" <> params), do: {:binary, wav(bytes, sample_rate(params)), "audio/wav"}
  def file(bytes, "audio/l16" <> params), do: {:binary, wav(bytes, sample_rate(params)), "audio/wav"}
  def file(bytes, mime), do: {:binary, bytes, mime |> String.split(";") |> hd() |> String.trim()}

  defp sample_rate(params) do
    case Regex.run(~r/rate=(\d+)/, params) do
      [_, rate] -> String.to_integer(rate)
      _ -> 24_000
    end
  end

  @doc "Wrap 16-bit mono little-endian PCM in a WAV (RIFF) header."
  def wav(pcm, rate) do
    size = byte_size(pcm)

    <<"RIFF", size + 36::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16, rate::little-32, rate * 2::little-32, 2::little-16,
      16::little-16, "data", size::little-32, pcm::binary>>
  end
end
