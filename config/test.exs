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

config :logger, level: :warning
