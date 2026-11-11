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

  # Numbers the data plane reads out of the config snapshot go into 32-bit
  # fields there (`rpm`, `weight`, `cache_ttl_s`, `timeout_ms` in
  # dataplane/src/config.zig). One value that does not fit makes the whole
  # snapshot unparseable, and every data plane then keeps its old config for
  # good. So each is bounded here, well inside 32 bits, where a bad value
  # only costs the reload that carried it.
  @max_rpm 1_000_000
  @max_concurrent 1_000_000
  @max_weight 1_000_000
  @max_cache_ttl_s 31_536_000
  @max_timeout_ms 3_600_000

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
    find_prices(route_model, upstream, target_model) || %{in: 0.0, cached_in: 0.0, cache_write: 0.0, out: 0.0}
  end

  @doc "Like `prices/3`, but nil when the config has no such route or target (so the caller can tell \"free\" from \"unknown\")."
  def find_prices(route_model, upstream, target_model) do
    target =
      case Enum.find(get().routes, &(&1.model == route_model)) do
        nil -> nil
        route -> Enum.find(route.targets, &(&1.upstream == upstream and &1.model == target_model))
      end

    case target do
      nil ->
        nil

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
            rpm: int!(k["rpm"], 0, 0..@max_rpm, "key #{inspect(k["name"])}: \"rpm\""),
            # Route model names (text or media) this key may use; nil = all.
            models: models(k["models"]),
            # Requests the data plane lets this key have in flight at once;
            # 0 = the data plane's own default (OMNIGATE_MAX_CONCURRENT_PER_KEY).
            max_concurrent: int!(k["max_concurrent"], 0, 0..@max_concurrent, "key #{inspect(k["name"])}: \"max_concurrent\""),
            # Jobs this key may have unfinished at once; nil = the media default.
            max_open_jobs: open_jobs!(k["max_open_jobs"], "key #{inspect(k["name"])}"),
            # Jobs this key may create per UTC day; nil = the media default.
            max_jobs_per_day: jobs_per_day!(k["max_jobs_per_day"], "key #{inspect(k["name"])}"),
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
            timeout_ms: int!(u["timeout_ms"], 0, 0..@max_timeout_ms, "upstream #{inspect(u["name"])}: \"timeout_ms\""),
            # Where the provider serves the API when not under /v1 (nil = /v1).
            v1_path: u["v1_path"]
          }
        end),
      routes:
        Enum.map(raw["routes"] || [], fn r ->
          model = Map.fetch!(r, "model")

          targets =
            Enum.map(Map.fetch!(r, "targets"), fn t ->
              price_in = price!(t["price_in_per_mtok"], 0.0, model)

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
                price_out_per_mtok: price!(t["price_out_per_mtok"], 0.0, model)
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

  @doc false
  def limits, do: %{rpm: @max_rpm, max_concurrent: @max_concurrent, weight: @max_weight, cache_ttl_s: @max_cache_ttl_s, timeout_ms: @max_timeout_ms}

  # A whole number within `range`, or `default` when the setting is left out.
  defp int!(nil, default, _range, _what), do: default

  defp int!(n, _default, first..last//_, what) do
    if is_integer(n) and n >= first and n <= last do
      n
    else
      raise ArgumentError, "#{what} must be a whole number from #{first} to #{last}, got #{inspect(n)}"
    end
  end

  defp open_jobs!(nil, _where), do: nil
  defp open_jobs!(n, _where) when is_integer(n) and n >= 0 and n <= 1_000_000_000, do: n

  defp open_jobs!(other, where) do
    raise ArgumentError, "#{where}: \"max_open_jobs\" must be a whole number, 0 (no limit) or more, got #{inspect(other)}"
  end

  defp jobs_per_day!(nil, _where), do: nil
  defp jobs_per_day!(n, _where) when is_integer(n) and n >= 0 and n <= 1_000_000_000, do: n

  defp jobs_per_day!(other, where) do
    raise ArgumentError, "#{where}: \"max_jobs_per_day\" must be a whole number, 0 (no limit) or more, got #{inspect(other)}"
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
  defp price!(n, _default, _model) when is_number(n) and n >= 0 and n <= 1.0e9, do: n * 1.0

  defp price!(other, _default, model) do
    raise ArgumentError, "route #{inspect(model)}: a price must be a number of dollars per 1M tokens, 0 or more, got #{inspect(other)}"
  end

  defp cache_ttl!(nil, _model), do: 0
  defp cache_ttl!(n, _model) when is_integer(n) and n >= 0 and n <= @max_cache_ttl_s, do: n

  defp cache_ttl!(other, model) do
    raise ArgumentError,
          "route #{inspect(model)}: \"cache_ttl_s\" must be a whole number of seconds, 0 or more (at most #{@max_cache_ttl_s}), got #{inspect(other)}"
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
  defp weight(n, _model) when is_integer(n) and n >= 0 and n <= @max_weight, do: n

  defp weight(other, model) do
    raise ArgumentError, "route #{inspect(model)}: a target's \"weight\" must be a non-negative integer (at most #{@max_weight}), got #{inspect(other)}"
  end

  # How long finished things are kept, in days. 0 keeps them forever, and is
  # the default for everything except the ledger's duplicate-detection ids.
  #
  # An id is needed for as long as a data plane might still send its event
  # again. Events wait in a data plane's spool file until the control plane
  # has acknowledged them, and are resent after an outage or a data-plane
  # restart; the spool is the only place a resend can come from. Three days
  # covers a control plane that is down over a weekend, or a data plane that
  # was stopped on Friday with events still spooled and started on Monday.
  # It used to be fourteen, which kept (at 61 MiB per million ids) five times
  # the memory for outages nobody leaves that long. Raise it if a data plane
  # can be off for longer with usage it has not delivered.
  @default_ledger_ids_days 3

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
    m |> build_media() |> check_per_second_prices!()
  end

  # A per-second price needs seconds to multiply. Video providers take them
  # from the request; image and speech providers are never sent a duration,
  # so there the price can only apply to the target's `default_seconds`.
  # Without one the job would be billed nothing per second (or only
  # `min_seconds`), whatever the request says. Refuse that at load.
  defp check_per_second_prices!(media) do
    kinds = Map.new(media.upstreams, &{&1.name, &1.kind})

    for route <- media.routes, target <- route.targets do
      kind = kinds[target.upstream]
      per_second = target.price.per_second_usd

      if is_number(per_second) and per_second > 0 and is_binary(kind) and
           not OmnigateControl.Jobs.Adapter.takes_duration?(kind) and is_nil(target.default_seconds) do
        raise ArgumentError,
              "media route #{inspect(route.model)}: the target on #{inspect(target.upstream)} has \"per_second_usd\", " <>
                "but a #{kind} provider is never sent a duration. Set \"default_seconds\" on the target " <>
                "(the seconds every job is billed for), or price it with \"per_job_usd\" or \"per_output_usd\""
      end
    end

    media
  end

  defp build_media(m) do
    webhooks = m["webhooks"] || %{}
    schedule = retry_schedule!(webhooks["retry_schedule_ms"])

    %{
      public_base_url: String.trim_trailing(m["public_base_url"] || "http://127.0.0.1:8080", "/"),
      poll_interval_ms: int!(m["poll_interval_ms"], 2_000, 1..3_600_000, "media.poll_interval_ms"),
      max_output_bytes: int!(m["max_output_bytes"], 512 * 1024 * 1024, 1..1_099_511_627_776, "media.max_output_bytes"),
      # A job's input and metadata are kept on disk while the job exists.
      max_input_bytes: int!(m["max_input_bytes"], 1_048_576, 1..8_000_000, "media.max_input_bytes"),
      # Unfinished jobs one key may have at a time (a key can set its own); 0 = no limit.
      max_open_jobs: open_jobs!(m["max_open_jobs"], "media") || 100,
      # Jobs one key may create per UTC day (a key can set its own); 0 = no
      # limit. The open-jobs limit does not bound jobs that end at once (a
      # refused input, a provider that is down), and each of those still
      # costs a log line, a ledger event and a webhook call.
      max_jobs_per_day: jobs_per_day!(m["max_jobs_per_day"], "media") || 10_000,
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
            timeout_s: int!(r["timeout_s"], 600, 1..604_800, "media route #{inspect(r["model"])}: \"timeout_s\""),
            # Top-level input fields a job may carry; nil = any.
            allowed_input: allowed_input!(r["allowed_input"], r["model"]),
            # Input field => value => factor on the job's price.
            price_multipliers: price_multipliers!(r["price_multipliers"], r["model"]),
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
                |> Map.merge(seconds!(t, r["model"]))
              end)
          }
        end),
      storage: normalize_storage(m["storage"] || %{}),
      webhooks: %{
        retry_schedule_ms: schedule,
        max_attempts: int!(webhooks["max_attempts"], length(schedule) + 1, 1..100, "media.webhooks.max_attempts"),
        timeout_ms: int!(webhooks["timeout_ms"], 10_000, 1..600_000, "media.webhooks.timeout_ms"),
        # Deliveries in flight at once: overall, and for one gateway key's jobs.
        max_concurrent: int!(webhooks["max_concurrent"], 16, 1..10_000, "media.webhooks.max_concurrent"),
        max_concurrent_per_key: int!(webhooks["max_concurrent_per_key"], 4, 1..10_000, "media.webhooks.max_concurrent_per_key"),
        # Refuse webhook URLs that resolve to loopback/private addresses
        # unless explicitly allowed (local development).
        allow_private: webhooks["allow_private"] == true,
        secret: secret(webhooks, "secret")
      }
    }
  end

  defp retry_schedule!(nil), do: @default_retry_schedule_ms

  defp retry_schedule!(list) do
    if is_list(list) and length(list) <= 50 and Enum.all?(list, &(is_integer(&1) and &1 >= 0 and &1 <= 2_592_000_000)) do
      list
    else
      raise ArgumentError, "media.webhooks.retry_schedule_ms must be a list of at most 50 waits in milliseconds (each up to 30 days), got #{inspect(list)}"
    end
  end

  # What a per-second price is applied to when the request does not settle
  # it: `default_seconds` when the request names no duration, never less than
  # `min_seconds`, and requests above `max_seconds` are refused.
  defp seconds!(t, model) do
    get = fn name ->
      case t[name] do
        nil -> nil
        n when is_number(n) and n >= 0 and n <= 1.0e9 -> n
        other -> raise ArgumentError, "media route #{inspect(model)}: \"#{name}\" must be a number of seconds, 0 or more, got #{inspect(other)}"
      end
    end

    seconds = %{default_seconds: get.("default_seconds"), min_seconds: get.("min_seconds"), max_seconds: get.("max_seconds")}

    cond do
      seconds.default_seconds == 0 ->
        raise ArgumentError, "media route #{inspect(model)}: \"default_seconds\" must be above 0 (leave it out for no default)"

      seconds.min_seconds && seconds.max_seconds && seconds.min_seconds > seconds.max_seconds ->
        raise ArgumentError, "media route #{inspect(model)}: \"min_seconds\" must not be above \"max_seconds\""

      seconds.default_seconds && seconds.max_seconds && seconds.default_seconds > seconds.max_seconds ->
        raise ArgumentError, "media route #{inspect(model)}: \"default_seconds\" must not be above \"max_seconds\""

      true ->
        seconds
    end
  end

  defp allowed_input!(nil, _model), do: nil

  defp allowed_input!(list, model) do
    if is_list(list) and Enum.all?(list, &(is_binary(&1) and &1 != "")) do
      Enum.uniq(list)
    else
      raise ArgumentError, "media route #{inspect(model)}: \"allowed_input\" must be a list of input field names, got #{inspect(list)}"
    end
  end

  defp price_multipliers!(nil, _model), do: %{}

  defp price_multipliers!(%{} = fields, model) do
    Map.new(fields, fn {field, factors} ->
      ok =
        is_map(factors) and map_size(factors) > 0 and
          Enum.all?(factors, fn {value, factor} -> is_binary(value) and is_number(factor) and factor >= 0 and factor <= 1.0e6 end)

      if ok do
        {field, Map.new(factors, fn {value, factor} -> {value, factor * 1.0} end)}
      else
        raise ArgumentError,
              "media route #{inspect(model)}: \"price_multipliers\".#{inspect(field)} must map each allowed value to a factor of 0 or more " <>
                "(for example {\"low\": 1, \"high\": 4}), got #{inspect(factors)}"
      end
    end)
  end

  defp price_multipliers!(other, model) do
    raise ArgumentError, "media route #{inspect(model)}: \"price_multipliers\" must be an object of input field => {value: factor}, got #{inspect(other)}"
  end

  defp media_price!(nil, _model), do: 0.0
  defp media_price!(n, _model) when is_number(n) and n >= 0 and n <= 1.0e9, do: n * 1.0

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
      url_ttl_s: int!(s["url_ttl_s"], 3_600, 1..31_536_000, "media.storage.url_ttl_s")
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

  defp to_float(nil), do: nil
  defp to_float(n) when is_number(n) and n >= 0 and n <= 1.0e12, do: n * 1.0
  defp to_float(other), do: raise(ArgumentError, "a key's \"budget_usd\" must be a number of dollars, 0 or more, got #{inspect(other)}")
end
