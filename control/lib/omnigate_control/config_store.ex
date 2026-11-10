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
            budget_usd: to_float(k["budget_usd"])
          }
        end),
      upstreams:
        Enum.map(raw["upstreams"] || [], fn u ->
          %{
            name: Map.fetch!(u, "name"),
            kind: Map.fetch!(u, "kind"),
            base_url: Map.fetch!(u, "base_url"),
            api_key_env: Map.fetch!(u, "api_key_env")
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
        end)
    }
  end

  defp to_float(nil), do: nil
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(n) when is_float(n), do: n
end
