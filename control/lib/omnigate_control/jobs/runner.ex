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
  """
  require Logger

  alias OmnigateControl.{ConfigStore, Http, Jobs, NetGuard, Storage}
  alias OmnigateControl.Jobs.{Adapter, Store}

  @max_transient_poll_errors 5

  def run(id) do
    case Store.get(id) do
      %{"status" => s} = job when s in ["queued", "running"] ->
        attempt(job, get_in(job, ["run", "target_index"]) || 0)

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.error("job #{id} crashed: " <> Exception.format(:error, e, __STACKTRACE__))
      Jobs.finish(id, "failed", %{"error" => %{"type" => "internal_error", "message" => "the gateway failed while running this job"}})
  end

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
        Jobs.finish(job["id"], "failed", %{"error" => %{"type" => "route_removed", "message" => "the route for this model no longer exists"}})

      index >= length(route.targets) ->
        Jobs.finish(job["id"], "failed", %{"error" => %{"type" => "all_targets_failed", "message" => "every target for this model failed"}})

      true ->
        target = Enum.at(route.targets, index)

        case resolve(target, route) do
          {:ok, t} -> run_target(job, index, Map.merge(t, %{target: target, timeout_ms: route.timeout_s * 1000}))
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
      true -> {:ok, %{upstream: upstream, adapter: adapter, ctx: %{api_key: api_key, timeout_ms: route.timeout_s * 1000}}}
    end
  end

  defp run_target(job, index, t) do
    run = job["run"] || %{}

    if run["target_index"] == index and is_binary(run["provider_id"]) do
      # Resumed after a restart: the provider already has this job.
      Logger.info("job #{job["id"]}: resuming provider job #{run["provider_id"]} on #{t.upstream.name}")
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
        case t.adapter.submit(t.upstream, t.target.model, job["input"], t.ctx) do
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
    current = Store.get(job["id"])
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
    Logger.warning("job #{job["id"]}: #{upstream_name} failed (#{outcome}), trying next target")

    moved =
      update_running(job["id"], fn j ->
        j
        |> Map.put("attempts", (j["attempts"] || []) ++ [%{"upstream" => upstream_name, "outcome" => outcome}])
        |> Map.put("run", %{"target_index" => index + 1})
      end)

    with {:ok, job} <- moved, do: attempt(job, index + 1)
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
        Jobs.finish(job["id"], "succeeded", %{
          "outputs" => records,
          "upstream" => t.upstream.name,
          "target_model" => t.target.model,
          "cost_usd" => Jobs.cost(t.target.price, t.adapter.billable(job["input"]), length(records)),
          "attempts" => (Store.get(job["id"])["attempts"] || []) ++ [%{"upstream" => t.upstream.name, "outcome" => "ok"}]
        })

      {:error, reason} ->
        Enum.each(files, fn {_i, tmp, _meta, _o} -> File.rm(tmp) end)
        Logger.error("job #{job["id"]}: storing outputs failed: #{describe(reason)}")

        # Another provider would hit the same broken storage; fail the job.
        Jobs.finish(job["id"], "failed", %{
          "upstream" => t.upstream.name,
          "target_model" => t.target.model,
          "error" => %{"type" => "storage_error", "message" => "the provider produced outputs but they could not be stored"}
        })
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
    Store.update(id, fn job -> if Jobs.terminal?(job), do: :noop, else: fun.(job) end)
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: reason |> inspect() |> String.slice(0, 200)
end
