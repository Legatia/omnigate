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

  ## A job canceled while its provider call is in flight

  The client's cancel ends the job at once, marked `"provider_pending"`
  (`Jobs.cancel/2`). The runner is the one who learns how the provider call
  ended, and it always closes the account with `Jobs.settle_canceled/2`:

    * the provider finished (a submit that answers with the result, a poll
      that says "done", a result that was being stored): the job's price is
      recorded against the key; nothing is downloaded, and anything already
      stored is deleted;
    * the provider can be told to stop: it is told, asked once more how the
      job ended, and billed only if it had finished anyway;
    * the provider cannot be told to stop (it has no cancel, or its adapter
      answers `:not_canceled` because generation has started): it is polled
      on, to the route's timeout, to see whether it finishes;
    * the attempt failed, or timed out: nothing is owed.
  """
  require Logger

  alias OmnigateControl.{Age, ConfigStore, Counters, Http, Jobs, NetGuard, Storage, Text}
  alias OmnigateControl.Jobs.{Adapter, Store}

  @max_transient_poll_errors 5

  def run(id) do
    case with_store(fn -> Store.get(id) end) do
      %{"status" => s} = job when s in ["queued", "running"] ->
        attempt(job, get_in(job, ["run", "target_index"]) || 0)

      %{"status" => "canceled", "provider_pending" => true} = job ->
        resume_canceled(job)

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.error("job #{id} crashed: " <> Exception.format(:error, e, __STACKTRACE__))
      finish(id, "failed", %{"error" => %{"type" => "internal_error", "message" => "the gateway failed while running this job"}})
  end

  # After a restart (or a lost runner): a job that was canceled while its
  # provider call was in flight. With a provider job id the question "did it
  # finish?" can still be asked; a call that had not answered when we stopped
  # is lost with the process, like that of any job interrupted by a restart.
  defp resume_canceled(job) do
    run = job["run"] || %{}
    index = run["target_index"]
    route = ConfigStore.media_route(job["model"])
    target = route && is_integer(index) && Enum.at(route.targets, index)

    with true <- is_binary(run["provider_id"]),
         %{} <- target,
         {:ok, t} <- resolve(target, route) do
      after_cancel(job, index, Map.merge(t, %{route: route, target: target, timeout_ms: route.timeout_s * 1000}))
    else
      _ -> settle_canceled(job["id"], %{})
    end
  end

  # The job was canceled and the provider has it under an id.
  defp after_cancel(job, index, t) do
    run = job["run"]

    stopped =
      can_cancel?(t) and
        apply(t.adapter, :cancel, [t.upstream, t.target.model, run["provider_id"], run["provider_state"] || %{}, t.ctx]) != :not_canceled

    if stopped do
      # Told to stop. If it had finished before that, it has been paid for.
      case done(apply(t.adapter, :poll, [t.upstream, t.target.model, run["provider_id"], run["provider_state"] || %{}, t.ctx])) do
        {:done, [_ | _] = outputs, measured} -> settle_canceled(job["id"], completed(job, Map.put(t, :measured, measured), length(outputs)))
        _ -> settle_canceled(job["id"], %{})
      end
    else
      # It cannot be stopped (no cancel at this provider, or too late for
      # one): see whether it finishes.
      poll_loop(job, index, Map.put(t, :cannot_cancel, true), 0)
    end
  end

  defp can_cancel?(t), do: function_exported?(t.adapter, :cancel, 5) and not Map.get(t, :cannot_cancel, false)

  # An adapter's "done", with what the provider measured (nothing, as a rule).
  defp done({:done, outputs}), do: {:done, outputs, %{}}
  defp done({:done, outputs, %{} = measured}), do: {:done, outputs, measured}
  defp done(other), do: other

  # What the job is billed for: the request as the adapter sends it, and the
  # seconds the provider says it made in place of those asked for.
  defp billable(t, input) do
    billable = t.adapter.billable(input)

    case Map.get(t, :measured, %{}) do
      %{seconds: s} when is_number(s) and s > 0 -> Map.put(billable, :seconds, s)
      _ -> billable
    end
  end

  defp settle_canceled(id, changes), do: with_store(fn -> Jobs.settle_canceled(id, changes) end)

  # What a canceled job owes for a provider call that completed with `count` outputs.
  defp completed(job, t, count) do
    input = Jobs.input!(job)
    unpriced(job, t)
    Logger.info("job #{job["id"]}: canceled, but #{t.upstream.name} completed the call (#{count} output(s)); its price is recorded, nothing is stored")

    %{
      "upstream" => t.upstream.name,
      "target_model" => t.target.model,
      "cost_usd" => Jobs.job_cost(t.route, t.target, billable(t, input), input, count),
      "attempts" =>
        ((with_store(fn -> Store.get(job["id"]) end) || %{})["attempts"] || []) ++ [%{"upstream" => t.upstream.name, "outcome" => "completed_after_cancel"}]
    }
  end

  defp canceled_pending?(id), do: Jobs.provider_pending?(with_store(fn -> Store.get(id) end) || %{})

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

  # A job that was finished under the runner (canceled) may still be waiting
  # for its account to be closed; whatever the runner was about to record,
  # nothing more is owed for it.
  defp finish(id, status, changes) do
    case with_store(fn -> Jobs.finish(id, status, changes) end) do
      :noop -> settle_canceled(id, %{})
      other -> other
    end
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
        finish(job["id"], "failed", %{"error" => %{"type" => "route_removed", "message" => "the route for this model no longer exists"}})

      index >= length(route.targets) ->
        finish(job["id"], "failed", %{"error" => %{"type" => "all_targets_failed", "message" => "every target for this model failed"}})

      true ->
        target = Enum.at(route.targets, index)

        case resolve(target, route) do
          {:ok, t} ->
            # A target whose price has no rate for this request is not sent
            # the job: it would run, and be recorded at a price nobody set.
            case Jobs.price_for(target, Jobs.input!(job)) do
              {:ok, _price} -> run_target(job, index, Map.merge(t, %{route: route, target: target, timeout_ms: route.timeout_s * 1000}))
              :unmatched -> next(job, index, target.upstream, "unpriced_variant: the price of this target has no variant for this request")
            end

          {:error, outcome} ->
            next(job, index, target.upstream, outcome)
        end
    end
  end

  defp resolve(target, route) do
    upstream = ConfigStore.media_upstream(target.upstream)
    adapter = upstream && Adapter.for_kind(upstream.kind)
    api_key = upstream && System.get_env(upstream.api_key_env)

    cond do
      upstream == nil ->
        {:error, "unknown_upstream"}

      adapter == nil ->
        {:error, "unsupported_kind:#{upstream.kind}"}

      api_key in [nil, ""] ->
        {:error, "missing_api_key_env:#{upstream.api_key_env}"}

      true ->
        ctx = %{api_key: api_key, timeout_ms: route.timeout_s * 1000, max_inline_bytes: inline_cap(), router: Map.get(target, :router)}
        {:ok, %{upstream: upstream, adapter: adapter, ctx: ctx}}
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
        case done(t.adapter.submit(t.upstream, t.target.model, Jobs.input!(job), Map.merge(t.ctx, %{job_id: job["id"], attempt: index}))) do
          {:async, provider_id, state} ->
            # Recorded also for a job canceled while the submit was in flight:
            # its account is still open, and closing it takes the id.
            recorded =
              with_store(fn ->
                Store.update(job["id"], fn j ->
                  if Jobs.terminal?(j) and not Jobs.provider_pending?(j) do
                    :noop
                  else
                    Map.put(j, "run", Map.merge(j["run"] || %{}, %{"provider_id" => provider_id, "provider_state" => state}))
                  end
                end)
              end)

            case recorded do
              {:ok, %{"status" => "canceled"} = job} -> after_cancel(job, index, t)
              {:ok, job} -> poll_loop(job, index, t, 0)
              _ -> cancel_provider(put_in(job, ["run", "provider_id"], provider_id))
            end

          {:done, outputs, measured} ->
            rehost(job, index, Map.put(t, :measured, measured), outputs)

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
      current == nil ->
        cancel_provider(job)

      # Canceled by the client just now, on a provider that can be told so.
      Jobs.provider_pending?(current) and can_cancel?(t) ->
        after_cancel(current, index, t)

      # Finished some other way. (A canceled job on a provider that cannot be
      # stopped is polled on below, to learn whether the call completes.)
      Jobs.terminal?(current) and not Jobs.provider_pending?(current) ->
        cancel_provider(job)

      System.os_time(:millisecond) > (run["attempt_started_ms"] || 0) + t.timeout_ms ->
        cancel_provider(job)
        next(job, index, t.upstream.name, "timeout")

      true ->
        case done(apply(t.adapter, :poll, [t.upstream, t.target.model, run["provider_id"], run["provider_state"] || %{}, t.ctx])) do
          :pending -> poll_loop(job, index, t, 0)
          {:done, outputs, measured} -> rehost(job, index, Map.put(t, :measured, measured), outputs)
          {:error, reason} -> next(job, index, t.upstream.name, reason)
          {:transient, reason} when errors + 1 >= @max_transient_poll_errors -> next(job, index, t.upstream.name, reason)
          {:transient, _reason} -> poll_loop(job, index, t, errors + 1)
        end
    end
  end

  # Record a failed attempt and move on to the next target.
  defp next(job, index, upstream_name, outcome) do
    # A provider's words about a failure can quote what it was sent. For a
    # private job only the kind of failure is kept (`http_400`, `timeout`).
    outcome = if job["private"] == true, do: kind_only(outcome), else: Text.line(outcome, 300)
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

      # Finished in the meantime (canceled): the attempt failed, nothing is owed.
      _other ->
        settle_canceled(job["id"], %{})
    end
  end

  defp kind_only(outcome) do
    case Regex.run(~r/\A[a-z0-9_]{1,40}(?=:|\z)/, to_string(outcome)) do
      [kind] -> kind
      _ -> "provider_error"
    end
  rescue
    _ -> "provider_error"
  end

  # -- outputs ---------------------------------------------------------------

  defp rehost(job, index, t, []), do: next(job, index, t.upstream.name, "no_outputs")

  defp rehost(job, index, t, outputs) do
    media = ConfigStore.get().media
    # (Defaults for a config built without them, as the tests do.)
    media = Map.merge(%{max_outputs_per_job: 16, max_job_output_bytes: max(2 * 1024 * 1024 * 1024, media.max_output_bytes)}, media)
    count = length(outputs)

    cond do
      # Canceled while the provider was working: the call completed and is
      # billed, but nothing of it is fetched or kept.
      canceled_pending?(job["id"]) ->
        settle_canceled(job["id"], completed(job, t, min(count, media.max_outputs_per_job)))

      # What a provider's answer lists is not ours to trust: each entry is a
      # download of up to `max_output_bytes`.
      count > media.max_outputs_per_job ->
        next(
          job,
          index,
          t.upstream.name,
          "too_many_outputs: the provider returned #{count}, at most #{media.max_outputs_per_job} are taken (media.max_outputs_per_job)"
        )

      true ->
        fetch_all(job, index, t, outputs, media)
    end
  end

  defp fetch_all(job, index, t, outputs, media) do
    tmp_dir = Storage.tmp_dir()
    tmps = for i <- 0..(length(outputs) - 1), do: Path.join(tmp_dir, "#{job["id"]}-#{i}")

    try do
      fetched =
        outputs
        |> Enum.zip(tmps)
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, [], media.max_job_output_bytes}, fn {{output, tmp}, i}, {:ok, acc, left} ->
          # Never more than one file's limit, nor than what is left of the job's.
          # (With `encrypt_to`, what reaches `tmp` is already ciphertext.)
          case fetch(output, tmp, min(media.max_output_bytes, left), job["encrypt_to"]) do
            {:ok, meta} ->
              {:cont, {:ok, acc ++ [{i, tmp, meta, output}], left - (meta["plaintext_bytes"] || meta["bytes"])}}

            {:error, :output_too_large} when left < media.max_output_bytes ->
              {:halt, {:error, "the outputs together exceed media.max_job_output_bytes (#{media.max_job_output_bytes})"}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      case fetched do
        {:ok, files, _left} ->
          store(job, t, files)

        {:error, reason} ->
          # Before the job is told: `next` may make it terminal, and nobody
          # who then looks should still find a half-fetched file of it.
          Enum.each(tmps, &File.rm/1)
          next(job, index, t.upstream.name, "output_fetch_failed: #{describe(reason)}")
      end
    after
      # Whatever happened (a download that failed half way, a raise, storage
      # that refused): no file of this job stays in the temp directory. Files
      # that were stored have been moved out of it already.
      Enum.each(tmps, &File.rm/1)
    end
  end

  defp store(job, t, files) do
    stored =
      Enum.reduce_while(files, {:ok, []}, fn {i, tmp, meta, output}, {:ok, acc} ->
        # An encrypted output keeps the extension of what is inside: `out-0.png.age`.
        name = "out-#{i}#{extension(meta["plaintext_content_type"] || meta["content_type"], output)}#{if meta["encryption"], do: ".age", else: ""}"

        case Storage.put(job["id"], name, tmp, meta) do
          {:ok, record} -> {:cont, {:ok, acc ++ [record]}}
          {:error, reason} -> {:halt, {:error, reason, acc}}
        end
      end)

    case stored do
      {:ok, records} ->
        input = Jobs.input!(job)
        unpriced(job, t)

        finished =
          with_store(fn ->
            Jobs.finish(job["id"], "succeeded", %{
              "outputs" => records,
              "upstream" => t.upstream.name,
              "target_model" => t.target.model,
              "cost_usd" => Jobs.job_cost(t.route, t.target, billable(t, input), input, length(records)),
              "attempts" => ((Store.get(job["id"]) || %{})["attempts"] || []) ++ [%{"upstream" => t.upstream.name, "outcome" => "ok"}]
            })
          end)

        case finished do
          {:ok, _} = ok ->
            ok

          # The job ended under us while its outputs were being fetched and
          # stored (canceled, as a rule). Nobody will ever be given these
          # files, so they do not stay; and if it was a cancel, the provider
          # call that produced them is billed all the same.
          _ ->
            Storage.discard(job["id"], records)
            settle_canceled(job["id"], completed(job, t, length(records)))
        end

      {:error, reason, records} ->
        # The ones that made it into storage before the failure go too.
        Storage.discard(job["id"], records)
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
    if not Jobs.priced?(t.target.price) do
      Counters.bump(:ledger_unpriced_events, 1)

      if Counters.once({:unpriced_job, job["model"], t.upstream.name, t.target.model}) do
        Logger.warning(
          "media route #{Text.line(job["model"], 80)}: target #{t.upstream.name}/#{Text.line(t.target.model, 80)} has no price, so its jobs are recorded at $0 " <>
            "(logged once per target; see omnigate_ledger_unpriced_events_total)"
        )
      end
    end
  end

  # `recipient` is the age recipient the job's outputs are encrypted to, or
  # nil. With one, the plaintext is never written: a download is encrypted
  # as it arrives, bytes that came inline are encrypted in memory.
  defp fetch({:url, url}, tmp, max, recipient), do: fetch({:url, url, nil}, tmp, max, recipient)

  defp fetch(_output, _tmp, max, _recipient) when max <= 0, do: {:error, :output_too_large}

  defp fetch({:url, url, hint}, tmp, max, recipient) when is_binary(url) do
    # The URL came out of a provider's answer: never fetch it, or anything
    # it redirects to, from an address we would not call for a webhook.
    with {:ok, meta} <- Http.download(url, tmp, max, guard: &NetGuard.target(&1, "output url"), encrypt: recipient) do
      type = content_type(hint, meta.content_type, url)

      if recipient do
        {:ok, encrypted(meta.bytes, meta.sha256, meta.plaintext_bytes, meta.plaintext_sha256, type)}
      else
        {:ok, %{"bytes" => meta.bytes, "sha256" => meta.sha256, "content_type" => type}}
      end
    end
  end

  defp fetch({:binary, bytes, content_type}, tmp, max, recipient) when is_binary(bytes) do
    type = clean(content_type) || "application/octet-stream"

    cond do
      byte_size(bytes) > max ->
        {:error, :output_too_large}

      recipient ->
        sealed = Age.encrypt(recipient, bytes)

        with :ok <- File.write(tmp, sealed) do
          {:ok, encrypted(byte_size(sealed), sha256(sealed), byte_size(bytes), sha256(bytes), type)}
        end

      true ->
        with :ok <- File.write(tmp, bytes) do
          {:ok, %{"bytes" => byte_size(bytes), "sha256" => sha256(bytes), "content_type" => type}}
        end
    end
  end

  defp fetch(_output, _tmp, _max, _recipient), do: {:error, "the provider's answer names an output that is neither a URL nor bytes"}

  # The record of an output that is stored encrypted: what the stored file
  # is (opaque bytes), and what is inside it once decrypted.
  defp encrypted(bytes, sha256, plaintext_bytes, plaintext_sha256, type) do
    %{
      "bytes" => bytes,
      "sha256" => sha256,
      "content_type" => "application/octet-stream",
      "encryption" => "age",
      "plaintext_bytes" => plaintext_bytes,
      "plaintext_sha256" => plaintext_sha256,
      "plaintext_content_type" => type
    }
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

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

  # A type as a provider gave it (a header, or a field of its JSON, which
  # need not be a string at all): the media type alone, in lower case, and
  # only if it looks like one.
  defp clean(type) when is_binary(type) do
    type = type |> String.split(";") |> hd() |> String.trim() |> String.downcase()
    if type =~ ~r|\A[a-z0-9][a-z0-9!#$&^_.+-]{0,63}/[a-z0-9][a-z0-9!#$&^_.+-]{0,63}\z|, do: type
  end

  defp clean(_), do: nil

  defp extension(content_type, output) do
    case Map.get(@types, content_type) do
      nil ->
        ext = if match?({:url, _, _}, output) or match?({:url, _}, output), do: url_ext(elem(output, 1)), else: ""
        if ext =~ ~r/\A\.[a-z0-9]{1,5}\z/, do: ext, else: ".bin"

      ext ->
        ext
    end
  end

  defp url_ext(url) when is_binary(url), do: (URI.parse(url).path || "") |> Path.extname() |> String.downcase()
  defp url_ext(_), do: ""

  defp update_running(id, fun) do
    with_store(fn -> Store.update(id, fn job -> if Jobs.terminal?(job), do: :noop, else: fun.(job) end) end)
  end

  defp describe(reason), do: Text.line(reason, 200)

  # Largest provider answer read when the media comes back inline: the output
  # limit, as base64 (4/3) plus the JSON around it, and never more than 256 MiB
  # in memory at once.
  defp inline_cap, do: min(div(ConfigStore.get().media.max_output_bytes * 4, 3) + 65_536, 256 * 1024 * 1024)
end
