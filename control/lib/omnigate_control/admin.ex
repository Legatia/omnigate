defmodule OmnigateControl.Admin do
  @moduledoc """
  What operators see: key listings and the dashboard's overview document.

  Nothing here ever contains a gateway key, its hash, a provider key or a
  webhook secret. Upstreams are shown by host only.
  """
  alias OmnigateControl.{Audit, ConfigStore, Jobs, Keys, Ledger, Privacy, Redactions, Rejections}

  @doc "One key as the admin API and the dashboard show it."
  def key_view(key) do
    totals = Keys.totals(key)
    burned = Keys.credits_burned(key)

    %{
      name: key.name,
      source: key |> Map.get(:source, :file) |> to_string(),
      created_at: Map.get(key, :created_at),
      budget_usd: key.budget_usd,
      # What the budget covers, how much of it is used, and when it starts over.
      budget_period: Keys.budget_period(key),
      period_spend_usd: Keys.period_spend(key),
      period_resets_at: Keys.period_resets_at(key),
      rpm: Map.get(key, :rpm, 0),
      # Requests in flight at once on the data plane; 0 = its default.
      max_concurrent: Map.get(key, :max_concurrent, 0),
      models: Map.get(key, :models),
      max_open_jobs: Keys.max_open_jobs(key),
      max_jobs_per_day: Keys.max_jobs_per_day(key),
      disabled: Keys.disabled?(key),
      blocked: Keys.over_budget?(key),
      state: Keys.state(key),
      # True for a managed key that a config-file key of the same name has put out of use.
      shadowed: false,
      has_webhook_secret: Map.get(key, :webhook_secret) != nil,
      # Privacy mode: the setting (null when off), and the same in a few words.
      privacy: Privacy.view(Map.get(key, :privacy)),
      privacy_summary: Privacy.summary(Map.get(key, :privacy)),
      requests: totals.requests,
      errors: totals.errors,
      input_tokens: totals.input_tokens,
      cached_input_tokens: totals.cached_input_tokens,
      cache_write_input_tokens: totals.cache_write_input_tokens,
      output_tokens: totals.output_tokens,
      cached_responses: totals.cached_responses,
      jobs: totals.jobs,
      # What the providers cost, and what that burned of the key's credit
      # (the same number unless a burn multiplier applies).
      cost_usd: totals.cost_usd,
      credits_burned_usd: burned,
      # A prepaid key's credit (null for any other key): see `Credits`.
      credits: OmnigateControl.Credits.view(key, burned)
    }
  end

  @doc "Every key, file keys first, then managed ones; shadowed managed keys last, marked as such."
  def keys do
    Enum.map(ConfigStore.get().keys, &key_view/1) ++
      Enum.map(ConfigStore.shadowed_keys(), &(&1 |> key_view() |> Map.merge(%{state: "shadowed", shadowed: true, blocked: false})))
  end

  @doc """
  The dashboard's data, also served as `GET /admin/overview`:

      generated_at  ISO 8601 time
      totals, today {requests, errors, input_tokens, cached_input_tokens,
                    cache_write_input_tokens, output_tokens, cached_responses,
                    jobs, cost_usd}  (today = the current UTC day)
      keys          [key_view]
      requests      recent text requests, newest first
      jobs          recent media jobs, newest first
      rejected      requests data planes refused before routing, by key and
                    reason, since this control plane started
      audit         the latest admin actions, newest first
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
      # Including managed keys shadowed by a file key of the same name: an
      # operator must be able to see why such a key stopped working.
      keys: keys(),
      requests: Ledger.recent() |> Enum.reject(&(&1["kind"] == "media")) |> Enum.take(25) |> Enum.map(&request_view(&1, names)),
      jobs: Enum.map(Jobs.Store.recent(25), &job_view(&1, names)),
      rejected: Enum.take(Rejections.all(), 50),
      # Values privacy mode replaced before a provider saw them: counts only.
      redactions: Enum.take(Redactions.all(), 50),
      audit: Audit.recent(10),
      config: config_view(config)
    }
  end

  @doc """
  One page of the usage feed (`GET /admin/events`): every recorded event,
  text requests and media jobs alike, oldest first, each with the cursor to
  continue after it. `key` limits the page to one key (by name, across its
  rotations). No content of any request is in the ledger, so none is here.

  Returns `{:ok, %{events, next, more, gap}}`, `{:error, :invalid_cursor}`
  or `{:error, :key_not_found}`.
  """
  def events(cursor, limit, key_name \\ nil) do
    all = ConfigStore.get().keys ++ ConfigStore.shadowed_keys()
    names = key_names(all)

    keep =
      case key_name do
        nil -> {:ok, fn _ -> true end}
        name -> if Enum.any?(all, &(&1.name == name)), do: {:ok, fn e -> Map.get(names, e["key_sha256"]) == name end}, else: {:error, :key_not_found}
      end

    with {:ok, keep} <- keep,
         {:ok, page} <- Ledger.events(cursor, limit, keep) do
      {:ok,
       %{
         events: Enum.map(page.events, fn {position, e} -> event_view(e, names, position) end),
         next: cursor_text(page.next),
         more: page.more,
         gap: page.gap
       }}
    end
  end

  @doc "A feed position as the text clients send back, and the reverse (`:error` for anything else)."
  def cursor_text({segment, offset}), do: "#{segment}-#{offset}"

  def parse_cursor(text) when is_binary(text) do
    case Regex.run(~r/\A(\d{1,9})-(\d{1,15})\z/, text) do
      [_, segment, offset] -> {:ok, {String.to_integer(segment), String.to_integer(offset)}}
      _ -> :error
    end
  end

  def parse_cursor(_), do: :error

  # Credit added to a key: a top-up or a bonus.
  defp event_view(%{"kind" => "credit"} = e, names, position) do
    %{
      cursor: cursor_text(position),
      id: e["id"],
      kind: "credit",
      ts: e["ts"],
      received_at: e["received_at"],
      key: Map.get(names, e["key_sha256"]),
      amount_usd: e["amount_usd"] || 0.0,
      source: e["source"],
      reference: e["reference"],
      budget_usd: e["budget_usd"],
      cost_usd: 0.0,
      credits_usd: 0.0
    }
  end

  defp event_view(e, names, position) do
    media = e["kind"] == "media"

    %{
      cursor: cursor_text(position),
      # A text request's id is the `x-omnigate-request-id` its client got; a
      # media job's is the job id.
      id: e["id"],
      kind: if(media, do: "media", else: "text"),
      ts: e["ts"],
      received_at: e["received_at"],
      # null for a key that has been deleted since.
      key: Map.get(names, e["key_sha256"]),
      tag: if(is_binary(e["tag"]), do: e["tag"]),
      model: e["route_model"],
      upstream: e["upstream"],
      target_model: e["target_model"],
      status: e["status"],
      stream: e["stream"] == true,
      input_tokens: e["input_tokens"] || 0,
      cached_input_tokens: e["cached_input_tokens"] || 0,
      cache_write_input_tokens: e["cache_write_input_tokens"] || 0,
      output_tokens: e["output_tokens"] || 0,
      outputs: if(media, do: e["outputs"] || 0),
      cached: e["cached"] == true,
      estimated: e["estimated"] == true,
      latency_ms: e["latency_ms"],
      # What the provider cost, and what the event burned of the key's
      # credit: the cost times its burn multiplier at the time.
      cost_usd: e["cost_usd"] || 0.0,
      credits_usd: if(is_number(e["credits_usd"]), do: e["credits_usd"], else: e["cost_usd"] || 0.0)
    }
  end

  # hash (current or from before a rotation) -> key name
  defp key_names(keys), do: for(k <- keys, hash <- Keys.hashes(k), into: %{}, do: {hash, k.name})

  defp request_view(e, names) do
    %{
      # The request id the client was given (`x-omnigate-request-id`).
      id: e["id"],
      ts: e["ts"],
      key: Map.get(names, e["key_sha256"]),
      model: e["route_model"],
      upstream: e["upstream"],
      target_model: e["target_model"],
      status: e["status"],
      stream: e["stream"] == true,
      input_tokens: e["input_tokens"] || 0,
      cached_input_tokens: e["cached_input_tokens"] || 0,
      cache_write_input_tokens: e["cache_write_input_tokens"] || 0,
      output_tokens: e["output_tokens"] || 0,
      # Answered from the data plane's response cache, at no cost.
      cached: e["cached"] == true,
      # The client left mid-stream and the provider's final usage never
      # came: the token counts are the data plane's estimate.
      estimated: e["estimated"] == true,
      latency_ms: e["latency_ms"],
      cost_usd: e["cost_usd"] || 0.0,
      credits_usd: if(is_number(e["credits_usd"]), do: e["credits_usd"], else: e["cost_usd"] || 0.0),
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
            cache_ttl_s: Map.get(r, :cache_ttl_s, 0),
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
      retention:
        Map.merge(
          %{jobs_days: 0, ledger_ids_days: 0, ledger_days: 0, delete_bucket_objects: true, private_outputs_hours: 24, receipts_days: 30},
          Map.get(config, :retention, %{})
        )
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
