defmodule OmnigateControl.Jobs.Adapters.ElevenLabs do
  @moduledoc """
  ElevenLabs-style text to speech: one synchronous
  `POST /v1/text-to-speech/{voice_id}?output_format=...` with an
  `xi-api-key` header, answering with audio bytes.

  Job `input`: `text` (required), `voice_id` (required), optional
  `output_format` (default `mp3_44100_128`); every other field is passed
  through in the body. `model_id` is set to the route target's model.

  Checked against the real service with `eleven_flash_v2_5` (November 2026).

  Those calls were made with the HTTP client this adapter used at the time
  (OTP's `:httpc`). They have not been repeated on the client that replaced
  it (`OmnigateControl.Http`): against the real service that one has only
  sent a request with an invalid key, which shows that the service is
  reached and its error is read, not that a job completes.
  """
  @behaviour OmnigateControl.Jobs.Adapter

  import OmnigateControl.Jobs.Adapter, only: [describe: 1]
  alias OmnigateControl.Http
  alias OmnigateControl.Jobs.Adapter

  @impl true
  def submit(up, model, input, ctx) do
    with text when is_binary(text) and text != "" <- input["text"],
         voice when is_binary(voice) and voice != "" <- input["voice_id"],
         true <- voice =~ ~r/^[A-Za-z0-9_-]+$/ do
      format = input["output_format"] || "mp3_44100_128"
      url = "#{up.base_url}/v1/text-to-speech/#{voice}?" <> URI.encode_query(%{"output_format" => format})
      body = input |> Map.drop(["voice_id", "output_format"]) |> Map.put("model_id", model)

      case Http.request(:post, url, [{"xi-api-key", ctx.api_key}, {"accept", "*/*"}], JSON.encode!(body),
             timeout: ctx.timeout_ms,
             max_body: Adapter.inline_cap(ctx)
           ) do
        {:ok, %{status: 200, body: audio, headers: headers}} when byte_size(audio) > 0 ->
          {:done, [{:binary, audio, headers["content-type"] || content_type(format)}]}

        {:ok, %{status: 200}} ->
          {:error, "empty audio response"}

        other ->
          {:error, describe(other)}
      end
    else
      _ -> {:error, "invalid_input: text and voice_id are required"}
    end
  end

  # `text` is what is spoken; nothing else in the input is billed per character.
  @impl true
  def billable(input), do: %{chars: Adapter.chars(input, ~w(text)), seconds: 0}

  defp content_type("mp3" <> _), do: "audio/mpeg"
  defp content_type("pcm" <> _), do: "audio/pcm"
  defp content_type("ulaw" <> _), do: "audio/basic"
  defp content_type("opus" <> _), do: "audio/ogg"
  defp content_type(_), do: "application/octet-stream"
end
