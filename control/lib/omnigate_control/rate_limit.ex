defmodule OmnigateControl.RateLimit do
  @moduledoc """
  Per-key requests-per-minute limit for work that starts in the control
  plane (media jobs).

  The data plane applies a key's `rpm` too, but it must not be the only
  brake: a request that reaches the job API by a path the data plane does not
  recognise as "create a job" would otherwise be unlimited. Counting here, in
  the handler that actually creates the job, cannot be bypassed that way.

  Fixed one-minute windows, counted with one atomic ETS update per request.
  In memory only: a restart forgives the current minute.
  """

  @table :omnigate_rate_limits

  @doc "Create the table. Call once at boot."
  def setup do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    end

    :ok
  end

  @doc """
  Count one request for `id` (a key name). `:ok`, or `{:error, retry_after_s}`
  once more than `rpm` requests arrived in the current minute. `rpm` of 0 or
  nil means no limit.
  """
  def check(id, rpm, now_s \\ System.os_time(:second))
  def check(_id, rpm, _now_s) when rpm in [nil, 0], do: :ok

  def check(id, rpm, now_s) when is_integer(rpm) and rpm > 0 do
    window = div(now_s, 60)
    count = :ets.update_counter(@table, {id, window}, 1, {{id, window}, 0})
    # The previous minute's counter is no longer needed.
    if count == 1, do: :ets.delete(@table, {id, window - 1})

    if count > rpm, do: {:error, max(60 - rem(now_s, 60), 1)}, else: :ok
  end

  @doc false
  def reset(id), do: :ets.match_delete(@table, {{id, :_}, :_})
end
