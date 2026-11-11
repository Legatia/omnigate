defmodule OmnigateControl.Jobs.Adapters.XaiVideo do
  @moduledoc """
  xAI's video generation API (Grok Imagine video models).

    * `POST /v1/videos/generations` with the job `input` plus `model`
      (`prompt`, and optionally `duration` in seconds, `aspect_ratio`,
      `resolution`, `image: {url}` ...) answers `{"request_id": ...}`
    * `GET /v1/videos/{request_id}` until `status` is `done`, `failed` or
      `expired`; when done, `video.url` is the file

  Price it with `per_second_usd`, which multiplies by `input.duration`.

  Checked against the real service with `grok-imagine-video-1.5-lite`
  (November 2026): submit, poll to `done`, download. The `failed` and
  `expired` states and image inputs have only met the mock.

  Re-run with real keys on the current HTTP client on 11 November 2026
  (commit 809b96f); it passed.
  """
  @behaviour OmnigateControl.Jobs.Adapter

  import OmnigateControl.Jobs.Adapter, only: [decode: 1, describe: 1, transient?: 1]
  alias OmnigateControl.Http
  alias OmnigateControl.Jobs.Adapter

  @impl true
  def submit(up, model, input, ctx) do
    body = Map.put(input, "model", model)

    case Http.request(:post, "#{up.base_url}/v1/videos/generations", headers(ctx), JSON.encode!(body), timeout: 60_000) do
      {:ok, %{status: status, body: resp}} when status in 200..299 ->
        case decode(resp) do
          %{"request_id" => id} when is_binary(id) and id != "" -> {:async, id, %{}}
          # Not documented, but harmless to honour: an answer that is already final.
          %{"video" => %{"url" => _}} = done -> interpret(done)
          _ -> {:error, "unexpected create response"}
        end

      other ->
        {:error, describe(other)}
    end
  end

  @impl true
  def poll(up, _model, id, _state, ctx) do
    case Http.request(:get, "#{up.base_url}/v1/videos/#{URI.encode(id, &URI.char_unreserved?/1)}", headers(ctx)) do
      {:ok, %{status: status, body: body}} when status in [200, 202] -> interpret(decode(body))
      other -> if transient?(other), do: {:transient, describe(other)}, else: {:error, describe(other)}
    end
  end

  @doc false
  def interpret(%{"status" => "failed"} = r), do: {:error, "provider_failed: #{error_text(r)}"}
  def interpret(%{"status" => "expired"}), do: {:error, "provider_expired: the result is no longer available"}

  def interpret(%{"video" => %{"url" => url}} = r) when is_binary(url) and url != "" do
    # "done", or a provider that omits the status once the file exists.
    if r["status"] in [nil, "done"], do: {:done, [{:url, url}]}, else: :pending
  end

  def interpret(%{"status" => "done"}), do: {:error, "provider reported done without a video url"}
  # "pending" today; anything else non-final is treated the same way.
  def interpret(_), do: :pending

  defp error_text(%{"error" => %{"message" => m}}) when is_binary(m), do: String.slice(m, 0, 300)
  defp error_text(%{"error" => e}) when is_binary(e), do: String.slice(e, 0, 300)
  defp error_text(%{"message" => m}) when is_binary(m), do: String.slice(m, 0, 300)
  defp error_text(_), do: "no detail"

  # The whole input goes to the provider, so every text field in it counts,
  # and so does whichever of the duration fields asks for more.
  @impl true
  def billable(input), do: %{chars: Adapter.chars(input, ~w(prompt text input)), seconds: Adapter.seconds(input, ~w(duration seconds))}

  defp headers(ctx), do: [{"authorization", "Bearer #{ctx.api_key}"}]
end
