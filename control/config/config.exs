import Config

# Tests get their own throwaway ledger and port so they never touch dev data
# or collide with a running dev instance.
if config_env() == :test do
  stamp = System.os_time(:millisecond)

  config :omnigate_control,
    port: 4999,
    ledger_path: Path.join(System.tmp_dir!(), "omnigate-test-ledger-#{stamp}.jsonl"),
    jobs_path: Path.join(System.tmp_dir!(), "omnigate-test-jobs-#{stamp}.jsonl"),
    media_dir: Path.join(System.tmp_dir!(), "omnigate-test-media-#{stamp}"),
    signing_secret: "test-signing-secret"
end
