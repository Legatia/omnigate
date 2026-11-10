defmodule OmnigateControl.Dashboard do
  @moduledoc """
  The operator dashboard: one self-contained HTML page.

  The page is rendered completely on the server from `Admin.overview/0`, so
  it shows current data with JavaScript disabled. With JavaScript, the same
  tables are refreshed every few seconds from `GET /admin/overview` without
  reloading, and keys can be created, rotated, disabled and deleted.

  Nothing is loaded from anywhere else: styles and script are inline, allowed
  by a per-response nonce in the Content-Security-Policy. All data is written
  with HTML escaping here and with `textContent` in the script.
  """

  @doc "The full page for an overview document, a CSRF token and a CSP nonce."
  def page(o, csrf, nonce) do
    [
      ~s(<!doctype html><html lang="en"><head><meta charset="utf-8">),
      ~s(<meta name="viewport" content="width=device-width, initial-scale=1">),
      ~s(<meta name="csrf" content="),
      h(csrf),
      ~s("><link rel="icon" href="data:,">),
      ~s(<title>omnigate control plane</title><style nonce="),
      nonce,
      ~s(">),
      css(),
      ~s(</style></head><body>),
      ~s(<header class="top"><div class="brand">omnigate <span>control plane</span></div>),
      ~s(<nav aria-label="Sections"><a href="#overview">Overview</a><a href="#keys">Keys</a>),
      ~s(<a href="#requests">Requests</a><a href="#jobs">Jobs</a><a href="#refused">Refused</a><a href="#activity">Activity</a>),
      ~s(<a href="#config">Configuration</a></nav>),
      ~s(<div class="right"><span id="updated" class="muted" role="status">Updated ),
      h(clock(o.generated_at)),
      ~s( UTC</span>),
      ~s(<form method="post" action="/logout"><input type="hidden" name="_csrf" value="),
      h(csrf),
      ~s("><button type="submit" class="ghost">Sign out</button></form></div></header><main>),
      overview(o),
      keys(o),
      requests(o),
      jobs(o),
      refused(o),
      activity(o),
      config(o.config),
      ~s(</main><script nonce="),
      nonce,
      ~s(">),
      js(),
      ~s(</script></body></html>)
    ]
    |> IO.iodata_to_binary()
  end

  # -- sections -------------------------------------------------------------------

  @cards [
    {"requests", "Requests", :int},
    {"errors", "Errors", :int},
    {"input_tokens", "Tokens in", :int},
    {"output_tokens", "Tokens out", :int},
    {"cost_usd", "Spend", :usd},
    {"jobs", "Media jobs", :int}
  ]

  defp overview(o) do
    [
      ~s(<section id="overview" aria-labelledby="h-overview"><h2 id="h-overview">Overview</h2><div class="cards">),
      for {field, label, kind} <- @cards do
        key = String.to_existing_atom(field)

        [
          ~s(<div class="card"><div class="label">),
          label,
          ~s(</div><div class="value" data-total="),
          field,
          ~s(">),
          fmt(kind, Map.get(o.totals, key, 0)),
          ~s(</div><div class="sub">today <span data-today="),
          field,
          ~s(">),
          fmt(kind, Map.get(o.today, key, 0)),
          ~s(</span></div></div>)
        ]
      end,
      ~s(</div></section>)
    ]
  end

  defp keys(o) do
    [
      ~s(<section id="keys" aria-labelledby="h-keys"><h2 id="h-keys">Keys</h2>),
      ~s(<div id="secret" class="secret" hidden><p id="secret-title"></p><div class="row"><code id="secret-value"></code>),
      ~s(<button type="button" id="secret-copy">Copy</button><button type="button" id="secret-close" class="ghost">Done</button></div>),
      ~s(<p class="muted">This is the only time the key is shown. Only its hash is stored.</p></div>),
      ~s(<div class="scroll"><table><thead><tr><th>Key</th><th>State</th><th>Spend</th><th class="num">Requests</th>),
      ~s(<th class="num">Errors</th><th class="num">Tokens in / out</th><th class="num">Jobs</th><th class="num">Per min</th>),
      ~s(<th>Models</th><th>Actions</th></tr></thead><tbody id="keys-body">),
      case o.keys do
        [] -> empty(10, "No keys yet. Create one below, or add one to the config file.")
        list -> Enum.map(list, &key_row/1)
      end,
      ~s(</tbody></table></div>),
      ~s(<form id="create" class="panel" autocomplete="off"><h3>Create a key</h3><div class="fields">),
      ~s(<label>Name<input name="name" required maxlength="64" pattern="[A-Za-z0-9][A-Za-z0-9._\\-]*" placeholder="my-app"></label>),
      ~s(<label>Budget in USD <span class="muted">optional</span><input name="budget_usd" type="number" min="0" step="any" inputmode="decimal"></label>),
      ~s(<label>Budget covers<select name="budget_period"><option value="total">everything, never resets</option>),
      ~s(<option value="monthly">each calendar month, UTC</option><option value="daily">each day, UTC</option></select></label>),
      ~s(<label>Requests per minute <span class="muted">optional</span><input name="rpm" type="number" min="0" step="1" inputmode="numeric"></label>),
      ~s(<label>Models <span class="muted">optional, comma-separated</span><input name="models" placeholder="all models"></label>),
      ~s(</div><div class="row"><button type="submit">Create key</button><span id="create-status" role="status" aria-live="polite"></span></div>),
      ~s(<noscript><p class="muted">Creating and changing keys from this page needs JavaScript. The same actions are available over the admin API at <code>/admin/keys</code>.</p></noscript>),
      ~s(</form></section>)
    ]
  end

  defp key_row(k) do
    managed = k.source == "managed"

    [
      ~s(<tr><td><span class="name">),
      h(k.name),
      ~s(</span> <span class="tag">),
      h(k.source),
      ~s(</span></td><td>),
      pill(k.state, state_class(k.state)),
      ~s(</td><td class="spend">),
      case k.budget_usd do
        nil ->
          [fmt(:usd, k.cost_usd), ~s( <span class="muted">no budget</span>)]

        budget ->
          # Against a monthly or daily budget, what counts is this period's spend.
          spent = if k.budget_period == "total", do: k.cost_usd, else: k.period_spend_usd

          [
            fmt(:usd, spent),
            ~s( <span class="muted">of ),
            fmt(:usd, budget),
            " ",
            period_label(k.budget_period),
            ~s(</span><progress max="100" value="),
            Integer.to_string(percent(spent, budget)),
            ~s(">),
            Integer.to_string(percent(spent, budget)),
            ~s(%</progress>),
            if(k.budget_period == "total", do: "", else: [~s(<span class="muted sub">), fmt(:usd, k.cost_usd), ~s( in total</span>)])
          ]
      end,
      ~s(</td><td class="num">),
      fmt(:int, k.requests),
      ~s(</td><td class="num">),
      fmt(:int, k.errors),
      ~s(</td><td class="num">),
      fmt(:int, k.input_tokens),
      " / ",
      fmt(:int, k.output_tokens),
      cache_note(k.cached_input_tokens, k.cache_write_input_tokens),
      ~s(</td><td class="num">),
      fmt(:int, k.jobs),
      ~s(</td><td class="num">),
      if(k.rpm > 0, do: fmt(:int, k.rpm), else: "—"),
      ~s(</td><td class="models">),
      if(k.models, do: h(Enum.join(k.models, ", ")), else: ~s(<span class="muted">all</span>)),
      ~s(</td><td class="actions">),
      if managed do
        [
          ~s(<button type="button" class="small" data-action="toggle" data-name="),
          h(k.name),
          ~s(">),
          if(k.disabled, do: "Enable", else: "Disable"),
          ~s(</button><button type="button" class="small" data-action="rotate" data-name="),
          h(k.name),
          ~s(">Rotate</button><button type="button" class="small danger" data-action="delete" data-name="),
          h(k.name),
          ~s(">Delete</button>)
        ]
      else
        ~s(<span class="muted">in config file</span>)
      end,
      ~s(</td></tr>)
    ]
  end

  defp requests(o) do
    [
      ~s(<section id="requests" aria-labelledby="h-requests"><h2 id="h-requests">Recent requests</h2><div class="scroll"><table><thead><tr>),
      ~s(<th>Time, UTC</th><th>Key</th><th>Model</th><th>Served by</th><th>Status</th><th class="num">Tokens in / out</th>),
      ~s(<th class="num">Latency</th><th class="num">Cost</th><th>Attempts</th></tr></thead><tbody id="requests-body">),
      case o.requests do
        [] ->
          empty(9, "No requests recorded since the control plane started.")

        list ->
          for r <- list do
            [
              ~s(<tr><td class="mono">),
              h(stamp(r.ts)),
              ~s(</td><td>),
              h(r.key || "—"),
              ~s(</td><td>),
              h(r.model),
              if(r.stream, do: ~s( <span class="tag">stream</span>), else: ""),
              if(r.cached, do: ~s( <span class="tag">cached</span>), else: ""),
              ~s(</td><td>),
              h(r.upstream || "—"),
              ~s(</td><td>),
              pill(to_string(r.status), http_class(r.status)),
              ~s(</td><td class="num">),
              fmt(:int, r.input_tokens),
              " / ",
              fmt(:int, r.output_tokens),
              cache_note(r.cached_input_tokens, r.cache_write_input_tokens),
              ~s(</td><td class="num">),
              if(r.latency_ms, do: [fmt(:int, r.latency_ms), " ms"], else: "—"),
              ~s(</td><td class="num">),
              fmt(:usd, r.cost_usd),
              ~s(</td><td class="mono small-text">),
              h(trail(r.attempts)),
              ~s(</td></tr>)
            ]
          end
      end,
      ~s(</tbody></table></div></section>)
    ]
  end

  defp jobs(o) do
    [
      ~s(<section id="jobs" aria-labelledby="h-jobs"><h2 id="h-jobs">Recent media jobs</h2><div class="scroll"><table><thead><tr>),
      ~s(<th>Created, UTC</th><th>Job</th><th>Key</th><th>Model</th><th>Status</th><th>Served by</th><th class="num">Cost</th>),
      ~s(<th>Outputs</th><th>Webhook</th></tr></thead><tbody id="jobs-body">),
      case o.jobs do
        [] ->
          empty(9, "No media jobs in the job store.")

        list ->
          for j <- list do
            [
              ~s(<tr><td class="mono">),
              h(stamp(j.created_at)),
              ~s(</td><td class="mono small-text">),
              h(j.id),
              ~s(</td><td>),
              h(j.key || "—"),
              ~s(</td><td>),
              h(j.model),
              ~s(</td><td>),
              pill(j.status, job_class(j.status)),
              if(j.cached, do: ~s( <span class="tag">cached</span>), else: ""),
              ~s(</td><td>),
              h(j.upstream || "—"),
              ~s(</td><td class="num">),
              fmt(:usd, j.cost_usd),
              ~s(</td><td>),
              case j.outputs do
                [] ->
                  ~s(<span class="muted">—</span>)

                outputs ->
                  outputs
                  |> Enum.with_index(1)
                  |> Enum.map(fn {out, i} ->
                    url = out["url"]

                    if is_binary(url) and String.starts_with?(url, ["http://", "https://"]) do
                      [~s(<a href="), h(url), ~s(" target="_blank" rel="noopener noreferrer">file ), Integer.to_string(i), ~s(</a>)]
                    else
                      ["file ", Integer.to_string(i)]
                    end
                  end)
                  |> Enum.intersperse(" ")
              end,
              ~s(</td><td>),
              case j.webhook do
                nil -> ~s(<span class="muted">—</span>)
                wh -> [pill(wh.status, webhook_class(wh.status)), ~s( <span class="muted">), Integer.to_string(wh.attempts), ~s( tries</span>)]
              end,
              ~s(</td></tr>)
            ]
          end
      end,
      ~s(</tbody></table></div></section>)
    ]
  end

  defp refused(o) do
    [
      ~s(<section id="refused" aria-labelledby="h-refused"><h2 id="h-refused">Refused requests</h2>),
      ~s(<p class="muted">Requests the gateway turned away before routing them, counted since this control plane started. They are not billed and do not appear above.</p>),
      ~s(<div class="scroll"><table><thead><tr><th>Key</th><th>Reason</th><th class="num">Count</th></tr></thead><tbody id="refused-body">),
      case o.rejected do
        [] ->
          empty(3, "None reported.")

        list ->
          for r <- list,
              do: [~s(<tr><td>), h(key_label(r.key)), ~s(</td><td class="mono">), h(r.reason), ~s(</td><td class="num">), fmt(:int, r.count), ~s(</td></tr>)]
      end,
      ~s(</tbody></table></div></section>)
    ]
  end

  defp activity(o) do
    [
      ~s(<section id="activity" aria-labelledby="h-activity"><h2 id="h-activity">Admin activity</h2>),
      ~s(<p class="muted">The latest sign-ins and key changes. The full record is the audit log file, also served at <code>/admin/audit</code>.</p>),
      ~s(<div class="scroll"><table><thead><tr><th>Time, UTC</th><th>Action</th><th>Target</th><th>Outcome</th><th>Signed in by</th><th>Address</th></tr></thead>),
      ~s(<tbody id="activity-body">),
      case o.audit do
        [] ->
          empty(6, "Nothing recorded yet.")

        list ->
          for a <- list do
            [
              ~s(<tr><td class="mono">),
              h(stamp(a["ts"])),
              ~s(</td><td>),
              h(a["action"]),
              ~s(</td><td>),
              h(a["target"] || "—"),
              ~s(</td><td>),
              pill(a["outcome"], if(a["outcome"] == "ok", do: "ok", else: "warn")),
              ~s(</td><td>),
              h(a["auth"]),
              ~s(</td><td class="mono">),
              h(a["address"] || "—"),
              ~s(</td></tr>)
            ]
          end
      end,
      ~s(</tbody></table></div></section>)
    ]
  end

  defp key_label("-"), do: "(no valid key)"
  defp key_label(name), do: name

  defp period_label("monthly"), do: "this month"
  defp period_label("daily"), do: "today"
  defp period_label(_), do: ""

  # "+ 1,200 cache read" under a token count, when a provider's prompt cache
  # was involved. One line per kind keeps the column narrow.
  defp cache_note(read, write) when read > 0 or write > 0 do
    [
      if(read > 0, do: [~s(<span class="muted sub">+ ), fmt(:int, read), ~s( cache read</span>)], else: ""),
      if(write > 0, do: [~s(<span class="muted sub">+ ), fmt(:int, write), ~s( cache write</span>)], else: "")
    ]
  end

  defp cache_note(_read, _write), do: ""

  defp config(c) do
    [
      ~s(<section id="config" aria-labelledby="h-config"><h2 id="h-config">Configuration</h2>),
      ~s(<p class="muted">Read from the config file, which is reloaded when it changes. Secrets are never shown.</p><div class="grid">),
      ~s(<div class="panel"><h3>Text upstreams</h3>),
      kv_table(["Name", "Protocol", "Host"], Enum.map(c.upstreams, &[&1.name, &1.kind, &1.host])),
      ~s(</div>),
      ~s(<div class="panel"><h3>Text routes</h3>),
      kv_table(
        ["Model", "Strategy", "Cache", "Targets"],
        Enum.map(c.routes, &[&1.model, &1.strategy, if(&1.cache_ttl_s > 0, do: "#{&1.cache_ttl_s} s", else: "off"), targets(&1.targets, &1.strategy)])
      ),
      ~s(</div><div class="panel"><h3>Media upstreams</h3>),
      kv_table(["Name", "Kind", "Host"], Enum.map(c.media.upstreams, &[&1.name, &1.kind, &1.host])),
      ~s(</div><div class="panel"><h3>Media routes</h3>),
      kv_table(
        ["Model", "Cache", "Targets"],
        Enum.map(c.media.routes, &[&1.model, if(&1.cache_ttl_s, do: "#{&1.cache_ttl_s} s", else: "off"), targets(&1.targets, "failover")])
      ),
      ~s(</div><div class="panel"><h3>Storage and retention</h3>),
      kv_table(["Setting", "Value"], [
        ["Output storage", storage(c.media.storage)],
        ["Public base URL", c.media.public_base_url],
        ["Finished jobs kept", days(c.retention.jobs_days)],
        ["Ledger ids kept", days(c.retention.ledger_ids_days)],
        ["Expired jobs' bucket objects", if(c.retention.delete_bucket_objects, do: "deleted with the job", else: "left in the bucket")]
      ]),
      ~s(</div></div></section>)
    ]
  end

  defp targets(list, strategy) do
    Enum.map_join(list, "  →  ", fn t ->
      weight = if strategy == "weighted", do: " ×#{t[:weight] || 1}", else: ""
      "#{t.upstream}/#{t.model}#{weight}"
    end)
  end

  defp storage(%{kind: "s3"} = s), do: "bucket #{s.bucket} on #{s.host}" <> if(s.prefix != "", do: " under #{s.prefix}", else: "")
  defp storage(_), do: "local disk"

  defp days(n) when n in [0, 0.0], do: "forever"
  defp days(n), do: "#{n} days"

  defp kv_table(_heads, []), do: ~s(<p class="muted">None configured.</p>)

  defp kv_table(heads, rows) do
    [
      ~s(<div class="scroll"><table><thead><tr>),
      Enum.map(heads, &[~s(<th>), &1, ~s(</th>)]),
      ~s(</tr></thead><tbody>),
      Enum.map(rows, fn row -> [~s(<tr>), Enum.map(row, &[~s(<td>), h(&1), ~s(</td>)]), ~s(</tr>)] end),
      ~s(</tbody></table></div>)
    ]
  end

  # -- small pieces ---------------------------------------------------------------

  defp empty(cols, text), do: [~s(<tr><td class="muted empty" colspan="), Integer.to_string(cols), ~s(">), text, ~s(</td></tr>)]

  defp pill(text, class), do: [~s(<span class="pill ), class, ~s(">), h(text), ~s(</span>)]

  defp state_class("active"), do: "ok"
  defp state_class("blocked"), do: "bad"
  defp state_class(_), do: "off"

  defp http_class(s) when is_integer(s) and s < 400, do: "ok"
  defp http_class(s) when is_integer(s) and s < 500, do: "warn"
  defp http_class(_), do: "bad"

  defp job_class("succeeded"), do: "ok"
  defp job_class("failed"), do: "bad"
  defp job_class("canceled"), do: "off"
  defp job_class(_), do: "info"

  defp webhook_class("delivered"), do: "ok"
  defp webhook_class("failed"), do: "bad"
  defp webhook_class("retrying"), do: "warn"
  defp webhook_class(_), do: "info"

  defp trail(attempts), do: Enum.map_join(attempts, " → ", &"#{&1.upstream}: #{&1.outcome}")

  defp percent(_spent, budget) when budget <= 0, do: 100
  defp percent(spent, budget), do: min(100, round(spent / budget * 100))

  # "2026-11-10T17:59:00.123Z" -> "2026-11-10 17:59:00"
  defp stamp(<<date::binary-size(10), _t, time::binary-size(8), _rest::binary>>), do: date <> " " <> time
  defp stamp(other), do: other || "—"

  defp clock(<<_date::binary-size(10), _t, time::binary-size(8), _rest::binary>>), do: time
  defp clock(other), do: other

  @doc false
  def fmt(:int, n) when is_integer(n) do
    n |> Integer.to_string() |> String.reverse() |> String.replace(~r/(\d{3})(?=\d)/, "\\1,") |> String.reverse()
  end

  def fmt(:int, n) when is_float(n), do: fmt(:int, round(n))
  def fmt(:usd, n), do: "$" <> :erlang.float_to_binary(n * 1.0, decimals: 4)

  defp h(nil), do: ""
  defp h(s), do: s |> to_string() |> Plug.HTML.html_escape()

  # -- assets ---------------------------------------------------------------------

  defp css do
    ~S"""
    :root{--bg:#f6f7f9;--panel:#fff;--text:#1c2024;--muted:#667085;--line:#e3e6ea;--accent:#2f5bea;--accent-text:#fff;
    --ok:#12703a;--ok-bg:#e3f6ea;--warn:#8a5a00;--warn-bg:#fdf1d3;--bad:#a8231c;--bad-bg:#fde7e5;--info:#1d4f91;--info-bg:#e4eefb;--off:#555d68;--off-bg:#eceef1}
    @media (prefers-color-scheme:dark){:root{--bg:#111418;--panel:#1a1e24;--text:#e8eaed;--muted:#98a1ae;--line:#2b313a;--accent:#7c9cff;--accent-text:#0b1020;
    --ok:#7fdc9f;--ok-bg:#143321;--warn:#f2c661;--warn-bg:#3a2e10;--bad:#ff9a92;--bad-bg:#41191a;--info:#9cc3ff;--info-bg:#152a45;--off:#b3bac4;--off-bg:#272c34}}
    *{box-sizing:border-box}html{scroll-padding-top:64px}
    body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;font-variant-numeric:tabular-nums}
    .top{position:sticky;top:0;z-index:2;display:flex;flex-wrap:wrap;align-items:center;gap:8px 20px;padding:10px 24px;background:var(--panel);border-bottom:1px solid var(--line)}
    .brand{font-weight:650;font-size:16px}.brand span{font-weight:400;color:var(--muted);margin-left:4px}
    nav{display:flex;flex-wrap:wrap;gap:4px 14px}nav a{color:var(--text);text-decoration:none;padding:4px 0;border-bottom:2px solid transparent}
    nav a:hover,nav a:focus-visible{border-bottom-color:var(--accent)}
    .right{margin-left:auto;display:flex;align-items:center;gap:12px}.right form{margin:0}
    main{max-width:1240px;margin:0 auto;padding:8px 24px 48px}
    section{margin-top:28px}h2{font-size:18px;margin:0 0 12px}h3{font-size:14px;margin:0 0 10px}
    .muted{color:var(--muted)}.mono{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:12.5px}.small-text{font-size:12px}
    .cards{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:12px}
    .card,.panel,.secret{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px 16px}
    .card .label{color:var(--muted);font-size:12.5px}.card .value{font-size:24px;font-weight:600;margin:2px 0;min-height:34px}.card .sub{color:var(--muted);font-size:12.5px}
    .scroll{overflow-x:auto;background:var(--panel);border:1px solid var(--line);border-radius:8px}
    .panel .scroll{border:0;border-radius:0}
    table{border-collapse:collapse;width:100%;min-width:max-content}
    th,td{padding:8px 10px;text-align:left;border-bottom:1px solid var(--line);vertical-align:middle;white-space:nowrap}
    th{font-size:12px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.03em}
    tbody tr:last-child td{border-bottom:0}.num{text-align:right}.empty{text-align:center;padding:22px;white-space:normal}
    .name{font-weight:600}.tag{font-size:11px;color:var(--muted);border:1px solid var(--line);border-radius:4px;padding:0 5px}
    .pill{display:inline-block;font-size:12px;font-weight:600;border-radius:999px;padding:1px 9px}
    .pill.ok{color:var(--ok);background:var(--ok-bg)}.pill.warn{color:var(--warn);background:var(--warn-bg)}.pill.bad{color:var(--bad);background:var(--bad-bg)}
    .pill.info{color:var(--info);background:var(--info-bg)}.pill.off{color:var(--off);background:var(--off-bg)}
    .spend progress{display:block;width:100px;height:6px;margin-top:5px;accent-color:var(--accent)}
    .sub{display:block;font-size:12px}
    select{display:block;width:100%;margin-top:5px;font:inherit;color:var(--text);background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:7px 9px}
    a{color:var(--accent)}
    button{font:inherit;cursor:pointer;border:1px solid var(--accent);background:var(--accent);color:var(--accent-text);border-radius:6px;padding:7px 14px}
    button.ghost,button.small{background:transparent;color:var(--text);border-color:var(--line)}
    button.small{padding:3px 8px;font-size:12.5px;margin-right:4px}button.danger{color:var(--bad)}
    button.armed{background:var(--bad-bg);color:var(--bad);border-color:var(--bad)}
    button:focus-visible,input:focus-visible,select:focus-visible,a:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
    button:disabled{opacity:.55;cursor:default}
    .actions button:last-child{margin-right:0}.models{white-space:normal;max-width:220px}
    .panel table{min-width:0}.panel td{white-space:normal;overflow-wrap:anywhere}
    form.panel{margin-top:14px}.fields{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px;margin-bottom:12px}
    label{display:block;font-size:12.5px;font-weight:600}label .muted{font-weight:400}
    input{display:block;width:100%;margin-top:5px;font:inherit;color:var(--text);background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:7px 9px}
    .row{display:flex;flex-wrap:wrap;align-items:center;gap:10px}
    .secret{margin-bottom:14px;border-color:var(--accent)}.secret p{margin:0 0 8px}.secret code{flex:1 1 280px;overflow-wrap:anywhere;background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:7px 9px;font-size:13px}
    #create-status.err{color:var(--bad)}
    .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:12px}
    @media (max-width:1000px){.cards{grid-template-columns:repeat(3,minmax(0,1fr))}}
    @media (max-width:600px){html{scroll-padding-top:8px}.top{position:static;padding:10px 16px}main{padding:4px 16px 40px}.right{margin-left:0;width:100%;justify-content:space-between}
    .cards{grid-template-columns:repeat(2,minmax(0,1fr))}.grid{grid-template-columns:1fr}.card .value{font-size:20px;min-height:28px}}
    """
  end

  defp js do
    ~S"""
    (function(){
    "use strict";
    var csrf=document.querySelector('meta[name=csrf]').content,armed=null,armTimer=null,busy=false;
    function $(id){return document.getElementById(id)}
    function el(tag,cls,text){var e=document.createElement(tag);if(cls)e.className=cls;if(text!=null)e.textContent=text;return e}
    function int(n){return Math.round(n||0).toLocaleString('en-US')}
    function usd(n){return '$'+(n||0).toFixed(4)}
    function stamp(s){return s&&s.length>=19?s.slice(0,10)+' '+s.slice(11,19):(s||'—')}
    function pill(text,cls){return el('span','pill '+cls,String(text))}
    function td(cls,child){var c=el('td',cls||'');if(child!=null){if(typeof child==='string')c.textContent=child;else c.appendChild(child)}return c}
    function muted(t){return el('span','muted',t)}
    function httpClass(s){return s<400?'ok':s<500?'warn':'bad'}
    function stateClass(s){return s==='active'?'ok':s==='blocked'?'bad':'off'}
    function jobClass(s){return s==='succeeded'?'ok':s==='failed'?'bad':s==='canceled'?'off':'info'}
    function hookClass(s){return s==='delivered'?'ok':s==='failed'?'bad':s==='retrying'?'warn':'info'}
    function trail(a){return (a||[]).map(function(x){return x.upstream+': '+x.outcome}).join(' → ')}
    function periodLabel(p){return p==='monthly'?' this month':p==='daily'?' today':''}
    function cacheNote(cell,read,write){if(read>0)cell.appendChild(el('span','muted sub','+ '+int(read)+' cache read'));
      if(write>0)cell.appendChild(el('span','muted sub','+ '+int(write)+' cache write'))}
    function emptyRow(cols,text){var r=el('tr'),c=el('td','muted empty',text);c.colSpan=cols;r.appendChild(c);return r}
    function fill(body,rows){body.replaceChildren.apply(body,rows)}

    function actionButton(k,action,label,danger){
      var id=k.name+'|'+action,on=armed===id,b=el('button','small'+(danger?' danger':'')+(on?' armed':''),on?'Confirm '+label.toLowerCase()+'?':label);
      b.type='button';b.dataset.action=action;b.dataset.name=k.name;b.dataset.disabled=k.disabled?'1':'';return b}

    function keyRow(k){
      var r=el('tr'),n=td('');n.appendChild(el('span','name',k.name));n.appendChild(document.createTextNode(' '));n.appendChild(el('span','tag',k.source));r.appendChild(n);
      r.appendChild(td('',pill(k.state,stateClass(k.state))));
      var s=td('spend');
      if(k.budget_usd==null){s.appendChild(document.createTextNode(usd(k.cost_usd)+' '));s.appendChild(muted('no budget'))}
      else{var total=k.budget_period==='total'||!k.budget_period,spent=total?k.cost_usd:k.period_spend_usd;
        s.appendChild(document.createTextNode(usd(spent)+' '));s.appendChild(muted('of '+usd(k.budget_usd)+periodLabel(k.budget_period)));
        var p=el('progress');p.max=100;var pc=k.budget_usd<=0?100:Math.min(100,Math.round(spent/k.budget_usd*100));p.value=pc;p.textContent=pc+'%';s.appendChild(p);
        if(!total)s.appendChild(el('span','muted sub',usd(k.cost_usd)+' in total'))}
      r.appendChild(s);
      r.appendChild(td('num',int(k.requests)));r.appendChild(td('num',int(k.errors)));
      var tk=td('num',int(k.input_tokens)+' / '+int(k.output_tokens));cacheNote(tk,k.cached_input_tokens,k.cache_write_input_tokens);r.appendChild(tk);r.appendChild(td('num',int(k.jobs)));
      r.appendChild(td('num',k.rpm>0?int(k.rpm):'—'));
      r.appendChild(k.models?td('models',k.models.join(', ')):td('models',muted('all')));
      var a=td('actions');
      if(k.source==='managed'){
        a.appendChild(actionButton(k,'toggle',k.disabled?'Enable':'Disable',false));
        a.appendChild(actionButton(k,'rotate','Rotate',false));
        a.appendChild(actionButton(k,'delete','Delete',true));
        if(armed&&armed.split('|')[0]===k.name){var c=el('button','small ghost','Cancel');c.type='button';c.dataset.action='cancel';a.appendChild(c)}
      }else{a.appendChild(muted('in config file'))}
      r.appendChild(a);return r}

    function requestRow(q){
      var r=el('tr');r.appendChild(td('mono',stamp(q.ts)));r.appendChild(td('',q.key||'—'));
      var m=td('',q.model||'—');if(q.stream){m.appendChild(document.createTextNode(' '));m.appendChild(el('span','tag','stream'))}
      if(q.cached){m.appendChild(document.createTextNode(' '));m.appendChild(el('span','tag','cached'))}r.appendChild(m);
      r.appendChild(td('',q.upstream||'—'));r.appendChild(td('',pill(q.status,httpClass(q.status))));
      var qt=td('num',int(q.input_tokens)+' / '+int(q.output_tokens));cacheNote(qt,q.cached_input_tokens,q.cache_write_input_tokens);r.appendChild(qt);
      r.appendChild(td('num',q.latency_ms==null?'—':int(q.latency_ms)+' ms'));r.appendChild(td('num',usd(q.cost_usd)));
      r.appendChild(td('mono small-text',trail(q.attempts)));return r}

    function jobRow(j){
      var r=el('tr');r.appendChild(td('mono',stamp(j.created_at)));r.appendChild(td('mono small-text',j.id));r.appendChild(td('',j.key||'—'));
      r.appendChild(td('',j.model||'—'));
      var s=td('',pill(j.status,jobClass(j.status)));if(j.cached){s.appendChild(document.createTextNode(' '));s.appendChild(el('span','tag','cached'))}r.appendChild(s);
      r.appendChild(td('',j.upstream||'—'));r.appendChild(td('num',usd(j.cost_usd)));
      var o=td('');
      if(!j.outputs||!j.outputs.length){o.appendChild(muted('—'))}
      else j.outputs.forEach(function(x,i){
        if(i)o.appendChild(document.createTextNode(' '));
        if(typeof x.url==='string'&&/^https?:\/\//.test(x.url)){var a=el('a','', 'file '+(i+1));a.href=x.url;a.target='_blank';a.rel='noopener noreferrer';o.appendChild(a)}
        else o.appendChild(document.createTextNode('file '+(i+1)))});
      r.appendChild(o);
      var w=td('');if(!j.webhook){w.appendChild(muted('—'))}else{w.appendChild(pill(j.webhook.status,hookClass(j.webhook.status)));w.appendChild(document.createTextNode(' '));w.appendChild(muted(j.webhook.attempts+' tries'))}
      r.appendChild(w);return r}

    function refusedRow(x){var r=el('tr');r.appendChild(td('',x.key==='-'?'(no valid key)':x.key));r.appendChild(td('mono',x.reason));r.appendChild(td('num',int(x.count)));return r}
    function activityRow(a){var r=el('tr');r.appendChild(td('mono',stamp(a.ts)));r.appendChild(td('',a.action));r.appendChild(td('',a.target||'—'));
      r.appendChild(td('',pill(a.outcome,a.outcome==='ok'?'ok':'warn')));r.appendChild(td('',a.auth||''));r.appendChild(td('mono',a.address||'—'));return r}

    var last=null;
    function render(d){
      last=d;
      document.querySelectorAll('[data-total]').forEach(function(e){var f=e.dataset.total;e.textContent=f==='cost_usd'?usd(d.totals[f]):int(d.totals[f])});
      document.querySelectorAll('[data-today]').forEach(function(e){var f=e.dataset.today;e.textContent=f==='cost_usd'?usd(d.today[f]):int(d.today[f])});
      fill($('keys-body'),d.keys.length?d.keys.map(keyRow):[emptyRow(10,'No keys yet. Create one below, or add one to the config file.')]);
      fill($('requests-body'),d.requests.length?d.requests.map(requestRow):[emptyRow(9,'No requests recorded since the control plane started.')]);
      fill($('jobs-body'),d.jobs.length?d.jobs.map(jobRow):[emptyRow(9,'No media jobs in the job store.')]);
      var rj=d.rejected||[],au=d.audit||[];
      fill($('refused-body'),rj.length?rj.map(refusedRow):[emptyRow(3,'None reported.')]);
      fill($('activity-body'),au.length?au.map(activityRow):[emptyRow(6,'Nothing recorded yet.')]);
      $('updated').textContent='Updated '+d.generated_at.slice(11,19)+' UTC'}

    function refresh(){
      if(busy||document.hidden)return Promise.resolve();
      return fetch('/admin/overview',{credentials:'same-origin',headers:{accept:'application/json'}}).then(function(r){
        if(r.status===401){location.href='/login';return null}
        if(!r.ok)throw new Error('HTTP '+r.status);return r.json()}).then(function(d){if(d)render(d)})
        .catch(function(){$('updated').textContent='Update failed; retrying'})}

    function api(method,path,body){
      busy=true;
      return fetch(path,{method:method,credentials:'same-origin',headers:{'content-type':'application/json','x-csrf-token':csrf,accept:'application/json'},body:body==null?null:JSON.stringify(body)})
        .then(function(r){return r.text().then(function(t){var j=null;try{j=t?JSON.parse(t):null}catch(e){}
          if(!r.ok)throw new Error(j&&j.error&&j.error.message?j.error.message:'Request failed (HTTP '+r.status+')');return j})})
        .finally(function(){busy=false})}

    function showSecret(name,key,verb){
      $('secret-title').textContent=verb+' key for “'+name+'”. Copy it now.';$('secret-value').textContent=key;$('secret-copy').textContent='Copy';
      $('secret').hidden=false;$('secret-copy').focus()}
    $('secret-close').addEventListener('click',function(){$('secret-value').textContent='';$('secret').hidden=true});
    $('secret-copy').addEventListener('click',function(){
      var text=$('secret-value').textContent,done=function(){$('secret-copy').textContent='Copied'};
      if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(text).then(done,select)}else select();
      function select(){var r=document.createRange();r.selectNodeContents($('secret-value'));var s=getSelection();s.removeAllRanges();s.addRange(r);
        try{if(document.execCommand('copy'))done();else $('secret-copy').textContent='Selected: press Ctrl+C'}catch(e){$('secret-copy').textContent='Selected: press Ctrl+C'}}});

    function disarm(){armed=null;clearTimeout(armTimer);if(last)render(last)}
    function status(text,isError){var s=$('create-status');s.textContent=text;s.className=isError?'err':''}

    $('keys-body').addEventListener('click',function(ev){
      var b=ev.target.closest('button[data-action]');if(!b)return;
      var action=b.dataset.action,name=b.dataset.name;
      if(action==='cancel'){disarm();return}
      var enable=action==='toggle'&&b.dataset.disabled==='1',id=name+'|'+action;
      if(!enable&&armed!==id){armed=id;clearTimeout(armTimer);armTimer=setTimeout(disarm,6000);if(last)render(last);
        var again=document.querySelector('button.armed');if(again)again.focus();return}
      armed=null;clearTimeout(armTimer);
      var path='/admin/keys/'+encodeURIComponent(name),call=
        action==='toggle'?api('PATCH',path,{disabled:!enable}):
        action==='rotate'?api('POST',path+'/rotate'):api('DELETE',path);
      call.then(function(res){if(action==='rotate'&&res&&res.key)showSecret(name,res.key,'New');status('',false);return refresh()})
        .catch(function(e){status(e.message,true);if(last)render(last)})});

    $('create').addEventListener('submit',function(ev){
      ev.preventDefault();var f=ev.target,body={name:f.elements.name.value.trim()};
      if(f.elements.budget_usd.value!==''){body.budget_usd=Number(f.elements.budget_usd.value);body.budget_period=f.elements.budget_period.value}
      if(f.elements.rpm.value!=='')body.rpm=Number(f.elements.rpm.value);
      var models=f.elements.models.value.split(',').map(function(s){return s.trim()}).filter(Boolean);if(models.length)body.models=models;
      var submit=f.querySelector('button[type=submit]');submit.disabled=true;status('Creating…',false);
      api('POST','/admin/keys',body).then(function(res){f.reset();status('Created.',false);showSecret(res.name,res.key,'New');return refresh()})
        .catch(function(e){status(e.message,true)}).finally(function(){submit.disabled=false})});

    setInterval(refresh,4000);document.addEventListener('visibilitychange',function(){if(!document.hidden)refresh()});refresh();
    })();
    """
  end
end
