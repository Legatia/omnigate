defmodule OmnigateControl.AdminAuthTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias OmnigateControl.{AdminAuth, Router}

  # config/config.exs sets this for the test environment.
  @token "test-admin-token-0123456789"

  defp call(conn), do: Router.call(conn, Router.init([]))

  defp login(password, ip) do
    conn(:post, "/login", "password=" <> URI.encode_www_form(password))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Map.put(:remote_ip, ip)
    |> call()
  end

  defp session_cookie(conn) do
    conn.resp_cookies[AdminAuth.cookie_name()]
  end

  describe "sessions" do
    test "a fresh session is valid, an expired or altered one is not" do
      now = 1_800_000_000
      session = AdminAuth.issue_session(now)

      assert AdminAuth.valid_session?(session, now)
      assert AdminAuth.valid_session?(session, now + AdminAuth.session_ttl_s() - 1)
      refute AdminAuth.valid_session?(session, now + AdminAuth.session_ttl_s())

      [expiry, nonce, sig] = String.split(session, ".")
      # Pushing the expiry out without re-signing must not work.
      refute AdminAuth.valid_session?("#{String.to_integer(expiry) + 99_999}.#{nonce}.#{sig}", now)
      refute AdminAuth.valid_session?("#{expiry}.#{nonce}.#{String.reverse(sig)}", now)
      refute AdminAuth.valid_session?("garbage", now)
      refute AdminAuth.valid_session?(nil, now)
    end
  end

  describe "the /admin API" do
    test "refuses requests without the admin token" do
      conn = conn(:get, "/admin/usage") |> call()
      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]

      conn = conn(:get, "/admin/usage") |> put_req_header("authorization", "Bearer wrong") |> call()
      assert conn.status == 401

      # The data planes' credential is not an admin credential.
      conn = conn(:get, "/admin/usage") |> put_req_header("x-omnigate-internal", "anything") |> call()
      assert conn.status == 401
    end

    test "accepts the admin token as a bearer token" do
      conn = conn(:get, "/admin/usage") |> put_req_header("authorization", "Bearer " <> @token) |> call()
      assert conn.status == 200
      assert %{"keys" => keys} = JSON.decode!(conn.resp_body)
      assert is_list(keys)
    end
  end

  describe "the dashboard" do
    test "sends an anonymous browser to the login page" do
      conn = conn(:get, "/") |> call()
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]

      conn = conn(:get, "/login") |> call()
      assert conn.status == 200
      assert conn.resp_body =~ ~s(name="password")
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "a wrong token gets no session" do
      conn = login("not-the-token", {10, 0, 0, 2})
      assert conn.status == 401
      assert session_cookie(conn) == nil
      refute conn.resp_body =~ "not-the-token"
    end

    test "the right token buys a session that opens the dashboard and the API" do
      conn = login(@token, {10, 0, 0, 3})
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/"]

      cookie = session_cookie(conn)
      assert cookie.http_only == true
      assert cookie.same_site == "Strict"
      assert cookie.max_age == AdminAuth.session_ttl_s()
      # The cookie is a signed session, never the token itself.
      refute cookie.value =~ @token

      header = AdminAuth.cookie_name() <> "=" <> cookie.value

      page = conn(:get, "/") |> put_req_header("cookie", header) |> call()
      assert page.status == 200
      assert page.resp_body =~ "omnigate control plane"
      assert page.resp_body =~ "Sign out"

      api = conn(:get, "/admin/usage") |> put_req_header("cookie", header) |> call()
      assert api.status == 200

      forged = conn(:get, "/") |> put_req_header("cookie", AdminAuth.cookie_name() <> "=" <> cookie.value <> "x") |> call()
      assert forged.status == 302
    end

    test "the cookie is marked Secure when the browser came over TLS" do
      conn =
        conn(:post, "/login", "password=" <> @token)
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("x-forwarded-proto", "https")
        |> Map.put(:remote_ip, {10, 0, 0, 4})
        |> call()

      assert session_cookie(conn).secure == true
    end

    test "logout clears the cookie" do
      conn = conn(:post, "/logout") |> call()
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]
      assert session_cookie(conn).max_age == 0
    end

    test "repeated failures from one address are refused for a while" do
      ip = {10, 0, 0, 99}
      AdminAuth.clear_failures(ip)

      for _ <- 1..5, do: assert(login("nope", ip).status == 401)
      # Even the right token is refused now, so guessing cannot continue.
      assert login(@token, ip).status == 429
      # Other addresses are unaffected.
      assert login(@token, {10, 0, 0, 98}).status == 302

      # After the window the address may try again.
      later = System.os_time(:second) + 61
      refute AdminAuth.throttled?(ip, later)
      AdminAuth.clear_failures(ip)
    end
  end

  test "health needs no credentials; internal routes still need the internal token" do
    assert (conn(:get, "/healthz") |> call()).status == 200
    assert (conn(:get, "/internal/config") |> call()).status == 401
    # The admin token is not a data-plane credential either.
    conn = conn(:get, "/internal/config") |> put_req_header("authorization", "Bearer " <> @token) |> call()
    assert conn.status == 401
  end
end
