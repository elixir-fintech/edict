defmodule Edict.Test.NotBlankConstraintsMigration do
  use Ecto.Migration

  # Mirrors the constraints in priv/templates/create_user_roles.exs.eex.
  # Kept separate from Edict.Test.Migrations so databases that already
  # ran version 0 pick them up.
  def change do
    for column <- [:user_id, :entity_type, :entity_id, :role] do
      create(constraint(:user_roles, :"user_roles_#{column}_not_blank", check: "#{column} <> ''"))
    end
  end
end
