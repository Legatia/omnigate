defmodule OmnigateControl.Keys do
  @moduledoc """
  Gateway keys created through the admin API ("managed" keys), next to the
  ones written in the config file.

  They live in a small JSON file (`OMNIGATE_KEYS`, default `data/keys.json`)
  that is rewritten atomically on every change and loaded at boot. Only the
  SHA-256 of a key is ever stored: the key itself is returned once, by
  `create/1` and `rotate/1`, and cannot be recovered afterwards. (A key's
  optional webhook signing secret is stored as given, because signing needs
  the secret itself.)

  `ConfigStore.get().keys` is the merged view of both sources, so the rest
  of the control plane, and the snapshot sent to data planes, treat managed
  keys exactly like file keys.

  Rotating a key replaces its secret but keeps its record: the hashes of
  earlier secrets are remembered (never accepted again) so that the key's
  spend, budget and media jobs carry over.
  """
  use GenServer
  require Logger

  alias OmnigateControl.{ConfigStore, Ledger}

  @name_format ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/
  @fields [:budget_usd, :budget_period, :rpm, :max_concurrent, :models, :max_open_jobs, :max_jobs_per_day, :webhook_secret, :disabled]
  @max_old_hashes 50

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Managed keys, in the shape `ConfigStore` uses for file keys."
  def managed, do: :persistent_term.get({__MODULE__, :managed}, [])

  @doc "Create a key. Returns `{:ok, key, raw_key}`; the raw key is not kept."
  def create(attrs) when is_map(attrs), do: GenServer.call(__MODULE__, {:create, attrs})

  @doc "Change `budget_usd`, `budget_period`, `rpm`, `models`, `disabled` or `webhook_secret` of a managed key."
  def update(name, attrs) when is_map(attrs), do: GenServer.call(__MODULE__, {:update, name, attrs})

  @doc "Give a managed key a new secret. Returns `{:ok, key, raw_key}`; the old secret stops working."
  def rotate(name), do: GenServer.call(__MODULE__, {:rotate, name})

  @doc "Remove a managed key. Its usage stays in the ledger."
  def delete(name), do: GenServer.call(__MODULE__, {:delete, name})

  # -- lookups over the merged view -------------------------------------------

  @doc "The key (from either source) with this name, or nil."
  def find(name), do: Enum.find(ConfigStore.get().keys, &(&1.name == name))

  @doc "The key whose current secret hashes to `hash`, or nil."
  def find_current(hash), do: Enum.find(ConfigStore.get().keys, &(&1.key_sha256 == hash))

  @doc "The key that owns `hash`: its current secret or one it had before a rotation."
  def find_owner(hash), do: Enum.find(ConfigStore.get().keys, &(hash in hashes(&1)))

  @doc "Every hash usage may be recorded under for this key: the current one first."
  def hashes(key), do: [key.key_sha256 | Map.get(key, :old_hashes, [])]

  @doc "Ledger totals for a key, across rotations."
  def totals(key) do
    key
    |> hashes()
    |> Enum.map(&Ledger.totals/1)
    |> Enum.reduce(fn t, sum -> Map.merge(sum, t, fn _field, a, b -> a + b end) end)
  end

  @doc "`total`, `monthly` or `daily`: what the key's budget covers."
  def budget_period(key), do: Map.get(key, :budget_period) || "total"

  @doc "Spend in the key's current budget period (its whole history for a total budget), across rotations."
  def period_spend(key, now \\ DateTime.utc_now()) do
    period = budget_period(key)
    key |> hashes() |> Enum.map(&Ledger.period_spend(&1, period, now)) |> Enum.sum()
  end

  @doc "ISO 8601 time at which the key's budget period ends, or nil for a total budget."
  def period_resets_at(key, now \\ DateTime.utc_now()) do
    case Ledger.period_resets_at(budget_period(key), now) do
      nil -> nil
      at -> DateTime.to_iso8601(at)
    end
  end

  @doc """
  True when the key has a budget and has spent it in the current period. A
  monthly or daily key therefore unblocks by itself when the period turns.
  """
  def over_budget?(key, now \\ DateTime.utc_now())
  def over_budget?(%{budget_usd: nil}, _now), do: false
  def over_budget?(key, now), do: period_spend(key, now) >= key.budget_usd

  def disabled?(key), do: Map.get(key, :disabled, false) == true

  @doc "How many unfinished jobs the key may have at once: its own setting, else the media default. 0 = no limit."
  def max_open_jobs(key) do
    case Map.get(key, :max_open_jobs) do
      nil -> ConfigStore.get().media |> Map.get(:max_open_jobs, 100)
      n -> n
    end
  end

  @doc "How many jobs the key may create per UTC day: its own setting, else the media default. 0 = no limit."
  def max_jobs_per_day(key) do
    case Map.get(key, :max_jobs_per_day) do
      nil -> ConfigStore.get().media |> Map.get(:max_jobs_per_day, 10_000)
      n -> n
    end
  end

  @doc """
  What a key's rate limits are counted under: the hash of its current
  secret, which is also what the data plane counts by. Two keys never share
  it (names in a config file are not checked for uniqueness), and a rotation
  starts a new allowance in both processes alike.
  """
  def identity(key), do: key.key_sha256

  @doc "`active`, `blocked` (budget spent) or `disabled` (switched off by an operator)."
  def state(key) do
    cond do
      disabled?(key) -> "disabled"
      over_budget?(key) -> "blocked"
      true -> "active"
    end
  end

  # -- server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    keys = load(path)
    publish(keys)
    if keys != [], do: Logger.info("loaded #{length(keys)} managed keys from #{path}")
    {:ok, %{path: path, keys: keys}}
  end

  @impl true
  def handle_call({:create, attrs}, _from, state) do
    with {:ok, name} <- validate_name(attrs["name"]),
         :ok <- unused(name, state),
         {:ok, fields} <- validate_fields(attrs, @fields) do
      raw = new_secret()

      key =
        Map.merge(
          %{
            name: name,
            key_sha256: OmnigateControl.sha256_hex(raw),
            budget_usd: nil,
            budget_period: "total",
            rpm: 0,
            max_concurrent: 0,
            models: nil,
            max_open_jobs: nil,
            max_jobs_per_day: nil,
            webhook_secret: nil,
            disabled: false,
            source: :managed,
            created_at: now_iso(),
            old_hashes: []
          },
          fields
        )

      commit(state, state.keys ++ [key], {:ok, key, raw})
    else
      {:error, _, _, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:update, name, attrs}, _from, state) do
    with {:ok, key} <- managed_key(name, state),
         {:ok, fields} <- validate_fields(attrs, @fields) do
      updated = Map.merge(key, fields)
      commit(state, replace(state.keys, updated), {:ok, updated})
    else
      {:error, _, _, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:rotate, name}, _from, state) do
    case managed_key(name, state) do
      {:ok, key} ->
        raw = new_secret()
        old = Enum.take([key.key_sha256 | key.old_hashes], @max_old_hashes)
        updated = %{key | key_sha256: OmnigateControl.sha256_hex(raw), old_hashes: old}
        commit(state, replace(state.keys, updated), {:ok, updated, raw})

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:delete, name}, _from, state) do
    case managed_key(name, state) do
      {:ok, key} -> commit(state, Enum.reject(state.keys, &(&1.name == key.name)), :ok)
      error -> {:reply, error, state}
    end
  end

  # Disk first: a change that cannot be saved is not applied.
  defp commit(state, keys, reply) do
    case save(state.path, keys) do
      :ok ->
        publish(keys)
        {:reply, reply, %{state | keys: keys}}

      {:error, reason} ->
        Logger.error("cannot write #{state.path}: #{inspect(reason)}")
        {:reply, {:error, 500, "storage_error", "the key store could not be written; nothing was changed"}, state}
    end
  end

  defp publish(keys) do
    :persistent_term.put({__MODULE__, :managed}, keys)
    ConfigStore.warn_shadowed()
  end

  defp replace(keys, updated), do: Enum.map(keys, &if(&1.name == updated.name, do: updated, else: &1))

  defp managed_key(name, state) do
    case Enum.find(state.keys, &(&1.name == name)) do
      nil ->
        if Enum.any?(ConfigStore.file_keys(), &(&1.name == name)) do
          {:error, 409, "read_only_key", "the key #{inspect(name)} is defined in the config file; edit the file to change it"}
        else
          {:error, 404, "key_not_found", "no key named #{inspect(name)}"}
        end

      key ->
        {:ok, key}
    end
  end

  defp unused(name, state) do
    if Enum.any?(state.keys ++ ConfigStore.file_keys(), &(&1.name == name)) do
      {:error, 409, "key_exists", "a key named #{inspect(name)} already exists"}
    else
      :ok
    end
  end

  # -- validation -----------------------------------------------------------------

  defp validate_name(name) when is_binary(name) do
    if name =~ @name_format do
      {:ok, name}
    else
      invalid("name must be 1-64 characters: letters, digits, '.', '_' or '-', starting with a letter or digit")
    end
  end

  defp validate_name(_), do: invalid("name is required")

  # Only fields present in the request are validated and returned.
  defp validate_fields(attrs, allowed) do
    Enum.reduce_while(allowed, {:ok, %{}}, fn field, {:ok, acc} ->
      case Map.fetch(attrs, Atom.to_string(field)) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case validate(field, value) do
            {:ok, v} -> {:cont, {:ok, Map.put(acc, field, v)}}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp validate(:budget_usd, nil), do: {:ok, nil}
  defp validate(:budget_usd, n) when is_number(n) and n >= 0 and n <= 1.0e12, do: {:ok, n * 1.0}
  defp validate(:budget_usd, _), do: invalid("budget_usd must be a number of dollars, 0 or more, or null for no budget")

  defp validate(:budget_period, nil), do: {:ok, "total"}

  defp validate(:budget_period, p) do
    if p in ConfigStore.budget_periods(), do: {:ok, p}, else: invalid("budget_period must be \"total\", \"monthly\" or \"daily\"")
  end

  defp validate(:rpm, nil), do: {:ok, 0}
  # The data plane reads `rpm` into a 32-bit field: a larger number would
  # make the config snapshot unreadable for every data plane (see
  # `ConfigStore.limits/0`).
  defp validate(:rpm, n) when is_integer(n) and n >= 0 do
    if n <= ConfigStore.limits().rpm, do: {:ok, n}, else: invalid("rpm must be at most #{ConfigStore.limits().rpm} (0 for no limit)")
  end

  defp validate(:rpm, _), do: invalid("rpm must be a whole number of requests per minute, or 0 for no limit")

  defp validate(:max_concurrent, nil), do: {:ok, 0}

  # Read by the data plane into a 32-bit field, like `rpm`.
  defp validate(:max_concurrent, n) when is_integer(n) and n >= 0 do
    max = ConfigStore.limits().max_concurrent
    if n <= max, do: {:ok, n}, else: invalid("max_concurrent must be at most #{max} (0 for the gateway default)")
  end

  defp validate(:max_concurrent, _), do: invalid("max_concurrent must be a whole number of requests in flight at once, or 0 for the gateway default")

  defp validate(:models, nil), do: {:ok, nil}

  defp validate(:models, list) when is_list(list) do
    if length(list) <= 1_000 and Enum.all?(list, &(is_binary(&1) and &1 != "" and byte_size(&1) <= 256)) do
      {:ok, Enum.uniq(list)}
    else
      invalid("models must be a list of at most 1000 model names, or null for all models")
    end
  end

  defp validate(:models, _), do: invalid("models must be a list of model names, or null for all models")

  defp validate(:max_open_jobs, nil), do: {:ok, nil}
  defp validate(:max_open_jobs, n) when is_integer(n) and n >= 0 and n <= 1_000_000_000, do: {:ok, n}
  defp validate(:max_open_jobs, _), do: invalid("max_open_jobs must be a whole number (0 for no limit), or null for the default")

  defp validate(:max_jobs_per_day, nil), do: {:ok, nil}
  defp validate(:max_jobs_per_day, n) when is_integer(n) and n >= 0 and n <= 1_000_000_000, do: {:ok, n}
  defp validate(:max_jobs_per_day, _), do: invalid("max_jobs_per_day must be a whole number (0 for no limit), or null for the default")

  defp validate(:disabled, b) when is_boolean(b), do: {:ok, b}
  defp validate(:disabled, _), do: invalid("disabled must be true or false")

  defp validate(:webhook_secret, nil), do: {:ok, nil}
  defp validate(:webhook_secret, ""), do: {:ok, nil}
  defp validate(:webhook_secret, s) when is_binary(s) and byte_size(s) <= 256, do: {:ok, s}
  defp validate(:webhook_secret, _), do: invalid("webhook_secret must be a string of at most 256 characters")

  defp invalid(message), do: {:error, 400, "invalid_request", message}

  # -- persistence ----------------------------------------------------------------

  defp new_secret, do: "og-" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp load(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"keys" => list}} when is_list(list) <- JSON.decode(text) do
      for %{"name" => name, "key_sha256" => hash} = k when is_binary(name) and is_binary(hash) <- list do
        %{
          name: name,
          key_sha256: hash,
          budget_usd: if(is_number(k["budget_usd"]), do: k["budget_usd"] * 1.0),
          budget_period: if(k["budget_period"] in ConfigStore.budget_periods(), do: k["budget_period"], else: "total"),
          # A file written before `rpm` was bounded may hold anything.
          rpm: if(is_integer(k["rpm"]), do: k["rpm"] |> max(0) |> min(ConfigStore.limits().rpm), else: 0),
          max_concurrent: if(is_integer(k["max_concurrent"]), do: k["max_concurrent"] |> max(0) |> min(ConfigStore.limits().max_concurrent), else: 0),
          models: if(is_list(k["models"]), do: k["models"]),
          max_open_jobs: if(is_integer(k["max_open_jobs"]) and k["max_open_jobs"] >= 0, do: k["max_open_jobs"]),
          max_jobs_per_day: if(is_integer(k["max_jobs_per_day"]) and k["max_jobs_per_day"] >= 0, do: k["max_jobs_per_day"]),
          webhook_secret: k["webhook_secret"],
          disabled: k["disabled"] == true,
          source: :managed,
          created_at: k["created_at"],
          old_hashes: if(is_list(k["old_hashes"]), do: k["old_hashes"], else: [])
        }
      end
    else
      {:error, :enoent} ->
        []

      other ->
        # Refuse to start over a file we cannot read: writing a fresh one would
        # silently revoke every managed key.
        raise "cannot read the key store #{path}: #{inspect(other)}"
    end
  end

  # Temp file, fsync, rename: a crash never leaves half a file in place.
  defp save(path, keys) do
    body =
      JSON.encode!(%{
        "version" => 1,
        "keys" => Enum.map(keys, fn k -> k |> Map.delete(:source) |> Map.new(fn {field, v} -> {Atom.to_string(field), v} end) end)
      })

    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- File.open(tmp, [:write, :binary]),
         :ok <- IO.binwrite(io, body),
         :ok <- :file.datasync(io),
         :ok <- File.close(io),
         _ <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end
end
