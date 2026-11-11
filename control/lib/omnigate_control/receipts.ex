defmodule OmnigateControl.Receipts do
  @moduledoc """
  A receipt for each answer that came from an attested upstream: the
  provider's signature over the exact request and response bytes, checked
  against the attestation that was verified before the request.

  The data plane reports, with the usage event of such an answer, the
  SHA-256 of the request body as it was sent, the SHA-256 of the response
  body as it arrived, and the provider's id for the completion
  (`dataplane/src/receipt.zig`). No content reaches this process. For each
  event it then

    1. takes the evidence that was verified *before* the request started
       (`Attestation.Manager.evidence_before/4`): a report fetched afterwards
       proves nothing about the machine that answered;
    2. fetches `GET /v1/signature/<id>?signing_algo=ed25519` from the
       upstream with its API key. A signature is recorded a moment after the
       answer, so "not found" is asked again a few times, with a bound;
    3. checks that the signed text is exactly `<model>:<request
       hash>:<response hash>` (signed by the model's machine,
       `provider_tee`) or `<request hash>:<response hash>` (signed by the
       provider's gateway, `gateway`), that the signature is valid, and that
       its key is the key of exactly one report verified in step 1
       (`Attestation.Near.verify_signature_over_hashes/5`).

  The result is a receipt: `verified`, or `not_verified` with the reason.
  Anything missing, late, unknown or ambiguous is `not_verified`; nothing
  about an answer is ever assumed.

  A receipt holds hashes, the signature and a summary of the evidence it
  was matched to: no prompt, no answer, no key. It is what a third party
  needs, together with the two bodies, to check the signature themselves
  (`tools/verify_receipt.py`).

  The newest #{10_000} receipts are kept, in memory and in one file
  (`OMNIGATE_RECEIPTS`, default `data/receipts.json`), and those older than
  `retention.receipts_days` (30 unless set, 0 = no age limit) are dropped.
  Nothing here runs for a config without an attested upstream.
  """
  use GenServer
  require Logger

  alias OmnigateControl.{Attestation, ConfigStore, Text}
  alias OmnigateControl.Attestation.Near

  @table :omnigate_receipts
  @max 10_000
  # Waits before each try of the signature request; "not found" and a
  # failing provider are asked again, anything else is final at once.
  @retry_ms [0, 1_000, 2_000, 4_000, 8_000]
  @max_running 8
  @max_queue 2_000
  @save_after_ms 1_000
  @task_timeout_ms 120_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Create the table. Called once at boot so that it outlives a restart of this process."
  def setup(table \\ @table) do
    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  # ---- Taking events -------------------------------------------------------

  @doc """
  Look through a batch of usage events for answers that carry what a receipt
  needs, and start on those. Never fails and never waits: usage recording
  does not depend on it.
  """
  def offer(events, server \\ __MODULE__) when is_list(events) do
    for %{"receipt" => %{} = _} = event <- events, wanted = slim(event), do: GenServer.cast(server, {:offer, wanted})
    :ok
  rescue
    _ -> :ok
  end

  # What is kept of an event: nothing that is not checked here.
  defp slim(event) do
    r = event["receipt"]

    with id when is_binary(id) <- event["id"],
         true <- id =~ ~r/\A[A-Za-z0-9_.:-]{1,128}\z/,
         status when is_integer(status) and status >= 200 and status < 300 <- event["status"],
         upstream when is_binary(upstream) <- event["upstream"],
         model when is_binary(model) <- event["target_model"],
         {:ok, request} <- sha256(r["request_sha256"]),
         {:ok, response} <- sha256(r["response_sha256"]) do
      ts_ms = if is_integer(event["ts_ms"]), do: event["ts_ms"], else: System.os_time(:millisecond)
      latency = if is_integer(event["latency_ms"]) and event["latency_ms"] >= 0, do: event["latency_ms"], else: 0

      %{
        "id" => id,
        "key_sha256" => if(is_binary(event["key_sha256"]), do: event["key_sha256"]),
        "created" => div(ts_ms, 1000),
        "started" => div(ts_ms - latency, 1000),
        "upstream" => Text.line(upstream, 128),
        "model" => Text.line(model, 256),
        "route_model" => if(is_binary(event["route_model"]), do: Text.line(event["route_model"], 256)),
        "stream" => event["stream"] == true,
        "request_sha256" => request,
        "response_sha256" => response,
        "completion_id" => completion_id(r["completion_id"])
      }
    else
      _ -> nil
    end
  end

  defp sha256(hex) when is_binary(hex) and byte_size(hex) == 64 do
    if hex =~ ~r/\A[0-9a-f]{64}\z/, do: {:ok, hex}, else: :error
  end

  defp sha256(_), do: :error

  # It becomes part of a URL's path: a plain token or nothing.
  defp completion_id(id) when is_binary(id), do: if(id =~ ~r/\A[A-Za-z0-9_.:-]{1,200}\z/, do: id)
  defp completion_id(_), do: nil

  # ---- Reading -------------------------------------------------------------

  @doc "The receipt of one request, or nil."
  def get(id, table \\ @table) when is_binary(id) do
    case :ets.whereis(table) != :undefined && :ets.lookup(table, id) do
      [{_, receipt}] -> receipt
      _ -> nil
    end
  end

  @doc "The receipt of one request if one of `hashes` (a key and its rotations) made it."
  def own(hashes, id, table \\ @table) do
    case get(id, table) do
      %{"key_sha256" => owner} = receipt when is_binary(owner) -> if owner in hashes, do: receipt
      _ -> nil
    end
  end

  @doc "The newest receipts, newest first."
  def recent(limit \\ 50, table \\ @table) do
    if :ets.whereis(table) == :undefined do
      []
    else
      table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(&{&1["created"], &1["id"]}, :desc) |> Enum.take(limit)
    end
  end

  @doc "How many receipts are held, by verdict."
  def counts(table \\ @table) do
    base = %{"verified" => 0, "not_verified" => 0, "pending" => 0}

    if :ets.whereis(table) == :undefined do
      base
    else
      :ets.foldl(fn {_, r}, acc -> Map.update(acc, r["verdict"], 1, &(&1 + 1)) end, base, table)
    end
  end

  @doc """
  A receipt as it is handed out: everything but whose key made the request
  (a hash of the key, which only this gateway can use).
  """
  def view(receipt), do: receipt |> Map.drop(["key_sha256", "started"]) |> Map.put("object", "attestation.receipt")

  @doc "Drop receipts created before `cutoff_s` (unix seconds). Returns how many."
  def prune(cutoff_s, server \\ __MODULE__) when is_integer(cutoff_s), do: GenServer.call(server, {:prune, cutoff_s}, 30_000)

  @doc "Wait until every receipt offered so far has been taken up (tests)."
  def sync(server \\ __MODULE__), do: GenServer.call(server, :sync)

  # ---- Server --------------------------------------------------------------

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)
    setup(table)
    # So that `terminate/2` runs on an orderly stop and writes what is pending.
    Process.flag(:trap_exit, true)

    state = %{
      table: table,
      path: Keyword.get(opts, :path),
      queue: :queue.new(),
      queued: 0,
      # task ref => receipt id
      running: %{},
      dirty: false,
      config: Keyword.get(opts, :config, &ConfigStore.get/0),
      # The next three are replaced by a test that starts a process of its
      # own; nothing in the config or the environment reaches them.
      evidence: Keyword.get(opts, :evidence, &Attestation.Manager.evidence_before/3),
      http: Keyword.get(opts, :http, OmnigateControl.Attestation.Http),
      retry_ms: Keyword.get(opts, :retry_ms, @retry_ms)
    }

    load(state)
    {:ok, state}
  end

  @impl true
  def handle_cast({:offer, wanted}, state) do
    id = wanted["id"]

    cond do
      # At-least-once delivery: an event may arrive twice.
      get(id, state.table) != nil ->
        {:noreply, state}

      attested_upstream(state, wanted["upstream"]) == nil ->
        {:noreply, state}

      state.queued >= @max_queue ->
        {:noreply, put(state, settle(wanted, nil, {:error, {:not_checked, "too many signatures were waiting to be checked"}}))}

      true ->
        state = put(state, Map.merge(wanted, %{"verdict" => "pending", "reason" => nil, "reason_code" => nil}))
        {:noreply, start_next(%{state | queue: :queue.in(id, state.queue), queued: state.queued + 1})}
    end
  end

  @impl true
  def handle_info({ref, {:checked, id, evidence, result}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> finished(ref, id, evidence, result) |> start_next()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case state.running[ref] do
      nil -> {:noreply, state}
      id -> {:noreply, state |> finished(ref, id, nil, {:error, {:not_checked, "the check crashed: " <> Text.line(inspect(reason), 120)}}) |> start_next()}
    end
  end

  def handle_info({:task_timeout, ref, pid}, state) do
    case state.running[ref] do
      nil ->
        {:noreply, state}

      id ->
        Process.demonitor(ref, [:flush])
        Task.Supervisor.terminate_child(OmnigateControl.Attestation.TaskSup, pid)
        {:noreply, state |> finished(ref, id, nil, {:error, {:signature_unavailable, "the provider did not answer in time"}}) |> start_next()}
    end
  end

  def handle_info(:save, state) do
    save(state)
    {:noreply, %{state | dirty: false}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call({:prune, cutoff_s}, _from, state) do
    old = for {id, r} <- :ets.tab2list(state.table), r["created"] < cutoff_s, r["verdict"] != "pending", do: id
    for id <- old, do: :ets.delete(state.table, id)
    {:reply, length(old), if(old == [], do: state, else: dirty(state))}
  end

  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  @impl true
  def terminate(_reason, state), do: if(state.dirty, do: save(state))

  # ---- One check -----------------------------------------------------------

  defp start_next(state) do
    if map_size(state.running) < @max_running and state.queued > 0 do
      {{:value, id}, queue} = :queue.out(state.queue)
      state = %{state | queue: queue, queued: state.queued - 1}

      case get(id, state.table) do
        %{"verdict" => "pending"} = receipt -> state |> start_check(receipt) |> start_next()
        _ -> start_next(state)
      end
    else
      state
    end
  end

  defp start_check(state, receipt) do
    id = receipt["id"]
    upstream = attested_upstream(state, receipt["upstream"])
    evidence = upstream && state.evidence.(receipt["upstream"], receipt["model"], receipt["started"])
    api_key = upstream && System.get_env(upstream.api_key_env || "")

    refusal =
      cond do
        upstream == nil ->
          {:not_checked, "the upstream is no longer configured with an attestation setting"}

        evidence == nil ->
          {:no_prior_attestation, "no attestation of this upstream and model had been verified when the request started"}

        receipt["completion_id"] == nil ->
          {:no_completion_id, "the answer named no completion id, so its signature could not be asked for"}

        api_key in [nil, ""] ->
          {:api_key_missing, "#{upstream.api_key_env} is not set in the control plane's environment, so the signature could not be fetched"}

        true ->
          nil
      end

    if refusal do
      put(state, settle(receipt, evidence, {:error, refusal}))
    else
      http = state.http
      delays = state.retry_ms
      url = Attestation.api_base(upstream.base_url) <> "/v1/signature/" <> receipt["completion_id"] <> "?signing_algo=ed25519"

      task =
        Task.Supervisor.async_nolink(OmnigateControl.Attestation.TaskSup, fn ->
          result =
            case fetch(http, url, api_key, delays) do
              {:ok, signature} ->
                case Near.verify_signature_over_hashes(signature, receipt["request_sha256"], receipt["response_sha256"], receipt["model"], evidence) do
                  {:ok, kind} -> {:ok, kind, signature}
                  # (A signature that failed a check is still shown in the receipt.)
                  {:error, reason} -> {:error, reason, signature}
                end

              {:error, reason} ->
                {:error, reason}
            end

          {:checked, id, evidence, result}
        end)

      Process.send_after(self(), {:task_timeout, task.ref, task.pid}, @task_timeout_ms)
      %{state | running: Map.put(state.running, task.ref, id)}
    end
  end

  # `{:ok, signature map}`, or why there is none.
  defp fetch(http, url, api_key, delays) do
    headers = [{"accept", "application/json"}, {"authorization", "Bearer " <> api_key}]

    Enum.reduce_while(delays, {:error, {:signature_unavailable, "never asked"}}, fn delay, _last ->
      if delay > 0, do: Process.sleep(delay)

      case http.get(url, headers) do
        {:ok, 200, _, body} ->
          case JSON.decode(body) do
            {:ok, %{} = signature} -> {:halt, {:ok, signature}}
            _ -> {:halt, {:error, {:signature_unavailable, "the provider's answer is not a JSON object"}}}
          end

        # Not recorded yet, or the provider is having a moment: ask again.
        {:ok, status, _, _} when status == 404 or status == 429 or status >= 500 ->
          {:cont, {:error, {:signature_unavailable, "the provider has no signature for this answer (HTTP #{status} after #{length(delays)} tries)"}}}

        {:ok, status, _, body} ->
          {:halt, {:error, {:signature_unavailable, "HTTP #{status}: #{Text.line(provider_words(body), 160)}"}}}

        {:error, reason} ->
          {:cont, {:error, {:signature_unavailable, "the provider could not be reached (#{Text.line(inspect(reason), 120)})"}}}
      end
    end)
  end

  defp provider_words(body) do
    case JSON.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) -> message
      {:ok, %{"message" => message}} when is_binary(message) -> message
      _ -> body
    end
  end

  defp finished(state, ref, id, evidence, result) do
    state = %{state | running: Map.delete(state.running, ref)}

    case get(id, state.table) do
      %{"verdict" => "pending"} = receipt -> put(state, settle(receipt, evidence, result))
      _ -> state
    end
  end

  # ---- The receipt ---------------------------------------------------------

  defp settle(receipt, evidence, result) do
    {verdict, reason, code, signature} =
      case result do
        {:ok, kind, signature} -> {"verified", nil, nil, signature_view(signature, Atom.to_string(kind))}
        {:error, {code, _} = reason, signature} -> {"not_verified", words(reason), Atom.to_string(code), signature_view(signature, signature["signature_kind"])}
        {:error, {code, _} = reason} -> {"not_verified", words(reason), Atom.to_string(code), nil}
      end

    if verdict != "verified" do
      Logger.warning(
        "receipt #{receipt["id"]}: the answer from #{Text.line(receipt["upstream"], 80)}/#{Text.line(receipt["model"], 120)} is NOT verified: #{reason}"
      )
    end

    receipt
    |> Map.merge(%{
      "verdict" => verdict,
      "reason" => reason,
      "reason_code" => code,
      "signature" => signature,
      "attestation" => evidence && evidence_view(evidence, signature),
      "checked_at" => System.os_time(:second)
    })
  end

  # What the provider returned, as far as it is text of a sane length.
  defp signature_view(signature, kind) do
    field = fn name -> if is_binary(signature[name]), do: Text.line(signature[name], 600) end

    %{
      "kind" => if(is_binary(kind), do: Text.line(kind, 40)),
      "text" => field.("text"),
      "signature" => field.("signature"),
      "signing_address" => field.("signing_address"),
      "signing_algo" => field.("signing_algo")
    }
  end

  # The evidence the signer was looked for in, and which report it matched.
  defp evidence_view(evidence, signature) do
    signer = signature && {signature["signing_algo"], signature["signing_address"] |> to_string() |> String.replace_prefix("0x", "") |> String.downcase()}

    report = fn role, r ->
      %{
        "role" => role,
        "tcb_status" => r.status,
        "signing_algo" => r.signing_algo,
        "signing_address" => r.signing_address,
        "app_compose_sha256" => r.app_compose_sha256,
        "mr_td" => r.mr_td,
        "rtmr3" => r.rtmr3,
        "signed_this_answer" => signer == {r.signing_algo, r.signing_address}
      }
    end

    %{
      "verified_at" => evidence.verified_at,
      "nonce" => evidence.nonce,
      "reports" => [report.("gateway", evidence.gateway) | Enum.map(evidence.models, &report.("model", &1))]
    }
  end

  defp words({:signature_text_mismatch, kind}),
    do: "the signed text is not the hashes of this request and response (#{kind}): the provider signed something else"

  defp words({:signer_not_verified, 0}), do: "the signature is valid, but its key is not the key of any report verified before the request"
  defp words({:signer_not_verified, n}), do: "the signature's key is named by #{n} verified reports; it has to be exactly one"
  defp words({:bad_response_signature, algo}), do: "the #{algo} signature does not verify"
  defp words({:unknown_signature_kind, nil}), do: "the provider did not say who signed (no signature_kind), so the signer cannot be matched"
  defp words({:unknown_signature_kind, kind}), do: "unknown signature kind #{Text.line(inspect(kind), 40)}"

  defp words({:signature_unavailable, {code, message}}),
    do: "the provider has no signature for this answer (#{Text.line(to_string(code), 60)}: #{Text.line(to_string(message), 160)})"

  defp words({:signature_unavailable, nil}), do: "the provider's answer carries no signature"
  defp words({:unsupported_algo, algo}), do: "signing algorithm #{Text.line(inspect(algo), 40)} is not supported"
  defp words({_code, text}) when is_binary(text), do: text
  defp words(reason), do: Attestation.describe(reason)

  # ---- Table and file ------------------------------------------------------

  defp attested_upstream(state, name) do
    case state.config.() do
      %{upstreams: upstreams} -> Enum.find(upstreams, &(&1.name == name and is_map(Map.get(&1, :attestation))))
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp put(state, receipt) do
    :ets.insert(state.table, {receipt["id"], receipt})
    trim(state.table)
    dirty(state)
  end

  # Past the cap the oldest settled receipts go.
  defp trim(table) do
    over = :ets.info(table, :size) - @max

    if over > 0 do
      table
      |> :ets.tab2list()
      |> Enum.filter(fn {_, r} -> r["verdict"] != "pending" end)
      |> Enum.sort_by(fn {id, r} -> {r["created"], id} end)
      # A batch, so that this sort is not run for every receipt.
      |> Enum.take(over + div(@max, 20))
      |> Enum.each(fn {id, _} -> :ets.delete(table, id) end)
    end
  end

  defp dirty(%{dirty: true} = state), do: state

  defp dirty(state) do
    Process.send_after(self(), :save, @save_after_ms)
    %{state | dirty: true}
  end

  defp load(%{path: nil}), do: :ok

  defp load(state) do
    with {:ok, text} <- File.read(state.path),
         {:ok, %{"receipts" => list}} when is_list(list) <- JSON.decode(text) do
      for %{"id" => id} = receipt when is_binary(id) <- list do
        # A check that was under way when the last run ended cannot be taken
        # up again: the evidence it would be matched to went with that run.
        receipt =
          if receipt["verdict"] == "pending",
            do: settle(receipt, nil, {:error, {:not_checked, "the gateway restarted before the signature was checked"}}),
            else: receipt

        :ets.insert(state.table, {id, receipt})
      end
    else
      {:error, :enoent} -> :ok
      other -> Logger.warning("receipts: #{state.path} could not be read (#{Text.line(inspect(other), 120)}); starting with none")
    end

    :ok
  end

  defp save(%{path: nil}), do: :ok

  defp save(state) do
    receipts = state.table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(&{&1["created"], &1["id"]})
    tmp = state.path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(state.path)),
         :ok <- File.write(tmp, JSON.encode!(%{"version" => 1, "receipts" => receipts})),
         :ok <- File.rename(tmp, state.path) do
      :ok
    else
      error -> Logger.warning("receipts: could not write #{state.path}: #{Text.line(inspect(error), 120)}")
    end
  rescue
    e -> Logger.warning("receipts: could not write #{state.path}: #{Text.line(Exception.message(e), 120)}")
  end
end
