import Config

# Tests get their own throwaway ledger and port so they never touch dev data
# or collide with a running dev instance.
if config_env() == :test do
  stamp = System.os_time(:millisecond)

  config :omnigate_control,
    port: 4999,
    ledger_path: Path.join(System.tmp_dir!(), "omnigate-test-ledger-#{stamp}.jsonl"),
    jobs_path: Path.join(System.tmp_dir!(), "omnigate-test-jobs-#{stamp}.jsonl"),
    keys_path: Path.join(System.tmp_dir!(), "omnigate-test-keys-#{stamp}.json"),
    audit_path: Path.join(System.tmp_dir!(), "omnigate-test-audit-#{stamp}.jsonl"),
    payments_path: Path.join(System.tmp_dir!(), "omnigate-test-payments-#{stamp}.json"),
    # Stands in for OMNIGATE_INTERNAL_TOKEN, which the control plane refuses
    # to start without. Tests that call /internal set the variable themselves.
    internal_token: "test-internal-token-from-app-env",
    media_dir: Path.join(System.tmp_dir!(), "omnigate-test-media-#{stamp}"),
    signing_secret: "test-signing-secret",
    admin_token: "test-admin-token-0123456789",
    # The suite sends wrong admin tokens on purpose, all from 127.0.0.1; the
    # lockout that follows would turn unrelated tests into 429s. The lockout
    # itself is tested with its own address and its own limit.
    bearer_max_failures: 1_000_000,
    # Compiles a route that raises, for the error-shape test.
    test_routes: true
end
