defmodule OmnigateControl.Retention do
  @moduledoc """
  Keeps state from growing forever, according to the config's `retention`
  section. Everything is off unless configured, so an upgrade never deletes
  anything by itself.

      "retention": { "jobs_days": 30, "ledger_ids_days": 7 }

    * `jobs_days`: finished jobs (succeeded, failed, canceled) that finished
      more than this many days ago are removed from the job store and from
      its log file, and their outputs stored on local disk are deleted.
      Unfinished jobs are never touched, whatever their age. A removed job
      can no longer be fetched, replayed by idempotency key, or used as a
      cache hit.

      Outputs stored in an S3 bucket are NOT deleted by the gateway. Expire
      those with the bucket's own lifecycle rules.

    * `ledger_ids_days`: the ledger forgets event ids it recorded more than
      this many days ago (see `OmnigateControl.Ledger`). Spend totals and the
      ledger file are untouched. An event resent after its id was forgotten
      would be counted twice, so keep this well above the longest outage a
      data plane might spool through.

  A value of 0, or leaving a setting out, means "keep forever".

  One sweep runs shortly after boot and then every hour.
  """
  use GenServer
  require Logger

  alias OmnigateControl.{ConfigStore, Ledger, Storage}
  alias OmnigateControl.Jobs.Store

  @day_ms 86_400_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Run one sweep now and return what it removed:
  `%{jobs: n, files: n, ledger_ids: n}`.
  """
  def sweep(retention \\ ConfigStore.get().retention, now_ms \\ System.os_time(:millisecond)) do
    {jobs, files} =
      case cutoff(retention[:jobs_days], now_ms) do
        nil ->
          {0, 0}

        cutoff_ms ->
          removed = Store.purge_finished_before(cutoff_ms)
          # Files go after the log no longer mentions their jobs: a crash in
          # between leaves a stray file, never a job whose file is missing.
          {length(removed), removed |> Enum.map(&Storage.delete_local/1) |> Enum.sum()}
      end

    ledger_ids =
      case cutoff(retention[:ledger_ids_days], now_ms) do
        nil -> 0
        cutoff_ms -> Ledger.prune_ids(cutoff_ms)
      end

    result = %{jobs: jobs, files: files, ledger_ids: ledger_ids}

    if jobs + files + ledger_ids > 0 do
      Logger.info("retention sweep removed #{jobs} finished jobs, #{files} stored files, #{ledger_ids} ledger dedup ids")
    end

    result
  end

  defp cutoff(days, now_ms) when is_number(days) and days > 0, do: now_ms - round(days * @day_ms)
  defp cutoff(_, _now_ms), do: nil

  # -- server --------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Let the boot-time job resume write its ledger events first.
    Process.send_after(self(), :sweep, Application.get_env(:omnigate_control, :retention_boot_delay_ms, 5_000))
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      sweep()
    rescue
      e -> Logger.error("retention sweep failed: #{Exception.message(e)}")
    catch
      :exit, reason -> Logger.error("retention sweep failed: #{inspect(reason)}")
    end

    Process.send_after(self(), :sweep, Application.get_env(:omnigate_control, :retention_interval_ms, 3_600_000))
    {:noreply, state}
  end
end
