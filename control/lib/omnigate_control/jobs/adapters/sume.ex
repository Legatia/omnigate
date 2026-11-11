defmodule OmnigateControl.Jobs.Adapters.Sume do
  @moduledoc """
  Sume's model API (https://www.sume.com/docs): one key for many image and
  video models, every request a job.

    * `POST /v1/image-router/generate` or `/v1/video-router/generate` with
      the model and its inputs → 202 with `data.job.id`
    * `GET /v1/jobs/{id}/status` → `data.sume_status` (`queued`,
      `processing`, `completed`, `failed`, `canceled`), `data.terminal`,
      `data.cancelable`, `data.next_poll_after_seconds`
    * `GET /v1/jobs/{id}/result` → `data.result.artifacts[]`, each with a
      `url`, a `content_type` and, for video, `duration_ms`
    * `POST /v1/jobs/{id}/cancel`, which Sume takes only before generation
      has started

  Which of the two routers a target uses is the target's `"router"` setting
  (`"image"` or `"video"`), never guessed from the model's name.

  Job `input` is sent as Sume's request body with `model` filled in. `mode`
  is always `"async"`; `webhook_url`, `metadata` and `wait_timeout_seconds`
  are never forwarded (the gateway has its own webhooks and metadata).

  ## Not charged twice

  Every submit carries an `Idempotency-Key` derived from the gateway's job
  id and the number of the attempt. A submit that is sent again (after a
  network error, or by a gateway that restarted before it could record the
  provider's job id) gets the original job back from Sume instead of a
  second, charged one.

  ## Errors

  Sume's error object has a stable `code`, a `public_reason` and a
  `retryable` flag. A failure is reported as `sume_<code>` (or
  `sume_<public_reason>` for a job that failed) followed by Sume's message;
  for a private job only that first word is kept. A refused submit is sent
  once more, with the same key, when Sume says it is retryable and asks for
  a wait of at most #{10} seconds; otherwise the job moves on to the route's
  next target, as it does for every provider. That includes
  `insufficient_funds`: another provider may still be able to run the job.

  ## Cancel

  `cancel/5` answers `:not_canceled` when Sume says the job can no longer be
  stopped. The runner then keeps asking how the job ends, and bills it if it
  completes.

  Written from Sume's public documentation (read 11 November 2026) and
  exercised only against this repository's mock (`tools/mock_media.py`).
  Not yet exercised against the real service: no request has been made with
  a Sume key.
  """
  @behaviour OmnigateControl.Jobs.Adapter

  import OmnigateControl.Jobs.Adapter, only: [decode: 1]
  alias OmnigateControl.Http
  alias OmnigateControl.Jobs.Adapter
  alias OmnigateControl.Text

  @default_base_url "https://api.sume.com"
  @never_forwarded ~w(mode webhook_url metadata wait_timeout_seconds)
  # Longest wait Sume may ask for between two polls, and before one resubmit.
  @max_poll_wait_s 60
  @max_submit_wait_s 10

  def default_base_url, do: @default_base_url
  def routers, do: ~w(image video)

  @impl true
  def submit(up, model, input, ctx) do
    case path(ctx) do
      nil ->
        {:error, "sume_router_not_set: the target needs \"router\": \"image\" or \"video\""}

      path ->
        body = JSON.encode!(request_body(input, model))
        headers = [{"idempotency-key", idempotency_key(ctx)} | headers(ctx)]
        send_submit(up.base_url <> path, headers, body, 1)
    end
  end

  defp send_submit(url, headers, body, tries_left) do
    case Http.request(:post, url, headers, body, timeout: 60_000) do
      {:ok, %{status: status, body: resp}} when status in 200..299 ->
        case decode(resp) do
          %{"data" => %{"job" => %{"id" => id}}} when is_binary(id) and id != "" -> {:async, id, %{}}
          %{"data" => %{"request_id" => id}} when is_binary(id) and id != "" -> {:async, id, %{}}
          _ -> {:error, "sume_unexpected_response: the submit answer names no job"}
        end

      # The same request again, with the same key: whichever of the two
      # arrived first is the one job Sume runs.
      {:error, _} when tries_left > 0 ->
        send_submit(url, headers, body, tries_left - 1)

      {:ok, resp} = answer ->
        error = error_object(resp.body)
        wait = retry_after(resp, error)

        if tries_left > 0 and error["retryable"] == true and wait <= @max_submit_wait_s do
          Process.sleep(wait * 1000)
          send_submit(url, headers, body, tries_left - 1)
        else
          {:error, failure(answer)}
        end

      other ->
        {:error, failure(other)}
    end
  end

  @doc false
  def request_body(input, model) do
    input |> Map.drop(@never_forwarded) |> Map.merge(%{"model" => model, "mode" => "async"})
  end

  @doc false
  def idempotency_key(ctx) do
    seed = "omnigate-sume:#{Map.get(ctx, :job_id, "")}:#{Map.get(ctx, :attempt, 0)}"
    "og-" <> (:crypto.hash(:sha256, seed) |> Base.encode16(case: :lower) |> binary_part(0, 48))
  end

  @impl true
  def poll(up, _model, id, _state, ctx) do
    if waiting?(id) do
      :pending
    else
      case status(up, id, ctx) do
        {:ok, data, resp} ->
          wait(id, poll_after(resp, data))
          interpret(up, id, data, ctx)

        # Asked to slow down: not a failure of the job.
        {:http, %{status: 429} = resp} ->
          wait(id, retry_after(resp, error_object(resp.body)))
          :pending

        {:http, %{status: status} = resp} when status >= 500 ->
          {:transient, failure({:ok, resp})}

        {:http, resp} ->
          {:error, failure({:ok, resp})}

        {:error, _} = other ->
          {:transient, failure(other)}
      end
    end
  end

  defp status(up, id, ctx) do
    case Http.request(:get, job_url(up, id, "/status"), headers(ctx)) do
      {:ok, %{status: 200, body: body} = resp} ->
        case decode(body) do
          %{"data" => %{} = data} -> {:ok, data, resp}
          _ -> {:http, %{resp | status: 502}}
        end

      {:ok, resp} ->
        {:http, resp}

      other ->
        other
    end
  end

  defp interpret(up, id, data, ctx) do
    case state(data) do
      "completed" -> result(up, id, ctx)
      "failed" -> {:error, failed_reason(up, id, ctx)}
      "canceled" -> {:error, "sume_job_canceled: the job was canceled at the provider"}
      s when s in ["queued", "processing"] -> :pending
      _ -> if data["terminal"] == true, do: {:error, "sume_unexpected_state: the job ended in a state this gateway does not know"}, else: :pending
    end
  end

  # Sume spells every state twice (`sume_status` and `status`); they agree.
  defp state(data) do
    case data["sume_status"] do
      s when is_binary(s) ->
        s

      _ ->
        case data["status"] do
          "IN_QUEUE" -> "queued"
          "IN_PROGRESS" -> "processing"
          "COMPLETED" -> "completed"
          "FAILED" -> "failed"
          "CANCELED" -> "canceled"
          _ -> nil
        end
    end
  end

  defp result(up, id, ctx) do
    case Http.request(:get, job_url(up, id, "/result"), headers(ctx)) do
      {:ok, %{status: 200, body: body}} ->
        artifacts = body |> decode() |> get_in([Access.key("data", %{}), Access.key("result", %{}), Access.key("artifacts", [])]) |> List.wrap()
        outputs = for %{"url" => url} = a <- artifacts, is_binary(url) and url != "", do: {:url, url, a["content_type"]}

        case outputs do
          [] -> {:error, "sume_no_output: the completed job lists no artifact"}
          _ -> {:done, outputs, measured(artifacts)}
        end

      # Completed a moment ago and the result is not readable yet.
      {:ok, %{status: 409, body: body}} = answer ->
        if error_object(body)["code"] == "job_not_completed", do: :pending, else: {:error, failure(answer)}

      {:ok, %{status: status}} = answer when status == 429 or status >= 500 ->
        {:transient, failure(answer)}

      {:ok, _} = answer ->
        {:error, failure(answer)}

      other ->
        {:transient, failure(other)}
    end
  end

  # Seconds of media the provider says it made, when every artifact that has
  # a duration reports it. This is what a per-second price is applied to.
  @doc false
  def measured(artifacts) do
    ms = for %{"duration_ms" => d} <- artifacts, is_number(d) and d > 0 and d <= 1.0e12, do: d

    case ms do
      [] -> %{}
      _ -> %{seconds: Enum.sum(ms) / 1000}
    end
  end

  # A failed job has no result; reading it answers 409 with the reason.
  defp failed_reason(up, id, ctx) do
    case Http.request(:get, job_url(up, id, "/result"), headers(ctx)) do
      {:ok, %{body: body}} ->
        error = error_object(body)
        reason = word(error["public_reason"]) || word(error["code"]) || "job_failed"
        "sume_#{reason}: #{message(error)}"

      _ ->
        "sume_job_failed: the provider reported the job as failed"
    end
  end

  @impl true
  def cancel(up, _model, id, _state, ctx) do
    # The runner asks how the job ended right after this: that question must
    # go out, whatever wait Sume asked for between polls.
    Process.delete({__MODULE__, :not_before, id})

    case status(up, id, ctx) do
      {:ok, %{"terminal" => true}, _} ->
        :ok

      {:ok, %{"cancelable" => true}, _} ->
        case Http.request(:post, job_url(up, id, "/cancel"), headers(ctx), "{}") do
          {:ok, %{status: status}} when status in 200..299 ->
            :ok

          # Ended in the meantime: the next poll says how.
          {:ok, %{status: 409, body: body}} ->
            if error_object(body)["code"] == "job_not_cancelable", do: :ok, else: :not_canceled

          _ ->
            :not_canceled
        end

      # Generation has started (or the question could not be asked): the job
      # runs on at the provider and is paid for if it completes.
      _ ->
        :not_canceled
    end
  end

  @impl true
  def billable(input), do: %{chars: Adapter.chars(input, ~w(prompt)), seconds: Adapter.seconds(input, ~w(duration))}

  # -- pieces ----------------------------------------------------------------

  defp path(ctx) do
    case Map.get(ctx, :router) do
      "image" -> "/v1/image-router/generate"
      "video" -> "/v1/video-router/generate"
      _ -> nil
    end
  end

  defp job_url(up, id, suffix), do: "#{up.base_url}/v1/jobs/#{URI.encode(id, &URI.char_unreserved?/1)}#{suffix}"

  defp headers(ctx), do: [{"authorization", "Bearer #{ctx.api_key}"}, {"content-type", "application/json"}]

  defp error_object(body) do
    case decode(body) do
      %{"error" => %{} = error} -> error
      _ -> %{}
    end
  end

  # `sume_<code>: <message>`. The code is Sume's own enumeration; the message
  # is the provider's sentence (dropped by the runner for a private job).
  defp failure({:ok, %{status: status, body: body}}) do
    error = error_object(body)

    case word(error["code"]) do
      nil -> Text.line("sume_http_#{status}: #{binary_part(body, 0, min(byte_size(body), 200))}", 300)
      code -> Text.line("sume_#{code}: #{message(error)}", 300)
    end
  end

  defp failure({:error, reason}), do: Text.line("sume_request_failed: #{inspect(reason)}", 300)

  defp message(error) do
    case error["message"] do
      m when is_binary(m) -> String.slice(m, 0, 240)
      _ -> "no detail"
    end
  end

  # One of the provider's identifiers, if it is shaped like one.
  defp word(value) when is_binary(value) do
    if value =~ ~r/\A[a-z0-9_]{1,34}\z/, do: value
  end

  defp word(_), do: nil

  defp retry_after(resp, error) do
    from_header = seconds(Map.get(resp.headers, "retry-after"))
    from_body = seconds(error["retry_after_seconds"])
    (from_header || from_body || 5) |> min(3600)
  end

  defp poll_after(resp, data) do
    seconds(Map.get(resp.headers, "x-sume-poll-after")) || seconds(data["next_poll_after_seconds"]) || 0
  end

  defp seconds(n) when is_number(n) and n >= 0, do: ceil(n)

  defp seconds(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp seconds(_), do: nil

  # The runner polls at its own interval. When Sume asks for a longer wait,
  # the polls in between are answered here without a request. (A job is
  # polled by one process; a restart forgets the wait, which costs one poll.)
  defp wait(id, seconds) when is_integer(seconds) and seconds > 0 do
    Process.put({__MODULE__, :not_before, id}, System.monotonic_time(:millisecond) + min(seconds, @max_poll_wait_s) * 1000 - 100)
  end

  defp wait(_id, _seconds), do: :ok

  defp waiting?(id) do
    case Process.get({__MODULE__, :not_before, id}) do
      nil -> false
      at -> System.monotonic_time(:millisecond) < at
    end
  end
end
