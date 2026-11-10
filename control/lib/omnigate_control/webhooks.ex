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

  This process only keeps timers; each delivery runs in its own task.
  """
  use GenServer
  require Logger

  alias OmnigateControl.{ConfigStore, Http, Jobs}
  alias OmnigateControl.Jobs.Store

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Attempt delivery for `job_id` after `delay_ms`. A job is only ever scheduled once at a time."
  def schedule(job_id, delay_ms), do: GenServer.cast(__MODULE__, {:schedule, job_id, delay_ms})

  @doc "`webhook-signature` value for a message."
  def signature(secret, msg_id, timestamp, body) do
    "v1," <> (:crypto.mac(:hmac, :sha256, signing_key(secret), "#{msg_id}.#{timestamp}.#{body}") |> Base.encode64())
  end

  @doc "Signing secret for a gateway key: its own, else the global one, else nil."
  def secret_for(key_sha256) do
    config = ConfigStore.get()
    key = Enum.find(config.keys, &(&1.key_sha256 == key_sha256))
    (key && key[:webhook_secret]) || config.media.webhooks.secret || System.get_env("OMNIGATE_WEBHOOK_SECRET")
  end

  @doc """
  `:ok` when `url` is an http(s) URL we are willing to call. Unless
  `media.webhooks.allow_private` is set, hosts that resolve to loopback,
  private or link-local addresses are refused.
  """
  def check_url(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] -> {:error, "webhook_url must be http or https"}
      uri.host in [nil, ""] -> {:error, "webhook_url has no host"}
      uri.userinfo != nil -> {:error, "webhook_url must not contain credentials"}
      ConfigStore.get().media.webhooks.allow_private -> :ok
      true -> public_host(uri.host)
    end
  end

  # -- timers ----------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:schedule, job_id, delay_ms}, timers) do
    if Map.has_key?(timers, job_id) do
      {:noreply, timers}
    else
      {:noreply, Map.put(timers, job_id, Process.send_after(self(), {:deliver, job_id}, delay_ms))}
    end
  end

  @impl true
  def handle_info({:deliver, job_id}, timers) do
    Task.Supervisor.start_child(OmnigateControl.Jobs.TaskSup, fn -> deliver(job_id) end)
    {:noreply, Map.delete(timers, job_id)}
  end

  # -- delivery --------------------------------------------------------------

  @doc false
  def deliver(job_id) do
    case Store.get(job_id) do
      %{"webhook" => %{"url" => url, "status" => status} = wh} = job when status in ["pending", "retrying"] ->
        config = ConfigStore.get().media.webhooks
        attempt = (wh["attempts"] || 0) + 1
        result = post(job, url, config)
        now = System.os_time(:millisecond)

        change =
          case result do
            {:ok, code} when code in 200..299 ->
              %{"status" => "delivered", "last_status" => code, "last_error" => nil, "delivered_at" => Store.now_iso(), "next_attempt_ms" => nil, "next_attempt_at" => nil}

            failure ->
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

        {:ok, updated} =
          Store.update(job_id, fn j -> Map.put(j, "webhook", j["webhook"] |> Map.merge(change) |> Map.put("attempts", attempt)) end)

        case updated["webhook"] do
          %{"status" => "retrying", "next_attempt_ms" => at} -> schedule(job_id, max(at - now, 0))
          %{"status" => "failed"} -> Logger.warning("webhook for #{job_id} gave up after #{attempt} attempts")
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp post(job, url, config) do
    with :ok <- check_url(url),
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
        {"user-agent", "omnigate-webhooks/0.1"}
      ]

      # Redirects are not followed: a 3xx is a failed delivery.
      case Http.request(:post, url, headers, body, timeout: config.timeout_ms) do
        {:ok, %{status: status}} -> {:ok, status}
        {:error, reason} -> {:error, reason |> inspect() |> String.slice(0, 200)}
      end
    else
      {:error, reason} -> {:error, reason}
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

  defp public_host(host) do
    addrs =
      for family <- [:inet, :inet6],
          {:ok, list} <- [:inet.getaddrs(String.to_charlist(host), family)],
          addr <- list,
          do: addr

    cond do
      addrs == [] -> {:error, "webhook_url host does not resolve"}
      Enum.any?(addrs, &private?/1) -> {:error, "webhook_url resolves to a private or loopback address"}
      true -> :ok
    end
  end

  defp private?({a, b, _, _}) do
    a in [0, 10, 127] or (a == 172 and b in 16..31) or (a == 192 and b == 168) or (a == 169 and b == 254) or
      (a == 100 and b in 64..127) or a >= 224
  end

  # IPv4-mapped (::ffff:a.b.c.d)
  defp private?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: private?({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})
  defp private?({0, 0, 0, 0, 0, 0, 0, n}) when n in [0, 1], do: true
  defp private?({a, _, _, _, _, _, _, _}), do: Bitwise.band(a, 0xFE00) == 0xFC00 or Bitwise.band(a, 0xFFC0) == 0xFE80
end
