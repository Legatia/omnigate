defmodule OmnigateControl.Storage do
  @moduledoc """
  Where re-hosted job outputs live.

  Provider output URLs expire (minutes to days). Each output is copied here
  as soon as a job finishes, so the URL a client gets keeps working.

  An output record is a JSON-shaped map:
  `%{"name", "content_type", "bytes", "sha256", "storage" => "local" | "s3", "key" (s3 only)}`.
  """

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
