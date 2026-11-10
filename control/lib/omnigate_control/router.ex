defmodule OmnigateControl.Router do
  @moduledoc """
  HTTP API.

    * `GET  /internal/config` — snapshot for data planes (internal token)
    * `POST /internal/usage/batch` — usage events from data planes (internal token)
    * `/internal/v1/jobs...`, `/internal/v1/files/...` — the media job API. Data
      planes authenticate the gateway key and forward `/v1/jobs*` and
      `/v1/files*` here, naming the key in `x-omnigate-key-sha256`.
    * `GET  /admin/usage`     — per-key totals as JSON (admin token or session)
    * `GET  /`                — dashboard (session; redirects to `/login`)
    * `GET/POST /login`, `POST /logout` — dashboard sessions, see `AdminAuth`
    * `GET  /metrics`         — Prometheus metrics (admin token or session)
    * `GET  /healthz`         — liveness, no authentication

  Three audiences, three credentials: data planes use the internal token,
  operators use the admin token (or a session bought with it), and
  applications never talk to this port at all.
  """
  use Plug.Router

  alias OmnigateControl.{AdminAuth, ConfigStore, Jobs, Ledger, Metrics, Storage, UrlSigner}

  plug :match
  plug Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: JSON, pass: ["*/*"]
  plug :internal_auth
  plug :admin_auth
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

      send_json(conn, 200, %{object: "list", data: key.key_sha256 |> Jobs.list(limit) |> Enum.map(&Jobs.view/1)})
    else
      {:error, status, type, message} -> send_error(conn, status, type, message)
    end
  end

  get "/internal/v1/jobs/:id" do
    with {:ok, key} <- gateway_key(conn),
         %{} = job <- Jobs.get(key.key_sha256, id) do
      send_json(conn, 200, Jobs.view(job))
    else
      {:error, status, type, message} -> send_error(conn, status, type, message)
      nil -> send_error(conn, 404, "job_not_found", "no such job")
    end
  end

  post "/internal/v1/jobs/:id/cancel" do
    with {:ok, key} <- gateway_key(conn),
         %{} = job <- Jobs.cancel(key.key_sha256, id) do
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
    send_json(conn, 200, %{keys: key_rows()})
  end

  get "/" do
    send_html(conn, 200, dashboard())
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
      keys:
        Enum.map(config.keys, fn k ->
          %{key_sha256: k.key_sha256, name: k.name, blocked: blocked?(k), rpm: k.rpm, models: k.models}
        end),
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
         %{} = key <- Enum.find(ConfigStore.get().keys, &(&1.key_sha256 == hash)) do
      {:ok, key}
    else
      _ -> {:error, 401, "invalid_api_key", "unknown gateway key"}
    end
  end

  # The data plane also checks this, but its view lags by one poll interval.
  defp within_budget(key) do
    if blocked?(key), do: {:error, 402, "budget_exceeded", "this key has exhausted its budget"}, else: :ok
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
        if Jobs.get(hash, job_id), do: :ok, else: {:error, 404, "file_not_found", "no such file"}

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

  defp blocked?(%{budget_usd: nil}), do: false
  defp blocked?(k), do: Ledger.spend(k.key_sha256) >= k.budget_usd

  defp key_rows do
    Enum.map(ConfigStore.get().keys, fn k ->
      Map.merge(Ledger.totals(k.key_sha256), %{
        name: k.name,
        budget_usd: k.budget_usd,
        blocked: blocked?(k)
      })
    end)
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

  defp redirect(conn, to) do
    conn |> put_resp_header("location", to) |> send_resp(302, "")
  end

  # Mark the cookie Secure whenever the browser reached us over TLS, directly
  # or through a proxy that says so, or when the operator insists.
  defp secure_cookie?(conn) do
    System.get_env("OMNIGATE_COOKIE_SECURE") == "1" or conn.scheme == :https or
      get_req_header(conn, "x-forwarded-proto") == ["https"]
  end

  defp send_html(conn, status, html) do
    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")
    |> send_resp(status, html)
  end

  defp login_page(error) do
    message = if error, do: "<p class=\"err\">#{h(error)}</p>", else: ""

    """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>omnigate · sign in</title>
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

  defp dashboard do
    rows =
      Enum.map_join(key_rows(), "\n", fn r ->
        budget = if r.budget_usd, do: :erlang.float_to_binary(r.budget_usd, decimals: 4), else: "∞"

        "<tr><td>#{h(r.name)}</td><td>#{r.requests}</td><td>#{r.errors}</td><td>#{r.input_tokens}</td>" <>
          "<td>#{r.output_tokens}</td><td>#{r.jobs}</td><td>$#{:erlang.float_to_binary(r.cost_usd, decimals: 6)}</td>" <>
          "<td>$#{budget}</td><td>#{if r.blocked, do: "blocked", else: "active"}</td></tr>"
      end)

    events =
      Ledger.recent()
      |> Enum.reject(&(&1["kind"] == "media"))
      |> Enum.map_join("\n", fn e ->
        attempts = Enum.map_join(e["attempts"] || [], " → ", &"#{&1["upstream"]}:#{&1["outcome"]}")

        "<tr><td>#{h(e["ts"])}</td><td>#{h(e["route_model"])}</td><td>#{h(e["upstream"] || "-")}</td>" <>
          "<td>#{e["status"]}</td><td>#{e["input_tokens"]}/#{e["output_tokens"]}</td>" <>
          "<td>#{e["latency_ms"]} ms</td><td>#{h(attempts)}</td></tr>"
      end)

    jobs =
      Enum.map_join(Jobs.Store.recent(20), "\n", fn j ->
        attempts = Enum.map_join(j["attempts"] || [], " → ", &"#{&1["upstream"]}:#{&1["outcome"]}")
        webhook = if j["webhook"], do: "#{j["webhook"]["status"]} (#{j["webhook"]["attempts"]})", else: "-"

        "<tr><td>#{h(j["created_at"])}</td><td>#{h(j["id"])}</td><td>#{h(j["model"])}</td><td>#{h(j["status"])}</td>" <>
          "<td>#{h(j["upstream"] || "-")}</td><td>#{length(j["outputs"] || [])}</td>" <>
          "<td>$#{:erlang.float_to_binary((j["cost_usd"] || 0) * 1.0, decimals: 6)}#{if j["cached"], do: " (cached)"}</td>" <>
          "<td>#{h(webhook)}</td><td>#{h(attempts)}</td></tr>"
      end)

    """
    <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="2">
    <title>omnigate</title>
    <style>body{font:14px system-ui;margin:24px;color:#222}table{border-collapse:collapse;margin-bottom:24px}
    td,th{border:1px solid #ddd;padding:4px 8px;text-align:left}th{background:#f5f5f5}
    .top{display:flex;justify-content:space-between;align-items:center}.top button{font:inherit;padding:4px 10px;cursor:pointer}</style></head>
    <body><div class="top"><h1>omnigate control plane</h1>
    <form method="post" action="/logout"><button type="submit">Sign out</button></form></div>
    <h2>Keys</h2><table><tr><th>Key</th><th>Requests</th><th>Errors</th><th>In tok</th><th>Out tok</th>
    <th>Jobs</th><th>Spend</th><th>Budget</th><th>State</th></tr>#{rows}</table>
    <h2>Recent requests</h2><table><tr><th>Time</th><th>Model</th><th>Served by</th><th>Status</th>
    <th>Tokens in/out</th><th>Latency</th><th>Attempts</th></tr>#{events}</table>
    <h2>Recent media jobs</h2><table><tr><th>Created</th><th>Job</th><th>Model</th><th>Status</th><th>Served by</th>
    <th>Outputs</th><th>Cost</th><th>Webhook</th><th>Attempts</th></tr>#{jobs}</table></body></html>
    """
  end

  defp h(nil), do: ""
  defp h(s), do: s |> to_string() |> Plug.HTML.html_escape()
end
