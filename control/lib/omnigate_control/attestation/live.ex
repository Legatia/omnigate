defmodule OmnigateControl.Attestation.Live do
  @moduledoc """
  One attestation check against a real provider, from the command line, with
  the same code the running control plane uses. It needs no API key, no
  config and no running gateway, and it changes nothing:

      mix run --no-start -e "OmnigateControl.Attestation.Live.main()"
      mix run --no-start -e 'OmnigateControl.Attestation.Live.main(["z-ai/glm-5.3-flash", "--gpu", "require"])'

  In a release: `bin/omnigate_control eval 'OmnigateControl.Attestation.Live.main()'`.

  Arguments: model ids (default: the first text model NEAR serves itself,
  from its public model list), `--base URL` (default
  `https://cloud-api.near.ai`), `--gpu require|if_present|skip`, `--all`
  (every text model NEAR serves itself) and `--json` (print the evidence as
  JSON instead of the checklist).

  It prints what was checked and ends with status 0 when every model
  verified, 1 otherwise. `tools/near_live.py` runs it.
  """
  alias OmnigateControl.Attestation
  alias OmnigateControl.Attestation.{Http, Tdx}

  @base "https://cloud-api.near.ai"

  @doc "Run the check and stop the VM with its status."
  def main(args \\ []) do
    System.halt(if run(args) == :ok, do: 0, else: 1)
  end

  @doc "Run the check; `:ok` when everything verified, `:error` otherwise."
  def run(args \\ []) do
    {:ok, _} = Application.ensure_all_started(:ssl)
    {opts, models} = parse(args, %{base: @base, gpu: "if_present", all: false, json: false}, [])
    setting = Attestation.normalize!(%{"provider" => "near", "gpu" => opts.gpu}, "command line")

    models =
      case models do
        [] -> listed(opts.base, opts.all)
        given -> {:ok, given}
      end

    case models do
      {:error, why} ->
        IO.puts("could not list models at #{opts.base}: #{why}")
        :error

      {:ok, models} ->
        cache = :ets.new(:live_collateral, [:set, :public])
        results = Enum.map(models, &one(&1, opts, setting, cache))
        failed = Enum.count(results, &(&1 != :ok))
        if not opts.json, do: IO.puts("\n#{length(results) - failed} of #{length(results)} verified")
        if failed == 0, do: :ok, else: :error
    end
  end

  defp parse(["--base", url | rest], opts, models), do: parse(rest, %{opts | base: url}, models)
  defp parse(["--gpu", mode | rest], opts, models), do: parse(rest, %{opts | gpu: mode}, models)
  defp parse(["--all" | rest], opts, models), do: parse(rest, %{opts | all: true}, models)
  defp parse(["--json" | rest], opts, models), do: parse(rest, %{opts | json: true}, models)
  defp parse([model | rest], opts, models), do: parse(rest, opts, models ++ [model])
  defp parse([], opts, models), do: {opts, models}

  # The models NEAR serves from its own confidential machines are the ones
  # it lists as its own; the others are relayed to third parties and have no
  # attestation.
  defp listed(base, all?) do
    with {:ok, 200, _, body} <- Http.get(String.trim_trailing(base, "/") <> "/v1/models", [{"accept", "application/json"}]),
         {:ok, %{"data" => data}} when is_list(data) <- JSON.decode(body) do
      own = for m <- data, is_map(m), m["owned_by"] == "nearai", "text" in (m["output_modalities"] || ["text"]), is_binary(m["id"]), do: m["id"]

      cond do
        own == [] -> {:error, "the list names no model owned by nearai"}
        all? -> {:ok, own}
        "z-ai/glm-5.3-flash" in own -> {:ok, ["z-ai/glm-5.3-flash"]}
        true -> {:ok, [hd(own)]}
      end
    else
      {:ok, status, _, _} -> {:error, "HTTP #{status}"}
      other -> {:error, inspect(other, limit: 5, printable_limit: 120)}
    end
  end

  defp one(model, opts, setting, cache) do
    collateral = fn quote ->
      with {:ok, key} <- Tdx.collateral_key(quote) do
        case :ets.lookup(cache, key) do
          [{_, c}] ->
            {:ok, c}

          [] ->
            with {:ok, c} <- Tdx.fetch_collateral(quote) do
              :ets.insert(cache, {key, c})
              {:ok, c}
            end
        end
      end
    end

    {micros, result} = :timer.tc(fn -> Attestation.check(opts.base, model, setting, collateral: collateral) end)

    case {result, opts.json} do
      {{:ok, evidence}, true} ->
        entry = %{
          upstream: opts.base,
          model: model,
          setting: setting,
          state: :verified,
          reason: nil,
          reason_code: nil,
          evidence: evidence,
          checked_at: evidence.verified_at,
          verified_since: evidence.verified_at,
          until: evidence.verified_at + setting.max_age_s,
          max_age_s: setting.max_age_s,
          last_attempt_at: evidence.verified_at,
          next_check_at: nil,
          checks: 1
        }

        IO.puts(JSON.encode!(Attestation.view(entry)))
        :ok

      {{:ok, evidence}, false} ->
        IO.puts("\nmodel #{model} at #{opts.base}   nonce #{evidence.nonce}")
        report("the provider's gateway", evidence.gateway, setting)
        for {m, i} <- Enum.with_index(evidence.models), do: report("model report #{i + 1} of #{length(evidence.models)}", m, setting)
        IO.puts("  VERIFIED in #{div(micros, 1000)} ms")
        :ok

      {{:error, reason}, true} ->
        IO.puts(
          JSON.encode!(%{
            upstream: opts.base,
            model: model,
            state: "failed",
            verified: false,
            reason: Attestation.describe(reason),
            reason_code: Attestation.code(reason)
          })
        )

        :error

      {{:error, reason}, false} ->
        IO.puts("\nmodel #{model} at #{opts.base}\n  NOT VERIFIED: #{Attestation.describe(reason)}")
        :error
    end
  end

  defp report(name, r, setting) do
    short = &String.slice(&1, 0, 16)

    IO.puts("""
      [ok] #{name}
           Intel TDX quote (v#{r.quote_version}) genuine; certificate chain ends at the pinned Intel SGX Root CA; nothing revoked
           platform status #{r.status}#{if r.advisory_ids != [], do: " " <> inspect(r.advisory_ids), else: ""} (accepted: #{Enum.join(setting.accepted_tcb, ", ")})
           not in debug mode (TD attributes #{r.td_attributes})
           the quote binds our nonce and the signing key #{r.signing_algo}:#{short.(r.signing_address)}…
           configuration shown is the one measured: app_compose sha256 #{short.(r.app_compose_sha256)}…
           event log replays to the measured RTMR3 #{short.(r.rtmr3)}…
           GPU evidence: #{r.gpu}\
    """)
  end
end
