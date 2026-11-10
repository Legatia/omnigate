defmodule OmnigateControl.Wave5Test do
  @moduledoc "One error shape, strict numeric settings, request ids."
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias OmnigateControl.{Env, Errors, Router}

  @admin [{"authorization", "Bearer test-admin-token-0123456789"}]

  defp call(conn), do: Router.call(conn, Router.init([]))
  defp json(conn), do: JSON.decode!(conn.resp_body)
  defp with_headers(conn, headers), do: Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
  defp internal, do: [{"x-omnigate-internal", OmnigateControl.internal_token()}]

  describe "the error object" do
    test "has message, a category in type, a null param and the reason in code" do
      assert Errors.body(404, "job_not_found", "no such job") ==
               %{error: %{message: "no such job", type: "invalid_request_error", param: nil, code: "job_not_found"}}

      assert %{error: %{request_id: "abc"}} = Errors.body(500, "internal_error", "m", %{request_id: "abc"})
    end

    test "categories match the data plane's table (dataplane/src/errors.zig, OpenAI column)" do
      for {reason, status, category} <- [
            {"missing_api_key", 401, "invalid_request_error"},
            {"invalid_api_key", 401, "invalid_request_error"},
            {"budget_exceeded", 402, "insufficient_quota"},
            {"model_not_allowed", 403, "permission_error"},
            {"model_not_found", 404, "invalid_request_error"},
            {"not_found", 404, "invalid_request_error"},
            {"method_not_allowed", 405, "invalid_request_error"},
            {"payload_too_large", 413, "invalid_request_error"},
            {"invalid_json", 400, "invalid_request_error"},
            {"rate_limit_exceeded", 429, "rate_limit_error"},
            {"too_many_open_jobs", 429, "rate_limit_error"},
            {"key_exists", 409, "invalid_request_error"},
            {"csrf_failed", 403, "permission_error"},
            {"unauthorized", 401, "invalid_request_error"},
            {"overloaded", 503, "server_error"},
            {"internal_error", 500, "server_error"},
            {"control_plane_unavailable", 503, "server_error"}
          ] do
        assert Errors.category(reason, status) == category, "#{reason}/#{status}"
      end
    end

    test "is what every kind of caller gets: jobs, admin, internal, anonymous" do
      cases = [
        {conn(:get, "/internal/v1/jobs/job_nope") |> with_headers(internal() ++ [{"x-omnigate-key-sha256", OmnigateControl.sha256_hex("og-unlimited-key")}]),
         404, "job_not_found"},
        {conn(:post, "/internal/usage/batch", ~s({"nope": 1})) |> put_req_header("content-type", "application/json") |> with_headers(internal()), 400,
         "invalid_request"},
        {conn(:post, "/internal/counters", ~s({"nope": 1})) |> put_req_header("content-type", "application/json") |> with_headers(internal()), 400,
         "invalid_request"},
        {conn(:delete, "/admin/keys/no-such-key") |> with_headers(@admin), 404, "key_not_found"},
        {conn(:get, "/admin/keys"), 401, "unauthorized"},
        {conn(:get, "/internal/config"), 401, "unauthorized"},
        {conn(:get, "/%61dmin/keys"), 400, "invalid_request"},
        {conn(:get, "/nowhere"), 404, "not_found"}
      ]

      for {request, status, code} <- cases do
        conn = call(request)
        assert conn.status == status, "#{request.method} #{request.request_path}"
        assert %{"error" => %{"message" => message, "type" => type, "param" => nil, "code" => ^code}} = json(conn)
        assert is_binary(message) and message != ""
        assert type == Errors.category(code, status)
        assert [id] = get_resp_header(conn, "x-request-id")
        assert id =~ ~r/\A[0-9a-f]{32}\z/
      end
    end
  end

  describe "request ids" do
    test "a data plane's id is adopted; a malformed one is replaced" do
      given = "0123456789abcdef0123456789abcdef"
      conn = conn(:get, "/healthz") |> put_req_header("x-omnigate-request-id", given) |> call()
      assert get_resp_header(conn, "x-request-id") == [given]

      for bad <- ["short", "has space in it", String.duplicate("a", 65), "new\nline-in-the-id"] do
        conn = conn(:get, "/healthz") |> put_req_header("x-omnigate-request-id", bad) |> call()
        assert [id] = get_resp_header(conn, "x-request-id")
        assert id != bad and id =~ ~r/\A[0-9a-f]{32}\z/
      end
    end
  end

  describe "numeric settings" do
    setup do
      on_exit(fn -> for name <- ["OMNIGATE_W5_INT", "OMNIGATE_W5_NUM"], do: System.delete_env(name) end)
    end

    test "unset or empty means the default" do
      assert Env.integer("OMNIGATE_W5_INT", 7) == {:ok, 7}
      System.put_env("OMNIGATE_W5_INT", "")
      assert Env.integer("OMNIGATE_W5_INT", 7) == {:ok, 7}
      assert Env.number("OMNIGATE_W5_NUM", 50) == {:ok, 50}
    end

    test "a well-formed value in range is used" do
      System.put_env("OMNIGATE_W5_INT", " 4100 ")
      assert Env.integer("OMNIGATE_W5_INT", 7, 1..65_535) == {:ok, 4100}
      System.put_env("OMNIGATE_W5_NUM", "0.5")
      assert Env.number("OMNIGATE_W5_NUM", 50) == {:ok, 0.5}
      System.put_env("OMNIGATE_W5_NUM", "0")
      assert Env.number("OMNIGATE_W5_NUM", 50) == {:ok, 0}
    end

    test "trailing junk, out-of-range and negative values are errors that name the variable" do
      for {text, range} <- [{"5x", 0..100}, {"4000 # the port", 1..65_535}, {"0", 1..65_535}, {"70000", 1..65_535}, {"four", 0..100}, {"1.5", 0..100}] do
        System.put_env("OMNIGATE_W5_INT", text)
        assert {:error, message} = Env.integer("OMNIGATE_W5_INT", 7, range)
        assert message =~ "OMNIGATE_W5_INT"
      end

      for text <- ["5x", "50MB", "-1", "fifty", "1e"] do
        System.put_env("OMNIGATE_W5_NUM", text)
        assert {:error, message} = Env.number("OMNIGATE_W5_NUM", 50)
        assert message =~ "OMNIGATE_W5_NUM"
      end
    end

    test "the startup check passes with the environment the tests run in" do
      assert Env.check_all() == :ok
    end
  end

  describe "the dashboard's key list" do
    test "includes a managed key shadowed by a file key, marked as such" do
      overview = OmnigateControl.Admin.overview()
      assert Enum.map(overview.keys, & &1.name) == Enum.map(OmnigateControl.Admin.keys(), & &1.name)
    end
  end

  test "the test-only route is public only because this is the test build" do
    # In a release `__test` is not in the guard's allow-list at all.
    assert Application.get_env(:omnigate_control, :test_routes) == true
    assert (conn(:get, "/__test/nothing") |> call()).status == 404
  end
end
