defmodule OmnigateControl.Jobs.Adapters.Replicate do
  @moduledoc """
  Replicate-style predictions API.

    * `POST /v1/models/{owner}/{name}/predictions` with `{"input": ...}`, or,
      for a target written `owner/name:version`, `POST /v1/predictions` with
      `{"version": ..., "input": ...}`
    * `GET /v1/predictions/{id}` until `status` is `succeeded`, `failed` or `canceled`
    * `output` is a URL or a list of URLs

  Checked against the real service with `black-forest-labs/flux-1.1-pro`
  (November 2026): create, poll, output download, and provider errors
  (unknown model, insufficient credit). The `owner/name:version` form and
  cancel have only met the mock.
  """
  @behaviour OmnigateControl.Jobs.Adapter

  import OmnigateControl.Jobs.Adapter, only: [decode: 1, describe: 1, transient?: 1]
  alias OmnigateControl.Http
  alias OmnigateControl.Jobs.Adapter

  @impl true
  def submit(up, model, input, ctx) do
    {url, body} =
      case String.split(model, ":", parts: 2) do
        [_name, version] -> {"#{up.base_url}/v1/predictions", %{"version" => version, "input" => input}}
        [name] -> {"#{up.base_url}/v1/models/#{name}/predictions", %{"input" => input}}
      end

    case Http.request(:post, url, headers(ctx), JSON.encode!(body), timeout: 60_000) do
      {:ok, %{status: status, body: resp}} when status in 200..299 ->
        case decode(resp) do
          %{"id" => id} = prediction when is_binary(id) ->
            # A fast model can already be terminal in the create response.
            case interpret(prediction) do
              :pending -> {:async, id, %{}}
              {:done, outputs} -> {:done, outputs}
              {:error, reason} -> {:error, reason}
            end

          _ ->
            {:error, "unexpected create response"}
        end

      other ->
        {:error, describe(other)}
    end
  end

  @impl true
  def poll(up, _model, id, _state, ctx) do
    case Http.request(:get, "#{up.base_url}/v1/predictions/#{id}", headers(ctx)) do
      {:ok, %{status: 200, body: body}} -> interpret(decode(body))
      other -> if transient?(other), do: {:transient, describe(other)}, else: {:error, describe(other)}
    end
  end

  @impl true
  def cancel(up, _model, id, _state, ctx) do
    Http.request(:post, "#{up.base_url}/v1/predictions/#{id}/cancel", headers(ctx), "")
    :ok
  end

  defp interpret(%{"status" => "succeeded", "output" => output}), do: {:done, urls(output)}
  defp interpret(%{"status" => "failed"} = p), do: {:error, "provider_failed: #{error_text(p["error"])}"}
  defp interpret(%{"status" => "canceled"}), do: {:error, "provider_canceled"}
  defp interpret(%{"status" => s}) when s in ["starting", "processing"], do: :pending
  defp interpret(_), do: {:error, "unexpected prediction state"}

  defp urls(url) when is_binary(url), do: if(http?(url), do: [{:url, url}], else: [])
  defp urls(list) when is_list(list), do: Enum.flat_map(list, &urls/1)
  defp urls(map) when is_map(map), do: map |> Map.values() |> Enum.flat_map(&urls/1)
  defp urls(_), do: []

  defp http?(s), do: String.starts_with?(s, ["http://", "https://"])

  defp error_text(nil), do: "no detail"
  defp error_text(e) when is_binary(e), do: String.slice(e, 0, 300)
  defp error_text(e), do: e |> inspect() |> String.slice(0, 300)

  # The whole input goes to the provider, so every text field in it counts,
  # and so does whichever of the duration fields asks for more.
  @impl true
  def billable(input), do: %{chars: Adapter.chars(input, ~w(prompt text input)), seconds: Adapter.seconds(input, ~w(duration seconds))}

  defp headers(ctx), do: [{"authorization", "Bearer #{ctx.api_key}"}]
end
