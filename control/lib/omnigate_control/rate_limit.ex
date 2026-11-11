defmodule OmnigateControl.RateLimit do
  @moduledoc """
  Per-key requests-per-minute limit for work that starts in the control
  plane (media jobs).

  The data plane applies a key's `rpm` too, but it must not be the only
  brake: a request that reaches the job API by a path the data plane does not
  recognise as "create a job" would otherwise be unlimited. Counting here, in
  the handler that actually creates the job, cannot be bypassed that way.

  The same token bucket as the data plane's (`dataplane/src/ratelimit.zig`),
  number for number, so a client sees one behaviour whichever process says
  no: a key with `rpm = N` may burst up to N requests and is refilled at N
  per minute, counted in thousandths of a request; a refusal says after how
  many seconds (rounded up) the next request will fit; a changed `rpm` starts
  with a full bucket. Buckets are kept per key, by the hash of its current
  secret, as the data plane does. In memory only: a restart forgives the last
  minute.
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
  Take one request from the bucket of `id`. `:ok`, or `{:error, retry_after_s}`
  when the bucket is empty. `rpm` of 0 or nil means no limit. `now_ms` is a
  monotonic clock reading.
  """
  def check(id, rpm, now_ms \\ System.monotonic_time(:millisecond))
  def check(_id, rpm, _now_ms) when rpm in [nil, 0], do: :ok

  def check(id, rpm, now_ms) when is_integer(rpm) and rpm > 0 and is_integer(now_ms) do
    capacity = rpm * 1000

    case :ets.lookup(@table, id) do
      [{^id, milli, last_ms, ^rpm} = old] ->
        # Refill: rpm requests per 60_000 ms == rpm*1000 milli-tokens per 60_000 ms.
        elapsed = max(now_ms - last_ms, 0)
        refill = div(elapsed * rpm, 60)

        {milli, last_ms} =
          cond do
            milli + refill >= capacity -> {capacity, now_ms}
            # Advance only by the time this refill accounts for, so integer
            # truncation never loses a fraction of a request.
            refill > 0 -> {milli + refill, last_ms + div(refill * 60, rpm)}
            true -> {milli, last_ms}
          end

        if milli >= 1000 do
          # Two requests may have read the same bucket; only one of them
          # replaces what it read, the other starts over.
          if swap(old, {id, milli - 1000, last_ms, rpm}), do: :ok, else: check(id, rpm, now_ms)
        else
          swap(old, {id, milli, last_ms, rpm})
          missing = 1000 - milli
          # ms until `missing` milli-tokens have been refilled, rounded up.
          wait_ms = div(missing * 60 + rpm - 1, rpm)
          {:error, max(1, div(wait_ms + 999, 1000))}
        end

      other ->
        # A new key, or one whose limit changed: a full bucket, less this request.
        fresh = {id, capacity - 1000, now_ms, rpm}

        installed =
          case other do
            [] -> :ets.insert_new(@table, fresh)
            [old] -> swap(old, fresh)
          end

        if installed, do: :ok, else: check(id, rpm, now_ms)
    end
  end

  # Replace exactly the row that was read; false when someone else got there first.
  defp swap(old, new), do: :ets.select_replace(@table, [{old, [], [{:const, new}]}]) == 1

  @doc false
  def reset(id), do: :ets.delete(@table, id)
end
