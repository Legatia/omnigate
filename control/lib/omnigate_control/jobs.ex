defmodule OmnigateControl.Jobs do
  @moduledoc """
  Async media jobs: one job API in front of image, video and speech
  providers.

  A job is tried against its route's targets in order (failover), its
  outputs are copied into storage the operator controls, its cost lands in
  the same ledger as text usage, and a signed webhook reports the result.

  Job lifecycle: `queued → running → succeeded | failed | canceled`.
  """
  alias OmnigateControl.{ConfigStore, Ledger, Storage, Webhooks}
  alias OmnigateControl.Jobs.{Runner, Store}

  @terminal ~w(succeeded failed canceled)
  @public ~w(id status model input metadata error cost_usd cached upstream target_model attempts
             created_at updated_at started_at finished_at)

  def terminal?(%{"status" => status}), do: status in @terminal

  @doc """
  Create a job for gateway key `key_sha256` from request `params`.

  Returns `{:ok, job}` (new), `{:existing, job}` (idempotent replay) or
  `{:error, http_status, type, message}`.
  """
  def create(key_sha256, params, idempotency_key \\ nil) do
    with {:ok, route} <- route(params["model"]),
         {:ok, input} <- object(params["input"], "input", true),
         {:ok, metadata} <- object(params["metadata"], "metadata", false),
         {:ok, webhook_url} <- webhook_url(params["webhook_url"], key_sha256),
         :ok <- idempotency_key_ok(idempotency_key) do
      now = DateTime.utc_now()
      cache? = params["cache"] == true or (is_integer(route.cache_ttl_s) and params["cache"] != false)

      job = %{
        "id" => "job_" <> random_id(),
        "status" => "queued",
        "model" => route.model,
        "input" => input,
        "metadata" => metadata,
        "outputs" => [],
        "error" => nil,
        "cost_usd" => 0.0,
        "cached" => false,
        "upstream" => nil,
        "target_model" => nil,
        "attempts" => [],
        "webhook" => webhook_url && %{"url" => webhook_url, "status" => "waiting", "attempts" => 0, "last_status" => nil},
        "created_at" => iso(now),
        "updated_at" => iso(now),
        "started_at" => nil,
        "finished_at" => nil,
        # internal
        "key_sha256" => key_sha256,
        "created_ms" => DateTime.to_unix(now, :millisecond),
        "idempotency_key" => idempotency_key,
        "request_hash" => hash(canonical(Map.take(params, ~w(model input metadata webhook_url cache)))),
        "cache_key" => cache_key(route.model, input),
        "ledgered" => false,
        "run" => nil
      }

      case Store.create(job) do
        {:ok, job} ->
          if cache? and serve_from_cache(job, route) do
            {:ok, Store.get(job["id"])}
          else
            start_runner(job["id"])
            {:ok, job}
          end

        {:existing, existing} ->
          if existing["request_hash"] == job["request_hash"] do
            {:existing, existing}
          else
            {:error, 409, "idempotency_conflict", "this Idempotency-Key was already used with a different request"}
          end
      end
    end
  end

  @doc "A job, only if it belongs to `key_sha256`."
  def get(key_sha256, id) do
    case Store.get(id) do
      %{"key_sha256" => ^key_sha256} = job -> job
      _ -> nil
    end
  end

  def list(key_sha256, limit), do: Store.list_for_key(key_sha256, limit)

  @doc "Cancel a job that has not finished. Finished jobs are returned unchanged."
  def cancel(key_sha256, id) do
    case get(key_sha256, id) do
      nil ->
        nil

      job ->
        case finish(id, "canceled", %{}) do
          {:ok, canceled} ->
            # The runner notices on its next step; tell the provider now.
            Task.Supervisor.start_child(OmnigateControl.Jobs.TaskSup, fn -> Runner.cancel_provider(job) end)
            canceled

          _ ->
            Store.get(id)
        end
    end
  end

  @doc """
  Move a job to a terminal status, exactly once. Later calls are no-ops, so a
  runner finishing a job that was canceled in the meantime changes nothing.
  """
  def finish(id, status, changes) when status in @terminal do
    now = DateTime.utc_now()

    result =
      Store.update(id, fn job ->
        if terminal?(job) do
          :noop
        else
          job
          |> Map.merge(changes)
          |> Map.merge(%{
            "status" => status,
            "finished_at" => iso(now),
            "finished_ms" => DateTime.to_unix(now, :millisecond),
            "run" => nil
          })
          |> arm_webhook(now)
        end
      end)

    with {:ok, job} <- result do
      settle(job)
      {:ok, Store.get(id)}
    end
  end

  @doc """
  On boot: continue unfinished jobs, write ledger events that a crash cut
  off, and re-arm undelivered webhooks.
  """
  def resume_all do
    now = System.os_time(:millisecond)

    for job <- Store.all() do
      cond do
        not terminal?(job) ->
          start_runner(job["id"])

        true ->
          if job["ledgered"] != true, do: record_cost(job)

          case job["webhook"] do
            %{"status" => s} = wh when s in ["pending", "retrying"] ->
              Webhooks.schedule(job["id"], max((wh["next_attempt_ms"] || now) - now, 0))

            _ ->
              :ok
          end
      end
    end

    :ok
  end

  def start_runner(id) do
    Task.Supervisor.start_child(OmnigateControl.Jobs.TaskSup, fn -> Runner.run(id) end)
  end

  @doc "Client-facing JSON view: no internal fields, fresh output URLs."
  def view(job) do
    job
    |> Map.take(@public)
    |> Map.merge(%{
      "object" => "job",
      "outputs" =>
        Enum.map(job["outputs"] || [], fn o ->
          %{
            "url" => Storage.url(job["id"], o),
            "content_type" => o["content_type"],
            "bytes" => o["bytes"],
            "sha256" => o["sha256"]
          }
        end),
      "webhook" =>
        case job["webhook"] do
          nil -> nil
          wh -> Map.take(wh, ~w(url status attempts last_status last_error next_attempt_at delivered_at))
        end
    })
  end

  @doc "Cost in USD of a finished job under a target's price."
  def cost(price, input, output_count) do
    chars =
      case Enum.find_value(~w(text prompt input), &(is_binary(input[&1]) && input[&1])) do
        nil -> 0
        text -> String.length(text)
      end

    seconds = number(input["duration"] || input["seconds"])

    price.per_job_usd + price.per_output_usd * output_count + price.per_input_char_usd * chars +
      price.per_second_usd * seconds
  end

  @doc "Stable hash of a route model and input, ignoring key order."
  def cache_key(model, input), do: hash([model, "\n", canonical(input)])

  @doc "JSON with object keys sorted at every level."
  def canonical(map) when is_map(map) do
    inner =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort()
      |> Enum.map_join(",", fn {k, v} -> JSON.encode!(k) <> ":" <> canonical(v) end)

    "{" <> inner <> "}"
  end

  def canonical(list) when is_list(list), do: "[" <> Enum.map_join(list, ",", &canonical/1) <> "]"
  def canonical(other), do: JSON.encode!(other)

  # -- internals -------------------------------------------------------------

  # Ledger first, then the webhook: both are safe to repeat after a crash
  # (the ledger dedups on job id; webhook state is in the job).
  defp settle(job) do
    record_cost(job)

    case job["webhook"] do
      %{"status" => "pending"} -> Webhooks.schedule(job["id"], 0)
      _ -> :ok
    end
  end

  defp record_cost(job) do
    status =
      case job["status"] do
        "succeeded" -> 200
        "canceled" -> 499
        _ -> 502
      end

    {:ok, _} =
      Ledger.record_media(%{
        "id" => job["id"],
        "key_sha256" => job["key_sha256"],
        "route_model" => job["model"],
        "upstream" => job["upstream"],
        "target_model" => job["target_model"],
        "status" => status,
        "cost_usd" => job["cost_usd"] || 0.0,
        "cached" => job["cached"] == true,
        "outputs" => length(job["outputs"] || []),
        "attempts" => job["attempts"] || [],
        "latency_ms" => (job["finished_ms"] || job["created_ms"]) - job["created_ms"],
        "ts_ms" => job["finished_ms"]
      })

    Store.update(job["id"], &Map.put(&1, "ledgered", true))
  end

  defp arm_webhook(%{"webhook" => %{} = wh} = job, now) do
    Map.put(job, "webhook", Map.merge(wh, %{"status" => "pending", "next_attempt_ms" => DateTime.to_unix(now, :millisecond)}))
  end

  defp arm_webhook(job, _now), do: job

  # Reuse the stored outputs of an identical, already succeeded job.
  defp serve_from_cache(job, route) do
    with {source_id, finished_ms} <- Store.cache_lookup(job["cache_key"]),
         true <- fresh?(finished_ms, route.cache_ttl_s),
         %{"status" => "succeeded", "outputs" => [_ | _] = outputs} = source <- Store.get(source_id),
         {:ok, shared} <- share_all(source_id, job["id"], outputs) do
      {:ok, _} =
        finish(job["id"], "succeeded", %{
          "outputs" => shared,
          "cached" => true,
          "cost_usd" => 0.0,
          "upstream" => source["upstream"],
          "target_model" => source["target_model"],
          "attempts" => [%{"upstream" => source["upstream"], "outcome" => "cache_hit"}]
        })

      true
    else
      _ -> false
    end
  end

  defp fresh?(_finished_ms, nil), do: true
  defp fresh?(finished_ms, ttl_s), do: System.os_time(:millisecond) - finished_ms <= ttl_s * 1000

  defp share_all(from, to, outputs) do
    Enum.reduce_while(outputs, {:ok, []}, fn output, {:ok, acc} ->
      case Storage.share(from, to, output) do
        {:ok, o} -> {:cont, {:ok, acc ++ [o]}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp route(model) when is_binary(model) do
    case ConfigStore.media_route(model) do
      nil -> {:error, 404, "model_not_found", "no media route for this model"}
      route -> {:ok, route}
    end
  end

  defp route(_), do: {:error, 400, "missing_model", "\"model\" must be a string"}

  defp object(nil, name, true), do: {:error, 400, "invalid_request", "\"#{name}\" is required and must be an object"}
  defp object(nil, _name, false), do: {:ok, nil}
  defp object(map, _name, _required) when is_map(map), do: {:ok, map}
  defp object(_, name, _), do: {:error, 400, "invalid_request", "\"#{name}\" must be an object"}

  defp webhook_url(nil, _key), do: {:ok, nil}

  defp webhook_url(url, key_sha256) when is_binary(url) do
    cond do
      Webhooks.secret_for(key_sha256) == nil ->
        {:error, 400, "webhook_not_configured", "no webhook signing secret is configured for this key"}

      true ->
        case Webhooks.check_url(url) do
          :ok -> {:ok, url}
          {:error, reason} -> {:error, 400, "invalid_webhook_url", reason}
        end
    end
  end

  defp webhook_url(_, _), do: {:error, 400, "invalid_webhook_url", "\"webhook_url\" must be a string"}

  defp idempotency_key_ok(nil), do: :ok
  defp idempotency_key_ok(k) when byte_size(k) in 1..255, do: :ok
  defp idempotency_key_ok(_), do: {:error, 400, "invalid_request", "Idempotency-Key must be 1 to 255 bytes"}

  defp number(n) when is_number(n), do: n

  defp number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0
    end
  end

  defp number(_), do: 0

  defp hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  defp random_id, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  defp iso(dt), do: dt |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
