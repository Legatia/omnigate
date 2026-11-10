defmodule OmnigateControl.Router do
  @moduledoc """
  HTTP API.

    * `GET  /internal/config` — snapshot for data planes (internal token)
    * `POST /internal/usage/batch` — usage events from data planes (internal token)
    * `/internal/v1/jobs...`, `/internal/v1/files/...` — the media job API. Data
      planes authenticate the gateway key and forward `/v1/jobs*` and
      `/v1/files*` here, naming the key in `x-omnigate-key-sha256`.
    * `GET  /admin/usage`     — per-key totals as JSON (admin token or session)
    * `GET  /admin/overview`  — everything the dashboard shows, as JSON
    * `GET/POST /admin/keys`, `PATCH/DELETE /admin/keys/:name`,
      `POST /admin/keys/:name/rotate` — managed gateway keys, see `Keys`
    * `GET  /`                — dashboard (session; redirects to `/login`)
    * `GET/POST /login`, `POST /logout` — dashboard sessions, see `AdminAuth`
    * `GET  /metrics`         — Prometheus metrics (admin token or session)
    * `GET  /healthz`         — liveness, no authentication

  Three audiences, three credentials: data planes use the internal token,
  operators use the admin token (or a session bought with it), and
  applications never talk to this port at all.
  """
  use Plug.Router

  alias OmnigateControl.{Admin, AdminAuth, ConfigStore, Dashboard, Jobs, Keys, Ledger, Metrics, Storage, UrlSigner}

  plug :match
  plug Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: JSON, pass: ["*/*"]
  plug :internal_auth
  plug :admin_auth
  plug :csrf
  plug :dispatch

  get "/healthz" do
    conn |> put_resp_content_type("text/plain") |> send_resp(200, "ok\n")
  end

  get "/metrics" do
    conn
    |> put_resp_header("content-type", "text/plain; version=0.0.4; charset=utf-8")
    |> send_resp(200, Metrics.render())
  end

  get "/internal/config" do
    send_json(conn, 200, snapshot())
  end

  post "/internal/usage/batch" do
    case conn.body_params do
      %{"events" => events} when is_list(events) ->
        {:ok, counts} = Ledger.record_batch(events)
        send_json(conn, 200, counts)

      _ ->
        send_json(conn, 400, %{error: "expected {\"events\": [...]}"})
    end
  end

  # -- media jobs ------------------------------------------------------------

  post "/internal/v1/jobs" do
    with {:ok, key} <- gateway_key(conn),
         :ok <- within_budget(key),
         :ok <- model_allowed(key, conn.body_params["model"]) do
      idempotency_key = conn |> get_req_header("idempotency-key") |> List.first()

      case Jobs.create(key.key_sha256, conn.body_params, idempotency_key) do
        {:ok, job} -> send_json(conn, 202, Jobs.view(job))
        {:existing, job} -> send_json(conn, 200, Jobs.view(job))
        {:error, status, type, message} -> send_error(conn, status, type, message)
      end
    else
      {:error, status, type, message} -> send_error(conn, status, type, message)
    end
  end

  get "/internal/v1/jobs" do
    with {:ok, key} <- gateway_key(conn) do
      conn = fetch_query_params(conn)

      limit =
        case Integer.parse(conn.query_params["limit"] || "") do
          {n, ""} -> n |> max(1) |> min(100)
          _ -> 20
        end

      # Jobs created before a key rotation are still this key's jobs.
      jobs =
        key
        |> Keys.hashes()
        |> Enum.flat_map(&Jobs.list(&1, limit))
        |> Enum.sort_by(& &1["created_ms"], :desc)
        |> Enum.take(limit)

      send_json(conn, 200, %{object: "list", data: Enum.map(jobs, &Jobs.view/1)})
    else
      {:error, status, type, message} -> send_error(conn, status, type, message)
    end
  end

  get "/internal/v1/jobs/:id" do
    with {:ok, key} <- gateway_key(conn),
         %{} = job <- own_job(key, id) do
      send_json(conn, 200, Jobs.view(job))
    else
      {:error, status, type, message} -> send_error(conn, status, type, message)
      nil -> send_error(conn, 404, "job_not_found", "no such job")
    end
  end

  post "/internal/v1/jobs/:id/cancel" do
    with {:ok, key} <- gateway_key(conn),
         %{"key_sha256" => owner} <- own_job(key, id),
         %{} = job <- Jobs.cancel(owner, id) do
      send_json(conn, 200, Jobs.view(job))
    else
      {:error, status, type, message} -> send_error(conn, status, type, message)
      nil -> send_error(conn, 404, "job_not_found", "no such job")
    end
  end

  # Locally stored outputs. Allowed for the gateway key that owns the job, or
  # for anyone holding a valid signed URL (`exp`, `sig`).
  get "/internal/v1/files/:job_id/:name" do
    conn = fetch_query_params(conn)

    with :ok <- file_access(conn, job_id, name),
         %{} = job <- Jobs.Store.get(job_id),
         %{} = output <- Enum.find(job["outputs"] || [], &(&1["name"] == name)) do
      send_output(conn, job_id, output)
    else
      {:error, status, type, message} -> send_error(conn, status, type, message)
      _ -> send_error(conn, 404, "file_not_found", "no such file")
    end
  end

  get "/admin/usage" do
    send_json(conn, 200, %{keys: Admin.keys()})
  end

  get "/admin/overview" do
    send_json(conn, 200, Admin.overview())
  end

  # -- managed keys ------------------------------------------------------------

  get "/admin/keys" do
    send_json(conn, 200, %{keys: Admin.keys()})
  end

  post "/admin/keys" do
    case Keys.create(json_object(conn)) do
      # The only response that ever contains the key itself.
      {:ok, key, raw} -> send_json(conn, 201, key |> Admin.key_view() |> Map.put(:key, raw))
      {:error, status, type, message} -> send_error(conn, status, type, message)
    end
  end

  patch "/admin/keys/:name" do
    case Keys.update(name, json_object(conn)) do
      {:ok, key} -> send_json(conn, 200, Admin.key_view(key))
      {:error, status, type, message} -> send_error(conn, status, type, message)
    end
  end

  post "/admin/keys/:name/rotate" do
    case Keys.rotate(name) do
      {:ok, key, raw} -> send_json(conn, 200, key |> Admin.key_view() |> Map.put(:key, raw))
      {:error, status, type, message} -> send_error(conn, status, type, message)
    end
  end

  delete "/admin/keys/:name" do
    case Keys.delete(name) do
      :ok -> send_json(conn, 200, %{deleted: name})
      {:error, status, type, message} -> send_error(conn, status, type, message)
    end
  end

  get "/" do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    # A bearer-token request has no session to tie a CSRF token to; it does
    # not need one either.
    csrf =
      case AdminAuth.session(conn) do
        nil -> ""
        session -> AdminAuth.csrf_token(session)
      end

    send_html(conn, 200, Dashboard.page(Admin.overview(), csrf, nonce), nonce)
  end

  get "/login" do
    if AdminAuth.authorized?(conn), do: redirect(conn, "/"), else: send_html(conn, 200, login_page(nil))
  end

  post "/login" do
    address = conn.remote_ip

    cond do
      AdminAuth.throttled?(address) ->
        send_html(conn, 429, login_page("Too many failed attempts. Wait a minute and try again."))

      AdminAuth.valid_token?(conn.body_params["password"]) ->
        AdminAuth.clear_failures(address)

        conn
        |> put_resp_cookie(AdminAuth.cookie_name(), AdminAuth.issue_session(),
          http_only: true,
          same_site: "Strict",
          secure: secure_cookie?(conn),
          max_age: AdminAuth.session_ttl_s()
        )
        |> redirect("/")

      true ->
        AdminAuth.note_failure(address)
        send_html(conn, 401, login_page("That is not the admin token."))
    end
  end

  post "/logout" do
    conn
    |> delete_resp_cookie(AdminAuth.cookie_name(), http_only: true, same_site: "Strict", secure: secure_cookie?(conn))
    |> redirect("/login")
  end

  match _ do
    send_json(conn, 404, %{error: "not_found"})
  end

  @doc "Data-plane view of the config: no budgets, no prices, no secrets."
  def snapshot do
    config = ConfigStore.get()

    body = %{
      # A disabled key is left out altogether, so data planes refuse it as
      # an unknown key (401) rather than as one that is out of budget.
      keys:
        for k <- config.keys, not Keys.disabled?(k) do
          %{key_sha256: k.key_sha256, name: k.name, blocked: Keys.over_budget?(k), rpm: k.rpm, models: k.models}
        end,
      upstreams: config.upstreams,
      routes:
        Enum.map(config.routes, fn r ->
          %{model: r.model, strategy: r.strategy, targets: Enum.map(r.targets, &Map.take(&1, [:upstream, :model, :weight]))}
        end)
    }

    # Version changes whenever anything the data plane sees changes,
    # including a key flipping to blocked.
    Map.put(body, :version, body |> JSON.encode!() |> OmnigateControl.sha256_hex() |> binary_part(0, 16))
  end

  # The data plane authenticated the gateway key; it tells us which one.
  defp gateway_key(conn) do
    with [hash] <- get_req_header(conn, "x-omnigate-key-sha256"),
         %{} = key <- Keys.find_current(hash),
         false <- Keys.disabled?(key) do
      {:ok, key}
    else
      _ -> {:error, 401, "invalid_api_key", "unknown gateway key"}
    end
  end

  # A job belongs to a key under its current secret or one from before a rotation.
  defp own_job(key, id), do: Enum.find_value(Keys.hashes(key), &Jobs.get(&1, id))

  # A JSON object body, or an empty map for anything else (validated downstream).
  defp json_object(conn) do
    case conn.body_params do
      %{} = params -> Map.delete(params, "_csrf")
      _ -> %{}
    end
  end

  # The data plane also checks this, but its view lags by one poll interval.
  defp within_budget(key) do
    if Keys.over_budget?(key), do: {:error, 402, "budget_exceeded", "this key has exhausted its budget"}, else: :ok
  end

  # A key may be limited to a list of models. The data plane applies the same
  # list to text routes; media jobs are checked here.
  defp model_allowed(%{models: nil}, _model), do: :ok

  defp model_allowed(%{models: models}, model) do
    if model in models do
      :ok
    else
      {:error, 403, "model_not_allowed", "this key is not allowed to use the model #{inspect(model)}"}
    end
  end

  defp file_access(conn, job_id, name) do
    case get_req_header(conn, "x-omnigate-key-sha256") do
      [hash] ->
        owner = Keys.find_current(hash)

        if owner && !Keys.disabled?(owner) && own_job(owner, job_id) do
          :ok
        else
          {:error, 404, "file_not_found", "no such file"}
        end

      _ ->
        case UrlSigner.verify(job_id, name, conn.query_params["exp"], conn.query_params["sig"]) do
          :ok -> :ok
          {:error, :missing} -> {:error, 401, "missing_api_key", "send a gateway key or use a signed URL"}
          {:error, :expired} -> {:error, 403, "url_expired", "this signed URL has expired"}
          {:error, _} -> {:error, 403, "invalid_signature", "this signed URL is not valid"}
        end
    end
  end

  defp send_output(conn, job_id, %{"storage" => "s3"} = output) do
    case Storage.url(job_id, output) do
      nil -> send_error(conn, 404, "file_not_found", "no such file")
      url -> conn |> put_resp_header("location", url) |> send_resp(302, "")
    end
  end

  defp send_output(conn, job_id, output) do
    path =
      case ConfigStore.get().media.storage do
        %{kind: "local"} = storage -> Storage.Local.path(storage, job_id, output["name"])
        _ -> nil
      end

    if path && File.regular?(path) do
      conn
      |> put_resp_header("content-type", output["content_type"] || "application/octet-stream")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_file(200, path)
    else
      send_error(conn, 404, "file_not_found", "no such file")
    end
  end

  defp send_error(conn, status, type, message) do
    send_json(conn, status, %{error: %{type: type, message: message}})
  end

  defp internal_auth(%{path_info: ["internal" | _]} = conn, _opts) do
    expected = System.get_env("OMNIGATE_INTERNAL_TOKEN") || ""

    case get_req_header(conn, "x-omnigate-internal") do
      [token] when expected != "" ->
        if Plug.Crypto.secure_compare(token, expected), do: conn, else: deny(conn)

      _ ->
        deny(conn)
    end
  end

  defp internal_auth(conn, _opts), do: conn

  defp deny(conn), do: conn |> send_json(401, %{error: "unauthorized"}) |> halt()

  # `/admin/*` is an API: answer 401. The dashboard is a page: send the
  # browser to the login form. Everything else here is either public
  # (`/healthz`, `/login`) or guarded by `internal_auth` above.
  defp admin_auth(%{path_info: [first | _]} = conn, _opts) when first in ["admin", "metrics"] do
    if AdminAuth.authorized?(conn) do
      conn
    else
      conn
      |> put_resp_header("www-authenticate", "Bearer")
      |> send_json(401, %{error: %{type: "unauthorized", message: "send Authorization: Bearer <admin token>"}})
      |> halt()
    end
  end

  defp admin_auth(%{path_info: []} = conn, _opts) do
    if AdminAuth.authorized?(conn), do: conn, else: conn |> redirect("/login") |> halt()
  end

  defp admin_auth(conn, _opts), do: conn

  # Cross-site request forgery: a page on another site can make the browser
  # send a request here with the session cookie attached. Anything that
  # changes state must therefore prove it came from our own page.
  defp csrf(%{method: method} = conn, _opts) when method in ["POST", "PUT", "PATCH", "DELETE"] do
    protected = match?(["admin" | _], conn.path_info) or conn.path_info == ["logout"]

    if not protected or AdminAuth.csrf_ok?(conn) do
      conn
    else
      conn
      |> send_json(403, %{error: %{type: "csrf_failed", message: "missing or wrong CSRF token; reload the dashboard and try again"}})
      |> halt()
    end
  end

  defp csrf(conn, _opts), do: conn

  defp redirect(conn, to) do
    conn |> put_resp_header("location", to) |> send_resp(302, "")
  end

  # Mark the cookie Secure whenever the browser reached us over TLS, directly
  # or through a proxy that says so, or when the operator insists.
  defp secure_cookie?(conn) do
    System.get_env("OMNIGATE_COOKIE_SECURE") == "1" or conn.scheme == :https or
      get_req_header(conn, "x-forwarded-proto") == ["https"]
  end

  # Nothing may load from anywhere else. With a nonce (the dashboard) only
  # the page's own inline style and script run, and the script may talk to
  # this origin; without one (the login page) there is no script at all.
  defp send_html(conn, status, html, nonce \\ nil) do
    policy =
      if nonce do
        "default-src 'none'; style-src 'nonce-#{nonce}'; script-src 'nonce-#{nonce}'; connect-src 'self'; img-src data:; " <>
          "form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
      else
        "default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
      end

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("content-security-policy", policy)
    |> send_resp(status, html)
  end

  defp login_page(error) do
    message = if error, do: "<p class=\"err\">#{h(error)}</p>", else: ""

    """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>omnigate · sign in</title><link rel="icon" href="data:,">
    <style>body{font:14px system-ui;margin:0;min-height:100vh;display:grid;place-items:center;color:#222;background:#fafafa}
    form{background:#fff;border:1px solid #ddd;border-radius:8px;padding:24px;width:min(320px,calc(100vw - 32px));box-sizing:border-box}
    h1{font-size:18px;margin:0 0 16px}label{display:block;margin-bottom:6px}
    input{width:100%;box-sizing:border-box;padding:8px;border:1px solid #bbb;border-radius:4px;font:inherit}
    button{margin-top:12px;width:100%;padding:8px;border:0;border-radius:4px;background:#222;color:#fff;font:inherit;cursor:pointer}
    .err{color:#b00020;margin:0 0 12px}</style></head>
    <body><form method="post" action="/login"><h1>omnigate control plane</h1>#{message}
    <label for="password">Admin token</label>
    <input id="password" name="password" type="password" autocomplete="current-password" autofocus required>
    <button type="submit">Sign in</button></form></body></html>
    """
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  defp h(s), do: s |> to_string() |> Plug.HTML.html_escape()
end
