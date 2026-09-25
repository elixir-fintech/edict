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
  If the cache is unavailable, builds the document from DB without caching it.
  """
  @spec load_document(map(), String.t()) :: Document.t()
  def load_document(config, user_id) do
    case cached_document(config.cache, user_id) do
      {:ok, doc} -> doc
      :stale -> rebuild_document(config, user_id)
      {:error, _reason} -> build_from_db(config, user_id)
    end
  end

  defp cached_document(cache, user_id) do
    with {:ok, doc} <- Store.get_document(cache, user_id),
         {:ok, version} <- Store.get_version(cache, user_id) do
      if doc.version == version, do: {:ok, doc}, else: :stale
    else
      :miss -> :stale
      error -> error
    end
  end

  # Read the version before the roles: a role change landing in between then
  # leaves this document tagged with the older version, so the next load
  # rebuilds instead of serving stale roles as current.
  defp rebuild_document(config, user_id) do
    case Store.get_version(config.cache, user_id) do
      {:ok, version} ->
        doc = Document.new(user_id, Edict.Core.list_roles(config, user_id), version)
        Store.put_document(config.cache, user_id, doc)
        doc

      {:error, _reason} ->
        build_from_db(config, user_id)
    end
  end

  # Freshness can't be established without the cache, so the DB is the only
  # source. The document is not cached, and its unique version never matches
  # a stored one.
  defp build_from_db(config, user_id) do
    Document.new(user_id, Edict.Core.list_roles(config, user_id), make_ref())
  end

  @doc "Check permission using an entity struct (via Edict.Entity protocol)."
  @spec can?(Document.t(), atom(), struct(), module()) :: boolean()
  def can?(document, action, entity, config_module) when is_struct(entity) do
    entity_type = Edict.Entity.entity_type(entity)
    entity_id = Edict.Entity.entity_id(entity)
    can?(document, action, entity_type, entity_id, config_module)
  end

  @doc """
  Check permission using entity_type and entity_id directly.

  A `nil` or blank entity ID, such as a missing request param, is always denied.
  """
  @spec can?(Document.t(), atom(), atom(), term(), module()) :: boolean()
  def can?(_document, _action, _entity_type, entity_id, _config_module)
      when entity_id in [nil, ""],
      do: false

  def can?(document, action, entity_type, entity_id, config_module) do
    roles = Document.roles_for(document, entity_type, to_string(entity_id))

    Enum.any?(roles, fn role ->
      action in config_module.actions_for(role, entity_type)
    end)
  end
end
