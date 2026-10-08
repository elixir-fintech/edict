defmodule Edict do
  @moduledoc """
  Cached authorization for Phoenix applications.

  Edict maintains a per-user authorization document in an ETS-backed cache.
  Permission checks read the cached document without a database query; a stale
  or missing document is rebuilt from the database, and strong permissions (see
  `Edict.Config.strong_permissions/1`) are checked against it unless a display
  check opts out. Documents are automatically invalidated when roles change, with
  cross-node support via Phoenix.PubSub.

  ## Setup

      # config/config.exs
      config :edict,
        config_module: MyApp.AuthConfig,
        repo: MyApp.Repo,
        pubsub: MyApp.PubSub

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        {Phoenix.PubSub, name: MyApp.PubSub},
        Edict.Supervisor,
        MyAppWeb.Endpoint
      ]

  ## Role management

      Edict.assign_role(user_id, :admin, :organization, "42")
      Edict.revoke_role(user_id, :admin, :organization, "42")
      Edict.assign_roles(user_id, :admin, [{:organization, "42"}, {:project, "7"}])

  Writes return `{:error, :invalid_role}` for a role and
  `{:error, :invalid_entity_type}` for an entity type the config does not
  define, and raise
  `ArgumentError` when called inside a transaction: use `Edict.Multi` there.

  ## Permission checks

      doc = Edict.load_document(user_id)
      Edict.can?(doc, :read, @project)          # via Edict.Entity protocol
      Edict.can?(doc, :read, :project, "7")      # raw type + id
      Edict.can?(doc, :approve_transfer, @account, strong: false)  # cached, for display

  In Plug and LiveView, the document is loaded automatically into
  `assigns.current_user_roles` — use `can?/3` or `can?/4` directly in templates.

  ## Key modules

  - `Edict.Config` — DSL for defining entity types, roles, and permissions
  - `Edict.Plug` — controller-level authorization
  - `Edict.LiveView` — LiveView on_mount authorization
  - `Edict.Enforcement.Authorize` — per-event authorization (`handle_event` hook)
  - `Edict.Multi` — role changes inside an `Ecto.Multi`, invalidated after commit
  - `Edict.Supervisor` — starts the cache and the cross-node listener
  - `Edict.Entity` — protocol for extracting entity identity from structs
  - `Edict.TestHelpers` — test helpers for granting roles and asserting permissions
  """

  alias Edict.Cache.Document
  alias Edict.Enforcement.Helpers

  @type id :: String.t() | integer()

  # --- Role Management ---

  @doc "Assigns a role to a user on an entity."
  @spec assign_role(id(), atom(), atom(), id()) ::
          {:ok, Edict.Schema.UserRole.t() | :already_assigned}
          | {:error, atom() | Ecto.Changeset.t()}
  def assign_role(user_id, role, entity_type, entity_id) do
    conf = write_config!()

    with :ok <- validate(conf, role, entity_type) do
      Edict.Core.assign_role(
        conf,
        to_string(user_id),
        to_string(role),
        to_string(entity_type),
        to_string(entity_id)
      )
    end
  end

  @doc "Revokes a specific role from a user on an entity."
  @spec revoke_role(id(), atom(), atom(), id()) ::
          {:ok, :revoked | :not_found} | {:error, atom()}
  def revoke_role(user_id, role, entity_type, entity_id) do
    conf = write_config!()

    with :ok <- validate(conf, role, entity_type) do
      Edict.Core.revoke_role(
        conf,
        to_string(user_id),
        to_string(role),
        to_string(entity_type),
        to_string(entity_id)
      )
    end
  end

  @doc "Revokes all roles for a user on a specific entity."
  @spec revoke_all_roles(id(), atom(), id()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def revoke_all_roles(user_id, entity_type, entity_id) do
    conf = write_config!()

    with :ok <- validate_entity_type(conf, entity_type) do
      Edict.Core.revoke_all_roles(
        conf,
        to_string(user_id),
        to_string(entity_type),
        to_string(entity_id)
      )
    end
  end

  @doc "Revokes all roles on an entity for all users."
  @spec revoke_entity(atom(), id()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def revoke_entity(entity_type, entity_id) do
    conf = write_config!()

    with :ok <- validate_entity_type(conf, entity_type) do
      Edict.Core.revoke_entity(conf, to_string(entity_type), to_string(entity_id))
    end
  end

  @doc "Lists all role assignments for a user."
  @spec list_roles(id()) :: [Edict.Schema.UserRole.t()]
  def list_roles(user_id) do
    Edict.Core.list_roles(config(), to_string(user_id))
  end

  @doc """
  Assigns a role to a user across multiple entities.

  Returns only the newly inserted assignments: entities the user already has
  the role on are skipped. Nothing is inserted if any entry is invalid.
  """
  @spec assign_roles(id(), atom(), [{atom(), id()}]) ::
          {:ok, [Edict.Schema.UserRole.t()]} | {:error, atom() | Ecto.Changeset.t()}
  def assign_roles(user_id, role, entities) do
    conf = write_config!()

    with :ok <- validate_role(conf, role),
         :ok <- validate_entity_types(conf, entities) do
      string_entities = Enum.map(entities, fn {et, eid} -> {to_string(et), to_string(eid)} end)
      Edict.Core.assign_roles(conf, to_string(user_id), to_string(role), string_entities)
    end
  end

  # Role writes invalidate the cache as soon as they run. Inside a transaction
  # that would happen before the commit, so atomic changes go through Edict.Multi.
  defp write_config! do
    conf = config()

    if conf.repo.in_transaction?() do
      raise ArgumentError,
            "Edict role writes cannot run inside a transaction. " <>
              "Use Edict.Multi to change roles atomically."
    end

    conf
  end

  @doc false
  def validate(config, role, entity_type) do
    cm = config.config_module

    cond do
      not cm.valid_role?(role) -> {:error, :invalid_role}
      not cm.valid_entity_type?(entity_type) -> {:error, :invalid_entity_type}
      true -> :ok
    end
  end

  defp validate_role(config, role) do
    if config.config_module.valid_role?(role), do: :ok, else: {:error, :invalid_role}
  end

  defp validate_entity_type(config, entity_type) do
    if config.config_module.valid_entity_type?(entity_type),
      do: :ok,
      else: {:error, :invalid_entity_type}
  end

  defp validate_entity_types(config, entities) do
    cm = config.config_module
    invalid? = Enum.any?(entities, fn {et, _} -> not cm.valid_entity_type?(et) end)
    if invalid?, do: {:error, :invalid_entity_type}, else: :ok
  end

  # --- Permission Checks ---

  @doc """
  Check permission using an entity struct (via Edict.Entity protocol).

  Strong permissions are checked against the database. Pass `strong: false` to
  check the document instead, for example to show or hide a button.
  """
  @spec can?(Document.t(), atom(), struct()) :: boolean()
  def can?(document, permission, entity) when is_struct(entity),
    do: can?(document, permission, entity, [])

  @doc """
  Check permission with an entity struct and options, or with a raw entity
  type and ID.

  Only a non-empty string or an integer is an entity ID; anything else, such as
  `nil` or an array request param, is denied. Options passed where the entity
  ID belongs raise `ArgumentError`.
  """
  @spec can?(Document.t(), atom(), struct(), keyword()) :: boolean()
  @spec can?(Document.t(), atom(), atom(), term()) :: boolean()
  def can?(document, permission, entity, opts) when is_struct(entity) and is_list(opts) do
    entity_type = Edict.Entity.entity_type(entity)
    entity_id = Edict.Entity.entity_id(entity)
    can?(document, permission, entity_type, entity_id, opts)
  end

  # A keyword list here is options passed in place of the entity ID. A request
  # param is never a list with atom keys, so an array param still reaches the
  # clause below and is denied.
  def can?(_document, _permission, entity_type, [{key, _value} | _])
      when is_atom(entity_type) and is_atom(key) do
    raise ArgumentError,
          "Edict.can?/4 got options where the entity ID belongs; " <>
            "pass the entity ID, then options"
  end

  def can?(document, permission, entity_type, entity_id) when is_atom(entity_type),
    do: can?(document, permission, entity_type, entity_id, [])

  @doc """
  Check permission using entity_type and entity_id directly, with options.

  The only option is `strong: false`, which checks a strong permission against the
  document instead of the database; other options are ignored, and any other
  `:strong` value raises
  `ArgumentError`. Unlike `Edict.Plug`, `Edict.LiveView` and `authorize`,
  `can?` does not validate the permission: a permission the entity type does
  not define simply returns `false`.
  """
  @spec can?(Document.t(), atom(), atom(), term(), keyword()) :: boolean()
  def can?(document, permission, entity_type, entity_id, opts) do
    Helpers.authorized?(config(), document, permission, entity_type, entity_id, opts)
  end

  # --- Document Loading ---

  @doc """
  Loads (or rebuilds) the authorization document for a user.

  Returns the cached document if fresh, or rebuilds from DB if stale/missing.
  If the cache is unavailable, builds the document from the DB without caching
  it, emits `[:edict, :cache, :unavailable]` telemetry and logs an error.
  """
  @spec load_document(id()) :: Document.t()
  def load_document(user_id) do
    Helpers.load_document(config(), to_string(user_id))
  end

  # --- Config Validation ---

  @doc """
  Validates that a config module implements all required callbacks.

  Raises `ArgumentError` if any required function is missing.
  """
  @spec validate_config!(module()) :: :ok
  def validate_config!(config_module) do
    Code.ensure_loaded!(config_module)

    required_functions = [
      {:entity_types, 0},
      {:valid_entity_type?, 1},
      {:valid_role?, 1},
      {:valid_permission?, 2},
      {:permissions_for, 2},
      {:strong_permission?, 2},
      {:user_id_from_assigns, 1},
      {:on_unauthorized, 0}
    ]

    missing =
      Enum.reject(required_functions, fn {fun, arity} ->
        function_exported?(config_module, fun, arity)
      end)

    unless missing == [] do
      formatted = Enum.map_join(missing, ", ", fn {f, a} -> "#{f}/#{a}" end)

      raise ArgumentError,
            "#{inspect(config_module)} is missing required functions: #{formatted}"
    end

    :ok
  end

  @doc """
  Returns Edict's settings from the `:edict` app config.

  `:repo`, `:pubsub` and `:config_module` are required; `:cache` defaults to
  `:edict_cache` and `:topic` to `"edict:versions"`.
  """
  @spec config() :: %{
          repo: module(),
          cache: atom(),
          pubsub: atom(),
          topic: String.t(),
          config_module: module()
        }
  def config do
    %{
      repo: Application.fetch_env!(:edict, :repo),
      cache: cache_name(),
      pubsub: Application.fetch_env!(:edict, :pubsub),
      topic: Application.get_env(:edict, :topic, "edict:versions"),
      config_module: Application.fetch_env!(:edict, :config_module)
    }
  end

  @doc false
  def cache_name, do: Application.get_env(:edict, :cache, :edict_cache)
end
