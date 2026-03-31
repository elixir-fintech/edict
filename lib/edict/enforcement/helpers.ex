defmodule Edict.Enforcement.Helpers do
  @moduledoc """
  Permission check functions.

  These read from the cached document in assigns — no cache or DB hit.
  Action resolution happens at check time using the config module.
  """

  alias Edict.Cache.{Document, Store}

  @doc """
  Loads (or rebuilds) the authorization document for a user from cache.

  Returns the cached document if fresh, or rebuilds from DB if stale/missing.
  """
  @spec load_document(map(), String.t()) :: Document.t()
  def load_document(config, user_id) do
    case Store.get_document(config.cache, user_id) do
      {:ok, doc} ->
        {:ok, current_version} = Store.get_version(config.cache, user_id)

        if doc.version == current_version do
          doc
        else
          rebuild_document(config, user_id)
        end

      :miss ->
        rebuild_document(config, user_id)
    end
  end

  defp rebuild_document(config, user_id) do
    role_rows = Edict.Core.list_roles(config, user_id)
    {:ok, version} = Store.get_version(config.cache, user_id)
    doc = Document.new(user_id, role_rows, version)
    Store.put_document(config.cache, user_id, doc)
    doc
  end

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
