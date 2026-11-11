defmodule OmnigateControl.Jobs.Adapters.GeminiInteractions do
  @moduledoc """
  Gemini's Interactions API, which is the only way to reach some models (the
  "omni" models, which can generate video, answer `generateContent` with
  "This model only supports Interactions API").

    * `POST /v1beta/interactions` with `{"model", "input"}` and an
      `x-goog-api-key` header
    * the answer has `status` and a list of `steps`; files are in
      `steps[].content[]` as `{"type", "mime_type", "data"}` (base64)
    * a request sent with `"background": true` answers before it is finished
      and is then polled at `GET /v1beta/interactions/{id}`

  Job `input`: `prompt` (or `text`), or, for anything else the API takes, a
  native body whose `input` field is set; either way `model` is filled in.

  Checked against the real service with `gemini-omni-1.2-flash` generating a
  short video in the foreground (November 2026). Background polling follows
  the documented outline and has only met the mock.

  Re-run with real keys on the current HTTP client on 11 November 2026
  (commit 809b96f); it passed.
  """
  @behaviour OmnigateControl.Jobs.Adapter

  import OmnigateControl.Jobs.Adapter, only: [decode: 1, describe: 1, transient?: 1]
  alias OmnigateControl.Http
  alias OmnigateControl.Jobs.Adapter
  alias OmnigateControl.Jobs.Adapters.Gemini

  @impl true
  def submit(up, model, input, ctx) do
    with {:ok, body} <- request_body(input, model) do
      case Http.request(:post, "#{up.base_url}/v1beta/interactions", headers(ctx), JSON.encode!(body),
             timeout: ctx.timeout_ms,
             max_body: Adapter.inline_cap(ctx)
           ) do
        {:ok, %{status: 200, body: resp}} ->
          interaction = decode(resp)

          case {interpret(interaction), interaction["id"]} do
            # Not finished yet (a background request): poll it by id.
            {:pending, id} when is_binary(id) and id != "" -> {:async, id, %{}}
            {:pending, _} -> {:error, "unexpected create response"}
            {result, _} -> result
          end

        other ->
          {:error, describe(other)}
      end
    end
  end

  @impl true
  def poll(up, _model, id, _state, ctx) do
    case Http.request(:get, "#{up.base_url}/v1beta/interactions/#{URI.encode(id, &URI.char_unreserved?/1)}", headers(ctx), nil,
           max_body: Adapter.inline_cap(ctx)
         ) do
      {:ok, %{status: 200, body: body}} -> interpret(decode(body))
      other -> if transient?(other), do: {:transient, describe(other)}, else: {:error, describe(other)}
    end
  end

  @doc false
  def request_body(%{"input" => _} = native, model), do: {:ok, Map.put(native, "model", model)}

  def request_body(input, model) do
    case input["prompt"] || input["text"] do
      text when is_binary(text) and text != "" -> {:ok, %{"model" => model, "input" => text}}
      _ -> {:error, "invalid_input: prompt (or text, or a native input) is required"}
    end
  end

  @doc false
  def interpret(%{"status" => "completed"} = interaction) do
    files =
      for step <- List.wrap(interaction["steps"]),
          %{"data" => b64} = part <- List.wrap(step["content"]),
          is_binary(b64),
          {:ok, bytes} <- [Base.decode64(b64, ignore: :whitespace)],
          byte_size(bytes) > 0 do
        Gemini.file(bytes, part["mime_type"] || "application/octet-stream")
      end

    case files do
      [] -> {:error, "no_output: the model returned no file"}
      _ -> {:done, files}
    end
  end

  def interpret(%{"status" => status} = interaction) when status in ["failed", "cancelled", "canceled", "incomplete"] do
    detail =
      case interaction["error"] do
        %{"message" => m} when is_binary(m) -> ": " <> String.slice(m, 0, 300)
        _ -> ""
      end

    {:error, "provider_#{status}#{detail}"}
  end

  # in_progress and anything else that is not final.
  def interpret(_), do: :pending

  # Counted from the request body: the text of `input`, whichever form it took.
  @impl true
  def billable(input) do
    case request_body(input, "") do
      {:ok, body} -> %{chars: Adapter.text_chars(body["input"]) + Adapter.text_chars(body["system_instruction"]), seconds: 0}
      _ -> %{chars: 0, seconds: 0}
    end
  end

  defp headers(ctx), do: [{"x-goog-api-key", ctx.api_key}]
end
