defmodule OmnigateControl.Jobs.Runner do
  @moduledoc """
  Runs one job to completion: submit to a target, poll, re-host the outputs,
  and fail over to the next target when something goes wrong.

  Progress is persisted at each step that matters (`run` inside the job):

    * before a submit: which target is being tried
    * right after an async submit: the provider's job id

  so `run/1` can be called again after a restart and continues where the
  previous process stopped. A job that already has a provider id is polled,
  never resubmitted.

  The job store can restart while a job is running (it is supervised like
  everything else). A runner then waits for it to come back instead of
  dying or failing the job: every read and write of job state goes through
  `with_store/1`.

  Whatever a provider says about a failure is treated as bytes from outside:
  it becomes one line of valid UTF-8 (`OmnigateControl.Text.line/2`) before
  it is logged or stored.
  """
  require Logger

  alias OmnigateControl.{ConfigStore, Counters, Http, Jobs, NetGuard, Storage, Text}
  alias OmnigateControl.Jobs.{Adapter, Store}

  @max_transient_poll_errors 5

  def run(id) do
    case with_store(fn -> Store.get(id) end) do
      %{"status" => s} = job when s in ["queued", "running"] ->
        attempt(job, get_in(job, ["run", "target_index"]) || 0)

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.error("job #{id} crashed: " <> Exception.format(:error, e, __STACKTRACE__))
      finish(id, "failed", %{"error" => %{"type" => "internal_error", "message" => "the gateway failed while running this job"}})
  end

  # Run `fun`, which reads or writes job state. While the store is restarting
  # its tables do not exist (reads raise) and its process is gone (calls
  # exit); wait for it, up to about half a minute, rather than give up.
  defp with_store(fun, tries \\ 60) do
    fun.()
  rescue
    e in ArgumentError ->
      if tries > 0, do: retry_store(fun, tries), else: reraise(e, __STACKTRACE__)
  catch
    :exit, reason ->
      if tries > 0, do: retry_store(fun, tries), else: exit(reason)
  end

  defp retry_store(fun, tries) do
    Process.sleep(500)
    with_store(fun, tries - 1)
  end

  defp finish(id, status, changes), do: with_store(fn -> Jobs.finish(id, status, changes) end)

  @doc "Best-effort cancel of the provider-side job recorded in `job`."
  def cancel_provider(%{"run" => %{"provider_id" => pid, "target_index" => index} = run} = job) when is_binary(pid) do
    with %{} = route <- ConfigStore.media_route(job["model"]),
         %{} = target <- Enum.at(route.targets, index),
         {:ok, t} <- resolve(target, route) do
      if function_exported?(t.adapter, :cancel, 5) do
        # `cancel` and `poll` are optional callbacks, hence the dynamic call.
        apply(t.adapter, :cancel, [t.upstream, target.model, pid, run["provider_state"] || %{}, t.ctx])
      end
    end

    :ok
  end

  def cancel_provider(_job), do: :ok

  # -- one target ------------------------------------------------------------

  defp attempt(job, index) do
    route = ConfigStore.media_route(job["model"])

    cond do
      route == nil ->
        finish(job["id"], "failed", %{"error" => %{"type" => "route_removed", "message" => "the route for this model no longer exists"}})

      index >= length(route.targets) ->
        finish(job["id"], "failed", %{"error" => %{"type" => "all_targets_failed", "message" => "every target for this model failed"}})

      true ->
        target = Enum.at(route.targets, index)

        case resolve(target, route) do
          {:ok, t} -> run_target(job, index, Map.merge(t, %{route: route, target: target, timeout_ms: route.timeout_s * 1000}))
          {:error, outcome} -> next(job, index, target.upstream, outcome)
        end
    end
  end

  defp resolve(target, route) do
    upstream = ConfigStore.media_upstream(target.upstream)
    adapter = upstream && Adapter.for_kind(upstream.kind)
    api_key = upstream && System.get_env(upstream.api_key_env)

    cond do
      upstream == nil -> {:error, "unknown_upstream"}
      adapter == nil -> {:error, "unsupported_kind:#{upstream.kind}"}
      api_key in [nil, ""] -> {:error, "missing_api_key_env:#{upstream.api_key_env}"}
      true -> {:ok, %{upstream: upstream, adapter: adapter, ctx: %{api_key: api_key, timeout_ms: route.timeout_s * 1000, max_inline_bytes: inline_cap()}}}
    end
  end

  defp run_target(job, index, t) do
    run = job["run"] || %{}

    if run["target_index"] == index and is_binary(run["provider_id"]) do
      # Resumed after a restart: the provider already has this job.
      Logger.info("job #{job["id"]}: resuming provider job #{Text.line(run["provider_id"], 100)} on #{t.upstream.name}")
      poll_loop(job, index, t, 0)
    else
      now = System.os_time(:millisecond)

      started =
        update_running(job["id"], fn j ->
          j
          |> Map.put("status", "running")
          |> Map.put("started_at", j["started_at"] || Store.now_iso())
          |> Map.put("run", %{"target_index" => index, "provider_id" => nil, "provider_state" => %{}, "attempt_started_ms" => now})
        end)

      with {:ok, job} <- started do
        case t.adapter.submit(t.upstream, t.target.model, Jobs.input!(job), t.ctx) do
          {:async, provider_id, state} ->
            recorded =
              update_running(job["id"], fn j ->
                Map.put(j, "run", Map.merge(j["run"], %{"provider_id" => provider_id, "provider_state" => state}))
              end)

            case recorded do
              {:ok, job} -> poll_loop(job, index, t, 0)
              # Canceled while the submit was in flight.
              _ -> cancel_provider(put_in(job, ["run", "provider_id"], provider_id))
            end

          {:done, outputs} ->
            rehost(job, index, t, outputs)

          {:error, reason} ->
            next(job, index, t.upstream.name, reason)
        end
      end
    end
  end

  defp poll_loop(job, index, t, errors) do
    Process.sleep(ConfigStore.get().media.poll_interval_ms)
    current = with_store(fn -> Store.get(job["id"]) end)
    run = job["run"]

    cond do
      current == nil or Jobs.terminal?(current) ->
        cancel_provider(job)

      System.os_time(:millisecond) > run["attempt_started_ms"] + t.timeout_ms ->
        cancel_provider(job)
        next(job, index, t.upstream.name, "timeout")

      true ->
        case apply(t.adapter, :poll, [t.upstream, t.target.model, run["provider_id"], run["provider_state"] || %{}, t.ctx]) do
          :pending -> poll_loop(job, index, t, 0)
          {:done, outputs} -> rehost(job, index, t, outputs)
          {:error, reason} -> next(job, index, t.upstream.name, reason)
          {:transient, reason} when errors + 1 >= @max_transient_poll_errors -> next(job, index, t.upstream.name, reason)
          {:transient, _reason} -> poll_loop(job, index, t, errors + 1)
        end
    end
  end

  # Record a failed attempt and move on to the next target.
  defp next(job, index, upstream_name, outcome) do
    outcome = Text.line(outcome, 300)
    Logger.warning("job #{job["id"]}: #{upstream_name} failed (#{outcome}), trying next target")

    moved =
      update_running(job["id"], fn j ->
        j
        |> Map.put("attempts", (j["attempts"] || []) ++ [%{"upstream" => upstream_name, "outcome" => outcome}])
        |> Map.put("run", %{"target_index" => index + 1})
      end)

    case moved do
      {:ok, job} ->
        attempt(job, index + 1)

      {:error, reason} ->
        # The store could not record the move (its disk, most likely). The
        # job stays as it is and is picked up again at the next start.
        Logger.error("job #{job["id"]}: could not record a failed attempt (#{Text.line(reason, 100)}); leaving it for the next start")

      # Finished in the meantime (canceled).
      other ->
        other
    end
  end

  # -- outputs ---------------------------------------------------------------

  defp rehost(job, index, t, []), do: next(job, index, t.upstream.name, "no_outputs")

  defp rehost(job, index, t, outputs) do
    max = ConfigStore.get().media.max_output_bytes
    tmp_dir = Storage.tmp_dir()

    fetched =
      outputs
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {output, i}, {:ok, acc} ->
        tmp = Path.join(tmp_dir, "#{job["id"]}-#{i}")

        case fetch(output, tmp, max) do
          {:ok, meta} -> {:cont, {:ok, acc ++ [{i, tmp, meta, output}]}}
          {:error, reason} -> {:halt, {:error, reason, acc}}
        end
      end)

    case fetched do
      {:ok, files} ->
        store(job, t, files)

      {:error, reason, files} ->
        Enum.each(files, fn {_i, tmp, _meta, _o} -> File.rm(tmp) end)
        next(job, index, t.upstream.name, "output_fetch_failed: #{describe(reason)}")
    end
  end

  defp store(job, t, files) do
    stored =
      Enum.reduce_while(files, {:ok, []}, fn {i, tmp, meta, output}, {:ok, acc} ->
        name = "out-#{i}#{extension(meta["content_type"], output)}"

        case Storage.put(job["id"], name, tmp, meta) do
          {:ok, record} -> {:cont, {:ok, acc ++ [record]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case stored do
      {:ok, records} ->
        input = Jobs.input!(job)
        unpriced(job, t)

        finish(job["id"], "succeeded", %{
          "outputs" => records,
          "upstream" => t.upstream.name,
          "target_model" => t.target.model,
          "cost_usd" => Jobs.job_cost(t.route, t.target, t.adapter.billable(input), input, length(records)),
          "attempts" => (with_store(fn -> Store.get(job["id"]) end)["attempts"] || []) ++ [%{"upstream" => t.upstream.name, "outcome" => "ok"}]
        })

      {:error, reason} ->
        Enum.each(files, fn {_i, tmp, _meta, _o} -> File.rm(tmp) end)
        Logger.error("job #{job["id"]}: storing outputs failed: #{describe(reason)}")

        # Another provider would hit the same broken storage; fail the job.
        finish(job["id"], "failed", %{
          "upstream" => t.upstream.name,
          "target_model" => t.target.model,
          "error" => %{"type" => "storage_error", "message" => "the provider produced outputs but they could not be stored"}
        })
    end
  end

  # A target with no price at all makes every job on it free for the key's
  # budget. That may be meant (a local model), but it is also what a
  # forgotten `price` looks like, so it is counted and said once per target.
  defp unpriced(job, t) do
    if not Enum.any?(Map.values(t.target.price), &(is_number(&1) and &1 > 0)) do
      Counters.bump(:ledger_unpriced_events, 1)

      if Counters.once({:unpriced_job, job["model"], t.upstream.name, t.target.model}) do
        Logger.warning(
          "media route #{Text.line(job["model"], 80)}: target #{t.upstream.name}/#{Text.line(t.target.model, 80)} has no price, so its jobs are recorded at $0 " <>
            "(logged once per target; see omnigate_ledger_unpriced_events_total)"
        )
      end
    end
  end

  defp fetch({:url, url}, tmp, max), do: fetch({:url, url, nil}, tmp, max)

  defp fetch({:url, url, hint}, tmp, max) do
    # The URL came out of a provider's answer: never fetch it, or anything
    # it redirects to, from an address we would not call for a webhook.
    with {:ok, meta} <- Http.download(url, tmp, max, guard: &NetGuard.target(&1, "output url")) do
      {:ok, %{"bytes" => meta.bytes, "sha256" => meta.sha256, "content_type" => content_type(hint, meta.content_type, url)}}
    end
  end

  defp fetch({:binary, bytes, content_type}, tmp, max) do
    if byte_size(bytes) > max do
      {:error, :output_too_large}
    else
      with :ok <- File.write(tmp, bytes) do
        {:ok,
         %{
           "bytes" => byte_size(bytes),
           "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
           "content_type" => clean(content_type) || "application/octet-stream"
         }}
      end
    end
  end

  @types %{
    "image/png" => ".png",
    "image/jpeg" => ".jpg",
    "image/webp" => ".webp",
    "image/gif" => ".gif",
    "image/svg+xml" => ".svg",
    "video/mp4" => ".mp4",
    "video/webm" => ".webm",
    "video/quicktime" => ".mov",
    "audio/mpeg" => ".mp3",
    "audio/wav" => ".wav",
    "audio/x-wav" => ".wav",
    "audio/ogg" => ".ogg",
    "audio/flac" => ".flac",
    "audio/pcm" => ".pcm",
    "application/json" => ".json"
  }
  @by_ext Map.new(@types, fn {type, ext} -> {ext, type} end) |> Map.merge(%{".jpeg" => "image/jpeg", ".wav" => "audio/wav"})

  # Prefer what the adapter said, then a specific response header, then the URL's extension.
  defp content_type(hint, header, url) do
    generic = [nil, "application/octet-stream", "binary/octet-stream"]

    Enum.find([clean(hint), clean(header)], &(&1 not in generic)) ||
      Map.get(@by_ext, url_ext(url), "application/octet-stream")
  end

  defp clean(nil), do: nil
  defp clean(type), do: type |> String.split(";") |> hd() |> String.trim() |> String.downcase()

  defp extension(content_type, output) do
    case Map.get(@types, content_type) do
      nil ->
        ext = if match?({:url, _, _}, output) or match?({:url, _}, output), do: url_ext(elem(output, 1)), else: ""
        if ext =~ ~r/^\.[a-z0-9]{1,5}$/, do: ext, else: ".bin"

      ext ->
        ext
    end
  end

  defp url_ext(url), do: (URI.parse(url).path || "") |> Path.extname() |> String.downcase()

  defp update_running(id, fun) do
    with_store(fn -> Store.update(id, fn job -> if Jobs.terminal?(job), do: :noop, else: fun.(job) end) end)
  end

  defp describe(reason), do: Text.line(reason, 200)

  # Largest provider answer read when the media comes back inline: the output
  # limit, as base64 (4/3) plus the JSON around it, and never more than 256 MiB
  # in memory at once.
  defp inline_cap, do: min(div(ConfigStore.get().media.max_output_bytes * 4, 3) + 65_536, 256 * 1024 * 1024)
end
