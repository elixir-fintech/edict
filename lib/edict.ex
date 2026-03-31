defmodule Edict do
  @moduledoc """
  Cached authorization for Phoenix applications.

  Edict maintains a per-user authorization document in an ETS-backed cache.
  Permission checks read from the cached document with sub-microsecond latency.

  ## Setup

      config :edict,
        config_module: MyApp.AuthConfig,
        repo: MyApp.Repo

      # application.ex
      children = [
        {Edict.Supervisor, pubsub: MyApp.PubSub},
      ]

  ## Usage

      Edict.assign_role(user_id, :admin, :organization, "42")
      Edict.can?(document, :read, @project)
  """

  alias Edict.Cache.{Document, Store}
  alias Edict.Enforcement.Helpers

  # --- Role Management ---

  @doc "Assigns a role to a user on an entity."
  @spec assign_role(String.t(), atom(), atom(), String.t()) :: {:ok, Edict.Schema.UserRole.t()} | {:error, atom()}
  def assign_role(user_id, role, entity_type, entity_id) do
    Edict.Core.assign_role(config(), user_id, role, entity_type, entity_id)
  end

  @doc "Revokes a specific role from a user on an entity."
  @spec revoke_role(String.t(), atom(), atom(), String.t()) :: {:ok, :revoked | :not_found}
  def revoke_role(user_id, role, entity_type, entity_id) do
    Edict.Core.revoke_role(config(), user_id, role, entity_type, entity_id)
  end

  @doc "Revokes all roles for a user on a specific entity."
  @spec revoke_all_roles(String.t(), atom(), String.t()) :: {:ok, non_neg_integer()}
  def revoke_all_roles(user_id, entity_type, entity_id) do
    Edict.Core.revoke_all_roles(config(), user_id, entity_type, entity_id)
  end

  @doc "Revokes all roles on an entity for all users."
  @spec revoke_entity(atom(), String.t()) :: {:ok, non_neg_integer()}
  def revoke_entity(entity_type, entity_id) do
    Edict.Core.revoke_entity(config(), entity_type, entity_id)
  end

  @doc "Lists all role assignments for a user."
  @spec list_roles(String.t()) :: [Edict.Schema.UserRole.t()]
  def list_roles(user_id) do
    Edict.Core.list_roles(config(), user_id)
  end

  @doc "Assigns a role to a user across multiple entities."
  @spec assign_roles(String.t(), atom(), [{atom(), String.t()}]) :: {:ok, [Edict.Schema.UserRole.t()]} | {:error, atom()}
  def assign_roles(user_id, role, entities) do
    Edict.Core.assign_roles(config(), user_id, role, entities)
  end

  # --- Permission Checks ---

  @doc "Check permission using an entity struct (via Edict.Entity protocol)."
  @spec can?(Document.t(), atom(), struct()) :: boolean()
  def can?(document, action, entity) when is_struct(entity) do
    Helpers.can?(document, action, entity, config_module())
  end

  @doc "Check permission using entity_type and entity_id directly."
  @spec can?(Document.t(), atom(), atom(), String.t()) :: boolean()
  def can?(document, action, entity_type, entity_id) do
    Helpers.can?(document, action, entity_type, entity_id, config_module())
  end

  # --- Document Loading ---

  @doc """
  Loads (or rebuilds) the authorization document for a user.

  Returns the cached document if fresh, or rebuilds from DB if stale/missing.
  """
  @spec load_document(String.t()) :: Document.t()
  def load_document(user_id) do
    user_id = to_string(user_id)
    cache = cache_name()

    case Store.get_document(cache, user_id) do
      {:ok, doc} ->
        {:ok, current_version} = Store.get_version(cache, user_id)

        if doc.version == current_version do
          doc
        else
          rebuild_document(user_id)
        end

      :miss ->
        rebuild_document(user_id)
    end
  end

  defp rebuild_document(user_id) do
    conf = config()
    roles = Edict.Core.list_roles(conf, user_id)
    {:ok, version} = Store.get_version(conf.cache, user_id)

    version = if version == 0, do: 1, else: version
    if version == 1, do: Store.set_version(conf.cache, user_id, 1)

    role_maps =
      Enum.map(roles, fn r ->
        %{entity_type: r.entity_type, entity_id: r.entity_id, role: r.role}
      end)

    doc = Document.new(user_id, role_maps, version)
    Store.put_document(conf.cache, user_id, doc)
    doc
  end

  defp config do
    %{
      repo: Application.fetch_env!(:edict, :repo),
      cache: cache_name(),
      pubsub: Application.fetch_env!(:edict, :pubsub),
      topic: Application.get_env(:edict, :topic, "edict:versions"),
      config_module: config_module()
    }
  end

  defp config_module, do: Application.fetch_env!(:edict, :config_module)

  @doc false
  def cache_name, do: Application.get_env(:edict, :cache, :edict_cache)
end
