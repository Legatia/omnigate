defmodule OmnigateControl.Webhooks do
  @moduledoc """
  Signed, retried job webhooks.

  When a job finishes, its JSON is POSTed to the job's `webhook_url` inside
  a `{"type": "job.<status>", "timestamp", "data": <job>}` envelope, signed
  the Standard Webhooks way:

      webhook-id:        msg_<job id>          (same on every retry)
      webhook-timestamp: <unix seconds>
      webhook-signature: v1,<base64 HMAC-SHA256(secret, "<id>.<timestamp>.<body>")>

  Anything but a 2xx answer is retried on `media.webhooks.retry_schedule_ms`.
  Delivery state lives in the job record, so it survives restarts.

  ## What the receiver controls, and what it does not

  The URL is the client's, so whoever runs it is not trusted:

    * Only the status of its answer matters. At most 16 KiB of the body
      are read, then the connection is closed: a receiver cannot make this
      process hold a large answer.
    * An attempt is written to the job **before** the request is sent. A
      delivery that is cut short by a crash or a restart has therefore used
      up its attempt, and a receiver that manages to make deliveries fail
      that way still gets at most `max_attempts` requests per job.
    * At most `media.webhooks.max_concurrent` deliveries run at once, and at
      most `media.webhooks.max_concurrent_per_key` for the jobs of one
      gateway key. The rest wait their turn, fairly across keys, so one
      key's slow receiver cannot hold up everyone else's webhooks or tie up
      more than its share of connections.

  This process keeps the timers and the queue; each delivery runs in its own
  task. Once a minute it also asks `Jobs.reconcile/0` to pick up anything a
  restart elsewhere left unfinished.
  """
  use GenServer
  require Logger

  alias OmnigateControl.{ConfigStore, Http, Jobs, Keys, Text}
  alias OmnigateControl.Jobs.Store

  # The answer to a webhook is only looked at for its status.
  @max_response_bytes 16 * 1024
  @reconcile_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Attempt delivery for `job_id` after `delay_ms`. A job is only ever scheduled once at a time."
  def schedule(job_id, delay_ms), do: GenServer.cast(__MODULE__, {:schedule, job_id, delay_ms})

  @doc "For monitoring and tests: `%{running: n, waiting: n, timers: n}`."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "`webhook-signature` value for a message."
  def signature(secret, msg_id, timestamp, body) do
    "v1," <> (:crypto.mac(:hmac, :sha256, signing_key(secret), "#{msg_id}.#{timestamp}.#{body}") |> Base.encode64())
  end

  @doc "Signing secret for a gateway key: its own, else the global one, else nil."
  def secret_for(key_sha256) do
    config = ConfigStore.get()
    # The key may have been rotated since the job was created.
    key = Keys.find_owner(key_sha256)
    (key && key[:webhook_secret]) || config.media.webhooks.secret || System.get_env("OMNIGATE_WEBHOOK_SECRET")
  end

  @doc """
  `:ok` when `url` is an http(s) URL we are willing to call. Unless
  `media.webhooks.allow_private` is set, hosts that resolve to loopback,
  private or link-local addresses are refused.
  """
  def check_url(url) do
    case target(url) do
      {:ok, _address} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The address a delivery to `url` must connect to: `{:ok, ip}`.

  The host is resolved once, every address it resolves to is checked against
  the private-address rules, and the caller then connects to the returned
  address itself (`Http.request(..., connect_to: ip)`). Checking a name and
  then letting the HTTP client resolve it again would let a hostile DNS
  server answer "public" for the check and "internal" for the call.
  """
  def target(url), do: OmnigateControl.NetGuard.target(url, "webhook_url")

  # -- timers and the queue ---------------------------------------------------

  @impl true
  def init(_opts) do
    Process.send_after(self(), :reconcile, @reconcile_ms)
    # known: job id => :timer | :waiting | :running | {:again, delay} (running, and to be
    #   scheduled again when it ends: that is how a delivery books its own retry);
    # running: monitor => {job id, key}; per_key: key => deliveries running;
    # waiting: key => queue of job ids; served: key => when it last got a slot.
    {:ok, %{known: %{}, running: %{}, per_key: %{}, waiting: %{}, served: %{}, tick: 0}}
  end

  @impl true
  def handle_cast({:schedule, job_id, delay_ms}, state) do
    case state.known do
      %{^job_id => running} when running == :running or is_tuple(running) ->
        {:noreply, %{state | known: Map.put(state.known, job_id, {:again, delay_ms})}}

      %{^job_id => _timer_or_waiting} ->
        {:noreply, state}

      _ ->
        {:noreply, arm(state, job_id, delay_ms)}
    end
  end

  defp arm(state, job_id, delay_ms) do
    Process.send_after(self(), {:deliver, job_id}, delay_ms |> max(0) |> min(86_400_000))
    %{state | known: Map.put(state.known, job_id, :timer)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    waiting = state.waiting |> Map.values() |> Enum.map(&:queue.len/1) |> Enum.sum()
    timers = Enum.count(state.known, fn {_id, where} -> where == :timer end)
    {:reply, %{running: map_size(state.running), waiting: waiting, timers: timers}, state}
  end

  @impl true
  def handle_info({:deliver, job_id}, state) do
    key = owner(job_id)
    queue = Map.get(state.waiting, key, :queue.new())
    {:noreply, drain(%{state | known: Map.put(state.known, job_id, :waiting), waiting: Map.put(state.waiting, key, :queue.in(job_id, queue))})}
  end

  # A delivery task ended, however it ended.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.running, ref) do
      {nil, _} ->
        {:noreply, state}

      {{job_id, key}, running} ->
        per_key =
          case Map.get(state.per_key, key, 1) - 1 do
            0 -> Map.delete(state.per_key, key)
            n -> Map.put(state.per_key, key, n)
          end

        served = if Map.has_key?(per_key, key) or Map.has_key?(state.waiting, key), do: state.served, else: Map.delete(state.served, key)
        state = %{state | running: running, per_key: per_key, served: served}

        state =
          case Map.pop(state.known, job_id) do
            {{:again, delay_ms}, known} -> arm(%{state | known: known}, job_id, delay_ms)
            {_, known} -> %{state | known: known}
          end

        {:noreply, drain(state)}
    end
  end

  def handle_info(:reconcile, state) do
    # In a task: it calls back into this process (`schedule/2`) and into the store.
    Task.Supervisor.start_child(OmnigateControl.Jobs.TaskSup, fn ->
      try do
        Jobs.reconcile()
      catch
        kind, reason -> Logger.warning("job reconcile skipped: #{Text.line(inspect({kind, reason}), 200)}")
      end
    end)

    Process.send_after(self(), :reconcile, @reconcile_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # The gateway key a job's deliveries are counted under: the key's name
  # when it still exists (so a rotation does not start a second allowance),
  # else the hash the job was created with.
  defp owner(job_id) do
    case Store.get(job_id) do
      %{"key_sha256" => hash} when is_binary(hash) ->
        case Keys.find_owner(hash) do
          %{name: name} -> {:key, name}
          _ -> {:hash, hash}
        end

      _ ->
        :unknown
    end
  rescue
    # The job store is restarting; the delivery itself will find out.
    ArgumentError -> :unknown
  end

  # Start waiting deliveries while there is room: overall, and for the key
  # each belongs to. The next slot goes to the key with the fewest deliveries
  # running, and among those to the one served longest ago, so a key with a
  # long queue does not starve the others.
  defp drain(state) do
    limits = limits()

    eligible =
      if map_size(state.running) >= limits.overall do
        []
      else
        for {key, queue} <- state.waiting,
            Map.get(state.per_key, key, 0) < limits.per_key,
            do: {{Map.get(state.per_key, key, 0), Map.get(state.served, key, 0)}, key, queue}
      end

    case Enum.min(eligible, fn -> nil end) do
      nil ->
        state

      {_rank, key, queue} ->
        {{:value, job_id}, rest} = :queue.out(queue)
        waiting = if :queue.is_empty(rest), do: Map.delete(state.waiting, key), else: Map.put(state.waiting, key, rest)
        {:ok, pid} = Task.Supervisor.start_child(OmnigateControl.Jobs.TaskSup, fn -> deliver(job_id) end)
        ref = Process.monitor(pid)

        drain(%{
          state
          | waiting: waiting,
            known: Map.put(state.known, job_id, :running),
            running: Map.put(state.running, ref, {job_id, key}),
            per_key: Map.update(state.per_key, key, 1, &(&1 + 1)),
            served: Map.put(state.served, key, state.tick + 1),
            tick: state.tick + 1
        })
    end
  end

  defp limits do
    config = ConfigStore.get().media.webhooks
    %{overall: positive(Map.get(config, :max_concurrent), 16), per_key: positive(Map.get(config, :max_concurrent_per_key), 4)}
  end

  defp positive(n, _default) when is_integer(n) and n > 0, do: n
  defp positive(_, default), do: default

  # -- delivery --------------------------------------------------------------

  @doc false
  def deliver(job_id) do
    config = ConfigStore.get().media.webhooks

    # The attempt is counted, on disk, before anything is sent. If this
    # process dies half-way, the job still says "attempt N made": the next
    # start carries on from there instead of starting over, and waits the
    # usual time first, however often we restart.
    claimed =
      Store.update(job_id, fn
        %{"webhook" => %{"url" => _, "status" => status} = wh} = job when status in ["pending", "retrying"] ->
          attempt = (wh["attempts"] || 0) + 1

          if attempt > config.max_attempts do
            Map.put(job, "webhook", Map.merge(wh, %{"status" => "failed", "next_attempt_ms" => nil, "next_attempt_at" => nil}))
          else
            delay = Enum.at(config.retry_schedule_ms, attempt - 1) || List.last(config.retry_schedule_ms) || 0
            Map.put(job, "webhook", Map.merge(wh, %{"attempts" => attempt, "next_attempt_ms" => System.os_time(:millisecond) + delay}))
          end

        _ ->
          :noop
      end)

    case claimed do
      {:ok, %{"webhook" => %{"status" => status, "attempts" => attempt, "url" => url}} = job} when status in ["pending", "retrying"] ->
        result = post(job, url, config)
        now = System.os_time(:millisecond)
        {:ok, updated} = Store.update(job_id, fn j -> Map.put(j, "webhook", Map.merge(j["webhook"], outcome(result, attempt, config, now))) end)

        case updated["webhook"] do
          %{"status" => "retrying", "next_attempt_ms" => at} -> schedule(job_id, max(at - now, 0))
          %{"status" => "failed"} -> Logger.warning("webhook for #{job_id} gave up after #{attempt} attempts")
          _ -> :ok
        end

      {:ok, %{"webhook" => %{"status" => "failed", "attempts" => attempts}}} ->
        Logger.warning("webhook for #{job_id} gave up after #{attempts} attempts")

      _ ->
        :ok
    end
  end

  defp outcome({:ok, code}, _attempt, _config, _now) when code in 200..299 do
    %{
      "status" => "delivered",
      "last_status" => code,
      "last_error" => nil,
      "delivered_at" => Store.now_iso(),
      "next_attempt_ms" => nil,
      "next_attempt_at" => nil
    }
  end

  defp outcome(failure, attempt, config, now) do
    {code, error} =
      case failure do
        {:ok, code} -> {code, "http_#{code}"}
        {:error, reason} -> {nil, reason}
      end

    delay = Enum.at(config.retry_schedule_ms, attempt - 1) || List.last(config.retry_schedule_ms)

    if attempt >= config.max_attempts or delay == nil do
      %{"status" => "failed", "last_status" => code, "last_error" => error, "next_attempt_ms" => nil, "next_attempt_at" => nil}
    else
      %{
        "status" => "retrying",
        "last_status" => code,
        "last_error" => error,
        "next_attempt_ms" => now + delay,
        "next_attempt_at" => DateTime.from_unix!(now + delay, :millisecond) |> DateTime.to_iso8601()
      }
    end
  end

  defp post(job, url, config) do
    # Resolved and checked again on every attempt; the address that passed
    # the check is the one connected to.
    with {:ok, address} <- target(url),
         secret when is_binary(secret) <- secret_for(job["key_sha256"]) do
      body =
        JSON.encode!(%{
          "type" => "job." <> job["status"],
          "timestamp" => Store.now_iso(),
          "data" => Jobs.view(job)
        })

      msg_id = "msg_" <> job["id"]
      timestamp = System.os_time(:second)

      headers = [
        {"webhook-id", msg_id},
        {"webhook-timestamp", Integer.to_string(timestamp)},
        {"webhook-signature", signature(secret, msg_id, timestamp, body)},
        {"user-agent", "omnigate-webhooks/" <> OmnigateControl.version()}
      ]

      # Redirects are not followed: a 3xx is a failed delivery. (Following one
      # would mean calling an address nobody checked.) The answer's body is
      # of no interest; what fits in a few KiB is read and the rest is not.
      case Http.request(:post, url, headers, body, timeout: config.timeout_ms, connect_to: address, max_body: @max_response_bytes, overflow: :truncate) do
        {:ok, %{status: status}} -> {:ok, status}
        {:error, reason} -> {:error, Text.line(reason, 200)}
      end
    else
      {:error, reason} -> {:error, Text.line(reason, 200)}
      nil -> {:error, "no webhook signing secret configured"}
    end
  end

  # Standard Webhooks secrets are `whsec_<base64 key>`; anything else is used as raw bytes.
  defp signing_key("whsec_" <> b64 = secret) do
    case Base.decode64(b64) do
      {:ok, key} -> key
      :error -> secret
    end
  end

  defp signing_key(secret), do: secret
end
