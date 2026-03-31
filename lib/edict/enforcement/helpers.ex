defmodule Edict.Enforcement.Helpers do
  @moduledoc """
  Permission check functions.

  These read from the cached document in assigns — no cache or DB hit.
  Action resolution happens at check time using the config module.
  """

  alias Edict.Cache.Document

  @doc "Check permission using an entity struct (via Edict.Entity protocol)."
  @spec can?(Document.t(), atom(), struct(), module()) :: boolean()
  def can?(document, action, entity, config_module) when is_struct(entity) do
    entity_type = Edict.Entity.entity_type(entity)
    entity_id = Edict.Entity.entity_id(entity)
    can?(document, action, entity_type, entity_id, config_module)
  end

  @doc "Check permission using entity_type and entity_id directly."
  @spec can?(Document.t(), atom(), atom(), String.t(), module()) :: boolean()
  def can?(document, action, entity_type, entity_id, config_module) do
    entity_id = to_string(entity_id)
    roles = Document.roles_for(document, entity_type, entity_id)

    Enum.any?(roles, fn role ->
      action in config_module.actions_for(role, entity_type)
    end)
  end
end
