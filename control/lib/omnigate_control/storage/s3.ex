defmodule OmnigateControl.Storage.S3 do
  @moduledoc """
  Outputs in an S3-compatible bucket the operator owns (path-style URLs).

  Objects are written with a SigV4-signed PUT streamed from disk. Returned
  URLs are SigV4-presigned GETs (the bucket is assumed private), valid for
  `presign_ttl_s` (default one hour). Setting `public_base_url` without
  `presign_ttl_s` returns plain `public_base_url/<key>` URLs instead, for a
  public bucket or a CDN in front of it.

  Checked against Cloudflare R2 (endpoint
  `https://<account id>.r2.cloudflarestorage.com`, region `auto`) in November
  2026: upload, presigned download, and refusal of unsigned requests. Other
  S3-compatible services have only met the mock.
  """
  @behaviour OmnigateControl.Storage

  alias OmnigateControl.{Http, SigV4}

  @impl true
  def put(config, job_id, name, tmp_path, meta) do
    with {:ok, creds} <- creds(config) do
      url = object_url(config, job_id, name)
      content_type = meta["content_type"] || "application/octet-stream"

      # content-type is signed, but handed to the HTTP client separately.
      headers =
        SigV4.sign_headers("PUT", url, [{"content-type", content_type}], meta["sha256"], creds)
        |> Enum.reject(fn {k, _} -> k == "content-type" end)

      case Http.request(:put, url, headers, {:file, tmp_path, meta["bytes"]},
             content_type: content_type,
             timeout: 300_000
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          {:ok, %{"key" => object_key(config, job_id, name)}}

        {:ok, %{status: status, body: body}} ->
          {:error, "s3 put returned #{status}: #{String.slice(body, 0, 200)}"}

        {:error, reason} ->
          {:error, "s3 put failed: #{inspect(reason)}"}
      end
    end
  end

  def url(config, job_id, %{"name" => name} = output) do
    key = output["key"] || object_key(config, job_id, name)

    case {config, creds(config)} do
      {%{kind: "s3", presign_ttl_s: ttl}, {:ok, creds}} when is_integer(ttl) ->
        SigV4.presign_get("#{config.endpoint}/#{config.bucket}/#{key}", ttl, creds)

      {%{kind: "s3"}, _} ->
        "#{config.public_base_url}/#{key}"

      # Storage was switched away from S3 after this output was stored.
      _ ->
        nil
    end
  end

  defp object_key(config, job_id, name), do: "#{config.prefix}#{job_id}/#{name}"

  defp object_url(config, job_id, name),
    do: "#{config.endpoint}/#{config.bucket}/#{object_key(config, job_id, name)}"

  defp creds(%{kind: "s3"} = config) do
    with access when is_binary(access) <- System.get_env(config.access_key_env),
         secret when is_binary(secret) <- System.get_env(config.secret_key_env) do
      {:ok, %{access_key: access, secret_key: secret, region: config.region, service: "s3"}}
    else
      _ -> {:error, "s3 credentials not set (#{config.access_key_env}, #{config.secret_key_env})"}
    end
  end

  defp creds(_), do: {:error, "storage is not s3"}
end
