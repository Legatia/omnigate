defmodule OmnigateControl.Jobs do
  @moduledoc """
  Async media jobs: one job API in front of image, video and speech
  providers.

  A job is tried against its route's targets in order (failover), its
  outputs are copied into storage the operator controls, its cost lands in
  the same ledger as text usage, and a signed webhook reports the result.

  Job lifecycle: `queued → running → succeeded | failed | canceled`.
  """
  require Logger

  alias OmnigateControl.{ConfigStore, Ledger, Storage, Text, Webhooks}
  alias OmnigateControl.Jobs.{Adapter, Runner, Store}

  # An input whose JSON is larger than this is kept in a file of its own
  # instead of in the job record (see "Large inputs" in `Jobs.Store`).
  @inline_input_bytes 8 * 1024

  @terminal ~w(succeeded failed canceled)
  @public ~w(id status model input metadata error cost_usd cached upstream target_model attempts
             created_at updated_at started_at finished_at)

  def terminal?(%{"status" => status}), do: status in @terminal

  @doc """
  Create a job for gateway key `key_sha256` from request `params`.

  Returns `{:ok, job}` (new), `{:existing, job}` (idempotent replay) or
  `{:error, http_status, type, message}`. With `open_cap: {limit, hashes}`
  the job is refused (429) when the key already has `limit` unfinished jobs;
  with `day_cap: {limit, hashes}`, when it already created `limit` jobs this
  UTC day.
  """
  def create(key_sha256, params, idempotency_key \\ nil, opts \\ []) do
    with {:ok, route} <- route(params["model"]),
         {:ok, input} <- object(params["input"], "input", true),
         {:ok, metadata} <- object(params["metadata"], "metadata", false),
         {:ok, input_json} <- small_enough(input, metadata),
         :ok <- fields_allowed(input, route),
         :ok <- quantities_ok(input, route),
         :ok <- multipliers_ok(input, route),
         {:ok, webhook_url} <- webhook_url(params["webhook_url"], key_sha256),
         :ok <- idempotency_key_ok(idempotency_key) do
      now = DateTime.utc_now()
      cache? = params["cache"] == true or (is_integer(route.cache_ttl_s) and params["cache"] != false)
      id = "job_" <> random_id()
      on_disk = byte_size(input_json) > @inline_input_bytes

      job = %{
        "id" => id,
        "status" => "queued",
        "model" => route.model,
        # A large input lives in its own file; `input/1` reads it back.
        "input" => if(on_disk, do: nil, else: input),
        "input_file" => on_disk,
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

      # The input is on disk before the job that points at it exists.
      stored = if on_disk, do: Store.put_input(id, input_json), else: :ok

      created =
        case stored do
          :ok -> Store.create(job, Keyword.take(opts, [:open_cap, :day_cap]))
          {:error, reason} -> {:error, {:input_not_stored, reason}}
        end

      # A job that was not created leaves no input file behind.
      if on_disk and not match?({:ok, _}, created), do: Store.delete_input(id)

      case created do
        {:error, :too_many_open} ->
          {limit, _} = Keyword.fetch!(opts, :open_cap)
          {:error, 429, "too_many_open_jobs", "this key already has #{limit} unfinished jobs; wait for some to finish"}

        {:error, :too_many_today} ->
          {limit, _} = Keyword.fetch!(opts, :day_cap)
          # The count starts again at midnight UTC: say how far away that is,
          # but never ask a client to stay away for more than an hour at a
          # time (the limit may be raised, or the key replaced, before then).
          retry_after_s = min(seconds_until_utc_midnight(), 3_600)
          {:error, 429, "too_many_jobs_today", "this key already created #{limit} jobs today (UTC); the count starts again at midnight UTC", retry_after_s}

        {:error, reason} ->
          Logger.error("job #{id} could not be stored: #{Text.line(reason, 200)}")
          {:error, 503, "storage_unavailable", "the job could not be stored; try again shortly"}

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

  @doc """
  The input of a job: from the record, or from the job's input file when it
  was too large for the record. `nil` when the file is gone.
  """
  def input(%{"input_file" => true, "id" => id}) do
    case Store.read_input(id) do
      {:ok, input} -> input
      :error -> nil
    end
  end

  def input(job), do: job["input"]

  @doc "Like `input/1`, but raises when a job's input file cannot be read (the job then fails as an internal error)."
  def input!(job) do
    case input(job) do
      %{} = input -> input
      _ -> raise "the input of job #{job["id"]} is missing"
    end
  end

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
  Finish what a finished job still owes: its cost in the ledger, and its
  webhook on the schedule. Both are normally done the moment a job ends
  (`finish/3`); this catches the ones that ended while the ledger or the
  webhook process was restarting. Called periodically; cheap when nothing is
  owed. Returns `%{ledgered: n, webhooks: n}`.
  """
  def reconcile(now \\ System.os_time(:millisecond)) do
    %{unledgered: unledgered, webhooks: webhooks} = Store.unsettled()

    ledgered =
      Enum.count(unledgered, fn id ->
        case Store.get(id) do
          %{"ledgered" => false} = job -> record_cost(job) == :ok
          _ -> false
        end
      end)

    # A delivery that is overdue by more than a moment has lost its timer.
    due = for {id, at} <- webhooks, is_nil(at) or at < now - 5_000, do: id
    Enum.each(due, &Webhooks.schedule(&1, 0))
    %{ledgered: ledgered, webhooks: length(due)}
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

  @doc """
  Client-facing JSON view: no internal fields, fresh output URLs.

  `input: false` leaves a large input (one kept in its own file) out and
  says so with `"input_omitted": true`; a list of jobs uses it so that one
  response cannot be made of a hundred megabyte-sized inputs.
  """
  def view(job, opts \\ []) do
    {input, omitted} =
      cond do
        job["input_file"] != true -> {job["input"], false}
        Keyword.get(opts, :input, true) -> {input(job), false}
        true -> {nil, true}
      end

    job
    |> Map.take(@public)
    |> Map.merge(%{
      "object" => "job",
      "input" => input,
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
    |> then(&if(omitted, do: Map.put(&1, "input_omitted", true), else: &1))
  end

  @doc """
  Cost in USD of a finished job under a target's price.

  `billable` is what the adapter reported it sent (`Adapter.billable/1`), not
  what the client's input says. Every component is at least zero on its own,
  so no field can lower the price of another.
  """
  def cost(price, billable, output_count) do
    part = fn rate, quantity -> if is_number(rate) and is_number(quantity) and rate > 0 and quantity > 0, do: rate * quantity, else: 0.0 end

    part.(price.per_job_usd, 1) + part.(price.per_output_usd, output_count) +
      part.(price.per_input_char_usd, Map.get(billable, :chars, 0)) + part.(price.per_second_usd, Map.get(billable, :seconds, 0))
  end

  @doc """
  Cost in USD of a finished job on one target of a route.

  What the target's price is applied to follows the operator's config as
  well as the request:

    * seconds: what the adapter sends to the provider, or the target's
      `default_seconds` when the request names none, and never less than the
      target's `min_seconds`. A client cannot make a per-second job free by
      leaving the duration out or declaring a tiny one.
    * the route's `price_multipliers`: the whole price is multiplied by the
      factor configured for the value of each listed input field
      (`{"quality": {"high": 4}}`). A value that is not listed (possible only
      if the config changed after the job was accepted) is charged at the
      highest factor of its field.
  """
  def job_cost(route, target, billable, input, output_count) do
    billable =
      if is_number(target.price.per_second_usd) and target.price.per_second_usd > 0 do
        Map.put(billable, :seconds, billed_seconds(target, Map.get(billable, :seconds, 0)))
      else
        billable
      end

    cost(target.price, billable, output_count) * multiplier(route, input)
  end

  @doc "Seconds a target bills for a request that asks for `requested` (0 = it names none)."
  def billed_seconds(target, requested) do
    requested = if is_number(requested) and requested > 0, do: requested, else: Map.get(target, :default_seconds) || 0
    max(requested, Map.get(target, :min_seconds) || 0)
  end

  @doc "The factor a route's `price_multipliers` give for `input` (1.0 when there are none)."
  def multiplier(route, input) when is_map(input) do
    Enum.reduce(Map.get(route, :price_multipliers) || %{}, 1.0, fn {field, factors}, product ->
      case factor(factors, Map.get(input, field)) do
        {:ok, f} -> product * f
        :error -> product * (factors |> Map.values() |> Enum.max(fn -> 1.0 end))
      end
    end)
  end

  def multiplier(_route, _input), do: 1.0

  # The factor for one field's value: the listed one, `"default"` (or 1) when
  # the request does not send the field, `:error` for a value not listed.
  defp factor(factors, nil), do: {:ok, Map.get(factors, "default", 1.0)}

  defp factor(factors, value) when is_binary(value) or is_number(value) or is_boolean(value) do
    case factors do
      %{^value => f} -> {:ok, f}
      _ -> Map.fetch(factors, to_string(value))
    end
  end

  defp factor(_factors, _value), do: :error

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

  # `:ok` once the job's cost is in the ledger and the job says so. If the
  # ledger cannot be reached right now (it is restarting), the job keeps
  # `"ledgered": false` and `reconcile/1` comes back to it; the job id is the
  # event id, so recording it twice is harmless.
  defp record_cost(job) do
    do_record_cost(job)
    :ok
  catch
    kind, reason ->
      Logger.error("job #{job["id"]}: its cost is not in the ledger yet (#{Text.line(inspect({kind, reason}), 200)}); it will be recorded later")
      :error
  end

  defp do_record_cost(job) do
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

  # A job's input is kept on disk for as long as the job is. Returns the
  # input's JSON, which is what gets written when it is large.
  defp small_enough(input, metadata) do
    max = ConfigStore.get().media |> Map.get(:max_input_bytes, 1_048_576)
    input_json = JSON.encode!(input)

    if byte_size(input_json) + byte_size(JSON.encode!(metadata)) > max do
      {:error, 413, "payload_too_large", "\"input\" and \"metadata\" together must not exceed #{max} bytes"}
    else
      {:ok, input_json}
    end
  end

  # A route may list the input fields it accepts. Anything else is refused
  # rather than forwarded: providers bill for options (a quality, a size, a
  # number of outputs) the operator's price does not know about.
  defp fields_allowed(input, route) do
    case Map.get(route, :allowed_input) do
      nil ->
        :ok

      allowed ->
        case input |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort() do
          [] ->
            :ok

          extra ->
            {:error, 400, "invalid_request",
             "this model does not accept the input field(s) #{extra |> Enum.take(5) |> Enum.map_join(", ", &Text.line(&1, 60))}; allowed: #{Enum.join(allowed, ", ")}"}
        end
    end
  end

  # A field with configured price multipliers may only carry a listed value.
  defp multipliers_ok(input, route) do
    Enum.find_value(Map.get(route, :price_multipliers) || %{}, :ok, fn {field, factors} ->
      case factor(factors, Map.get(input, field)) do
        {:ok, _} ->
          nil

        :error ->
          listed = factors |> Map.keys() |> Enum.reject(&(&1 == "default")) |> Enum.sort() |> Enum.join(", ")
          {:error, 400, "invalid_request", "\"input.#{field}\" must be one of: #{listed}"}
      end
    end)
  end

  @durations ~w(duration seconds)
  @counts ~w(n num_outputs num_images)

  # These fields feed the price. A negative or non-numeric value is refused
  # here rather than left for a provider to ignore, and a model that is
  # priced per second needs a duration to price: from the request, or from
  # the target's `default_seconds`.
  defp quantities_ok(input, route) do
    per_second = Enum.filter(route.targets, &(is_number(&1.price.per_second_usd) and &1.price.per_second_usd > 0))

    shape =
      Enum.find_value(@durations ++ @counts, :ok, fn field ->
        case Map.fetch(input, field) do
          :error ->
            nil

          {:ok, value} ->
            cond do
              field in @durations and not match?({:ok, _}, Adapter.seconds_value(value)) ->
                {:error, 400, "invalid_request", "\"input.#{field}\" must be a number of seconds, 0 or more (5, \"5\" or \"5s\")"}

              field in @counts and not (is_integer(value) and value >= 0) ->
                {:error, 400, "invalid_request", "\"input.#{field}\" must be a whole number, 0 or more"}

              true ->
                nil
            end
        end
      end)

    with :ok <- shape, do: duration_priced(input, per_second)
  end

  defp duration_priced(_input, []), do: :ok

  defp duration_priced(input, per_second) do
    in_request = Adapter.seconds(input, @durations)

    Enum.find_value(per_second, :ok, fn target ->
      max = Map.get(target, :max_seconds)
      # Only what the provider is actually sent counts: a kind that takes no
      # duration is billed on the target's default whatever the input says,
      # exactly as `job_cost/5` does (its adapter reports 0 seconds).
      upstream = ConfigStore.media_upstream(target.upstream)
      requested = if upstream && Adapter.takes_duration?(upstream.kind), do: in_request, else: 0

      cond do
        requested <= 0 and is_nil(Map.get(target, :default_seconds)) ->
          {:error, 400, "invalid_request",
           "this model is priced per second: send \"input.duration\", a number of seconds above 0 " <>
             "(the operator has not set a default duration for it)"}

        is_number(max) and requested > max ->
          {:error, 400, "invalid_request", "\"input.duration\" must be at most #{max} seconds for this model"}

        true ->
          nil
      end
    end)
  end

  defp seconds_until_utc_midnight do
    now = DateTime.utc_now()
    86_400 - (now.hour * 3_600 + now.minute * 60 + now.second)
  end

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

  # Stored with the job and written to its log, so it has to be text.
  defp idempotency_key_ok(k) when byte_size(k) in 1..255 do
    if String.printable?(k), do: :ok, else: {:error, 400, "invalid_request", "Idempotency-Key must be printable UTF-8 text"}
  end

  defp idempotency_key_ok(_), do: {:error, 400, "invalid_request", "Idempotency-Key must be 1 to 255 bytes"}

  defp hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  defp random_id, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  defp iso(dt), do: dt |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
