defmodule OmnigateControl.Storage.Local do
  @moduledoc """
  Outputs on local disk under `media.storage.dir/<job_id>/<name>`, served by
  the gateway at `/v1/files/<job_id>/<name>` behind a signed, expiring URL.
  """
  @behaviour OmnigateControl.Storage

  alias OmnigateControl.UrlSigner

  @impl true
  def put(config, job_id, name, tmp_path, _meta) do
    dest = path(config, job_id, name)

    with :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- move(tmp_path, dest) do
      {:ok, %{}}
    end
  end

  @doc "Absolute path of a stored output."
  def path(config, job_id, name), do: Path.join([config.dir, job_id, name])

  def url(media, job_id, %{"name" => name}) do
    ttl = Map.get(media.storage, :url_ttl_s, 3_600)
    "#{media.public_base_url}/v1/files/#{job_id}/#{name}?" <> UrlSigner.sign(job_id, name, ttl)
  end

  def share(%{kind: "local"} = config, from_job_id, to_job_id, %{"name" => name} = output) do
    src = path(config, from_job_id, name)
    dest = path(config, to_job_id, name)

    with :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- link_or_copy(src, dest) do
      {:ok, output}
    end
  end

  # Storage kind changed since the output was stored.
  def share(_config, _from, _to, _output), do: {:error, :storage_changed}

  defp move(src, dest) do
    case File.rename(src, dest) do
      :ok -> :ok
      {:error, _} -> with {:ok, _} <- File.copy(src, dest), do: :ok
    end
  end

  defp link_or_copy(src, dest) do
    case File.ln(src, dest) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, _} -> with {:ok, _} <- File.copy(src, dest), do: :ok
    end
  end
end
