defmodule OmnigateControl.AdminAuth do
  @moduledoc """
  Who may see the dashboard and call `/admin/*`.

  There is one admin secret, `OMNIGATE_ADMIN_TOKEN`. It works two ways:

    * as an API token: `Authorization: Bearer <token>` on `/admin/*`;
    * as the dashboard password: `POST /login` exchanges it for a session
      cookie, so the token itself is sent once, not on every page load.

  If the variable is not set, a random token is generated at boot and logged
  once, so the control plane is never open by default.

  Sessions are stateless: the cookie is `<expiry>.<nonce>.<mac>`, signed with
  a key derived from the admin token. Changing the token ends every session.

  Requests that change something and are authenticated by the session cookie
  must also carry a CSRF token (`x-csrf-token` header or `_csrf` form field).
  The token is an HMAC of the session cookie, so it is per session and needs
  no server-side state. Requests authenticated by the bearer token are exempt:
  a browser never attaches that header on its own.

  Failed logins and wrong bearer tokens are counted per client address and
  refused for a while after too many, to slow down guessing. Behind a reverse
  proxy every client shares the proxy's address, so the limit then applies to
  all of them together, and anyone can lock everyone out by guessing. Set
  `OMNIGATE_TRUST_FORWARDED=1` when the only way in is a proxy that writes
  `X-Forwarded-For` itself (compose.yaml does): the address the proxy reports
  is then used instead. Do not set it when clients can reach the control
  plane directly, because they could then pick the address they are counted
  under.
  """
  require Logger

  @cookie "omnigate_session"
  @session_ttl_s 12 * 3600
  @failures :omnigate_login_failures
  @max_failures 5
  @window_s 60
  # Wrong bearer tokens on /admin and /metrics. Higher than the login limit:
  # scripts share an address more often than people do, and a lockout here
  # also stops the operator's own automation for a minute.
  @max_bearer_failures 20
  @min_token_bytes 16
  @max_tracked 10_000

  def cookie_name, do: @cookie
  def session_ttl_s, do: @session_ttl_s

  @doc """
  Resolve the admin token and create the failed-login table. Call once at
  boot. `{:error, message}` when a token was set but is too short to be safe:
  the control plane then refuses to start rather than run with it.
  """
  def setup do
    if :ets.whereis(@failures) == :undefined do
      :ets.new(@failures, [:named_table, :public, :set])
    end

    case resolve_token(System.get_env("OMNIGATE_ADMIN_TOKEN") || Application.get_env(:omnigate_control, :admin_token)) do
      {:ok, token} ->
        :persistent_term.put({__MODULE__, :token}, token)
        :persistent_term.put({__MODULE__, :session_key}, :crypto.mac(:hmac, :sha256, token, "omnigate-session-v1"))
        :ok

      {:error, _message} = error ->
        error
    end
  end

  @doc false
  def resolve_token(token) when is_binary(token) and token != "" do
    if byte_size(token) < @min_token_bytes do
      {:error,
       "OMNIGATE_ADMIN_TOKEN is shorter than #{@min_token_bytes} characters. It is the dashboard password and the admin API token; " <>
         "set a long random value (or leave it unset to have one generated for this run)."}
    else
      {:ok, token}
    end
  end

  def resolve_token(_unset) do
    generated = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    Logger.warning(
      "OMNIGATE_ADMIN_TOKEN is not set. Generated one for this run (dashboard password and /admin API token): " <>
        generated
    )

    {:ok, generated}
  end

  @doc "Is this the admin token? Constant-time."
  def valid_token?(candidate) when is_binary(candidate) do
    Plug.Crypto.secure_compare(candidate, :persistent_term.get({__MODULE__, :token}))
  end

  def valid_token?(_), do: false

  @doc "A new session cookie value."
  def issue_session(now \\ System.os_time(:second)) do
    payload = "#{now + @session_ttl_s}.#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
    payload <> "." <> mac(payload)
  end

  @doc "Is this cookie value a session we issued that has not expired?"
  def valid_session?(value, now \\ System.os_time(:second))

  def valid_session?(value, now) when is_binary(value) do
    with [expiry, nonce, sig] <- String.split(value, "."),
         true <- Plug.Crypto.secure_compare(sig, mac(expiry <> "." <> nonce)),
         {expires_at, ""} <- Integer.parse(expiry) do
      expires_at > now
    else
      _ -> false
    end
  end

  def valid_session?(_, _), do: false

  @doc """
  Who is asking, decided once per request and behind the throttle:

    * `:session` — a valid session cookie;
    * `:token` — the admin token as a bearer token;
    * `:denied` — an `Authorization` header that is not the admin token
      (counted against the caller's address);
    * `:throttled` — an `Authorization` header from an address that has sent
      too many wrong ones; it is not even compared, so the answer says
      nothing about whether the token was right;
    * `:none` — no credentials at all.

  Every place that accepts the bearer token goes through here (the router
  keeps the answer in `conn.assigns.auth`). A path that compared the token
  on its own, outside the throttle, would be a place to guess it at full
  speed: its answer, or how long it takes, tells right from wrong.
  """
  def authenticate(conn) do
    cond do
      session(conn) != nil ->
        :session

      Plug.Conn.get_req_header(conn, "authorization") == [] ->
        :none

      true ->
        address = client_address(conn)

        cond do
          bearer_throttled?(address) ->
            :throttled

          bearer?(conn) ->
            :token

          true ->
            note_bearer_failure(address)
            :denied
        end
    end
  end

  @doc """
  True when the request carries the admin token as a bearer token, or a valid
  session cookie. Not throttled: request handling uses `authenticate/1`.
  """
  def authorized?(conn) do
    bearer?(conn) or session?(conn)
  end

  @doc "True when the request carries the admin token as a bearer token."
  def bearer?(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> valid_token?(String.trim(token))
      ["bearer " <> token] -> valid_token?(String.trim(token))
      _ -> false
    end
  end

  defp session?(conn), do: session(conn) != nil

  @doc "The request's session cookie value when it is a valid session, else nil."
  def session(conn) do
    conn = Plug.Conn.fetch_cookies(conn)
    value = conn.req_cookies[@cookie]
    if valid_session?(value), do: value
  end

  @doc "The CSRF token that goes with a session cookie value."
  def csrf_token(session) when is_binary(session), do: mac("csrf." <> session)

  @doc """
  May this request change state? Yes with the bearer token; with a session
  cookie only when the matching CSRF token came along, in the `x-csrf-token`
  header or the `_csrf` body field.
  """
  def csrf_ok?(conn) do
    # What the router decided for this request; decided here (also behind
    # the throttle) only when called without it.
    auth = Map.get(conn.assigns, :auth) || authenticate(conn)

    cond do
      auth == :token ->
        true

      session = auth == :session && session(conn) ->
        sent =
          case Plug.Conn.get_req_header(conn, "x-csrf-token") do
            [token] -> token
            _ -> is_map(conn.body_params) && conn.body_params["_csrf"]
          end

        is_binary(sent) and Plug.Crypto.secure_compare(sent, csrf_token(session))

      true ->
        # Not authenticated at all: nothing to protect, and other plugs refuse it.
        true
    end
  end

  # -- failed-login throttle ---------------------------------------------------

  @doc """
  The address failed attempts are counted against: the peer, or, when
  `OMNIGATE_TRUST_FORWARDED` is on, the last hop of `X-Forwarded-For` (the
  one the nearest proxy wrote). IPv6 addresses are cut to their /64, since a
  single host usually owns all of it.
  """
  def client_address(conn, trust_forwarded \\ System.get_env("OMNIGATE_TRUST_FORWARDED") in ["1", "true"]) do
    with true <- trust_forwarded,
         [_ | _] = values <- Plug.Conn.get_req_header(conn, "x-forwarded-for"),
         hop = values |> List.last() |> String.split(",") |> List.last() |> String.trim(),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(hop)) do
      network(ip)
    else
      _ -> network(conn.remote_ip)
    end
  end

  defp network({a, b, c, d, _, _, _, _}), do: {a, b, c, d, 0, 0, 0, 0}
  defp network(ip), do: ip

  @doc "Has this address used up its failed attempts for the current window?"
  def throttled?(address, now \\ System.os_time(:second)) do
    case :ets.lookup(@failures, address) do
      [{_, count, window_start}] -> now - window_start < @window_s and count >= @max_failures
      [] -> false
    end
  end

  def note_failure(address, now \\ System.os_time(:second)) do
    case :ets.lookup(@failures, address) do
      [{_, count, window_start}] when now - window_start < @window_s ->
        :ets.insert(@failures, {address, count + 1, window_start})

      _ ->
        forget_expired(now)
        :ets.insert(@failures, {address, 1, now})
    end

    :ok
  end

  # Entries are only useful for one window. Sweep the finished ones once the
  # table has grown, so guesses from many addresses cannot fill memory.
  defp forget_expired(now) do
    if :ets.info(@failures, :size) > @max_tracked do
      :ets.select_delete(@failures, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now - @window_s}], [true]}])
    end
  end

  def clear_failures(address) do
    :ets.delete(@failures, address)
    :ok
  end

  @doc "Has this address sent too many wrong bearer tokens in the current window?"
  def bearer_throttled?(address, now \\ System.os_time(:second)) do
    case :ets.lookup(@failures, {:bearer, address}) do
      [{_, count, window_start}] -> now - window_start < @window_s and count >= max_bearer_failures()
      [] -> false
    end
  end

  def note_bearer_failure(address, now \\ System.os_time(:second)), do: note_failure({:bearer, address}, now)
  def clear_bearer_failures(address), do: clear_failures({:bearer, address})

  defp max_bearer_failures, do: Application.get_env(:omnigate_control, :bearer_max_failures, @max_bearer_failures)

  defp mac(payload) do
    key = :persistent_term.get({__MODULE__, :session_key})
    Base.url_encode64(:crypto.mac(:hmac, :sha256, key, payload), padding: false)
  end
end
