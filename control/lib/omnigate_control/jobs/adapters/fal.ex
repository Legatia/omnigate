defmodule OmnigateControl.Jobs.Adapters.Fal do
  @moduledoc """
  fal-style queue API.

    * `POST {base}/{model}` with the input as the body → `request_id`,
      `status_url`, `response_url`, `cancel_url`
    * `GET status_url` → `IN_QUEUE` | `IN_PROGRESS` | `COMPLETED`
    * `GET response_url` → the model's result; every object with a `url`
      field in it (`images[]`, `video`, `audio`, ...) is an output

  The URLs the provider returns are only followed when they are under the
  configured `base_url`, so a response cannot redirect the API key elsewhere.

  Not yet exercised against the real service.
  """
  @behaviour OmnigateControl.Jobs.Adapter

  import OmnigateControl.Jobs.Adapter, only: [decode: 1, describe: 1, transient?: 1]
  alias OmnigateControl.Http
  alias OmnigateControl.Jobs.Adapter

  @impl true
  def submit(up, model, input, ctx) do
    case Http.request(:post, "#{up.base_url}/#{model}", headers(ctx), JSON.encode!(input), timeout: 60_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case decode(body) do
          %{"request_id" => id} = resp when is_binary(id) ->
            {:async, id, Map.take(resp, ["status_url", "response_url", "cancel_url"])}

          _ ->
            {:error, "unexpected submit response"}
        end

      other ->
        {:error, describe(other)}
    end
  end

  @impl true
  def poll(up, model, id, state, ctx) do
    status_url = trusted(up, state["status_url"]) || "#{up.base_url}/#{model}/requests/#{id}/status"

    case Http.request(:get, status_url, headers(ctx)) do
      {:ok, %{status: status, body: body}} when status in [200, 202] ->
        case decode(body) do
          %{"status" => "COMPLETED"} -> result(up, model, id, state, ctx)
          %{"status" => s} when s in ["IN_QUEUE", "IN_PROGRESS"] -> :pending
          _ -> {:error, "unexpected queue state"}
        end

      other ->
        if transient?(other), do: {:transient, describe(other)}, else: {:error, describe(other)}
    end
  end

  @impl true
  def cancel(up, model, id, state, ctx) do
    url = trusted(up, state["cancel_url"]) || "#{up.base_url}/#{model}/requests/#{id}/cancel"
    Http.request(:put, url, headers(ctx), "")
    :ok
  end

  defp result(up, model, id, state, ctx) do
    url = trusted(up, state["response_url"]) || "#{up.base_url}/#{model}/requests/#{id}"

    case Http.request(:get, url, headers(ctx)) do
      {:ok, %{status: 200, body: body}} ->
        {:done, body |> decode() |> outputs()}

      # A completed request whose result is an error (validation, model failure).
      {:ok, %{status: status}} = other when status in 400..499 ->
        {:error, "provider_failed: " <> describe(other)}

      other ->
        {:transient, describe(other)}
    end
  end

  # Depth-first, in document order: every map carrying a string "url".
  defp outputs(%{"url" => url} = file) when is_binary(url), do: [{:url, url, file["content_type"]}]
  defp outputs(map) when is_map(map), do: map |> Enum.sort() |> Enum.flat_map(fn {_k, v} -> outputs(v) end)
  defp outputs(list) when is_list(list), do: Enum.flat_map(list, &outputs/1)
  defp outputs(_), do: []

  defp trusted(up, url) when is_binary(url), do: if(String.starts_with?(url, up.base_url <> "/"), do: url)
  defp trusted(_up, _), do: nil

  # The whole input goes to the provider, so every text field in it counts,
  # and so does whichever of the duration fields asks for more.
  @impl true
  def billable(input), do: %{chars: Adapter.chars(input, ~w(prompt text input)), seconds: Adapter.seconds(input, ~w(duration seconds))}

  defp headers(ctx), do: [{"authorization", "Key #{ctx.api_key}"}]
end
