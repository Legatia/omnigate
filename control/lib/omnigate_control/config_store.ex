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

  @doc """
  The normalized config map. Its `keys` are the keys written in the config
  file followed by the ones created through the admin API (`Keys`), so
  everything downstream sees one list.
  """
  def get do
    config = :persistent_term.get({__MODULE__, :config})
    file = only_file(config.keys)
    names = MapSet.new(file, & &1.name)
    # A name can belong to one key only. The file wins; a managed key of the
    # same name is shadowed (see `shadowed_keys/0`) until one of them is renamed
    # or removed.
    %{config | keys: file ++ Enum.reject(OmnigateControl.Keys.managed(), &MapSet.member?(names, &1.name))}
  end

  @doc "Managed keys that are out of use because the config file defines a key with the same name."
  def shadowed_keys do
    names = MapSet.new(file_keys(), & &1.name)
    Enum.filter(OmnigateControl.Keys.managed(), &MapSet.member?(names, &1.name))
  end

  @doc "Log a warning for each managed key that has just become shadowed. Cheap; called when either source changes."
  def warn_shadowed do
    now = shadowed_keys() |> Enum.map(& &1.name) |> Enum.sort()
    before = :persistent_term.get({__MODULE__, :shadow_warned}, [])

    for name <- now -- before do
      Logger.warning(
        "key #{inspect(name)} is defined in the config file and also exists as a managed key: the file's key is in use, " <>
          "the managed one is shadowed and its secret no longer works. Rename one of them or delete the managed key."
      )
    end

    if now != before, do: :persistent_term.put({__MODULE__, :shadow_warned}, now)
    :ok
  end

  @doc "Only the keys written in the config file."
  def file_keys, do: only_file(:persistent_term.get({__MODULE__, :config}).keys)

  # A config that went through `get/0` and was put back (tests do this)
  # carries managed keys; they must not be counted twice.
  defp only_file(keys), do: Enum.reject(keys, &(Map.get(&1, :source) == :managed))

  @doc "When the config was last (re)loaded, and how many reloads succeeded since boot."
  def meta, do: :persistent_term.get({__MODULE__, :meta}, %{reloads: 0, loaded_at_ms: 0})

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

  @doc """
  All four prices for a (route model, upstream, target model) triple, in USD
  per 1M tokens: `%{in, cached_in, cache_write, out}`. Cached input and cache
  writes cost the input price unless the target says otherwise.
  """
  def prices(route_model, upstream, target_model) do
    target =
      case Enum.find(get().routes, &(&1.model == route_model)) do
        nil -> nil
        route -> Enum.find(route.targets, &(&1.upstream == upstream and &1.model == target_model))
      end

    case target do
      nil ->
        %{in: 0.0, cached_in: 0.0, cache_write: 0.0, out: 0.0}

      t ->
        %{
          in: t.price_in_per_mtok,
          cached_in: Map.get(t, :price_cached_in_per_mtok, t.price_in_per_mtok),
          cache_write: Map.get(t, :price_cache_write_per_mtok, t.price_in_per_mtok),
          out: t.price_out_per_mtok
        }
    end
  end

  # -- server --------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    {:ok, config, mtime} = load!(path)
    :persistent_term.put({__MODULE__, :config}, config)
    :persistent_term.put({__MODULE__, :meta}, %{reloads: 0, loaded_at_ms: System.os_time(:millisecond)})
    Logger.info("loaded config #{path}: #{length(config.routes)} routes, #{length(config.keys)} keys")
    warn_shadowed()
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
              :persistent_term.put({__MODULE__, :meta}, %{reloads: meta().reloads + 1, loaded_at_ms: System.os_time(:millisecond)})
              Logger.info("reloaded config #{state.path}")
              warn_shadowed()
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
            # What the budget covers: everything ever ("total"), or the
            # current UTC month or day, after which the key unblocks again.
            budget_period: budget_period!(k["budget_period"], k["name"]),
            # Requests per minute enforced by the data plane; 0 = unlimited.
            rpm: to_int(k["rpm"], 0),
            # Route model names (text or media) this key may use; nil = all.
            models: models(k["models"]),
            # Jobs this key may have unfinished at once; nil = the media default.
            max_open_jobs: open_jobs!(k["max_open_jobs"], "key #{inspect(k["name"])}"),
            webhook_secret: secret(k, "webhook_secret"),
            # Switched off by the operator: refused everywhere, usage kept.
            disabled: k["disabled"] == true,
            source: :file,
            created_at: nil,
            old_hashes: []
          }
        end),
      upstreams:
        Enum.map(raw["upstreams"] || [], fn u ->
          %{
            name: Map.fetch!(u, "name"),
            kind: text_kind!(u),
            base_url: Map.fetch!(u, "base_url"),
            api_key_env: Map.fetch!(u, "api_key_env"),
            # Max wait for response headers; 0 = the data plane's default.
            timeout_ms: to_int(u["timeout_ms"], 0),
            # Where the provider serves the API when not under /v1 (nil = /v1).
            v1_path: u["v1_path"]
          }
        end),
      routes:
        Enum.map(raw["routes"] || [], fn r ->
          model = Map.fetch!(r, "model")

          targets =
            Enum.map(Map.fetch!(r, "targets"), fn t ->
              price_in = to_float(t["price_in_per_mtok"] || 0)

              %{
                upstream: Map.fetch!(t, "upstream"),
                model: Map.fetch!(t, "model"),
                # Share of traffic under the "weighted" strategy.
                weight: weight(t["weight"], model),
                price_in_per_mtok: price_in,
                # Input read from, and written to, the provider's prompt cache.
                # Both cost the plain input price unless given.
                price_cached_in_per_mtok: price!(t["price_cached_in_per_mtok"], price_in, model),
                price_cache_write_per_mtok: price!(t["price_cache_write_per_mtok"], price_in, model),
                price_out_per_mtok: to_float(t["price_out_per_mtok"] || 0)
              }
            end)

          %{
            model: model,
            strategy: strategy(r["strategy"], model, targets),
            # How long the data plane may answer identical requests from its
            # own response cache; 0 = never.
            cache_ttl_s: cache_ttl!(r["cache_ttl_s"], model),
            targets: targets
          }
        end),
      media: normalize_media(raw["media"] || %{}),
      retention: normalize_retention(raw["retention"] || %{})
    }
  end

  defp open_jobs!(nil, _where), do: nil
  defp open_jobs!(n, _where) when is_integer(n) and n >= 0, do: n

  defp open_jobs!(other, where) do
    raise ArgumentError, "#{where}: \"max_open_jobs\" must be a whole number, 0 (no limit) or more, got #{inspect(other)}"
  end

  defp models(nil), do: nil

  defp models(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1) do
      list
    else
      raise ArgumentError, "a key's \"models\" must be a list of model names, got #{inspect(list)}"
    end
  end

  defp models(other), do: raise(ArgumentError, "a key's \"models\" must be a list of model names, got #{inspect(other)}")

  @strategies ~w(failover round_robin weighted)

  # How the data plane orders a route's targets: in config order (failover),
  # rotating (round_robin), or at random in proportion to target weights.
  defp strategy(nil, _model, _targets), do: "failover"

  defp strategy("weighted", model, targets) do
    if Enum.any?(targets, &(&1.weight > 0)) do
      "weighted"
    else
      raise ArgumentError, "route #{inspect(model)}: strategy \"weighted\" needs at least one target with a weight above 0"
    end
  end

  defp strategy(s, _model, _targets) when s in @strategies, do: s

  defp strategy(other, model, _targets) do
    raise ArgumentError,
          "route #{inspect(model)}: \"strategy\" must be one of #{Enum.join(@strategies, ", ")}, got #{inspect(other)}"
  end

  defp price!(nil, default, _model), do: default
  defp price!(n, _default, _model) when is_number(n) and n >= 0, do: n * 1.0

  defp price!(other, _default, model) do
    raise ArgumentError, "route #{inspect(model)}: a price must be a number of dollars per 1M tokens, 0 or more, got #{inspect(other)}"
  end

  defp cache_ttl!(nil, _model), do: 0
  defp cache_ttl!(n, _model) when is_integer(n) and n >= 0, do: n

  defp cache_ttl!(other, model) do
    raise ArgumentError, "route #{inspect(model)}: \"cache_ttl_s\" must be a whole number of seconds, 0 or more, got #{inspect(other)}"
  end

  @budget_periods ~w(total monthly daily)

  @doc false
  def budget_periods, do: @budget_periods

  defp budget_period!(nil, _name), do: "total"
  defp budget_period!(p, _name) when p in @budget_periods, do: p

  defp budget_period!(other, name) do
    raise ArgumentError,
          "key #{inspect(name)}: \"budget_period\" must be one of #{Enum.join(@budget_periods, ", ")}, got #{inspect(other)}"
  end

  defp weight(nil, _model), do: 1
  defp weight(n, _model) when is_integer(n) and n >= 0, do: n

  defp weight(other, model) do
    raise ArgumentError, "route #{inspect(model)}: a target's \"weight\" must be a non-negative integer, got #{inspect(other)}"
  end

  # How long finished things are kept, in days. 0 keeps them forever, and is
  # the default for everything except the ledger's duplicate-detection ids.
  @default_ledger_ids_days 14

  defp normalize_retention(r) do
    %{
      jobs_days: days(r["jobs_days"], "jobs_days"),
      # Event ids are only needed while a data plane might still resend an
      # event, and the set otherwise grows with every request ever served. So
      # this one has a finite default; an explicit 0 still keeps them forever.
      ledger_ids_days: if(is_nil(r["ledger_ids_days"]), do: @default_ledger_ids_days, else: days(r["ledger_ids_days"], "ledger_ids_days")),
      # Ledger segments (the event history) older than this are deleted;
      # totals are kept in the ledger's snapshots.
      ledger_days: days(r["ledger_days"], "ledger_days"),
      # Also delete a removed job's objects from the bucket. On unless
      # switched off; it only ever does anything when jobs_days is set.
      delete_bucket_objects:
        case r["delete_bucket_objects"] do
          nil -> true
          b when is_boolean(b) -> b
          other -> raise ArgumentError, "retention.delete_bucket_objects must be true or false, got #{inspect(other)}"
        end
    }
  end

  defp days(nil, _name), do: 0
  defp days(n, _name) when is_number(n) and n >= 0, do: n
  defp days(other, name), do: raise(ArgumentError, "retention.#{name} must be a number of days (0 = keep forever), got #{inspect(other)}")

  @default_retry_schedule_ms [5_000, 30_000, 120_000, 600_000, 1_800_000, 7_200_000, 21_600_000]

  # Media (async job) config. Never sent to data planes.
  defp normalize_media(m) do
    webhooks = m["webhooks"] || %{}
    schedule = webhooks["retry_schedule_ms"] || @default_retry_schedule_ms

    %{
      public_base_url: String.trim_trailing(m["public_base_url"] || "http://127.0.0.1:8080", "/"),
      poll_interval_ms: to_int(m["poll_interval_ms"], 2_000),
      max_output_bytes: to_int(m["max_output_bytes"], 512 * 1024 * 1024),
      # A job's input and metadata are kept in memory and on disk while the job exists.
      max_input_bytes: to_int(m["max_input_bytes"], 1_048_576),
      # Unfinished jobs one key may have at a time (a key can set its own); 0 = no limit.
      max_open_jobs: open_jobs!(m["max_open_jobs"], "media") || 100,
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
                    per_job_usd: media_price!(price["per_job_usd"], r["model"]),
                    per_output_usd: media_price!(price["per_output_usd"], r["model"]),
                    per_input_char_usd: media_price!(price["per_input_char_usd"], r["model"]),
                    per_second_usd: media_price!(price["per_second_usd"], r["model"])
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

  defp media_price!(nil, _model), do: 0.0
  defp media_price!(n, _model) when is_number(n) and n >= 0, do: n * 1.0

  defp media_price!(other, model) do
    raise ArgumentError, "media route #{inspect(model)}: a price must be a number of dollars, 0 or more, got #{inspect(other)}"
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

  defp normalize_storage(s) do
    %{
      kind: "local",
      dir:
        s["dir"] || System.get_env("OMNIGATE_MEDIA_DIR") || Application.get_env(:omnigate_control, :media_dir) ||
          Path.expand("data/media", File.cwd!()),
      url_ttl_s: to_int(s["url_ttl_s"], 3_600)
    }
  end

  # The data plane only speaks these two protocols and cannot parse a snapshot
  # that names another, so a typo must fail here, where the old config is kept.
  defp text_kind!(u) do
    case Map.fetch!(u, "kind") do
      kind when kind in ["openai", "anthropic"] ->
        kind

      other ->
        raise ArgumentError,
              "upstream #{inspect(u["name"])}: kind must be \"openai\" or \"anthropic\", got #{inspect(other)} " <>
                "(media providers go under media.upstreams)"
    end
  end

  # "outputs" and "/outputs/" both mean the key prefix "outputs/".
  defp normalize_prefix(nil), do: ""

  defp normalize_prefix(prefix) do
    case String.trim(prefix, "/") do
      "" -> ""
      trimmed -> trimmed <> "/"
    end
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
