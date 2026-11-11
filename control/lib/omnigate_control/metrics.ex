defmodule OmnigateControl.Metrics do
  @moduledoc """
  Prometheus metrics for `GET /metrics` (text exposition format 0.0.4).

  Everything is computed on request from state the control plane already
  keeps (the ledger totals, the job store, the config), so there is nothing
  to instrument and nothing extra to store. Per-key series are labelled with
  the key's configured name, never its hash.
  """
  alias OmnigateControl.{Attestation, ConfigStore, Counters, Keys, Ledger, Redactions, Rejections}
  alias OmnigateControl.Jobs.Store

  @job_statuses ~w(queued running succeeded failed canceled)
  @webhook_states ~w(waiting pending retrying delivered failed)

  @doc "The whole metrics page."
  def render do
    config = ConfigStore.get()
    meta = ConfigStore.meta()
    ledger = Ledger.stats()
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    attestations = Attestation.Manager.all()
    now_s = System.os_time(:second)

    # Across rotations of a managed key, so its series never restart.
    keys = Enum.map(config.keys, fn k -> {k, Keys.totals(k)} end)
    per_key = fn fun -> Enum.map(keys, fn {k, t} -> {[key: k.name], fun.(k, t)} end) end

    # Counted in one pass over the job table, without copying it.
    {by_status, by_webhook} =
      Store.fold({%{}, %{}}, fn job, {by_status, by_webhook} ->
        by_webhook = if is_map(job["webhook"]), do: Map.update(by_webhook, job["webhook"]["status"], 1, &(&1 + 1)), else: by_webhook
        {Map.update(by_status, job["status"], 1, &(&1 + 1)), by_webhook}
      end)

    [
      metric("omnigate_build_info", :gauge, "Build information; the value is always 1.", [{[version: version()], 1}]),
      metric("omnigate_uptime_seconds", :gauge, "Seconds since the control plane started.", [{[], uptime_ms / 1000}]),
      metric("omnigate_config_reloads_total", :counter, "Config file reloads applied since start.", [{[], meta.reloads}]),
      metric("omnigate_config_last_reload_timestamp_seconds", :gauge, "Unix time the config was last loaded.", [
        {[], meta.loaded_at_ms / 1000}
      ]),
      metric("omnigate_key_requests_total", :counter, "Requests and media jobs recorded in the ledger, per gateway key.", per_key.(fn _, t -> t.requests end)),
      metric(
        "omnigate_key_errors_total",
        :counter,
        "Recorded requests that ended with status 400 or above, per gateway key.",
        per_key.(fn _, t -> t.errors end)
      ),
      metric("omnigate_key_input_tokens_total", :counter, "Input tokens billed, per gateway key.", per_key.(fn _, t -> t.input_tokens end)),
      metric(
        "omnigate_key_cached_input_tokens_total",
        :counter,
        "Input tokens read from a provider's prompt cache, per gateway key.",
        per_key.(fn _, t -> t.cached_input_tokens end)
      ),
      metric(
        "omnigate_key_cache_write_input_tokens_total",
        :counter,
        "Input tokens written to a provider's prompt cache, per gateway key.",
        per_key.(fn _, t -> t.cache_write_input_tokens end)
      ),
      metric("omnigate_key_output_tokens_total", :counter, "Output tokens billed, per gateway key.", per_key.(fn _, t -> t.output_tokens end)),
      metric(
        "omnigate_key_cached_responses_total",
        :counter,
        "Requests answered from the data plane's response cache, per gateway key.",
        per_key.(fn _, t -> t.cached_responses end)
      ),
      metric("omnigate_key_jobs_total", :counter, "Media jobs recorded in the ledger, per gateway key.", per_key.(fn _, t -> t.jobs end)),
      metric("omnigate_key_cost_usd_total", :counter, "Spend in US dollars, per gateway key.", per_key.(fn _, t -> t.cost_usd end)),
      metric(
        "omnigate_key_budget_usd",
        :gauge,
        "Budget in US dollars, for keys that have one.",
        for({k, _} <- keys, k.budget_usd != nil, do: {[key: k.name], k.budget_usd})
      ),
      metric(
        "omnigate_key_period_cost_usd",
        :gauge,
        "Spend in US dollars in the key's current budget period (month, day, or everything for a total budget).",
        per_key.(fn k, _ -> Keys.period_spend(k) end)
      ),
      metric(
        "omnigate_key_blocked",
        :gauge,
        "1 when the key has spent its budget for the current period and is refused, else 0.",
        per_key.(fn k, _ -> if(Keys.over_budget?(k), do: 1, else: 0) end)
      ),
      metric(
        "omnigate_rejected_requests_total",
        :counter,
        "Requests data planes refused before routing, by key name and reason, since this control plane started.",
        Enum.map(Rejections.all(), &{[key: &1.key, reason: &1.reason], &1.count})
      ),
      metric(
        "omnigate_redactions_total",
        :counter,
        "Values privacy mode replaced by placeholders before a provider saw them, by key name and class, since this control plane started.",
        Enum.map(Redactions.all(), &{[key: &1.key, class: &1.class], &1.count})
      ),
      metric(
        "omnigate_key_private",
        :gauge,
        "1 when the key has privacy mode switched on (any part of it), else 0.",
        per_key.(fn k, _ -> if(Map.get(k, :privacy), do: 1, else: 0) end)
      ),
      metric("omnigate_jobs", :gauge, "Media jobs currently in the job store, by status.", Enum.map(@job_statuses, &{[status: &1], Map.get(by_status, &1, 0)})),
      metric(
        "omnigate_webhooks",
        :gauge,
        "Webhook deliveries of the jobs currently in the job store, by state.",
        Enum.map(@webhook_states, &{[state: &1], Map.get(by_webhook, &1, 0)})
      ),
      metric("omnigate_ledger_events_total", :counter, "Usage events in the ledger.", [{[], ledger.events}]),
      metric("omnigate_ledger_dedup_ids", :gauge, "Event ids held in memory to reject resent events.", [{[], ledger.dedup_ids}]),
      metric(
        "omnigate_ledger_invalid_events_total",
        :counter,
        "Usage events dropped because they were malformed, since this control plane started.",
        [{[], Counters.get(:ledger_invalid_events)}]
      ),
      metric(
        "omnigate_attestation_verified",
        :gauge,
        "1 while the attestation of an upstream's model is verified and recent enough, 0 otherwise (its targets are then not used).",
        Enum.map(attestations, fn e -> {[upstream: e.upstream, model: e.model], if(Attestation.Manager.verified?(e, now_s), do: 1, else: 0)} end)
      ),
      metric(
        "omnigate_attestation_age_seconds",
        :gauge,
        "Seconds since the attestation of an upstream's model last verified; absent until it has.",
        for(e <- attestations, e.checked_at, do: {[upstream: e.upstream, model: e.model], now_s - e.checked_at})
      ),
      metric(
        "omnigate_attestation_checks_total",
        :counter,
        "Attestation checks since start, by outcome: ok, failed (the evidence did not hold), unavailable (it could not be fetched).",
        Enum.map(Attestation.Manager.counts(), fn {outcome, n} -> {[outcome: outcome], n} end)
      ),
      metric(
        "omnigate_ledger_unpriced_events_total",
        :counter,
        "Usage events recorded at $0 because the config has no such route or target, since this control plane started.",
        [{[], Counters.get(:ledger_unpriced_events)}]
      )
    ]
    |> IO.iodata_to_binary()
  end

  defp version, do: :omnigate_control |> Application.spec(:vsn) |> to_string()

  # One metric family: HELP, TYPE, then a line per sample.
  defp metric(name, type, help, samples) do
    [
      "# HELP ",
      name,
      " ",
      escape_help(help),
      "\n",
      "# TYPE ",
      name,
      " ",
      Atom.to_string(type),
      "\n",
      Enum.map(samples, fn {labels, value} -> [name, labels(labels), " ", number(value), "\n"] end)
    ]
  end

  defp labels([]), do: ""

  defp labels(pairs) do
    ["{", pairs |> Enum.map(fn {k, v} -> [Atom.to_string(k), "=\"", escape_label(to_string(v)), "\""] end) |> Enum.intersperse(","), "}"]
  end

  @doc false
  def escape_label(value) do
    value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"") |> String.replace("\n", "\\n")
  end

  defp escape_help(text), do: text |> String.replace("\\", "\\\\") |> String.replace("\n", "\\n")

  defp number(n) when is_integer(n), do: Integer.to_string(n)
  defp number(n) when is_float(n), do: Float.to_string(n)
end
