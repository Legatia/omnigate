defmodule OmnigateControl.Http do
  @moduledoc """
  Outbound HTTP/1.1, written directly on `:gen_tcp` and `:ssl`.

  It used to sit on OTP's `:httpc`, which hands back a whole response body
  however large it is (and never streams a body that is not a 200). Every
  response here is read through a cap instead: whoever answers a webhook, a
  provider call or a download decides how many bytes they send, so the caller
  decides how many are read. When the cap is reached the connection is closed.

  One connection per request, `connection: close`: job traffic is low-volume,
  and a fresh connection is never one the peer already dropped.
  """

  @type response :: %{status: pos_integer(), headers: %{String.t() => String.t()}, body: binary(), truncated: boolean()}

  # Largest response body `request/5` reads unless told otherwise.
  @default_max_body 4 * 1024 * 1024
  # Status line plus headers.
  @max_head_bytes 64 * 1024
  @max_redirects 5
  # Longest a single write may wait for the peer to take it.
  @send_timeout 60_000
  # A body is written in pieces of this size.
  @write_chunk 65_536

  @doc """
  One request. `headers` is a list of `{name, value}` binaries.

  `body` is `nil`, a binary, or `{:file, path, size}` to stream a file from
  disk. Options:

    * `:timeout` — ms for the whole exchange (default 30 s)
    * `:connect_timeout` — ms (default 10 s)
    * `:send_timeout` — ms one write may wait for the peer to take it
      (default 60 s, and never more than what is left of `:timeout`); a body
      is written in pieces of 64 KiB, so a peer that stops reading fails
      the request instead of holding its process for ever
    * `:content_type` — for a request with a body (default `application/json`)
    * `:max_body` — most response-body bytes to read (default 4 MiB)
    * `:overflow` — what a larger body means: `:error` (default) gives
      `{:error, :response_too_large}`; `:truncate` returns what fit, with
      `truncated: true` (for callers that only want the status)
    * `:connect_to` — an `:inet` address tuple to connect to instead of
      resolving the URL's host again, while still sending the host's name in
      `Host`, in TLS SNI, and checking the certificate against it. Callers
      that validated an address use it so that the address they checked is
      the one that gets called.

  Redirects are never followed.
  """
  @spec request(atom(), String.t(), [{String.t(), String.t()}], term(), keyword()) :: {:ok, response()} | {:error, term()}
  def request(method, url, headers, body \\ nil, opts \\ []) do
    cap = Keyword.get(opts, :max_body, @default_max_body)
    overflow = Keyword.get(opts, :overflow, :error)
    timeout = Keyword.get(opts, :timeout, 30_000)

    sink = fn chunk, {acc, bytes} ->
      cond do
        bytes + byte_size(chunk) <= cap -> {:cont, {[acc, chunk], bytes + byte_size(chunk)}}
        overflow == :truncate -> {:halt, {:truncated, [acc, binary_part(chunk, 0, cap - bytes)]}}
        true -> {:halt, {:error, :response_too_large}}
      end
    end

    handler = fn _status, _headers -> {:read, sink, {[], 0}} end

    case exchange(method, url, headers, body, opts, handler, deadline(timeout), timeout) do
      {:ok, status, resp_headers, {:truncated, data}} ->
        {:ok, %{status: status, headers: resp_headers, body: IO.iodata_to_binary(data), truncated: true}}

      {:ok, _status, _resp_headers, {:error, reason}} ->
        {:error, reason}

      {:ok, status, resp_headers, {data, _bytes}} ->
        {:ok, %{status: status, headers: resp_headers, body: IO.iodata_to_binary(data), truncated: false}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Stream a GET response body to `dest`, hashing as it goes.

  Aborts once more than `max_bytes` have arrived. Returns
  `{:ok, %{bytes, sha256, content_type}}`. Only a 200 or 206 has its body
  read at all: any other answer is an error (or a redirect) and its body,
  whatever its size, is left unread.

  Redirects are followed here, one hop at a time and at most
  `:max_redirects` (default #{@max_redirects}) of them. With `guard: fun`,
  every URL about to be fetched, the first one and each redirect target, is
  passed to `fun` first: `{:ok, ip}` means "fetch it, connecting to exactly
  this address", `{:error, reason}` stops the download. That is how a URL
  that came out of a provider's answer is kept away from internal addresses
  (see `OmnigateControl.NetGuard`).

  With `encrypt: recipient` (an age recipient, see `OmnigateControl.Age`)
  the body is encrypted as it arrives and only ciphertext is written to
  `dest`. `bytes` and `sha256` then describe the file as written, and
  `plaintext_bytes` and `plaintext_sha256` what was downloaded; `max_bytes`
  still bounds the download.

  Options: `:idle_timeout` (ms without a byte, default 60 s), `:timeout` (ms
  for one hop as a whole, default 30 min), `:headers`, `:encrypt`.
  """
  def download(url, dest, max_bytes, opts \\ []) do
    File.mkdir_p!(Path.dirname(dest))
    follow(url, dest, max_bytes, opts, Keyword.get(opts, :max_redirects, @max_redirects))
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp follow(url, dest, max_bytes, opts, hops_left) do
    with {:ok, hop_opts} <- guard(url, opts) do
      case fetch_once(url, dest, max_bytes, hop_opts) do
        {:redirect, _location} when hops_left <= 0 ->
          {:error, "too many redirects"}

        {:redirect, location} ->
          # Relative targets are resolved against the URL that sent them.
          follow(url |> URI.merge(location) |> URI.to_string(), dest, max_bytes, opts, hops_left - 1)

        result ->
          result
      end
    end
  end

  defp guard(url, opts) do
    case Keyword.get(opts, :guard) do
      nil ->
        {:ok, opts}

      fun ->
        case fun.(url) do
          {:ok, ip} -> {:ok, Keyword.put(opts, :connect_to, ip)}
          {:error, reason} -> {:error, "blocked: #{reason}"}
        end
    end
  end

  defp fetch_once(url, dest, max_bytes, opts) do
    idle = Keyword.get(opts, :idle_timeout, 60_000)
    owner = self()

    recipient = Keyword.get(opts, :encrypt)

    sink = fn chunk, st ->
      bytes = st.bytes + byte_size(chunk)

      if bytes > max_bytes do
        {:halt, {:error, :output_too_large}}
      else
        st = %{st | bytes: bytes, hash: :crypto.hash_update(st.hash, chunk)}

        case st.seal do
          nil ->
            :ok = :file.write(st.io, chunk)
            {:cont, st}

          seal ->
            {sealed, seal} = OmnigateControl.Age.update(seal, chunk)
            {:cont, written(%{st | seal: seal}, sealed)}
        end
      end
    end

    handler = fn
      status, headers when status in [301, 302, 303, 307, 308] ->
        case headers["location"] do
          location when is_binary(location) and location != "" -> {:stop, {:redirect, location}}
          _ -> {:stop, {:error, {:http_status, status}}}
        end

      status, headers when status in [200, 206] ->
        io = File.open!(dest, [:write, :binary, :raw])
        # Remembered so the file is closed however the exchange ends.
        send(owner, {:http_download_file, io})
        st = %{io: io, bytes: 0, hash: :crypto.hash_init(:sha256), ctype: headers["content-type"], seal: nil, out_bytes: 0, out_hash: nil}

        st =
          if recipient do
            {header, seal} = OmnigateControl.Age.start(recipient)
            written(%{st | seal: seal, out_hash: :crypto.hash_init(:sha256)}, header)
          else
            st
          end

        {:read, sink, st}

      status, _headers ->
        {:stop, {:error, {:http_status, status}}}
    end

    result = exchange(:get, url, Keyword.get(opts, :headers, []), nil, opts, handler, deadline(Keyword.get(opts, :timeout, 1_800_000)), idle)

    # An encrypted file ends with its last chunk, which only now is known to
    # be the last. (The file is still open.)
    result =
      case result do
        {:ok, status, headers, %{seal: seal} = st} when seal != nil ->
          {:ok, status, headers, written(%{st | seal: nil}, OmnigateControl.Age.finish(seal))}

        other ->
          other
      end

    receive do
      {:http_download_file, io} -> File.close(io)
    after
      0 -> :ok
    end

    case result do
      {:ok, _status, _headers, %{bytes: bytes, hash: hash, ctype: ctype, out_hash: nil}} ->
        {:ok, %{bytes: bytes, sha256: hash |> :crypto.hash_final() |> Base.encode16(case: :lower), content_type: ctype}}

      {:ok, _status, _headers, %{bytes: bytes, hash: hash, ctype: ctype, out_bytes: out_bytes, out_hash: out_hash}} ->
        {:ok,
         %{
           bytes: out_bytes,
           sha256: out_hash |> :crypto.hash_final() |> Base.encode16(case: :lower),
           content_type: ctype,
           plaintext_bytes: bytes,
           plaintext_sha256: hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
         }}

      {:ok, _status, _headers, other} ->
        File.rm(dest)
        other

      {:error, reason} ->
        File.rm(dest)
        {:error, reason}
    end
  end

  # Ciphertext written to a download's file, counted and hashed.
  defp written(st, data) do
    :ok = :file.write(st.io, data)
    %{st | out_bytes: st.out_bytes + IO.iodata_length(data), out_hash: :crypto.hash_update(st.out_hash, data)}
  end

  # -- one exchange ------------------------------------------------------------

  # `handler.(status, headers)` decides what happens to the body:
  # `{:read, sink, acc}` feeds it to `sink.(chunk, acc)` (`{:cont, acc}` or
  # `{:halt, value}`), `{:stop, value}` leaves it unread. Returns
  # `{:ok, status, headers, acc_or_value}` or `{:error, reason}`.
  defp exchange(method, url, headers, body, opts, handler, deadline, idle) do
    {url, headers, opts} = pin(url, headers, opts)
    uri = URI.parse(url)

    with :ok <- plain(url, headers, opts),
         {:ok, sock} <- connect(uri, opts, deadline) do
      try do
        with :ok <- send_request(sock, method, uri, headers, body, opts, deadline),
             {:ok, status, resp_headers, rest} <- read_head(sock, "", deadline, idle) do
          case handler.(status, resp_headers) do
            {:stop, value} ->
              {:ok, status, resp_headers, value}

            {:read, sink, acc} ->
              case read_body(sock, rest, framing(method, status, resp_headers), sink, acc, deadline, idle) do
                {:ok, acc} -> {:ok, status, resp_headers, acc}
                {:halt, value} -> {:ok, status, resp_headers, value}
                {:error, reason} -> {:error, reason}
              end
          end
        end
      after
        close(sock)
      end
    end
  end

  # Nothing that could break out of the request line or a header line. The
  # `:content_type` option becomes a header line too.
  defp plain(url, headers, opts) do
    bad = fn text -> not is_binary(text) or text =~ ~r/[\x00-\x1f\x7f]/ end

    cond do
      url =~ ~r/[\x00-\x20\x7f]/ -> {:error, :invalid_url}
      Enum.any?(headers, fn {k, v} -> bad.(k) or bad.(v) or k =~ ~r/[\s:]/ end) -> {:error, :invalid_header}
      Keyword.has_key?(opts, :content_type) and bad.(Keyword.get(opts, :content_type)) -> {:error, :invalid_header}
      true -> :ok
    end
  end

  defp connect(%URI{scheme: scheme, host: host, port: port} = _uri, opts, deadline) when scheme in ["http", "https"] and is_binary(host) do
    port = port || if(scheme == "https", do: 443, else: 80)
    timeout = min(Keyword.get(opts, :connect_timeout, 10_000), remaining(deadline))

    {address, family} =
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, ip} when tuple_size(ip) == 8 -> {ip, [:inet6]}
        {:ok, ip} -> {ip, []}
        {:error, _} -> {String.to_charlist(host), []}
      end

    # A write that the peer does not take (it stopped reading, and the
    # kernel's buffers are full) would otherwise block for ever: `send` has no
    # timeout of its own, and the deadline is only looked at between writes.
    # With these a write that makes no progress for `:send_timeout` fails and
    # closes the socket; TLS writes go through the same socket.
    send_timeout = max(min(Keyword.get(opts, :send_timeout, @send_timeout), remaining(deadline)), 1)
    socket_opts = [:binary, active: false, nodelay: true, send_timeout: send_timeout, send_timeout_close: true]

    with {:ok, tcp} <- :gen_tcp.connect(address, port, socket_opts ++ family, max(timeout, 1)) do
      if scheme == "https" do
        # The name to present and to check the certificate against: the real
        # host when connecting to a pinned address, else the URL's own host
        # when that is a name. For a bare address the address itself is checked.
        name = Keyword.get(opts, :tls_name) || if(is_list(address), do: host)

        ssl_opts =
          [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
          ] ++ if(name, do: [server_name_indication: String.to_charlist(name)], else: [])

        case :ssl.connect(tcp, ssl_opts, max(remaining(deadline), 1)) do
          {:ok, ssl} ->
            {:ok, {:ssl, ssl}}

          {:error, reason} ->
            :gen_tcp.close(tcp)
            {:error, {:tls, reason}}
        end
      else
        {:ok, {:tcp, tcp}}
      end
    end
  end

  defp connect(_uri, _opts, _deadline), do: {:error, :invalid_url}

  defp send_request(sock, method, uri, headers, body, opts, deadline) do
    given = MapSet.new(headers, fn {k, _} -> String.downcase(k) end)
    default_port = if uri.scheme == "https", do: 443, else: 80
    host = if uri.port in [nil, default_port], do: uri.host, else: "#{uri.host}:#{uri.port}"
    # An IPv6 literal goes in brackets.
    host =
      if String.contains?(uri.host, ":") and not String.starts_with?(host, "["), do: String.replace_prefix(host, uri.host, "[" <> uri.host <> "]"), else: host

    length =
      case body do
        nil -> nil
        {:file, _path, size} -> size
        bin when is_binary(bin) -> byte_size(bin)
      end

    extra =
      [
        {"host", host},
        {"user-agent", "omnigate/" <> OmnigateControl.version()},
        {"accept", "*/*"}
      ]
      |> Enum.reject(fn {k, _} -> MapSet.member?(given, k) end)
      |> Kernel.++(
        if(length, do: [{"content-type", Keyword.get(opts, :content_type, "application/json")}, {"content-length", Integer.to_string(length)}], else: [])
      )
      |> Enum.reject(fn {k, _} -> k == "content-type" and MapSet.member?(given, "content-type") end)

    target = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
    verb = method |> to_string() |> String.upcase()

    head = [
      verb,
      " ",
      target,
      " HTTP/1.1\r\n",
      Enum.map(extra ++ Enum.reject(headers, fn {k, _} -> String.downcase(k) in ["connection", "content-length", "transfer-encoding"] end), fn {k, v} ->
        [k, ": ", v, "\r\n"]
      end),
      "connection: close\r\n\r\n"
    ]

    case body do
      nil -> write(sock, head)
      # Head and body in one write, so a small request is one packet.
      bin when is_binary(bin) and byte_size(bin) <= @write_chunk -> write(sock, [head, bin])
      bin when is_binary(bin) -> with :ok <- write(sock, head), do: send_binary(sock, bin, deadline)
      {:file, path, _size} -> with :ok <- write(sock, head), do: send_file(sock, path, deadline)
    end
  end

  # A long body goes out in pieces: each has the socket's send timeout to be
  # taken by the peer, and the exchange's deadline is checked between them.
  defp send_binary(_sock, <<>>, _deadline), do: :ok

  defp send_binary(sock, bin, deadline) do
    size = min(byte_size(bin), @write_chunk)
    <<piece::binary-size(^size), rest::binary>> = bin

    cond do
      remaining(deadline) <= 0 -> {:error, :timeout}
      true -> with :ok <- write(sock, piece), do: send_binary(sock, rest, deadline)
    end
  end

  defp send_file(sock, path, deadline) do
    with {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      try do
        Stream.repeatedly(fn -> :file.read(io, @write_chunk) end)
        |> Enum.reduce_while(:ok, fn
          {:ok, data}, :ok ->
            cond do
              remaining(deadline) <= 0 ->
                {:halt, {:error, :timeout}}

              true ->
                case write(sock, data) do
                  :ok -> {:cont, :ok}
                  error -> {:halt, error}
                end
            end

          :eof, :ok ->
            {:halt, :ok}

          {:error, reason}, :ok ->
            {:halt, {:error, reason}}
        end)
      after
        File.close(io)
      end
    end
  end

  # Status line and headers. Informational (1xx) answers are skipped.
  defp read_head(sock, buf, deadline, idle) do
    case :erlang.decode_packet(:http_bin, buf, []) do
      {:ok, {:http_response, _version, status, _reason}, rest} ->
        with {:ok, headers, rest} <- read_headers(sock, rest, %{}, deadline, idle, @max_head_bytes) do
          if status in 100..199, do: read_head(sock, rest, deadline, idle), else: {:ok, status, headers, rest}
        end

      {:more, _} when byte_size(buf) > @max_head_bytes ->
        {:error, :response_head_too_large}

      {:more, _} ->
        with {:ok, data} <- recv(sock, deadline, idle), do: read_head(sock, buf <> data, deadline, idle)

      _ ->
        {:error, :bad_response}
    end
  end

  defp read_headers(_sock, _buf, _acc, _deadline, _idle, budget) when budget <= 0, do: {:error, :response_head_too_large}

  defp read_headers(sock, buf, acc, deadline, idle, budget) do
    case :erlang.decode_packet(:httph_bin, buf, []) do
      {:ok, {:http_header, _, name, _, value}, rest} ->
        read_headers(sock, rest, Map.put(acc, name |> to_string() |> String.downcase(), value), deadline, idle, budget - (byte_size(buf) - byte_size(rest)))

      {:ok, :http_eoh, rest} ->
        {:ok, acc, rest}

      {:more, _} when byte_size(buf) > @max_head_bytes ->
        {:error, :response_head_too_large}

      {:more, _} ->
        with {:ok, data} <- recv(sock, deadline, idle), do: read_headers(sock, buf <> data, acc, deadline, idle, budget)

      _ ->
        {:error, :bad_response}
    end
  end

  defp framing(method, status, headers) do
    cond do
      method == :head or status in [204, 304] ->
        :none

      String.contains?(String.downcase(headers["transfer-encoding"] || ""), "chunked") ->
        :chunked

      is_binary(headers["content-length"]) ->
        case Integer.parse(String.trim(headers["content-length"])) do
          {n, ""} when n >= 0 -> {:length, n}
          _ -> :invalid
        end

      true ->
        :until_close
    end
  end

  defp read_body(_sock, _buf, :none, _sink, acc, _deadline, _idle), do: {:ok, acc}
  defp read_body(_sock, _buf, :invalid, _sink, _acc, _deadline, _idle), do: {:error, :bad_response}

  defp read_body(sock, buf, {:length, n}, sink, acc, deadline, idle) do
    case take(sock, buf, n, sink, acc, deadline, idle) do
      {:ok, _rest, acc} -> {:ok, acc}
      other -> other
    end
  end

  defp read_body(sock, buf, :until_close, sink, acc, deadline, idle) do
    case feed(sink, buf, acc) do
      {:cont, acc} ->
        case recv(sock, deadline, idle) do
          {:ok, data} -> read_body(sock, data, :until_close, sink, acc, deadline, idle)
          {:error, :closed} -> {:ok, acc}
          {:error, reason} -> {:error, reason}
        end

      {:halt, value} ->
        {:halt, value}
    end
  end

  defp read_body(sock, buf, :chunked, sink, acc, deadline, idle) do
    case :binary.split(buf, "\r\n") do
      [line, rest] ->
        case chunk_size(line) do
          {:ok, 0} ->
            # Trailers, if any, are not needed; the connection is closed anyway.
            {:ok, acc}

          {:ok, size} ->
            case take(sock, rest, size, sink, acc, deadline, idle) do
              {:ok, rest, acc} -> after_chunk(sock, rest, sink, acc, deadline, idle)
              other -> other
            end

          :error ->
            {:error, :bad_response}
        end

      [_] when byte_size(buf) > 1024 ->
        {:error, :bad_response}

      [_] ->
        with {:ok, data} <- recv(sock, deadline, idle), do: read_body(sock, buf <> data, :chunked, sink, acc, deadline, idle)
    end
  end

  # The CRLF that ends a chunk's data.
  defp after_chunk(sock, buf, sink, acc, deadline, idle) do
    case buf do
      <<"\r\n", rest::binary>> -> read_body(sock, rest, :chunked, sink, acc, deadline, idle)
      b when byte_size(b) < 2 -> with {:ok, data} <- recv(sock, deadline, idle), do: after_chunk(sock, buf <> data, sink, acc, deadline, idle)
      _ -> {:error, :bad_response}
    end
  end

  # At most 15 hex digits, so the size can never be a surprise to arithmetic.
  defp chunk_size(line) do
    hex = line |> String.split(";") |> hd() |> String.trim()

    if byte_size(hex) in 1..15 do
      case Integer.parse(hex, 16) do
        {n, ""} when n >= 0 -> {:ok, n}
        _ -> :error
      end
    else
      :error
    end
  end

  # Pass exactly `n` body bytes to the sink, from the buffer first.
  defp take(_sock, buf, 0, _sink, acc, _deadline, _idle), do: {:ok, buf, acc}

  defp take(sock, buf, n, sink, acc, deadline, idle) do
    case buf do
      "" ->
        case recv(sock, deadline, idle) do
          {:ok, data} -> take(sock, data, n, sink, acc, deadline, idle)
          # The peer promised more than it sent.
          {:error, :closed} -> {:error, :truncated_response}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        use = min(byte_size(buf), n)
        part = binary_part(buf, 0, use)
        rest = binary_part(buf, use, byte_size(buf) - use)

        case feed(sink, part, acc) do
          {:cont, acc} -> take(sock, rest, n - use, sink, acc, deadline, idle)
          {:halt, value} -> {:halt, value}
        end
    end
  end

  defp feed(_sink, "", acc), do: {:cont, acc}
  defp feed(sink, chunk, acc), do: sink.(chunk, acc)

  # -- sockets and time -----------------------------------------------------

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms
  defp remaining(deadline), do: deadline - System.monotonic_time(:millisecond)

  defp recv(sock, deadline, idle) do
    case min(remaining(deadline), idle) do
      t when t <= 0 ->
        {:error, :timeout}

      t ->
        case sock do
          {:tcp, s} -> :gen_tcp.recv(s, 0, t)
          {:ssl, s} -> :ssl.recv(s, 0, t)
        end
    end
  end

  defp write({:tcp, s}, data), do: :gen_tcp.send(s, data)
  defp write({:ssl, s}, data), do: :ssl.send(s, data)

  defp close({:tcp, s}), do: :gen_tcp.close(s)
  defp close({:ssl, s}), do: :ssl.close(s)

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
end
