defprotocol Edict.Entity do
  @moduledoc """
  Protocol for extracting entity identity from structs.

  Implementations are generated automatically by `Edict.Config` for entities
  that declare a `struct:` option. Implement manually for custom ID extraction.
  """

  @doc "Returns the entity ID as a string."
  @spec entity_id(t()) :: String.t()
  def entity_id(entity)

  @doc "Returns the entity type as an atom."
  @spec entity_type(t()) :: atom()
  def entity_type(entity)
end
