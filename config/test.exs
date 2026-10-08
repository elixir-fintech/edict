import Config

config :edict, Edict.Test.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "edict_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :edict,
  ecto_repos: [Edict.Test.Repo]

config :edict, Edict.Test.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "edict-test-endpoint-secret-key-base-0123456789abcdef0123456789abcdef",
  live_view: [
    signing_salt: "edict-test-endpoint-live-view-signing-salt-0123456789"
  ]

config :logger, level: :warning
