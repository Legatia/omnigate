defmodule OmnigateControl.Admin do
  @moduledoc """
  What operators see: key listings and the dashboard's overview document.

  Nothing here ever contains a gateway key, its hash, a provider key or a
  webhook secret. Upstreams are shown by host only.
  """
  alias OmnigateControl.{ConfigStore, Jobs, Keys, Ledger}

  @doc "One key as the admin API and the dashboard show it."
  def key_view(key) do
    totals = Keys.totals(key)

    %{
      name: key.name,
      source: key |> Map.get(:source, :file) |> to_string(),
      created_at: Map.get(key, :created_at),
      budget_usd: key.budget_usd,
      rpm: Map.get(key, :rpm, 0),
      models: Map.get(key, :models),
      disabled: Keys.disabled?(key),
      blocked: Keys.over_budget?(key),
      state: Keys.state(key),
      has_webhook_secret: Map.get(key, :webhook_secret) != nil,
      requests: totals.requests,
      errors: totals.errors,
      input_tokens: totals.input_tokens,
      output_tokens: totals.output_tokens,
      jobs: totals.jobs,
      cost_usd: totals.cost_usd
    }
  end

  @doc "Every key, file keys first."
  def keys, do: Enum.map(ConfigStore.get().keys, &key_view/1)

  @doc """
  The dashboard's data, also served as `GET /admin/overview`:

      generated_at  ISO 8601 time
      totals, today {requests, errors, input_tokens, output_tokens, jobs, cost_usd}
                    (today = the current UTC day)
      keys          [key_view]
      requests      recent text requests, newest first
      jobs          recent media jobs, newest first
      config        {upstreams, routes, media: {upstreams, routes, storage,
                    public_base_url}, retention}
  """
  def overview do
    config = ConfigStore.get()
    names = key_names(config.keys)

    %{
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      totals: Ledger.grand_totals(),
      today: Ledger.day_totals(),
      keys: Enum.map(config.keys, &key_view/1),
      requests: Ledger.recent() |> Enum.reject(&(&1["kind"] == "media")) |> Enum.take(25) |> Enum.map(&request_view(&1, names)),
      jobs: Enum.map(Jobs.Store.recent(25), &job_view(&1, names)),
      config: config_view(config)
    }
  end

  # hash (current or from before a rotation) -> key name
  defp key_names(keys), do: for(k <- keys, hash <- Keys.hashes(k), into: %{}, do: {hash, k.name})

  defp request_view(e, names) do
    %{
      ts: e["ts"],
      key: Map.get(names, e["key_sha256"]),
      model: e["route_model"],
      upstream: e["upstream"],
      target_model: e["target_model"],
      status: e["status"],
      stream: e["stream"] == true,
      input_tokens: e["input_tokens"] || 0,
      output_tokens: e["output_tokens"] || 0,
      latency_ms: e["latency_ms"],
      cost_usd: e["cost_usd"] || 0.0,
      attempts: attempts(e["attempts"])
    }
  end

  defp job_view(j, names) do
    view = Jobs.view(j)

    %{
      id: j["id"],
      created_at: j["created_at"],
      key: Map.get(names, j["key_sha256"]),
      model: j["model"],
      status: j["status"],
      upstream: j["upstream"],
      cost_usd: (j["cost_usd"] || 0) * 1.0,
      cached: j["cached"] == true,
      error: get_in(j, ["error", "message"]),
      outputs: Enum.map(view["outputs"] || [], &Map.take(&1, ["url", "content_type", "bytes"])),
      webhook:
        case j["webhook"] do
          nil -> nil
          wh -> %{status: wh["status"], attempts: wh["attempts"] || 0}
        end,
      attempts: attempts(j["attempts"])
    }
  end

  defp attempts(list), do: Enum.map(list || [], &%{upstream: &1["upstream"], outcome: &1["outcome"]})

  defp config_view(config) do
    media = config.media

    %{
      upstreams: Enum.map(config.upstreams, &%{name: &1.name, kind: &1.kind, host: host(&1.base_url)}),
      routes:
        Enum.map(config.routes, fn r ->
          %{
            model: r.model,
            strategy: Map.get(r, :strategy, "failover"),
            targets: Enum.map(r.targets, &%{upstream: &1.upstream, model: &1.model, weight: Map.get(&1, :weight, 1)})
          }
        end),
      media: %{
        public_base_url: media.public_base_url,
        upstreams: Enum.map(media.upstreams, &%{name: &1.name, kind: &1.kind, host: host(&1.base_url)}),
        routes:
          Enum.map(media.routes, fn r ->
            %{model: r.model, cache_ttl_s: r.cache_ttl_s, targets: Enum.map(r.targets, &%{upstream: &1.upstream, model: &1.model})}
          end),
        storage:
          case media.storage do
            %{kind: "s3"} = s -> %{kind: "s3", bucket: s.bucket, host: host(s.endpoint), prefix: s.prefix}
            _ -> %{kind: "local"}
          end
      },
      retention: Map.get(config, :retention, %{jobs_days: 0, ledger_ids_days: 0})
    }
  end

  # Host and port only: a base URL may carry a path or, by mistake, credentials.
  defp host(url) do
    case URI.parse(url || "") do
      %URI{host: host, port: port, scheme: scheme} when is_binary(host) ->
        default = if scheme == "https", do: 443, else: 80
        if port in [nil, default], do: host, else: "#{host}:#{port}"

      _ ->
        "?"
    end
  end
end
