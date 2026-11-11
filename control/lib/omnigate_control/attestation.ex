defmodule OmnigateControl.Attestation do
  @moduledoc """
  Attested upstreams: providers that run inside confidential hardware and can
  prove it.

  A text upstream in the config may carry

      "attestation": {
        "provider": "near",
        "accepted_tcb": ["UpToDate"],
        "gpu": "if_present",
        "max_age_s": 900,
        "measurements": {
          "gateway_app_compose_sha256": [],
          "model_app_compose_sha256": [],
          "gateway_mr_td": [],
          "model_mr_td": []
        }
      }

  Then every target on that upstream is only used while its evidence has
  been verified, and verified recently: `OmnigateControl.Attestation.Manager`
  checks each (upstream, model) with a fresh nonce when the config is loaded
  and again before `max_age_s` runs out. A target that is not verified is
  left out by the data plane like one that is down; when no target is left
  the client gets a 503 `attestation_unverified`.

  This module holds what does not need a process: the setting, one check
  from report to verdict, and the views of a result that the admin API and
  the data-plane snapshot show.

  What a pass means and does not mean is written down in
  `docs/attestation.md`. In short: genuine Intel TDX hardware, in an
  accepted patch state, not in debug mode, running the configuration the
  report shows, answered our nonce just now. Whether that configuration is
  software to trust is the operator's policy (`measurements`), which is
  empty unless set.
  """
  alias OmnigateControl.Attestation.{Near, Tdx}

  @providers ~w(near)
  @gpu_modes ~w(require if_present skip)
  @tcb_statuses ~w(UpToDate SWHardeningNeeded ConfigurationNeeded ConfigurationAndSWHardeningNeeded OutOfDate OutOfDateConfigurationNeeded)
  @measurement_lists ~w(gateway_app_compose_sha256 model_app_compose_sha256 gateway_mr_td model_mr_td)
  @fields ~w(provider accepted_tcb gpu max_age_s measurements)

  @default_max_age_s 900

  @type setting :: %{
          provider: String.t(),
          accepted_tcb: [String.t()],
          gpu: String.t(),
          max_age_s: pos_integer,
          measurements: %{String.t() => [String.t()]}
        }

  # ---- The setting ---------------------------------------------------------

  @doc """
  Validate an upstream's `"attestation"` as written (JSON). Returns the
  normalised setting, nil when there is none, or raises `ArgumentError` with
  `where` in front. Strict: a setting that is not understood must not be
  taken for one that is.
  """
  @spec normalize!(term, String.t()) :: setting | nil
  def normalize!(nil, _where), do: nil

  def normalize!(%{} = raw, where) do
    unknown = Map.keys(raw) -- @fields

    if unknown != [] do
      raise ArgumentError,
            "#{where}: \"attestation\" has no setting named #{unknown |> Enum.sort() |> Enum.take(3) |> Enum.map_join(", ", &inspect/1)} (it has: #{Enum.join(@fields, ", ")})"
    end

    provider = raw["provider"]

    if provider not in @providers do
      raise ArgumentError, "#{where}: \"attestation\".\"provider\" must be one of #{Enum.join(@providers, ", ")}, got #{inspect(provider)}"
    end

    %{
      provider: provider,
      accepted_tcb: accepted_tcb!(raw["accepted_tcb"], where),
      gpu: gpu!(raw["gpu"], where),
      max_age_s: max_age!(raw["max_age_s"], where),
      measurements: measurements!(raw["measurements"], where)
    }
  end

  def normalize!(other, where) do
    raise ArgumentError, "#{where}: \"attestation\" must be an object with #{Enum.join(@fields, ", ")}, got #{inspect(other)}"
  end

  defp accepted_tcb!(nil, _where), do: ["UpToDate"]

  defp accepted_tcb!(list, where) do
    if is_list(list) and list != [] and Enum.all?(list, &(&1 in @tcb_statuses)) do
      Enum.uniq(list)
    else
      raise ArgumentError,
            "#{where}: \"attestation\".\"accepted_tcb\" must be a list of one or more of #{Enum.join(@tcb_statuses, ", ")}, got #{inspect(list)}"
    end
  end

  defp gpu!(nil, _where), do: "if_present"
  defp gpu!(mode, _where) when mode in @gpu_modes, do: mode
  defp gpu!(other, where), do: raise(ArgumentError, "#{where}: \"attestation\".\"gpu\" must be one of #{Enum.join(@gpu_modes, ", ")}, got #{inspect(other)}")

  defp max_age!(nil, _where), do: @default_max_age_s
  defp max_age!(n, _where) when is_integer(n) and n >= 60 and n <= 86_400, do: n

  defp max_age!(other, where) do
    raise ArgumentError, "#{where}: \"attestation\".\"max_age_s\" must be a whole number of seconds from 60 to 86400, got #{inspect(other)}"
  end

  defp measurements!(nil, _where), do: Map.new(@measurement_lists, &{&1, []})

  defp measurements!(%{} = raw, where) do
    unknown = Map.keys(raw) -- @measurement_lists

    if unknown != [] do
      raise ArgumentError,
            "#{where}: \"attestation\".\"measurements\" has no list named #{unknown |> Enum.sort() |> Enum.take(3) |> Enum.map_join(", ", &inspect/1)} (it has: #{Enum.join(@measurement_lists, ", ")})"
    end

    Map.new(@measurement_lists, fn name ->
      # SHA-256 is 32 bytes, MRTD (SHA-384) 48.
      bytes = if String.ends_with?(name, "sha256"), do: 32, else: 48
      list = raw[name] || []

      ok =
        is_list(list) and length(list) <= 64 and
          Enum.all?(list, fn v -> is_binary(v) and byte_size(v) == 2 * bytes and match?({:ok, _}, Base.decode16(v, case: :mixed)) end)

      if not ok do
        raise ArgumentError,
              "#{where}: \"attestation\".\"measurements\".#{inspect(name)} must be a list of at most 64 values of #{2 * bytes} hexadecimal characters, got #{inspect(list)}"
      end

      {name, Enum.map(list, &String.downcase/1)}
    end)
  end

  defp measurements!(other, where) do
    raise ArgumentError, "#{where}: \"attestation\".\"measurements\" must be an object of lists, got #{inspect(other)}"
  end

  # ---- What has to be attested ---------------------------------------------

  @doc """
  Every (upstream, model) the config routes to on an upstream that has an
  attestation setting: `[%{upstream, model, base_url, setting}]`, once each.
  """
  def wanted(config) do
    attested = for u <- config.upstreams, is_map(Map.get(u, :attestation)), into: %{}, do: {u.name, u}

    for route <- config.routes, target <- route.targets, up = attested[target.upstream], uniq: true do
      %{upstream: up.name, model: target.model, base_url: up.base_url, setting: up.attestation}
    end
  end

  # ---- One check -----------------------------------------------------------

  @doc """
  One check from nothing to a verdict: a fresh nonce, the report for `model`
  from `base_url`, every verification step, then the operator's measurement
  policy.

  Options: `:collateral` (a caching function from quote bytes to
  `{:ok, collateral}`), `:http`, `:now`, `:nonce`, and, for tests only,
  `:trusted_root_der`. Nothing in the configuration or the environment can
  set the last one.

  `{:ok, evidence}` or `{:error, reason}`; `reason` is `{atom, detail}`.
  """
  def check(base_url, model, setting, opts \\ []) do
    nonce = Keyword.get(opts, :nonce) || Near.nonce()
    pass = Keyword.take(opts, [:http, :collateral, :now, :trusted_root_der])

    verify_opts =
      [model: model, accepted_statuses: setting.accepted_tcb, gpu: gpu_mode(setting.gpu)] ++
        pass ++ if(Keyword.has_key?(opts, :collateral), do: [], else: [collateral: &Tdx.fetch_collateral(&1, Keyword.take(opts, [:http]))])

    with {:ok, body} <- Near.fetch_report(attestation_base(base_url), model, nonce, Keyword.take(opts, [:http])),
         {:ok, verified} <- Near.verify_all(body, nonce, verify_opts),
         :ok <- measurements(verified, setting.measurements) do
      {:ok, verified}
    end
  end

  defp gpu_mode("require"), do: :require
  defp gpu_mode("skip"), do: :skip
  defp gpu_mode(_), do: :if_present

  # An upstream's base URL is where `/v1/...` hangs; the attestation report
  # is under `/v1` too.
  defp attestation_base(base_url), do: base_url |> String.trim_trailing("/") |> String.replace_suffix("/v1", "")

  @doc """
  The operator's policy on what was measured. An empty list accepts any
  value: the check then says "genuine hardware running exactly this", not
  "running something I approved".
  """
  def measurements(verified, lists) do
    checks =
      [{"gateway_app_compose_sha256", [verified.gateway], :app_compose_sha256}, {"gateway_mr_td", [verified.gateway], :mr_td}] ++
        [{"model_app_compose_sha256", verified.models, :app_compose_sha256}, {"model_mr_td", verified.models, :mr_td}]

    Enum.find_value(checks, :ok, fn {name, reports, field} ->
      case lists[name] || [] do
        [] ->
          nil

        allowed ->
          case Enum.find(reports, &(Map.fetch!(&1, field) not in allowed)) do
            nil -> nil
            report -> {:error, {:measurement_not_allowed, {name, Map.fetch!(report, field)}}}
          end
      end
    end)
  end

  @doc """
  Is this failure one that says nothing about the evidence (the report, the
  collateral or NVIDIA's verdict could not be fetched)? Then what was
  verified before still stands until it is too old; any other failure
  withdraws it at once.
  """
  def transient?({reason, _}) when reason in [:report_unavailable, :rate_limited, :collateral_unavailable, :gpu_verdict_unavailable], do: true
  def transient?({wrapper, {_index, inner}}) when wrapper == :model_report_failed, do: transient?(inner)
  def transient?({wrapper, inner}) when wrapper == :gateway_report_failed, do: transient?(inner)
  def transient?(_), do: false

  # ---- Views ---------------------------------------------------------------

  @doc """
  A manager entry as the admin API shows it: the verdict, when it was
  reached, the policy it was reached under and the evidence it rests on.
  Nothing in it is secret: an attestation report is public.
  """
  def view(entry, now \\ System.os_time(:second)) do
    verified = OmnigateControl.Attestation.Manager.verified?(entry, now)

    %{
      upstream: entry.upstream,
      model: entry.model,
      provider: entry.setting.provider,
      state: if(entry.state == :verified and not verified, do: "failed", else: Atom.to_string(entry.state)),
      verified: verified,
      reason: entry.reason,
      reason_code: entry.reason_code,
      checked_at: entry.checked_at,
      age_s: entry.checked_at && now - entry.checked_at,
      verified_since: entry.verified_since,
      until: entry.until,
      max_age_s: entry.max_age_s,
      last_attempt_at: entry.last_attempt_at,
      next_check_at: entry.next_check_at,
      checks: entry.checks,
      policy: Map.take(entry.setting, [:accepted_tcb, :gpu, :measurements]),
      evidence: entry.evidence && evidence_view(entry.evidence)
    }
  end

  defp evidence_view(e) do
    %{nonce: e.nonce, verified_at: e.verified_at, gateway: report_view(e.gateway), models: Enum.map(e.models, &report_view/1)}
  end

  defp report_view(r) do
    %{
      tcb_status: r.status,
      advisory_ids: r.advisory_ids,
      quote_version: r.quote_version,
      td_attributes: r.td_attributes,
      report_data: r.report_data,
      signing_algo: r.signing_algo,
      signing_address: r.signing_address,
      tls_cert_fingerprint: r.tls_cert_fingerprint,
      app_compose_sha256: r.app_compose_sha256,
      mr_td: r.mr_td,
      rtmr3: r.rtmr3,
      gpu: Atom.to_string(r.gpu),
      collateral_expires_at: r.collateral_expires_at
    }
  end

  # ---- Words ---------------------------------------------------------------

  @doc "A failure as one line an operator can act on."
  def describe({:gateway_report_failed, inner}), do: "the provider's gateway: " <> describe(inner)
  def describe({:model_report_failed, {index, inner}}), do: "model report #{index + 1}: " <> describe(inner)
  def describe({:report_unavailable, {status, body}}) when is_integer(status), do: "no attestation report (HTTP #{status}: #{clip(provider_words(body))})"
  def describe({:report_unavailable, why}), do: "no attestation report (#{clip(inspect(why))})"
  def describe({:rate_limited, _}), do: "the provider is rate limiting attestation requests"
  def describe({:bad_report, why}), do: "malformed report: #{clip(to_string(why))}"
  def describe({:gateway_report_missing, _}), do: "the answer has no gateway report"
  def describe({:model_reports_missing, model}), do: "the provider returned no attestation for model #{clip(to_string(model))}"
  def describe({:wrong_model, name}), do: "the report is for another model (#{clip(to_string(name))})"
  def describe({:nonce_mismatch, where}), do: "the report does not carry our nonce (#{where}): it is not fresh"
  def describe({:signer_not_bound, _}), do: "the quote does not bind the signing key the report names"
  def describe({:tcb_status_not_accepted, {status, advisories}}), do: "platform status #{status} is not accepted#{advisories(advisories)}"
  def describe({:debug_enabled, _}), do: "the machine is in debug mode"
  def describe({:configuration_mismatch, hash}), do: "the configuration shown (sha256 #{hash}) is not the one measured"
  def describe({:event_log_mismatch, _}), do: "the event log does not replay to the measured value"
  def describe({:measurement_not_allowed, {list, value}}), do: "#{list} #{value} is not on the configured allowlist"
  def describe({:gpu_evidence_missing, _}), do: "no GPU evidence, and the setting requires it"
  def describe({:gpu_verdict_failed, _}), do: "NVIDIA did not accept the GPU evidence"
  def describe({:gpu_verdict_unavailable, why}), do: "NVIDIA's attestation service could not be reached (#{clip(inspect(why))})"
  def describe({:collateral_unavailable, {url, why}}), do: "Intel's collateral could not be fetched (#{clip(to_string(url))}: #{clip(inspect(why))})"
  def describe({:collateral_unavailable, why}), do: "Intel's collateral could not be fetched (#{clip(inspect(why))})"
  def describe({reason, detail}) when is_atom(reason), do: "#{reason |> Atom.to_string() |> String.replace("_", " ")}#{detail(detail)}"
  def describe(other), do: clip(inspect(other))

  @doc "The failure's name, for a metric label or a machine: the innermost reason."
  def code({wrapper, {_index, inner}}) when wrapper == :model_report_failed, do: code(inner)
  def code({wrapper, inner}) when wrapper == :gateway_report_failed, do: code(inner)
  def code({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  def code(_), do: "error"

  # A provider's error is usually `{"error": {"message": ...}}`; the message
  # is what an operator wants to read. Anything else is shown as it came.
  defp provider_words(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) -> message
      _ -> body
    end
  end

  defp provider_words(other), do: inspect(other)

  defp advisories([]), do: ""
  defp advisories(list) when is_list(list), do: " (advisories: #{list |> Enum.take(8) |> Enum.join(", ")})"
  defp advisories(_), do: ""

  defp detail(nil), do: ""
  defp detail(d) when is_binary(d), do: ": " <> clip(d)
  defp detail(d), do: ": " <> clip(inspect(d))

  # Whatever a provider sent back ends up on one line of bounded length.
  defp clip(text), do: OmnigateControl.Text.line(text, 200)
end
