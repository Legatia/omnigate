defmodule OmnigateControl.Storage do
  @moduledoc """
  Where re-hosted job outputs live.

  Provider output URLs expire (minutes to days). Each output is copied here
  as soon as a job finishes, so the URL a client gets keeps working.

  An output record is a JSON-shaped map:
  `%{"name", "content_type", "bytes", "sha256", "storage" => "local" | "s3", "key" (s3 only)}`.
  """

  require Logger

  alias OmnigateControl.ConfigStore
  alias OmnigateControl.Storage.{Local, S3}

  @callback put(config :: map(), job_id :: String.t(), name :: String.t(), tmp_path :: String.t(), meta :: map()) ::
              {:ok, map()} | {:error, term()}

  @doc "Move a downloaded file into the configured store. Retries a few times."
  def put(job_id, name, tmp_path, meta, attempts \\ 3) do
    config = ConfigStore.get().media.storage

    case impl(config.kind).put(config, job_id, name, tmp_path, meta) do
      {:ok, extra} ->
        File.rm(tmp_path)
        {:ok, Map.merge(%{"name" => name, "storage" => config.kind}, Map.merge(meta, extra))}

      {:error, _reason} when attempts > 1 ->
        Process.sleep(500)
        put(job_id, name, tmp_path, meta, attempts - 1)

      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  @doc "Client-facing URL for a stored output of `job_id`."
  def url(job_id, %{"storage" => "s3"} = output), do: S3.url(ConfigStore.get().media.storage, job_id, output)
  def url(job_id, output), do: Local.url(ConfigStore.get().media, job_id, output)

  @doc "Give `to_job_id` its own reference to an output of `from_job_id` (cache hits)."
  def share(from_job_id, to_job_id, %{"storage" => "local"} = output) do
    Local.share(ConfigStore.get().media.storage, from_job_id, to_job_id, output)
  end

  def share(_from, _to, output), do: {:ok, output}

  @doc """
  Delete a job's outputs that are stored on local disk; returns how many
  files were removed. Outputs in a bucket are handled by `delete_remote/2`.
  """
  def delete_local(%{"id" => id} = job) do
    with %{kind: "local"} = config <- ConfigStore.get().media.storage,
         # Paths are built from these, so only well-formed ones are trusted.
         true <- is_binary(id) and id =~ ~r/^job_[0-9a-f]+$/ do
      removed =
        for %{"storage" => "local", "name" => name} <- job["outputs"] || [],
            is_binary(name) and Path.basename(name) == name,
            File.rm(Local.path(config, id, name)) == :ok,
            reduce: 0 do
          count -> count + 1
        end

      # Gone only if nothing else is in it.
      File.rmdir(Path.join(config.dir, id))
      removed
    else
      _ -> 0
    end
  end

  @doc """
  Delete from the bucket the objects of jobs that were just removed; returns
  how many objects were deleted. Best effort: a failure is logged and the
  sweep goes on (the object then stays until the bucket's own rules or a
  later manual clean-up remove it).

  Two rules keep this from ever touching anything else in the bucket:

    * an object is deleted only if its key is exactly the key this gateway
      would have written for that job and file name under the configured
      prefix, so a hand-edited job record cannot point it elsewhere;
    * an object still referenced by a job that remains (a cache hit shares
      the original job's object) is kept.

  Does nothing unless storage is currently S3.
  """
  def delete_remote(removed_jobs, remaining_jobs) do
    case ConfigStore.get().media.storage do
      %{kind: "s3"} = config ->
        in_use =
          for job <- remaining_jobs, %{"storage" => "s3", "key" => key} <- job["outputs"] || [], into: MapSet.new(), do: key

        removed_jobs
        |> Enum.flat_map(&own_objects(config, &1))
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(in_use, &1))
        |> Enum.count(fn key ->
          case S3.delete(config, key) do
            :ok ->
              true

            {:error, reason} ->
              Logger.warning("retention: could not delete bucket object #{key}: #{OmnigateControl.Text.line(reason, 200)}")
              false
          end
        end)

      _ ->
        0
    end
  end

  # Keys of a job's S3 outputs that sit where this gateway puts them.
  defp own_objects(config, %{"id" => id} = job) when is_binary(id) do
    if id =~ ~r/^job_[0-9a-f]+$/ do
      for %{"storage" => "s3", "name" => name} = output <- job["outputs"] || [],
          is_binary(name) and Path.basename(name) == name,
          key = S3.object_key(config, id, name),
          output["key"] in [nil, key] do
        key
      end
    else
      []
    end
  end

  defp own_objects(_config, _job), do: []

  @doc "Directory for in-flight downloads."
  def tmp_dir do
    dir =
      case ConfigStore.get().media.storage do
        %{kind: "local", dir: dir} -> Path.join(dir, "tmp")
        _ -> Path.join(System.tmp_dir!(), "omnigate-media-tmp")
      end

    File.mkdir_p!(dir)
    dir
  end

  defp impl("s3"), do: S3
  defp impl(_), do: Local
end
