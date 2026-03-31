defmodule Edict.Cache.Document do
  @moduledoc """
  The cached authorization document for a user.

  Stores the user's roles grouped by entity (type + ID).
  Actions are not resolved here — they are resolved at check time
  using the Config module.
  """

  defstruct [:user_id, :version, roles: %{}]

  @type t :: %__MODULE__{
          user_id: String.t(),
          version: non_neg_integer(),
          roles: %{{atom(), String.t()} => [atom()]}
        }

  @doc """
  Builds a document from a list of role assignment maps.

  Each map must have `:entity_type`, `:entity_id`, and `:role` keys (strings).
  """
  @spec new(String.t(), [map()], non_neg_integer()) :: t()
  def new(user_id, role_rows, version) do
    roles =
      role_rows
      |> Enum.group_by(
        fn row -> {String.to_existing_atom(row.entity_type), row.entity_id} end,
        fn row -> String.to_existing_atom(row.role) end
      )

    %__MODULE__{user_id: user_id, version: version, roles: roles}
  end

  @doc """
  Returns the roles a user has on a specific entity.
  """
  @spec roles_for(t(), atom(), String.t()) :: [atom()]
  def roles_for(%__MODULE__{roles: roles}, entity_type, entity_id) do
    Map.get(roles, {entity_type, entity_id}, [])
  end
end
