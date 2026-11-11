defmodule OmnigateControl.Retention do
  @moduledoc """
  Keeps state from growing forever, according to the config's `retention`
  section. Jobs and ledger segments are kept until a setting says otherwise,
  so an upgrade never deletes either by itself. The one thing with a finite
  default is the ledger's set of duplicate-detection ids (`ledger_ids_days`,
  3 days), which is not history but working memory.

      "retention": { "jobs_days": 30, "ledger_ids_days": 3, "ledger_days": 90, "delete_bucket_objects": true }

    * `jobs_days`: finished jobs (succeeded, failed, canceled) that finished
      more than this many days ago are removed from the job store and from
      its log file, and their outputs stored on local disk are deleted.
      Unfinished jobs are never touched, whatever their age. A removed job
      can no longer be fetched, replayed by idempotency key, or used as a
      cache hit.

      Outputs stored in an S3-compatible bucket are deleted too, object by
      object, unless `delete_bucket_objects` is false (the default is true).
      This is best effort: an object that could not be deleted is logged and
      left behind, so a lifecycle rule on the bucket is still a good backstop.
      Only objects under this gateway's own key layout are ever deleted, and
      an object a remaining job still points at (a cache hit shares the
      original's object) is kept.

    * `ledger_ids_days`: the ledger forgets the event ids of whole UTC days
      that ended more than this many days ago (see
      `OmnigateControl.Ledger.Ids`), so an id is kept for at least this long
      and at most a day longer. Spend totals and the ledger file are
      untouched. An event resent after its id was forgotten would be counted
      twice, so keep this above the longest time a data plane may hold
      undelivered usage in its spool: the longest control-plane outage, or
      the longest a data plane is switched off, that you expect to ride out.
      The default is 3.

    * `ledger_days`: sealed ledger segments (the files `ledger.NNNNNN.jsonl`
      next to the active `ledger.jsonl`) older than this are deleted. Their
      contribution to every total lives on in the ledger's snapshot, so
      lifetime and current-period spend stay exact; what goes is the
      per-request history in those files. A segment is deleted only once
      two snapshot generations cover it, and the newest sealed segment is
      always kept.

  A value of 0, or leaving a setting out, means "keep forever" (except
  `ledger_ids_days`, which defaults to 3 when left out).

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
  `%{jobs: n, files: n, bucket_objects: n, ledger_ids: n, ledger_segments: n}`.
  """
  def sweep(retention \\ ConfigStore.get().retention, now_ms \\ System.os_time(:millisecond)) do
    {jobs, files, objects} =
      case cutoff(retention[:jobs_days], now_ms) do
        nil ->
          {0, 0, 0}

        cutoff_ms ->
          removed = Store.purge_finished_before(cutoff_ms)
          # Files go after the log no longer mentions their jobs: a crash in
          # between leaves a stray file, never a job whose file is missing.
          files = removed |> Enum.map(&Storage.delete_local/1) |> Enum.sum()

          objects =
            if removed != [] and Map.get(retention, :delete_bucket_objects, true) != false do
              Storage.delete_remote(removed, Store.all())
            else
              0
            end

          {length(removed), files, objects}
      end

    ledger_ids =
      case cutoff(retention[:ledger_ids_days], now_ms) do
        nil -> 0
        cutoff_ms -> Ledger.prune_ids(cutoff_ms)
      end

    # Old event history goes segment by segment; the totals it contributed
    # stay in the ledger's snapshots.
    ledger_segments =
      case cutoff(retention[:ledger_days], now_ms) do
        nil -> 0
        cutoff_ms -> Ledger.prune_segments(cutoff_ms)
      end

    result = %{jobs: jobs, files: files, bucket_objects: objects, ledger_ids: ledger_ids, ledger_segments: ledger_segments}

    if jobs + files + objects + ledger_ids + ledger_segments > 0 do
      Logger.info(
        "retention sweep removed #{jobs} finished jobs, #{files} stored files, #{objects} bucket objects, " <>
          "#{ledger_ids} ledger dedup ids, #{ledger_segments} ledger segments"
      )
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
