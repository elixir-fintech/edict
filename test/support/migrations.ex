defmodule Edict.Test.Migrations do
  use Ecto.Migration

  def change do
    create table(:user_roles, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, :string, null: false)
      add(:entity_type, :string, null: false)
      add(:entity_id, :string, null: false)
      add(:role, :string, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:user_roles, [:user_id, :entity_type, :entity_id, :role]))
    create(index(:user_roles, [:user_id]))
    create(index(:user_roles, [:entity_type, :entity_id]))
  end
end
