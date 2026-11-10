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

  Failed logins are counted per client address and refused for a while after
  too many, to slow down guessing. Behind a reverse proxy every client shares
  the proxy's address, so the limit then applies to all of them together.
  """
  require Logger

  @cookie "omnigate_session"
  @session_ttl_s 12 * 3600
  @failures :omnigate_login_failures
  @max_failures 5
  @window_s 60

  def cookie_name, do: @cookie
  def session_ttl_s, do: @session_ttl_s

  @doc "Resolve the admin token and create the failed-login table. Call once at boot."
  def setup do
    if :ets.whereis(@failures) == :undefined do
      :ets.new(@failures, [:named_table, :public, :set])
    end

    token =
      case System.get_env("OMNIGATE_ADMIN_TOKEN") || Application.get_env(:omnigate_control, :admin_token) do
        token when is_binary(token) and token != "" ->
          if byte_size(token) < 16 do
            Logger.warning("OMNIGATE_ADMIN_TOKEN is shorter than 16 characters; use a long random value")
          end

          token

        _ ->
          generated = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

          Logger.warning(
            "OMNIGATE_ADMIN_TOKEN is not set. Generated one for this run (dashboard password and /admin API token): " <>
              generated
          )

          generated
      end

    :persistent_term.put({__MODULE__, :token}, token)
    :persistent_term.put({__MODULE__, :session_key}, :crypto.mac(:hmac, :sha256, token, "omnigate-session-v1"))
    :ok
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

  @doc "True when the request carries the admin token as a bearer token, or a valid session cookie."
  def authorized?(conn) do
    bearer?(conn) or session?(conn)
  end

  defp bearer?(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> valid_token?(String.trim(token))
      ["bearer " <> token] -> valid_token?(String.trim(token))
      _ -> false
    end
  end

  defp session?(conn) do
    conn = Plug.Conn.fetch_cookies(conn)
    valid_session?(conn.req_cookies[@cookie])
  end

  # -- failed-login throttle ---------------------------------------------------

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
        :ets.insert(@failures, {address, 1, now})
    end

    :ok
  end

  def clear_failures(address) do
    :ets.delete(@failures, address)
    :ok
  end

  defp mac(payload) do
    key = :persistent_term.get({__MODULE__, :session_key})
    Base.url_encode64(:crypto.mac(:hmac, :sha256, key, payload), padding: false)
  end
end
