defmodule Edict.Cache.Document do
  @moduledoc """
  The cached authorization document for a user.

  Stores the user's roles grouped by entity (type + ID).
  Permissions are not resolved here — they are resolved at check time
  using the Config module.
  """

  defstruct [:user_id, :version, roles: %{}]

  @type t :: %__MODULE__{
          user_id: String.t(),
          version: Edict.Cache.Store.version(),
          roles: %{{atom(), String.t()} => [atom()]}
        }

  @doc """
  Builds a document from a list of role assignment maps.

  Each map must have `:entity_type`, `:entity_id`, and `:role` keys (strings).
  Rows whose entity type or role is not an existing atom are dropped, which is
  why `Edict.Supervisor` loads the config module at startup.
  """
  @spec new(String.t(), [map()], Edict.Cache.Store.version()) :: t()
  def new(user_id, role_rows, version) do
    roles =
      role_rows
      |> Enum.reduce(%{}, fn row, acc ->
        with {:ok, entity_type} <- safe_to_existing_atom(row.entity_type),
             {:ok, role} <- safe_to_existing_atom(row.role) do
          key = {entity_type, row.entity_id}
          Map.update(acc, key, [role], &[role | &1])
        else
          :error -> acc
        end
      end)
      |> Map.new(fn {key, roles} -> {key, Enum.reverse(roles)} end)

    %__MODULE__{user_id: user_id, version: version, roles: roles}
  end

  defp safe_to_existing_atom(str) when is_binary(str) do
    {:ok, String.to_existing_atom(str)}
  rescue
    ArgumentError -> :error
  end

  @doc """
  Returns the roles a user has on a specific entity.
  """
  @spec roles_for(t(), atom(), String.t()) :: [atom()]
  def roles_for(%__MODULE__{roles: roles}, entity_type, entity_id) do
    Map.get(roles, {entity_type, entity_id}, [])
  end
end
