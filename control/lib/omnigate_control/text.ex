defmodule OmnigateControl.Text do
  @moduledoc """
  Making outside text safe to keep.

  Provider error bodies, header values and job inputs are bytes somebody else
  chose. Before any of them is written to a log, stored in a job, put in the
  ledger or encoded as JSON, it goes through here: `JSON.encode!/1` raises on
  invalid UTF-8, and a raw newline in a log line lets the sender forge the
  next line.
  """

  @doc "`bin` as valid UTF-8: invalid sequences become U+FFFD."
  def utf8(bin) when is_binary(bin), do: if(String.valid?(bin), do: bin, else: String.replace_invalid(bin))

  @doc """
  One line of valid UTF-8, at most `max` characters: control characters
  (newlines included) and Unicode line separators become spaces, runs of
  spaces collapse. Anything that is not a string is `inspect/1`ed first.
  """
  def line(text, max \\ 300)

  def line(text, max) when is_binary(text) do
    text
    |> utf8()
    |> String.replace(~r/[\x00-\x1f\x7f\x{85}\x{2028}\x{2029}]+/u, " ")
    |> String.replace(~r/ {2,}/, " ")
    |> String.trim()
    |> String.slice(0, max)
  end

  def line(other, max), do: other |> inspect() |> line(max)

  @doc """
  `term` with every string in it (map keys too) made valid UTF-8, and
  anything JSON cannot carry (tuples, pids, ...) turned into its `inspect/1`
  text. The result always survives `JSON.encode!/1`.
  """
  def clean(bin) when is_binary(bin), do: utf8(bin)
  def clean(n) when is_number(n) or is_boolean(n) or is_nil(n), do: n
  def clean(atom) when is_atom(atom), do: Atom.to_string(atom)
  def clean(list) when is_list(list), do: Enum.map(list, &clean/1)
  def clean(%_{} = struct), do: struct |> inspect() |> utf8()
  def clean(map) when is_map(map), do: Map.new(map, fn {k, v} -> {clean_key(k), clean(v)} end)
  def clean(other), do: other |> inspect() |> utf8()

  defp clean_key(k) when is_binary(k), do: utf8(k)
  defp clean_key(k) when is_atom(k), do: k
  defp clean_key(k), do: inspect(k)

  @doc "True when `term` holds a string that is not valid UTF-8."
  def dirty?(bin) when is_binary(bin), do: not String.valid?(bin)
  def dirty?(list) when is_list(list), do: Enum.any?(list, &dirty?/1)
  def dirty?(%_{}), do: false
  def dirty?(map) when is_map(map), do: Enum.any?(map, fn {k, v} -> dirty?(k) or dirty?(v) end)
  def dirty?(_), do: false
end
