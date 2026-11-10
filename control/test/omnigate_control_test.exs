defmodule OmnigateControlTest do
  use ExUnit.Case, async: true

  alias OmnigateControl.{ConfigStore, Ledger}

  test "sha256_hex matches the data plane's encoding" do
    assert OmnigateControl.sha256_hex("abc") ==
             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end

  test "cost uses per-million-token prices" do
    assert_in_delta Ledger.cost(1_000_000, 500_000, {3.0, 15.0}), 10.5, 1.0e-9
    assert Ledger.cost(0, 0, {3.0, 15.0}) == 0.0
  end

  test "normalize hashes raw keys and fills price defaults" do
    config =
      ConfigStore.normalize(%{
        "keys" => [%{"name" => "dev", "key" => "abc", "budget_usd" => 1}],
        "upstreams" => [
          %{"name" => "u", "kind" => "openai", "base_url" => "http://x", "api_key_env" => "K"}
        ],
        "routes" => [%{"model" => "m", "targets" => [%{"upstream" => "u", "model" => "real"}]}]
      })

    [key] = config.keys
    assert key.key_sha256 == OmnigateControl.sha256_hex("abc")
    assert key.budget_usd == 1.0
    refute Map.has_key?(key, :key)
    [%{targets: [target]}] = config.routes
    assert target.price_in_per_mtok == 0.0
  end
end
