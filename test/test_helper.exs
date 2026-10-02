{:ok, _} = Edict.Test.Repo.start_link()

# Run migrations
Ecto.Migrator.up(Edict.Test.Repo, 0, Edict.Test.Migrations, log: false)
Ecto.Migrator.up(Edict.Test.Repo, 1, Edict.Test.NotBlankConstraintsMigration, log: false)

Ecto.Adapters.SQL.Sandbox.mode(Edict.Test.Repo, :manual)

ExUnit.start()
