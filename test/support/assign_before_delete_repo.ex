defmodule Edict.Test.AssignBeforeDeleteRepo do
  # Simulates a concurrent assignment landing just before revoke_entity/3
  # deletes: every delete_all first assigns user-3 on organization 42.

  alias Edict.Schema.UserRole
  alias Edict.Test.Repo

  def delete_all(queryable, opts \\ []) do
    Repo.insert!(%UserRole{
      user_id: "user-3",
      entity_type: "organization",
      entity_id: "42",
      role: "viewer"
    })

    Repo.delete_all(queryable, opts)
  end
end
