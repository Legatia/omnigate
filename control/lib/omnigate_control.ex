defmodule OmnigateControl do
  @moduledoc """
  omnigate control plane.

  Source of truth for gateway keys, budgets, routes and the usage ledger.
  Zig data-plane nodes pull `GET /internal/config` and push
  `POST /internal/usage/batch`; this node computes spend and flips keys to
  `blocked` when they exceed their budget.
  """

  @doc """
  The secret data planes present on `/internal/*`: `OMNIGATE_INTERNAL_TOKEN`,
  or nil when it is unset or empty. (Tests may supply one through the
  application environment instead.)
  """
  def internal_token do
    case System.get_env("OMNIGATE_INTERNAL_TOKEN") do
      token when is_binary(token) and token != "" -> token
      _ -> Application.get_env(:omnigate_control, :internal_token)
    end
  end

  @doc "Lowercase hex SHA-256, matching the data plane's `sha256Hex`."
  def sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
