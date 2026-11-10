defmodule OmnigateControl.Router do
  @moduledoc """
  HTTP API.

    * `GET  /internal/config` — snapshot for data planes (internal token)
    * `POST /internal/usage/batch` — usage events from data planes (internal token)
    * `GET  /admin/usage`     — per-key totals as JSON
    * `GET  /`                — minimal dashboard (LiveView comes later)

  Binds to 127.0.0.1 only. Put it behind auth before exposing it.
  """
  use Plug.Router

  alias OmnigateControl.{ConfigStore, Ledger}

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: JSON, pass: ["*/*"]
  plug :internal_auth
  plug :dispatch

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

  get "/admin/usage" do
    send_json(conn, 200, %{keys: key_rows()})
  end

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, dashboard())
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
          %{key_sha256: k.key_sha256, name: k.name, blocked: blocked?(k)}
        end),
      upstreams: config.upstreams,
      routes:
        Enum.map(config.routes, fn r ->
          %{model: r.model, targets: Enum.map(r.targets, &Map.take(&1, [:upstream, :model]))}
        end)
    }

    # Version changes whenever anything the data plane sees changes,
    # including a key flipping to blocked.
    Map.put(body, :version, body |> JSON.encode!() |> OmnigateControl.sha256_hex() |> binary_part(0, 16))
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
          "<td>#{r.output_tokens}</td><td>$#{:erlang.float_to_binary(r.cost_usd, decimals: 6)}</td>" <>
          "<td>$#{budget}</td><td>#{if r.blocked, do: "blocked", else: "active"}</td></tr>"
      end)

    events =
      Enum.map_join(Ledger.recent(), "\n", fn e ->
        attempts = Enum.map_join(e["attempts"] || [], " → ", &"#{&1["upstream"]}:#{&1["outcome"]}")

        "<tr><td>#{h(e["ts"])}</td><td>#{h(e["route_model"])}</td><td>#{h(e["upstream"] || "-")}</td>" <>
          "<td>#{e["status"]}</td><td>#{e["input_tokens"]}/#{e["output_tokens"]}</td>" <>
          "<td>#{e["latency_ms"]} ms</td><td>#{h(attempts)}</td></tr>"
      end)

    """
    <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="2">
    <title>omnigate</title>
    <style>body{font:14px system-ui;margin:24px;color:#222}table{border-collapse:collapse;margin-bottom:24px}
    td,th{border:1px solid #ddd;padding:4px 8px;text-align:left}th{background:#f5f5f5}</style></head>
    <body><h1>omnigate control plane</h1>
    <h2>Keys</h2><table><tr><th>Key</th><th>Requests</th><th>Errors</th><th>In tok</th><th>Out tok</th>
    <th>Spend</th><th>Budget</th><th>State</th></tr>#{rows}</table>
    <h2>Recent requests</h2><table><tr><th>Time</th><th>Model</th><th>Served by</th><th>Status</th>
    <th>Tokens in/out</th><th>Latency</th><th>Attempts</th></tr>#{events}</table></body></html>
    """
  end

  defp h(nil), do: ""
  defp h(s), do: s |> to_string() |> Plug.HTML.html_escape()
end
