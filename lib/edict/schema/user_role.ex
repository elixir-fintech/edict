defmodule Edict.Schema.UserRole do
  @moduledoc """
  Ecto schema for the `user_roles` table.

  Stores explicit role assignments: which user has which role on which entity.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "user_roles" do
    field :user_id, :string
    field :entity_type, :string
    field :entity_id, :string
    field :role, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @required_fields ~w(user_id entity_type entity_id role)a

  @doc "Creates a changeset for a user role assignment."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(user_role, attrs) do
    user_role
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
  end
end
