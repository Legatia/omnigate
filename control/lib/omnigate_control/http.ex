defmodule OmnigateControl.Http do
  @moduledoc """
  Outbound HTTP on top of OTP's `:httpc` (no extra dependencies).

  Every request asks for `connection: close`: job traffic is low-volume and a
  fresh connection avoids being handed a socket the peer already dropped.
  """

  @type response :: %{status: pos_integer(), headers: %{String.t() => String.t()}, body: binary()}

  @doc """
  One request. `headers` is a list of `{name, value}` binaries.

  `body` is `nil`, a binary, or `{:file, path, size}` to stream a file from
  disk. Options: `:timeout` (ms, default 30 s), `:redirect` (default false),
  `:content_type`, and `:connect_to`.

  `connect_to: ip` (an `:inet` address tuple) opens the connection to that
  address instead of resolving the URL's host again, while still sending the
  host's name in `Host`, in TLS SNI, and checking the certificate against it.
  Callers that validated an address use it so that the address they checked
  is the one that gets called.
  """
  @spec request(atom(), String.t(), [{String.t(), String.t()}], term(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def request(method, url, headers, body \\ nil, opts \\ []) do
    {url, headers, opts} = pin(url, headers, opts)
    hdrs = to_httpc_headers(headers)
    url_c = String.to_charlist(url)

    {req, body_headers} =
      case body do
        nil ->
          {nil, []}

        {:file, path, size} ->
          {{file_body(path), size}, [{~c"content-length", Integer.to_charlist(size)}]}

        bin when is_binary(bin) ->
          {bin, []}
      end

    request =
      case req do
        nil ->
          {url_c, hdrs}

        {{fun, acc}, _size} ->
          {url_c, hdrs ++ body_headers, content_type(opts), {fun, acc}}

        bin ->
          {url_c, hdrs, content_type(opts), bin}
      end

    case :httpc.request(method, request, http_opts(url, opts), body_format: :binary) do
      {:ok, {{_, status, _}, resp_headers, resp_body}} ->
        {:ok, %{status: status, headers: header_map(resp_headers), body: resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Stream a GET response body to `dest`, hashing as it goes.

  Aborts once more than `max_bytes` have arrived. Returns
  `{:ok, %{bytes, sha256, content_type}}`.
  """
  def download(url, dest, max_bytes, opts \\ []) do
    idle = Keyword.get(opts, :idle_timeout, 60_000)
    headers = to_httpc_headers(Keyword.get(opts, :headers, []))

    http_opts = http_opts(url, Keyword.put(opts, :redirect, true))

    case :httpc.request(:get, {String.to_charlist(url), headers}, http_opts,
           sync: false,
           stream: {:self, :once},
           body_format: :binary
         ) do
      {:ok, ref} ->
        File.mkdir_p!(Path.dirname(dest))
        file = File.open!(dest, [:write, :binary, :raw])

        result =
          try do
            receive_stream(ref, file, %{bytes: 0, hash: :crypto.hash_init(:sha256), ctype: nil, pid: nil}, max_bytes, idle)
          after
            File.close(file)
          end

        if match?({:error, _}, result), do: File.rm(dest)
        result

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp receive_stream(ref, file, st, max, idle) do
    receive do
      {:http, {^ref, :stream_start, headers, pid}} ->
        :httpc.stream_next(pid)
        receive_stream(ref, file, %{st | ctype: header_map(headers)["content-type"], pid: pid}, max, idle)

      {:http, {^ref, :stream_start, headers}} ->
        receive_stream(ref, file, %{st | ctype: header_map(headers)["content-type"]}, max, idle)

      {:http, {^ref, :stream, chunk}} ->
        bytes = st.bytes + byte_size(chunk)

        if bytes > max do
          :httpc.cancel_request(ref)
          {:error, :output_too_large}
        else
          :ok = :file.write(file, chunk)
          if st.pid, do: :httpc.stream_next(st.pid)
          receive_stream(ref, file, %{st | bytes: bytes, hash: :crypto.hash_update(st.hash, chunk)}, max, idle)
        end

      {:http, {^ref, :stream_end, _headers}} ->
        {:ok,
         %{
           bytes: st.bytes,
           sha256: st.hash |> :crypto.hash_final() |> Base.encode16(case: :lower),
           content_type: st.ctype
         }}

      # Non-2xx responses are not streamed; they arrive whole.
      {:http, {^ref, {{_, status, _}, _headers, _body}}} ->
        {:error, {:http_status, status}}

      {:http, {^ref, {:error, reason}}} ->
        {:error, reason}
    after
      idle ->
        :httpc.cancel_request(ref)
        {:error, :timeout}
    end
  end

  # httpc body generator: reads the file in 64 KiB slices.
  defp file_body(path) do
    fun = fn
      nil ->
        case File.open(path, [:read, :binary, :raw]) do
          {:ok, io} -> read_slice(io)
          {:error, _} -> :eof
        end

      io ->
        read_slice(io)
    end

    {fun, nil}
  end

  defp read_slice(io) do
    case :file.read(io, 65_536) do
      {:ok, data} ->
        {:ok, data, io}

      _ ->
        File.close(io)
        :eof
    end
  end

  defp content_type(opts), do: String.to_charlist(Keyword.get(opts, :content_type, "application/json"))

  # Rewrites the URL to the pinned address and carries the real host name in
  # the Host header and, via `:tls_name`, into the TLS options.
  @doc false
  def pin(url, headers, opts) do
    case Keyword.get(opts, :connect_to) do
      nil ->
        {url, headers, opts}

      ip ->
        uri = URI.parse(url)
        literal = ip |> :inet.ntoa() |> to_string()
        literal = if tuple_size(ip) == 8, do: "[" <> literal <> "]", else: literal
        default_port = if uri.scheme == "https", do: 443, else: 80
        host_header = if uri.port in [nil, default_port], do: uri.host, else: "#{uri.host}:#{uri.port}"

        pinned =
          "#{uri.scheme}://#{literal}:#{uri.port || default_port}#{uri.path || "/"}" <>
            if(uri.query, do: "?" <> uri.query, else: "")

        headers = [{"host", host_header} | Enum.reject(headers, fn {k, _} -> String.downcase(k) == "host" end)]
        {pinned, headers, Keyword.put(opts, :tls_name, uri.host)}
    end
  end

  defp http_opts(url, opts) do
    base = [
      timeout: Keyword.get(opts, :timeout, 30_000),
      connect_timeout: Keyword.get(opts, :connect_timeout, 10_000),
      autoredirect: Keyword.get(opts, :redirect, false)
    ]

    if String.starts_with?(url, "https://") do
      base ++
        [
          ssl:
            [
              verify: :verify_peer,
              cacerts: :public_key.cacerts_get(),
              customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
            ] ++
              case Keyword.get(opts, :tls_name) do
                # Connecting to a pinned address: name the host for SNI and
                # for the certificate check, since the URL no longer does.
                nil -> []
                name -> [server_name_indication: String.to_charlist(name)]
              end
        ]
    else
      base
    end
  end

  defp to_httpc_headers(headers) do
    [{~c"connection", ~c"close"} | Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)]
  end

  defp header_map(headers) do
    Map.new(headers, fn {k, v} -> {k |> to_string() |> String.downcase(), to_string(v)} end)
  end
end
