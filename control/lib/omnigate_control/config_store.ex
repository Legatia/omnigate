defmodule OmnigateControl.ConfigStore do
  @moduledoc """
  Loads the gateway config file and hot-reloads it when it changes on disk.

  The file may list raw gateway keys (`"key"`) for local development or
  pre-hashed ones (`"key_sha256"`). Raw keys are hashed on load and never
  leave this process.
  """
  use GenServer
  require Logger

  @reload_ms 2_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The normalized config map."
  def get, do: :persistent_term.get({__MODULE__, :config})

  @doc "Price for a (route model, upstream, target model) triple, in USD per 1M tokens."
  def price(route_model, upstream, target_model) do
    get().routes
    |> Enum.find(&(&1.model == route_model))
    |> case do
      nil ->
        {0.0, 0.0}

      route ->
        case Enum.find(route.targets, &(&1.upstream == upstream and &1.model == target_model)) do
          nil -> {0.0, 0.0}
          t -> {t.price_in_per_mtok, t.price_out_per_mtok}
        end
    end
  end

  # -- server --------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    {:ok, config, mtime} = load!(path)
    :persistent_term.put({__MODULE__, :config}, config)
    Logger.info("loaded config #{path}: #{length(config.routes)} routes, #{length(config.keys)} keys")
    schedule()
    {:ok, %{path: path, mtime: mtime}}
  end

  @impl true
  def handle_info(:reload, state) do
    state =
      case File.stat(state.path, time: :posix) do
        {:ok, %{mtime: mtime}} when mtime != state.mtime ->
          case safe_load(state.path) do
            {:ok, config, mtime} ->
              :persistent_term.put({__MODULE__, :config}, config)
              Logger.info("reloaded config #{state.path}")
              %{state | mtime: mtime}

            {:error, reason} ->
              Logger.error("config reload failed, keeping previous: #{inspect(reason)}")
              %{state | mtime: mtime}
          end

        _ ->
          state
      end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :reload, @reload_ms)

  defp safe_load(path) do
    load!(path)
  rescue
    e -> {:error, e}
  end

  defp load!(path) do
    %{mtime: mtime} = File.stat!(path, time: :posix)
    raw = path |> File.read!() |> JSON.decode!()
    {:ok, normalize(raw), mtime}
  end

  @doc false
  def normalize(raw) do
    %{
      keys:
        Enum.map(raw["keys"] || [], fn k ->
          %{
            name: Map.fetch!(k, "name"),
            key_sha256: k["key_sha256"] || OmnigateControl.sha256_hex(Map.fetch!(k, "key")),
            budget_usd: to_float(k["budget_usd"]),
            # Requests per minute enforced by the data plane; 0 = unlimited.
            rpm: to_int(k["rpm"], 0),
            webhook_secret: secret(k, "webhook_secret")
          }
        end),
      upstreams:
        Enum.map(raw["upstreams"] || [], fn u ->
          %{
            name: Map.fetch!(u, "name"),
            kind: Map.fetch!(u, "kind"),
            base_url: Map.fetch!(u, "base_url"),
            api_key_env: Map.fetch!(u, "api_key_env"),
            # Max wait for response headers; 0 = the data plane's default.
            timeout_ms: to_int(u["timeout_ms"], 0)
          }
        end),
      routes:
        Enum.map(raw["routes"] || [], fn r ->
          %{
            model: Map.fetch!(r, "model"),
            targets:
              Enum.map(Map.fetch!(r, "targets"), fn t ->
                %{
                  upstream: Map.fetch!(t, "upstream"),
                  model: Map.fetch!(t, "model"),
                  price_in_per_mtok: to_float(t["price_in_per_mtok"] || 0),
                  price_out_per_mtok: to_float(t["price_out_per_mtok"] || 0)
                }
              end)
          }
        end),
      media: normalize_media(raw["media"] || %{})
    }
  end

  @default_retry_schedule_ms [5_000, 30_000, 120_000, 600_000, 1_800_000, 7_200_000, 21_600_000]

  # Media (async job) config. Never sent to data planes.
  defp normalize_media(m) do
    webhooks = m["webhooks"] || %{}
    schedule = webhooks["retry_schedule_ms"] || @default_retry_schedule_ms

    %{
      public_base_url: String.trim_trailing(m["public_base_url"] || "http://127.0.0.1:8080", "/"),
      poll_interval_ms: to_int(m["poll_interval_ms"], 2_000),
      max_output_bytes: to_int(m["max_output_bytes"], 512 * 1024 * 1024),
      upstreams:
        Enum.map(m["upstreams"] || [], fn u ->
          %{
            name: Map.fetch!(u, "name"),
            kind: Map.fetch!(u, "kind"),
            base_url: u |> Map.fetch!("base_url") |> String.trim_trailing("/"),
            api_key_env: Map.fetch!(u, "api_key_env")
          }
        end),
      routes:
        Enum.map(m["routes"] || [], fn r ->
          %{
            model: Map.fetch!(r, "model"),
            cache_ttl_s: r["cache_ttl_s"],
            timeout_s: to_int(r["timeout_s"], 600),
            targets:
              Enum.map(Map.fetch!(r, "targets"), fn t ->
                price = t["price"] || %{}

                %{
                  upstream: Map.fetch!(t, "upstream"),
                  model: Map.fetch!(t, "model"),
                  price: %{
                    per_job_usd: to_float(price["per_job_usd"] || 0),
                    per_output_usd: to_float(price["per_output_usd"] || 0),
                    per_input_char_usd: to_float(price["per_input_char_usd"] || 0),
                    per_second_usd: to_float(price["per_second_usd"] || 0)
                  }
                }
              end)
          }
        end),
      storage: normalize_storage(m["storage"] || %{}),
      webhooks: %{
        retry_schedule_ms: schedule,
        max_attempts: to_int(webhooks["max_attempts"], length(schedule) + 1),
        timeout_ms: to_int(webhooks["timeout_ms"], 10_000),
        # Refuse webhook URLs that resolve to loopback/private addresses
        # unless explicitly allowed (local development).
        allow_private: webhooks["allow_private"] == true,
        secret: secret(webhooks, "secret")
      }
    }
  end

  defp normalize_storage(%{"kind" => "s3"} = s) do
    endpoint = s |> Map.fetch!("endpoint") |> String.trim_trailing("/")
    bucket = Map.fetch!(s, "bucket")

    %{
      kind: "s3",
      endpoint: endpoint,
      bucket: bucket,
      region: s["region"] || "us-east-1",
      prefix: normalize_prefix(s["prefix"]),
      access_key_env: Map.fetch!(s, "access_key_env"),
      secret_key_env: Map.fetch!(s, "secret_key_env"),
      # Where clients fetch objects. Defaults to the path-style bucket URL.
      public_base_url: String.trim_trailing(s["public_base_url"] || "#{endpoint}/#{bucket}", "/"),
      # Buckets are private unless the operator names a public base URL, so
      # returned URLs are SigV4-presigned GETs (valid this long) by default.
      presign_ttl_s:
        case s["presign_ttl_s"] do
          n when is_integer(n) and n > 0 -> n
          _ -> if s["public_base_url"], do: nil, else: 3_600
        end
    }
  end

  # "outputs" and "/outputs/" both mean the key prefix "outputs/".
  defp normalize_prefix(nil), do: ""

  defp normalize_prefix(prefix) do
    case String.trim(prefix, "/") do
      "" -> ""
      trimmed -> trimmed <> "/"
    end
  end

  defp normalize_storage(s) do
    %{
      kind: "local",
      dir: s["dir"] || Application.get_env(:omnigate_control, :media_dir) || Path.expand("data/media", File.cwd!()),
      url_ttl_s: to_int(s["url_ttl_s"], 3_600)
    }
  end

  # A secret given inline (`name`) or as the name of an env var (`name_env`).
  defp secret(map, name) do
    case map[name] do
      nil -> map[name <> "_env"] && System.get_env(map[name <> "_env"])
      v -> v
    end
  end

  @doc "The media route for a public model name, or nil."
  def media_route(model), do: Enum.find(get().media.routes, &(&1.model == model))

  @doc "A media upstream by name, or nil."
  def media_upstream(name), do: Enum.find(get().media.upstreams, &(&1.name == name))

  @doc false
  # Test hook: swap the media section without touching the file.
  def put_media(media) do
    :persistent_term.put({__MODULE__, :config}, %{get() | media: media})
  end

  defp to_int(nil, default), do: default
  defp to_int(n, _default) when is_integer(n), do: n
  defp to_int(n, _default) when is_float(n), do: trunc(n)

  defp to_float(nil), do: nil
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(n) when is_float(n), do: n
end
