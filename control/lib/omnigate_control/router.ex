defmodule OmnigateControl.Router do
  @moduledoc """
  HTTP API.

    * `GET  /internal/config` — snapshot for data planes (internal token)
    * `POST /internal/usage/batch` — usage events from data planes (internal token)
    * `POST /internal/counters` — counts of requests data planes refused (internal token)
    * `/internal/v1/jobs...`, `/internal/v1/files/...` — the media job API. Data
      planes authenticate the gateway key and forward `/v1/jobs*` and
      `/v1/files*` here, naming the key in `x-omnigate-key-sha256`.
    * `GET  /admin/usage`     — per-key totals as JSON (admin token or session)
    * `GET  /admin/overview`  — everything the dashboard shows, as JSON
    * `GET/POST /admin/keys`, `PATCH/DELETE /admin/keys/:name`,
      `POST /admin/keys/:name/rotate` — managed gateway keys, see `Keys`
    * `GET  /admin/audit`     — the latest admin actions, see `Audit`
    * `GET  /admin/attestations`, `POST /admin/attestations/verify` — attested
      upstreams and their verdicts, see `Attestation`
    * `GET  /admin/receipts`, `GET /admin/receipts/:id` — the receipts of
      answers from attested upstreams, see `Receipts`; the key that made a
      request reads its own through the data plane, which forwards
      `GET /v1/attestations/:id` to `/internal/v1/attestations/:id`
    * `GET  /`                — dashboard (session; redirects to `/login`)
    * `GET  /private-chat`    — the Private chat page (session), with
      `GET /admin/private-chat/state` and `POST /admin/private-chat/send`,
      see `PrivateChat`
    * `GET/POST /login`, `POST /logout` — dashboard sessions, see `AdminAuth`
    * `GET  /metrics`         — Prometheus metrics (admin token or session)
    * `GET  /healthz`         — liveness, no authentication
    * `GET  /readyz`          — readiness: config loaded, ledger and job store up and writable

  Three audiences, three credentials: data planes use the internal token,
  operators use the admin token (or a session bought with it), and
  applications never talk to this port at all.
  """
  use Plug.Router

  alias OmnigateControl.{
    Admin,
    AdminAuth,
    Attestation,
    Audit,
    ConfigStore,
    Dashboard,
    Jobs,
    Keys,
    Ledger,
    Metrics,
    Privacy,
    PrivateChat,
    PrivateChatPage,
    RateLimit,
    Receipts,
    Redactions,
    Rejections,
    Storage,
    Text,
    UrlSigner
  }

  require Logger

  # First path segments that are reachable without the admin token: the
  # internal API (which has its own token), probes and the login form. The
  # test route exists, and is listed, only in a build that compiles it in.
  @public_segments ["internal", "healthz", "readyz", "login", "logout"] ++
                     if(Application.compile_env(:omnigate_control, :test_routes, false), do: ["__test"], else: [])

  # Largest request body the parser reads; anything bigger is a 413. The
  # limit is spelled out because the data plane enforces the same number for
  # job requests (`max_job_body` in proxy.zig): a body one process accepts
  # must not be refused by the other.
  @max_body_bytes 8_000_000
  # The only body an anonymous caller may have parsed is the login form,
  # which is a few dozen bytes.
  @public_body_limit 4096

  @parse_full Plug.Parsers.init(parsers: [:urlencoded, :json], json_decoder: JSON, pass: ["*/*"], length: @max_body_bytes)
  @parse_small Plug.Parsers.init(parsers: [:urlencoded, :json], json_decoder: JSON, pass: ["*/*"], length: @public_body_limit)

  # `GET /v1/jobs` per key per minute when the key has no `rpm` of its own.
  @list_rpm 600

  # Order matters. The guards below decide by `conn.path_info`, which is the
  # path exactly as sent, while the router matches on the percent-DECODED
  # path: `/%61dmin/keys` used to slip past every guard and still reach the
  # `/admin/keys` handler. `plain_path` makes the two views identical before
  # anything else runs, and the guards refuse whatever they do not recognise.
  # Authentication also comes before body parsing, and `parse_body` parses
  # only for callers who have authenticated (and the login form), so an
  # anonymous caller cannot make this process read or parse megabytes.
  plug(:request_id)
  plug(:close_unread)
  plug(:plain_path)
  plug(:match)
  plug(:internal_auth)
  plug(:admin_auth)
  plug(:parse_body)
  plug(:csrf)
  plug(:dispatch)

  # Every failure leaves here as the same JSON error object, whatever raised
  # it: a body that is not JSON, a body that is too large, or a bug.
  def call(conn, opts) do
    super(conn, opts)
  rescue
    error ->
      {conn, error} =
        case error do
          %Plug.Conn.WrapperError{conn: inner, reason: reason} -> {inner, reason}
          other -> {conn, other}
        end

      if conn.state in [:sent, :chunked, :file] do
        reraise error, __STACKTRACE__
      else
        failure(conn, error, __STACKTRACE__)
      end
  end

  defp failure(conn, %Plug.Parsers.ParseError{}, _stack), do: send_error(conn, 400, "invalid_json", "the request body is not valid JSON")

  defp failure(conn, %Plug.Parsers.RequestTooLargeError{}, _stack),
    do: send_error(conn, 413, "payload_too_large", "the request body is larger than the control plane accepts")

  defp failure(conn, %Plug.Parsers.BadEncodingError{}, _stack), do: send_error(conn, 400, "invalid_request", "the request body is not valid UTF-8")

  defp failure(conn, error, stack) do
    # The id ties the client's error to this log line; nothing else about the
    # failure leaves the process.
    id = conn.assigns[:request_id] || new_request_id()
    # The method and the path are the caller's words: one line of plain text, whatever was sent.
    Logger.error("request #{id} #{Text.line(conn.method, 20)} #{Text.line(conn.request_path, 200)} failed: " <> Exception.format(:error, error, stack))

    conn
    |> put_resp_header("x-request-id", id)
    |> send_error(500, "internal_error", "the control plane failed to handle this request", %{request_id: id})
  end

  get "/healthz" do
    conn |> put_resp_content_type("text/plain") |> send_resp(200, "ok\n")
  end

  # Only in the test build: a route that fails, to check what a failure looks like from outside.
  if Application.compile_env(:omnigate_control, :test_routes, false) do
    get "/__test/raise" do
      _ = conn
      raise "secret detail that must stay in the log"
    end
  end

  # Liveness says the process answers; readiness says it can do its job.
  get "/readyz" do
    case readiness() do
      :ok -> send_json(conn, 200, %{status: "ready"})
      {:error, reason} -> send_json(conn, 503, %{status: "not_ready", reason: reason})
    end
  end

  get "/metrics" do
    conn
    |> put_resp_header("content-type", "text/plain; version=0.0.4; charset=utf-8")
    |> send_resp(200, Metrics.render())
  end

  # The snapshot says which keys are out of budget, and that comes from the
  # ledger. While the ledger is starting (or restarting) there is no spend to
  # read, and "nothing spent" would unblock every key. Answer "not now"
  # instead: a data plane keeps the config it has until it gets a new one.
  get "/internal/config" do
    if Ledger.ready?() do
      send_json(conn, 200, snapshot())
    else
      conn |> put_resp_header("retry-after", "1") |> send_error(503, "not_ready", "the ledger is starting; keep the current config and ask again")
    end
  end

  post "/internal/usage/batch" do
    case conn.body_params do
      %{"events" => events} when is_list(events) ->
        {:ok, counts} = Ledger.record_batch(events)
        # Answers from attested upstreams carry what a receipt needs.
        Receipts.offer(events)
        send_json(conn, 200, counts)

      _ ->
        send_error(conn, 400, "invalid_request", "expected {\"events\": [...]}")
    end
  end

  # Requests refused before routing never become usage events; data planes
  # report how many there were, by key name and reason.
  post "/internal/counters" do
    case conn.body_params do
      %{"counters" => counters} when is_list(counters) ->
        # The same report carries what privacy mode replaced (counts by
        # class): those are not refusals and are kept apart.
        {redactions, rejections} = Enum.split_with(counters, &Redactions.counter?/1)
        send_json(conn, 200, %{accepted: Rejections.record(rejections) + Redactions.record(redactions)})

      _ ->
        send_error(conn, 400, "invalid_request", "expected {\"counters\": [...]}")
    end
  end

  # -- media jobs ------------------------------------------------------------

  post "/internal/v1/jobs" do
    with {:ok, key} <- gateway_key(conn),
         :ok <- within_budget(key),
         :ok <- model_allowed(key, conn.body_params["model"]),
         {:ok, asked_private} <- privacy_header(conn),
         idempotency_key = conn |> get_req_header("idempotency-key") |> List.first(),
         :ok <- within_rate(key, idempotency_key) do
      # Unfinished jobs, and jobs created today, are counted across the key's rotations.
      hashes = Keys.hashes(key)
      caps = [open_cap: {Keys.max_open_jobs(key), hashes}, day_cap: {Keys.max_jobs_per_day(key), hashes}]
      # Privacy mode: the key's setting, and what this request added to it.
      privacy = %{no_store: Privacy.no_store?(key) or asked_private, encrypt_to: Privacy.recipient(key)}

      # The caller's label for the job (`x-omnigate-tag`), for the usage feed.
      tag = conn |> get_req_header("x-omnigate-tag") |> List.first() |> Ledger.tag()

      case Jobs.create(key.key_sha256, conn.body_params, idempotency_key, [{:privacy, privacy}, {:tag, tag} | caps]) do
        {:ok, job} ->
          send_json(conn, 202, Jobs.view(job))

        {:existing, job} ->
          send_json(conn, 200, Jobs.view(job))

        # Too many unfinished jobs: worth trying again once some have finished.
        {:error, 429, type, message} ->
          conn |> put_resp_header("retry-after", "10") |> send_error(429, type, message)

        # A limit that lifts at a known time says when.
        {:error, 429, type, message, retry_after_s} ->
          conn |> put_resp_header("retry-after", Integer.to_string(retry_after_s)) |> send_error(429, type, message)

        {:error, status, type, message} ->
          send_error(conn, status, type, message)
      end
    else
      {:error, 429, type, message, retry_after_s} -> conn |> put_resp_header("retry-after", Integer.to_string(retry_after_s)) |> send_error(429, type, message)
      {:error, status, type, message} -> send_error(conn, status, type, message)
    end
  end

  get "/internal/v1/jobs" do
    with {:ok, key} <- gateway_key(conn),
         :ok <- list_within_rate(key) do
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

      # A list leaves large inputs out (`"input_omitted": true`); fetch the job to see one.
      send_json(conn, 200, %{object: "list", data: Enum.map(jobs, &Jobs.view(&1, input: false))})
    else
      {:error, 429, type, message, retry_after_s} -> conn |> put_resp_header("retry-after", Integer.to_string(retry_after_s)) |> send_error(429, type, message)
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

  # The receipt of one answer from an attested upstream, for the key that
  # made the request (across its rotations). Anyone else's, and an id that
  # has none, are the same 404.
  get "/internal/v1/attestations/:id" do
    with {:ok, key} <- gateway_key(conn),
         %{} = receipt <- Receipts.own(Keys.hashes(key), id) do
      send_json(conn, 200, Receipts.view(receipt))
    else
      {:error, status, type, message} -> send_error(conn, status, type, message)
      nil -> send_error(conn, 404, "receipt_not_found", "no receipt for this request id")
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
    attrs = json_object(conn)
    result = Keys.create(attrs)
    Audit.record(conn, "key.create", audit_name(attrs["name"]), outcome(result), privacy: privacy_change(attrs, result))

    case result do
      # The only response that ever contains the key itself.
      {:ok, key, raw} -> send_json(conn, 201, key |> Admin.key_view() |> Map.put(:key, raw))
      {:error, status, type, message} -> send_error(conn, status, type, message)
    end
  end

  patch "/admin/keys/:name" do
    attrs = json_object(conn)
    result = Keys.update(name, attrs)
    # Which fields were sent, never their values (one of them is a secret).
    Audit.record(conn, "key.update", audit_name(name), outcome(result),
      fields: attrs |> Map.keys() |> Enum.sort() |> Enum.take(20),
      privacy: privacy_change(attrs, result)
    )

    case result do
      {:ok, key} -> send_json(conn, 200, Admin.key_view(key))
      {:error, status, type, message} -> send_error(conn, status, type, message)
    end
  end

  post "/admin/keys/:name/rotate" do
    result = Keys.rotate(name)
    Audit.record(conn, "key.rotate", audit_name(name), outcome(result))

    case result do
      {:ok, key, raw} -> send_json(conn, 200, key |> Admin.key_view() |> Map.put(:key, raw))
      {:error, status, type, message} -> send_error(conn, status, type, message)
    end
  end

  # Credit bought in advance, once per payment reference (see `Keys.topup/2`).
  post "/admin/keys/:name/topup" do
    attrs = json_object(conn)
    result = Keys.topup(name, attrs)

    Audit.record(conn, "key.topup", audit_name(name), outcome(result),
      topup:
        case result do
          {:ok, _key, done} -> Map.take(done, ["reference", "amount_usd", "budget_usd", "replayed"])
          # What was asked, cut to what an audit line should hold.
          _ -> %{"reference" => audit_name(attrs["reference"]), "amount_usd" => if(is_number(attrs["amount_usd"]), do: attrs["amount_usd"])}
        end
    )

    case result do
      {:ok, key, done} -> send_json(conn, 200, %{key: Admin.key_view(key), topup: done})
      {:error, status, type, message} -> send_error(conn, status, type, message)
    end
  end

  # The usage feed: every ledger event, oldest first, by cursor.
  get "/admin/events" do
    conn = fetch_query_params(conn)
    q = conn.query_params

    limit =
      case Integer.parse(q["limit"] || "") do
        {n, ""} -> n |> max(1) |> min(1000)
        _ -> 100
      end

    cursor =
      case q["after"] do
        empty when empty in [nil, ""] -> {:ok, nil}
        text -> Admin.parse_cursor(text)
      end

    with {:ok, position} <- cursor,
         {:ok, page} <- Admin.events(position, limit, if(q["key"] in [nil, ""], do: nil, else: q["key"])) do
      send_json(conn, 200, page)
    else
      {:error, :key_not_found} ->
        send_error(conn, 404, "key_not_found", "no key named #{inspect(String.slice(to_string(q["key"]), 0, 64))}")

      _ ->
        send_error(
          conn,
          400,
          "invalid_cursor",
          "\"after\" must be a cursor from an earlier page (the \"next\" field, or an event's \"cursor\"); leave it out to start at the oldest event"
        )
    end
  end

  delete "/admin/keys/:name" do
    result = Keys.delete(name)
    Audit.record(conn, "key.delete", audit_name(name), outcome(result))

    case result do
      :ok -> send_json(conn, 200, %{deleted: name})
      {:error, status, type, message} -> send_error(conn, status, type, message)
    end
  end

  get "/admin/audit" do
    conn = fetch_query_params(conn)

    limit =
      case Integer.parse(conn.query_params["limit"] || "") do
        {n, ""} -> n |> max(1) |> min(500)
        _ -> 50
      end

    send_json(conn, 200, %{entries: Audit.recent(limit)})
  end

  # -- attested upstreams -------------------------------------------------------

  get "/admin/attestations" do
    now = System.os_time(:second)
    send_json(conn, 200, %{attestations: Enum.map(Attestation.Manager.all(), &Attestation.view(&1, now)), checks: Attestation.Manager.counts()})
  end

  # Receipts of answers from attested upstreams: the newest, or one by its
  # request id, with the name of the key that made the request.
  get "/admin/receipts" do
    conn = fetch_query_params(conn)

    limit =
      case Integer.parse(conn.query_params["limit"] || "") do
        {n, ""} -> n |> max(1) |> min(500)
        _ -> 50
      end

    send_json(conn, 200, %{receipts: Enum.map(Receipts.recent(limit), &admin_receipt/1), counts: Receipts.counts()})
  end

  get "/admin/receipts/:id" do
    case Receipts.get(id) do
      nil -> send_error(conn, 404, "receipt_not_found", "no receipt for this request id")
      receipt -> send_json(conn, 200, admin_receipt(receipt))
    end
  end

  # Check one (upstream, model) now, with a fresh nonce, and answer with the verdict.
  post "/admin/attestations/verify" do
    attrs = json_object(conn)

    with upstream when is_binary(upstream) <- attrs["upstream"],
         model when is_binary(model) <- attrs["model"],
         %{} = entry <- Attestation.Manager.verify_now(upstream, model) do
      Audit.record(conn, "attestation.verify", audit_name("#{upstream}/#{model}"), if(entry.state == :verified, do: "ok", else: "failed"))
      send_json(conn, 200, Attestation.view(entry))
    else
      nil -> send_error(conn, 404, "not_found", "the config routes no target to this upstream and model on an attested upstream")
      _ -> send_error(conn, 400, "invalid_request", "expected {\"upstream\": name, \"model\": name}")
    end
  end

  get "/" do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    # A bearer-token request has no session to tie a CSRF token to; it does
    # not need one either.
    csrf =
      case conn.assigns[:auth] == :session && AdminAuth.session(conn) do
        session when is_binary(session) -> AdminAuth.csrf_token(session)
        _ -> ""
      end

    send_html(conn, 200, Dashboard.page(Admin.overview(), csrf, nonce), nonce)
  end

  # -- the Private chat page ----------------------------------------------------

  # Opt-in: the page exists only while the config has an attested upstream.
  get "/private-chat" do
    if Attestation.configured?(), do: private_chat_page(conn), else: no_private_chat(conn)
  end

  get "/admin/private-chat/state" do
    if Attestation.configured?(), do: send_json(conn, 200, PrivateChat.state()), else: no_private_chat(conn)
  end

  # One turn of the page's conversation: a dry run and the real request,
  # both through the data plane's public port with the page's own key.
  # Nothing of the body is logged or audited.
  post "/admin/private-chat/send" do
    if Attestation.configured?() do
      case PrivateChat.send_turn(json_object(conn)) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, status, type, message} -> send_error(conn, status, type, message)
      end
    else
      no_private_chat(conn)
    end
  end

  defp no_private_chat(conn),
    do: send_error(conn, 404, "not_found", "the Private chat page is off: no upstream in the config has an \"attestation\" setting")

  defp private_chat_page(conn) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    csrf =
      case conn.assigns[:auth] == :session && AdminAuth.session(conn) do
        session when is_binary(session) -> AdminAuth.csrf_token(session)
        _ -> ""
      end

    send_html(conn, 200, PrivateChatPage.page(csrf, nonce), nonce)
  end

  get "/login" do
    case conn.assigns[:auth] do
      ok when ok in [:session, :token] -> redirect(conn, "/")
      # A bearer token from an address that sent too many wrong ones gets
      # the same answer here as on `/` and `/admin/*`, not a page with 200.
      :throttled -> too_many_tokens(conn)
      _ -> send_html(conn, 200, login_page(nil))
    end
  end

  # Failed and throttled attempts are anyone's to cause: they go to the
  # audit log through `Audit.anonymous/4`, which never makes this request
  # (or an operator's) wait and writes at most two lines per address a minute.
  post "/login" do
    address = AdminAuth.client_address(conn)

    cond do
      # Counted before the password is compared (see `AdminAuth.begin_attempt/3`).
      AdminAuth.begin_attempt(address) == :throttled ->
        Audit.anonymous(conn, "login", "throttled", auth: "password")
        send_html(conn, 429, login_page("Too many failed attempts. Wait a minute and try again."))

      AdminAuth.valid_token?(conn.body_params["password"]) ->
        AdminAuth.clear_failures(address)
        Audit.record(conn, "login", nil, "ok", auth: "password")

        conn
        |> put_resp_cookie(AdminAuth.cookie_name(), AdminAuth.issue_session(),
          http_only: true,
          same_site: "Strict",
          secure: secure_cookie?(conn),
          max_age: AdminAuth.session_ttl_s()
        )
        |> redirect("/")

      true ->
        Audit.anonymous(conn, "login", "denied", auth: "password")
        send_html(conn, 401, login_page("That is not the admin token."))
    end
  end

  post "/logout" do
    # Only a logout that ends a session is worth a line.
    if conn.assigns[:auth] == :session, do: Audit.record(conn, "logout", nil, "ok")

    conn
    |> delete_resp_cookie(AdminAuth.cookie_name(), http_only: true, same_site: "Strict", secure: secure_cookie?(conn))
    |> redirect("/login")
  end

  match _ do
    send_error(conn, 404, "not_found", "no such endpoint")
  end

  @doc "`:ok`, or `{:error, reason}` naming the first thing that is not ready."
  def readiness do
    cond do
      not config_loaded?() ->
        {:error, "config is not loaded"}

      is_nil(Process.whereis(OmnigateControl.Jobs.Store)) ->
        {:error, "job store is not running"}

      true ->
        case Ledger.status() do
          %{ready: true, writable: true} -> :ok
          %{ready: true} -> {:error, "ledger file is not writable"}
          _ -> {:error, "ledger is not running (it may still be replaying)"}
        end
    end
  end

  defp config_loaded? do
    is_map(ConfigStore.get())
  rescue
    _ -> false
  end

  @doc "Data-plane view of the config: no budgets, no prices, no secrets."
  def snapshot do
    config = ConfigStore.get()

    body = %{
      # A disabled key is left out altogether, so data planes refuse it as
      # an unknown key (401) rather than as one that is out of budget.
      keys:
        for k <- config.keys, not Keys.disabled?(k) do
          %{
            key_sha256: k.key_sha256,
            name: k.name,
            blocked: Keys.over_budget?(k),
            rpm: k.rpm,
            # Requests in flight at once; 0 = the data plane's own default.
            max_concurrent: Map.get(k, :max_concurrent, 0),
            models: k.models,
            # Privacy mode, as far as a data plane applies it; null = none.
            privacy: Privacy.for_data_plane(Map.get(k, :privacy))
          }
        end,
      # (How an upstream is attested is this side's business; the verdict
      # goes out per target, below.)
      upstreams: Enum.map(config.upstreams, &Map.delete(&1, :attestation)),
      routes:
        Enum.map(config.routes, fn r ->
          %{
            model: r.model,
            strategy: r.strategy,
            # Seconds the data plane may answer identical requests from its own cache; 0 = never.
            cache_ttl_s: Map.get(r, :cache_ttl_s, 0),
            targets:
              Enum.map(r.targets, fn t ->
                target = Map.take(t, [:upstream, :model, :weight])

                # On an attested upstream: whether the evidence is verified
                # right now. Absent for every other target.
                case Attestation.Manager.for_snapshot(t.upstream, t.model) do
                  nil -> target
                  verdict -> Map.put(target, :attestation, verdict)
                end
              end)
          }
        end),
      # Names only: media jobs are routed here, but data planes list them in /v1/models.
      media_models: Enum.map(config.media.routes, & &1.model)
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

  # `x-omnigate-privacy` on a job request: `{:ok, true}` when it asks for
  # nothing of the job to be kept. (The data plane validated it and sends
  # `no-store`; checked again, like everything that arrives.)
  defp privacy_header(conn) do
    case get_req_header(conn, "x-omnigate-privacy") do
      [] ->
        {:ok, false}

      [value] ->
        case Privacy.header(value) do
          {:ok, private} -> {:ok, private}
          :error -> {:error, 400, "invalid_request", "invalid x-omnigate-privacy header: use \"on\", or a comma-separated list of no-store, redact, unlink"}
        end

      _ ->
        {:error, 400, "invalid_request", "x-omnigate-privacy was sent more than once"}
    end
  end

  # For the audit log: a key's privacy mode after a change that set it
  # ("off" when the change switched it off); nil when the change did not
  # touch it or did not happen.
  defp privacy_change(attrs, result) do
    with true <- Map.has_key?(attrs, "privacy"),
         key when is_map(key) <- changed_key(result) do
      case Privacy.summary(Map.get(key, :privacy)) do
        "" -> "off"
        summary -> summary
      end
    else
      _ -> nil
    end
  end

  defp changed_key({:ok, key}), do: key
  defp changed_key({:ok, key, _raw}), do: key
  defp changed_key(_), do: nil

  # A job belongs to a key under its current secret or one from before a rotation.
  defp admin_receipt(receipt) do
    owner = is_binary(receipt["key_sha256"]) && Keys.find_owner(receipt["key_sha256"])
    receipt |> Receipts.view() |> Map.put("key", if(owner, do: owner.name))
  end

  defp own_job(key, id), do: Enum.find_value(Keys.hashes(key), &Jobs.get(&1, id))

  defp outcome({:ok, _key}), do: "ok"
  defp outcome({:ok, _key, _raw}), do: "ok"
  defp outcome(:ok), do: "ok"
  defp outcome({:error, _status, type, _message}), do: type

  # Whatever was sent as a name goes into the audit log, cut to a sane length.
  defp audit_name(name) when is_binary(name), do: String.slice(name, 0, 64)
  defp audit_name(_), do: nil

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

  # The key's requests-per-minute limit, counted here for job creation. The
  # data plane counts too, but only for the exact paths it recognises, and a
  # limit that guards paid work must not depend on that.
  #
  # Counted per key (by the hash of its current secret, like the data plane),
  # not per name: two keys never share an allowance. A request that repeats
  # an Idempotency-Key this key already used creates nothing (it gets the
  # first job back), so it does not use up the allowance either.
  defp within_rate(key, idempotency_key) do
    if is_binary(idempotency_key) and Jobs.Store.idempotent?(key.key_sha256, idempotency_key) do
      :ok
    else
      case RateLimit.check(Keys.identity(key), Map.get(key, :rpm, 0)) do
        :ok -> :ok
        {:error, retry_after_s} -> {:error, 429, "rate_limit_exceeded", "this key is over its requests-per-minute limit", retry_after_s}
      end
    end
  end

  # Listing jobs is cheap but not free, and nothing else limits it for a key
  # without an `rpm`. It has a bucket of its own, so listing never eats into
  # the allowance for creating jobs.
  defp list_within_rate(key) do
    rpm =
      case Map.get(key, :rpm, 0) do
        n when is_integer(n) and n > 0 -> n
        _ -> @list_rpm
      end

    case RateLimit.check({:list, Keys.identity(key)}, rpm) do
      :ok -> :ok
      {:error, retry_after_s} -> {:error, 429, "rate_limit_exceeded", "this key is listing jobs too often", retry_after_s}
    end
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
      # The bytes and their declared type came from a provider. They are sent
      # as a download from a sandboxed, script-less context, and never as a
      # type a browser would render as a page on this origin.
      conn
      |> put_resp_header("content-type", OmnigateControl.Storage.served_type(output["content_type"]))
      |> put_resp_header("content-disposition", "attachment; filename=\"#{safe_filename(output["name"])}\"")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "sandbox; default-src 'none'")
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_file(200, path)
    else
      send_error(conn, 404, "file_not_found", "no such file")
    end
  end

  defp safe_filename(name) when is_binary(name) do
    if name =~ ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z/, do: name, else: "output.bin"
  end

  defp safe_filename(_), do: "output.bin"

  # Every error leaves in one shape (see `OmnigateControl.Errors`): the
  # reason in `error.code`, an OpenAI-style category in `error.type`. It is
  # the shape the data plane uses for its own refusals, so a client of
  # `/v1/jobs` sees the same thing whichever process said no.
  defp send_error(conn, status, reason, message, extra \\ %{}) do
    send_json(conn, status, OmnigateControl.Errors.body(status, reason, message, extra))
  end

  # Each request gets an id, returned as `x-request-id` and written with any
  # failure in the log. A data plane relaying a client's request sends its
  # own id along, so one id follows the request through both processes.
  defp request_id(conn, _opts) do
    id =
      case get_req_header(conn, "x-omnigate-request-id") do
        [given] when byte_size(given) in 8..64 -> if given =~ ~r/\A[A-Za-z0-9_-]+\z/, do: given, else: new_request_id()
        _ -> new_request_id()
      end

    conn |> assign(:request_id, id) |> put_resp_header("x-request-id", id)
  end

  defp new_request_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp internal_auth(%{path_info: ["internal" | _]} = conn, _opts) do
    expected = OmnigateControl.internal_token() || ""

    case get_req_header(conn, "x-omnigate-internal") do
      [token] when expected != "" ->
        if Plug.Crypto.secure_compare(token, expected), do: conn, else: deny(conn)

      _ ->
        deny(conn)
    end
  end

  defp internal_auth(conn, _opts), do: conn

  defp deny(conn), do: conn |> send_error(401, "unauthorized", "missing or wrong internal token") |> halt()

  # `/admin/*` is an API: answer 401. The dashboard is a page: send the
  # browser to the login form. Everything else here is either public
  # (`/healthz`, `/login`) or guarded by `internal_auth` above.
  #
  # Wherever the admin token is accepted, it is checked in one place
  # (`AdminAuth.authenticate/1`), which counts wrong tokens per address and
  # stops comparing once there were too many: token guessing is slowed the
  # same way password guessing is. That includes the dashboard and the login
  # page, which also accept the token; they used to compare it on their own.
  defp admin_auth(%{path_info: [first | _]} = conn, _opts) when first in ["admin", "metrics"] do
    conn = assign(conn, :auth, AdminAuth.authenticate(conn))

    case conn.assigns.auth do
      ok when ok in [:session, :token] ->
        conn

      :throttled ->
        too_many_tokens(conn)

      # `:denied` (a wrong token, now counted) or `:none` (no token: not a guess).
      _ ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> send_error(401, "unauthorized", "send Authorization: Bearer <admin token>")
        |> halt()
    end
  end

  defp admin_auth(%{path_info: path} = conn, _opts) when path in [[], ["private-chat"]] do
    conn = assign(conn, :auth, AdminAuth.authenticate(conn))

    case conn.assigns.auth do
      ok when ok in [:session, :token] -> conn
      :throttled -> too_many_tokens(conn)
      _ -> conn |> redirect("/login") |> halt()
    end
  end

  # The login form and logout are public, but both look at who is asking
  # (the form sends a signed-in visitor on to the dashboard).
  defp admin_auth(%{path_info: [first]} = conn, _opts) when first in ["login", "logout"] do
    assign(conn, :auth, AdminAuth.authenticate(conn))
  end

  # Everything else must be one of the few paths that are public on purpose.
  # An unknown first segment is refused here rather than left to the router,
  # so a route added later is closed until someone decides who may call it.
  defp admin_auth(%{path_info: [first | _]} = conn, _opts) when first in @public_segments, do: conn

  defp admin_auth(conn, _opts) do
    conn |> send_error(404, "not_found", "no such endpoint") |> halt()
  end

  defp too_many_tokens(conn) do
    conn
    |> put_resp_header("retry-after", "60")
    |> send_error(429, "too_many_attempts", "too many wrong admin tokens from this address; wait a minute")
    |> halt()
  end

  # Whose request bodies are read and parsed:
  #
  #   * `/internal/*` and `/admin/*`: the caller has authenticated by now
  #     (the two plugs before this one refused everyone else);
  #   * `POST /login`: the login form, at most a few KiB;
  #   * `POST /logout` from a signed-in browser: it carries the CSRF token.
  #
  # Nobody else's. `POST /healthz`, `DELETE /login`, `POST /login/x`, a body
  # on a GET: none of them is read at all, whatever the method. They get the
  # answer the path deserves (usually 404) and, because an unread body is
  # still on the connection, the connection is closed afterwards
  # (`close_unread`) rather than drained.
  defp parse_body(conn, _opts) do
    case body_policy(conn) do
      :full ->
        conn |> put_private(:omnigate_body_parsed, true) |> Plug.Parsers.call(@parse_full)

      :small ->
        if declared_length(conn) in 0..@public_body_limit do
          conn |> put_private(:omnigate_body_parsed, true) |> Plug.Parsers.call(@parse_small)
        else
          conn |> send_error(413, "payload_too_large", "the request body is larger than this endpoint accepts") |> halt()
        end

      :none ->
        %{conn | body_params: %{}}
    end
  end

  defp body_policy(%{path_info: [first | _]}) when first in ["internal", "admin"], do: :full
  defp body_policy(%{method: "POST", path_info: ["login"]}), do: :small
  defp body_policy(%{method: "POST", path_info: ["logout"], assigns: %{auth: :session}}), do: :small
  defp body_policy(_conn), do: :none

  # The body length a request declares: a number, 0 when it declares no body
  # at all, `:unknown` for chunked or malformed.
  defp declared_length(conn) do
    case get_req_header(conn, "content-length") do
      [n] ->
        case Integer.parse(n) do
          {bytes, ""} when bytes >= 0 -> bytes
          _ -> :unknown
        end

      [] ->
        if get_req_header(conn, "transfer-encoding") == [], do: 0, else: :unknown

      _ ->
        :unknown
    end
  end

  # A request body that nothing read is still in the socket when the answer
  # goes out. The server would read it (up to megabytes) just to throw it
  # away before the next request on the connection; closing the connection
  # costs the sender more than it costs us.
  defp close_unread(conn, _opts) do
    register_before_send(conn, fn conn ->
      if conn.private[:omnigate_body_parsed] != true and declared_length(conn) != 0 do
        put_resp_header(conn, "connection", "close")
      else
        conn
      end
    end)
  end

  # No route here needs a percent-encoded character (ids, names and file
  # names are all plain), so any `%` in the path is refused outright, as is
  # anything that would decode differently from how it was sent.
  defp plain_path(conn, _opts) do
    plain = fn segment -> not String.contains?(segment, ["%", "\\", <<0>>]) and segment not in [".", ".."] end

    # A request line without a usable path (some servers hand over nil for
    # odd targets such as "//host") is refused like any other odd spelling.
    if is_binary(conn.request_path) and Enum.all?(conn.path_info, plain) and not String.contains?(conn.request_path, "%") do
      conn
    else
      conn |> send_error(400, "invalid_request", "the request path must not contain encoded characters") |> halt()
    end
  end

  # Cross-site request forgery: a page on another site can make the browser
  # send a request here with the session cookie attached. Anything that
  # changes state must therefore prove it came from our own page.
  defp csrf(%{method: method} = conn, _opts) when method in ["POST", "PUT", "PATCH", "DELETE"] do
    protected = match?(["admin" | _], conn.path_info) or conn.path_info == ["logout"]

    if not protected or AdminAuth.csrf_ok?(conn) do
      conn
    else
      conn
      |> send_error(403, "csrf_failed", "missing or wrong CSRF token; reload the dashboard and try again")
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
