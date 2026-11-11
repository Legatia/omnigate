defmodule OmnigateControl.Privacy do
  @moduledoc """
  A key's privacy mode: what the gateway does so that less of a request is
  kept, seen or linked to anyone.

  The setting, on a key in the config file or a managed key:

      "privacy": true

  switches on the three parts that need nothing else, or, part by part:

      "privacy": {
        "no_store":   true,
        "redact":     true,          (or a list: ["email", "phone", "card", "ip", "secret"])
        "unlink":     true,
        "encrypt_to": "age1...",
        "attested":   true
      }

    * `no_store`: nothing of a request's content is kept here. The data
      plane does not read or write its response cache; a media job's input
      and metadata never enter the job log and are erased when the job ends,
      its outputs are deleted after `retention.private_outputs_hours`, and
      OpenAI is told `"store": false`.
    * `redact`: the data plane replaces e-mail addresses, phone numbers,
      payment card numbers, IP addresses and common secret formats in a text
      request with placeholders before a provider sees it, and puts the
      originals back in the answer.
    * `unlink`: the request fields that name an end user to a provider are
      removed.
    * `encrypt_to`: an age recipient. The outputs of the key's media jobs
      are encrypted to it before they are stored anywhere.
    * `attested`: a text request only goes to a target whose provider has
      proven, and recently, what hardware and configuration it runs on
      (`OmnigateControl.Attestation`). When no such target is there the
      request is refused, not sent elsewhere. Media jobs are refused: no
      media provider is attested.

  `true` is `no_store`, `redact` (every class) and `unlink`. It is not
  `attested`: that part needs an attested upstream in the config, and a
  key that had `true` before the part existed must keep working. A request can
  add parts for itself with the `x-omnigate-privacy` header; nothing a
  request sends can take one away.

  Normalised, a setting is `nil` (nothing on) or a map with all five fields.
  """
  alias OmnigateControl.Age

  @classes ~w(email phone card ip secret)
  @fields ~w(no_store redact unlink encrypt_to attested)

  @doc "The classes of values `redact` knows."
  def classes, do: @classes

  @doc """
  Validate a setting as written (JSON). `{:ok, normalised}` or
  `{:error, message}`.
  """
  def normalize(nil), do: {:ok, nil}
  def normalize(false), do: {:ok, nil}
  def normalize(true), do: {:ok, %{no_store: true, redact: @classes, unlink: true, encrypt_to: nil, attested: false}}

  def normalize(%{} = map) do
    map = Map.new(map, fn {k, v} -> {to_string(k), v} end)

    with [] <- Map.keys(map) -- @fields,
         {:ok, no_store} <- flag(map["no_store"], "no_store"),
         {:ok, unlink} <- flag(map["unlink"], "unlink"),
         {:ok, attested} <- flag(map["attested"], "attested"),
         {:ok, redact} <- redact(map["redact"]),
         {:ok, encrypt_to} <- encrypt_to(map["encrypt_to"]) do
      if no_store or unlink or attested or redact != [] or encrypt_to != nil do
        {:ok, %{no_store: no_store, redact: redact, unlink: unlink, encrypt_to: encrypt_to, attested: attested}}
      else
        {:ok, nil}
      end
    else
      [_ | _] = unknown ->
        {:error,
         "privacy has no setting named #{unknown |> Enum.sort() |> Enum.take(3) |> Enum.map_join(", ", &inspect(String.slice(&1, 0, 40)))} (it has: #{Enum.join(@fields, ", ")})"}

      {:error, message} ->
        {:error, message}
    end
  end

  def normalize(_), do: {:error, "privacy must be true, false, or an object with #{Enum.join(@fields, ", ")}"}

  @doc "Like `normalize/1`, raising with `where` in front (config load)."
  def normalize!(value, where) do
    case normalize(value) do
      {:ok, privacy} -> privacy
      {:error, message} -> raise ArgumentError, "#{where}: #{message}"
    end
  end

  defp flag(nil, _name), do: {:ok, false}
  defp flag(b, _name) when is_boolean(b), do: {:ok, b}
  defp flag(_, name), do: {:error, "privacy.#{name} must be true or false"}

  defp redact(nil), do: {:ok, []}
  defp redact(false), do: {:ok, []}
  defp redact(true), do: {:ok, @classes}

  defp redact(list) when is_list(list) do
    if Enum.all?(list, &(&1 in @classes)) do
      # In the fixed order, so that two spellings of one setting are equal.
      {:ok, Enum.filter(@classes, &(&1 in list))}
    else
      {:error, "privacy.redact must be true, false, or a list of: #{Enum.join(@classes, ", ")}"}
    end
  end

  defp redact(_), do: {:error, "privacy.redact must be true, false, or a list of: #{Enum.join(@classes, ", ")}"}

  defp encrypt_to(nil), do: {:ok, nil}
  defp encrypt_to(""), do: {:ok, nil}

  defp encrypt_to(text) when is_binary(text) do
    case Age.recipient(text) do
      {:ok, _key} -> {:ok, String.downcase(text, :ascii)}
      {:error, why} -> {:error, "privacy.encrypt_to must be an age recipient (age1...): #{why}"}
    end
  end

  defp encrypt_to(_), do: {:error, "privacy.encrypt_to must be an age recipient (age1...)"}

  @doc "A stored setting (string keys, from the key store) back in normalised form; anything unreadable is no setting."
  def load(stored) do
    case normalize(stored) do
      {:ok, privacy} -> privacy
      {:error, _} -> nil
    end
  end

  @doc "The setting as the admin API shows it; nil when nothing is on."
  def view(nil), do: nil
  def view(%{} = p), do: %{no_store: p.no_store, redact: p.redact, unlink: p.unlink, encrypt_to: p.encrypt_to, attested: attested?(p)}

  @doc "What a data plane needs of it (it has no use for the recipient); nil when none of that is on."
  def for_data_plane(%{} = p) do
    if p.no_store or p.unlink or attested?(p) or p.redact != [], do: %{no_store: p.no_store, redact: p.redact, unlink: p.unlink, attested: attested?(p)}
  end

  def for_data_plane(_), do: nil

  @doc "One line for a list of keys: `no-store, redact, unlink, encrypt`, or an empty string."
  def summary(nil), do: ""

  def summary(%{} = p) do
    [p.no_store && "no-store", p.redact != [] && "redact", p.unlink && "unlink", p.encrypt_to && "encrypt", attested?(p) && "attested"]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  @doc "Does this key keep nothing of a request?"
  def no_store?(key), do: match?(%{no_store: true}, of(key))

  @doc "The age recipient the key's job outputs are encrypted to, or nil."
  def recipient(key) do
    case of(key) do
      %{encrypt_to: r} when is_binary(r) -> r
      _ -> nil
    end
  end

  @doc "Does this key's setting (or the setting itself) ask for attested providers only?"
  def attested?(%{attested: true}), do: true
  def attested?(%{privacy: %{attested: true}}), do: true
  def attested?(_), do: false

  @doc "A key's setting, or nil."
  def of(key) when is_map(key), do: Map.get(key, :privacy)
  def of(_), do: nil

  @doc """
  What an `x-omnigate-privacy` request header asks for, for a media job:
  `{:ok, no_store?}` or `:error`. (The data plane has checked it already;
  this is the same grammar. It refuses a job that asks for `attested`, so
  the word is accepted here and means nothing more.)
  """
  def header(nil), do: {:ok, false}

  def header(value) when is_binary(value) do
    v = value |> String.trim() |> String.downcase(:ascii)

    cond do
      v in ["on", "true", "1"] ->
        {:ok, true}

      v == "" or byte_size(v) > 64 ->
        :error

      true ->
        parts = v |> String.split(",") |> Enum.map(&String.trim/1)

        if Enum.all?(parts, &(&1 in ["no-store", "no_store", "redact", "unlink", "attested"])),
          do: {:ok, Enum.any?(parts, &(&1 in ["no-store", "no_store"]))},
          else: :error
    end
  end
end
