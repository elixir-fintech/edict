defmodule Edict.Schema.UserRole do
  @moduledoc """
  Ecto schema for the `edict_user_roles` table.

  Stores explicit role assignments: which user has which role on which entity.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "edict_user_roles" do
    field :user_id, :string
    field :entity_type, :string
    field :entity_id, :string
    field :role, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: String.t() | nil,
          entity_type: String.t() | nil,
          entity_id: String.t() | nil,
          role: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @required_fields ~w(user_id entity_type entity_id role)a

  @doc "Creates a changeset for a user role assignment."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(user_role, attrs) do
    user_role
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_length(:user_id, max: 255)
    |> validate_length(:entity_type, max: 255)
    |> validate_length(:entity_id, max: 255)
    |> validate_length(:role, max: 255)
  end
end
