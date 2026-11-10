defmodule OmnigateControl.Env do
  @moduledoc """
  Numeric environment variables, read strictly.

  `Integer.parse("5x")` is `{5, "x"}` and `Float.parse("50MB")` is
  `{50.0, "MB"}`: a typo would be accepted as a number and the rest silently
  dropped. Here a value is either a whole, well-formed number in range or an
  error that names the variable, and a bad value stops the control plane at
  startup instead of being replaced by a default nobody asked for.
  """

  @doc """
  An integer from the environment.

  `{:ok, default}` when the variable is unset or empty, `{:ok, n}` when it is
  a whole number within `range`, otherwise `{:error, message}`.
  """
  def integer(name, default, range \\ 0..2_147_483_647//1) do
    case System.get_env(name) do
      empty when empty in [nil, ""] ->
        {:ok, default}

      text ->
        case Integer.parse(String.trim(text)) do
          {n, ""} ->
            if n in range, do: {:ok, n}, else: {:error, "#{name} must be between #{range.first} and #{range.last}, got #{n}"}

          _ ->
            {:error, "#{name} is not a whole number: #{inspect(text)}"}
        end
    end
  end

  @doc "A non-negative number (integer or decimal) from the environment, same contract as `integer/3`."
  def number(name, default) do
    case System.get_env(name) do
      empty when empty in [nil, ""] ->
        {:ok, default}

      text ->
        trimmed = String.trim(text)

        parsed =
          case Integer.parse(trimmed) do
            {n, ""} ->
              {:ok, n}

            _ ->
              case Float.parse(trimmed) do
                {f, ""} -> {:ok, f}
                _ -> :error
              end
          end

        case parsed do
          {:ok, n} when n >= 0 -> {:ok, n}
          {:ok, n} -> {:error, "#{name} must not be negative, got #{n}"}
          :error -> {:error, "#{name} is not a number: #{inspect(text)}"}
        end
    end
  end

  @doc "Every numeric variable this process reads, checked once at startup. `:ok` or the first error."
  def check_all do
    checks = [
      integer("OMNIGATE_CONTROL_PORT", 4000, 1..65_535),
      number("OMNIGATE_AUDIT_MAX_MB", 50)
    ]

    Enum.find(checks, :ok, &match?({:error, _}, &1))
  end
end
