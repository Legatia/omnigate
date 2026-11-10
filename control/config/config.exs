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
    # Stands in for OMNIGATE_INTERNAL_TOKEN, which the control plane refuses
    # to start without. Tests that call /internal set the variable themselves.
    internal_token: "test-internal-token-from-app-env",
    media_dir: Path.join(System.tmp_dir!(), "omnigate-test-media-#{stamp}"),
    signing_secret: "test-signing-secret",
    admin_token: "test-admin-token-0123456789"
end
