import Config

# Tests get their own throwaway ledger and port so they never touch dev data
# or collide with a running dev instance.
if config_env() == :test do
  config :omnigate_control,
    port: 4999,
    ledger_path:
      Path.join(System.tmp_dir!(), "omnigate-test-ledger-#{System.os_time(:millisecond)}.jsonl")
end
