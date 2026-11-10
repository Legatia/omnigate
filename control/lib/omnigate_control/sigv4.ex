defmodule OmnigateControl.SigV4 do
  @moduledoc """
  AWS Signature Version 4, enough for S3-compatible PUT/GET and presigned GETs.

  Implemented on `:crypto` so the control plane needs no AWS SDK.
  """

  @algorithm "AWS4-HMAC-SHA256"

  @type creds :: %{access_key: String.t(), secret_key: String.t(), region: String.t(), service: String.t()}

  @doc "Derived signing key (raw bytes) for a date (`YYYYMMDD`), region and service."
  def signing_key(secret_key, date, region, service) do
    ("AWS4" <> secret_key)
    |> hmac(date)
    |> hmac(region)
    |> hmac(service)
    |> hmac("aws4_request")
  end

  @doc """
  Hex signature for a request.

  `headers` is a list of `{name, value}`; all of them are signed. `amz_date`
  is `YYYYMMDDTHHMMSSZ`. `payload_hash` is the hex SHA-256 of the body (or
  `UNSIGNED-PAYLOAD`).
  """
  def signature(method, path, query, headers, payload_hash, amz_date, creds) do
    {canonical, _signed} = canonical_request(method, path, query, headers, payload_hash)
    date = binary_part(amz_date, 0, 8)

    creds.secret_key
    |> signing_key(date, creds.region, creds.service)
    |> hmac(string_to_sign(amz_date, scope(date, creds), canonical))
    |> Base.encode16(case: :lower)
  end

  @doc "Headers to add to a request (`authorization`, plus the ones that were signed)."
  def sign_headers(method, url, headers, payload_hash, creds, now \\ DateTime.utc_now()) do
    uri = URI.parse(url)
    amz_date = amz_date(now)

    headers =
      [{"host", host_header(uri)}, {"x-amz-content-sha256", payload_hash}, {"x-amz-date", amz_date}] ++ headers

    {_canonical, signed} = canonical_request(method, uri.path || "/", uri.query || "", headers, payload_hash)
    sig = signature(method, uri.path || "/", uri.query || "", headers, payload_hash, amz_date, creds)
    date = binary_part(amz_date, 0, 8)

    auth =
      "#{@algorithm} Credential=#{creds.access_key}/#{scope(date, creds)}, SignedHeaders=#{signed}, Signature=#{sig}"

    # The HTTP client sets Host itself.
    [{"authorization", auth} | Enum.reject(headers, fn {k, _} -> k == "host" end)]
  end

  @doc "A presigned GET URL valid for `expires_s` seconds."
  def presign_get(url, expires_s, creds, now \\ DateTime.utc_now()) do
    uri = URI.parse(url)
    amz_date = amz_date(now)
    date = binary_part(amz_date, 0, 8)

    params = [
      {"X-Amz-Algorithm", @algorithm},
      {"X-Amz-Credential", "#{creds.access_key}/#{scope(date, creds)}"},
      {"X-Amz-Date", amz_date},
      {"X-Amz-Expires", Integer.to_string(expires_s)},
      {"X-Amz-SignedHeaders", "host"}
    ]

    query = canonical_query(params)
    headers = [{"host", host_header(uri)}]
    sig = signature("GET", uri.path || "/", query, headers, "UNSIGNED-PAYLOAD", amz_date, creds)
    "#{uri.scheme}://#{host_header(uri)}#{encode_path(uri.path || "/")}?#{query}&X-Amz-Signature=#{sig}"
  end

  @doc "Canonical request text and the signed-headers list."
  def canonical_request(method, path, query, headers, payload_hash) do
    sorted =
      headers
      |> Enum.map(fn {k, v} -> {String.downcase(k), v |> String.trim() |> String.replace(~r/\s+/, " ")} end)
      |> Enum.sort()

    signed = Enum.map_join(sorted, ";", &elem(&1, 0))
    header_block = Enum.map_join(sorted, "", fn {k, v} -> "#{k}:#{v}\n" end)

    canonical =
      Enum.join(
        [String.upcase(to_string(method)), encode_path(path), canonical_query(query), header_block, signed, payload_hash],
        "\n"
      )

    {canonical, signed}
  end

  @doc false
  def string_to_sign(amz_date, scope, canonical_request) do
    Enum.join([@algorithm, amz_date, scope, sha256_hex(canonical_request)], "\n")
  end

  def sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  def amz_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y%m%dT%H%M%SZ")

  defp scope(date, creds), do: "#{date}/#{creds.region}/#{creds.service}/aws4_request"

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    default = if scheme == "https", do: 443, else: 80
    if port in [nil, default], do: host, else: "#{host}:#{port}"
  end

  # Each path segment percent-encoded once (S3 style), slashes kept.
  defp encode_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &(&1 |> URI.decode() |> encode()))
  end

  defp canonical_query(query) when is_binary(query) do
    query
    |> URI.query_decoder()
    |> Enum.to_list()
    |> canonical_query()
  end

  defp canonical_query(params) when is_list(params) do
    params
    |> Enum.map(fn {k, v} -> {encode(k), encode(v)} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end

  # RFC 3986 unreserved characters only.
  defp encode(s), do: URI.encode(s, &URI.char_unreserved?/1)

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
