defmodule Edict.Enforcement.Helpers do
  @moduledoc """
  Permission check functions.

  `can?/4` and `can?/5` read only the given document: no cache or DB hit.
  `authorized?/6` is what enforcement and `Edict.can?` use. It checks strong
  actions against the DB and everything else against the document. Action resolution happens
  at check time using the config module.
  """

  require Logger

  # Lists and maps (array or nested request params) must never be joined by
  # to_string/1 into another entity's ID, so only scalars are entity IDs.
  defguardp is_entity_id(entity_id)
            when (is_binary(entity_id) and entity_id != "") or is_integer(entity_id)

  alias Edict.Cache.{Document, Store}

  @doc """
  Loads (or rebuilds) the authorization document for a user from cache.

  Returns the cached document if fresh, or rebuilds from DB if stale/missing.
  If the cache is unavailable, builds the document from DB without caching it,
  emits `[:edict, :cache, :unavailable]` telemetry and logs an error.
  """
  @spec load_document(map(), String.t()) :: Document.t()
  def load_document(config, user_id) do
    case cached_document(config.cache, user_id) do
      {:ok, doc} -> doc
      :stale -> rebuild_document(config, user_id)
      {:error, reason} -> build_from_db(config, user_id, reason)
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

      {:error, reason} ->
        build_from_db(config, user_id, reason)
    end
  end

  # Freshness can't be established without the cache, so the DB is the only
  # source. The document is not cached, and its unique version never matches
  # a stored one.
  defp build_from_db(config, user_id, reason) do
    report_unavailable(user_id, reason)
    Document.new(user_id, Edict.Core.list_roles(config, user_id), make_ref())
  end

  defp report_unavailable(user_id, reason) do
    :telemetry.execute([:edict, :cache, :unavailable], %{count: 1}, %{
      user_id: user_id,
      reason: reason
    })

    Logger.error(
      "Edict cache unavailable (#{inspect(reason)}); authorizing user #{user_id} from the database"
    )
  end

  @doc """
  Checks a permission, reading the DB for strong actions.

  A strong action (`strong_action?/1` on the config module) is checked
  against the user's current rows for the entity, never against the cache,
  unless `opts` contains `strong: false`. Every other action is checked
  against `document`. Only a non-empty string or an integer is an entity ID;
  anything else is denied without a DB query. A `nil` document is accepted only
  for such an invalid ID; with a valid one it raises `ArgumentError`, so a
  missing `current_user_roles` never grants.
  """
  @spec authorized?(map(), Document.t() | nil, atom(), atom(), term(), Enumerable.t()) ::
          boolean()
  def authorized?(_edict_config, nil, action, entity_type, entity_id, _opts)
      when is_entity_id(entity_id) do
    raise ArgumentError,
          "cannot check #{inspect(action)} on #{inspect(entity_type)} #{inspect(entity_id)} " <>
            "without an authorization document: current_user_roles is not assigned. " <>
            "Load it with Edict.Plug or on_mount {Edict.LiveView, ...}"
  end

  def authorized?(edict_config, document, action, entity_type, entity_id, opts) do
    opts = strong_opts!(opts)
    config_module = edict_config.config_module

    document =
      if strong_check?(config_module, action, entity_id, opts),
        do: fresh_document(edict_config, document.user_id, entity_type, entity_id),
        else: document

    can?(document, action, entity_type, entity_id, config_module)
  end

  @doc """
  Validates the `:strong` option and returns it as a keyword list.

  Returns `[]` when absent and `[strong: false]` when opting out. Raises
  `ArgumentError` for any other value: only the config makes an action strong.
  """
  @spec strong_opts!(Enumerable.t()) :: [] | [strong: false]
  def strong_opts!(opts) do
    case Enum.find(opts, &match?({:strong, _}, &1)) do
      nil ->
        []

      {:strong, false} ->
        [strong: false]

      {:strong, value} ->
        raise ArgumentError, "the :strong option only accepts false, got: #{inspect(value)}"
    end
  end

  @doc """
  Returns the Edict config for a check and the current user's ID.

  The config comes from `opts`, then `assigns`, then the app env. A blank user
  ID (`nil` or `""`) is returned as `nil`: there is no user to check, so the
  caller denies without loading a document.
  """
  @spec resolve(map(), map()) :: {map(), String.t() | nil}
  def resolve(opts, assigns) do
    edict_config = opts[:edict_config] || assigns[:edict_config] || Edict.config()
    user_id = edict_config.config_module.user_id_from_assigns(assigns) |> to_string()
    {edict_config, if(user_id == "", do: nil, else: user_id)}
  end

  @doc """
  Raises `ArgumentError` unless the config defines `action` for `entity_type`.

  A typo such as `:aprove` would otherwise deny every request silently.
  """
  @spec validate_action!(module(), atom(), atom()) :: :ok
  def validate_action!(config_module, action, entity_type) do
    unless config_module.valid_action?(action, entity_type) do
      raise ArgumentError,
            "unknown action #{inspect(action)} for entity type #{inspect(entity_type)}"
    end

    :ok
  end

  @doc """
  Raises `ArgumentError` unless `opts` contains every key in `keys`.

  A security declaration must be explicit: a default could silently guard
  the wrong action or resource.
  """
  @spec require_options!(Enumerable.t(), [atom()], String.t()) :: :ok
  def require_options!(opts, keys, owner) do
    case Enum.reject(keys, &has_option?(opts, &1)) do
      [] -> :ok
      [key | _] -> raise ArgumentError, "#{owner} requires the #{inspect(key)} option"
    end
  end

  @doc """
  Validates `Edict.Plug` and `Edict.LiveView` options up front.

  Requires `:action`, `:entity_type`, and `:param` or `:entity_from`, and
  rejects `:strong`.
  """
  @spec validate_enforcement_opts!(Enumerable.t(), String.t()) :: :ok
  def validate_enforcement_opts!(opts, owner) do
    reject_strong!(opts)
    require_options!(opts, [:action, :entity_type], owner)

    unless has_option?(opts, :param) or has_option?(opts, :entity_from) do
      raise ArgumentError, "#{owner} requires the :param or :entity_from option"
    end

    :ok
  end

  defp has_option?(opts, key), do: Enum.any?(opts, &match?({^key, _}, &1))

  @doc """
  Raises `ArgumentError` if `opts` contains `:strong`.

  Enforcement (Plug, LiveView mount, `authorize` events) always follows
  `strong_actions`; only `Edict.can?` may opt out, for display checks.
  """
  @spec reject_strong!(Enumerable.t()) :: :ok
  def reject_strong!(opts) do
    if has_option?(opts, :strong) do
      raise ArgumentError,
            "the :strong option is only accepted by Edict.can?; " <>
              "enforcement always follows strong_actions"
    end

    :ok
  end

  # An invalid entity ID is denied by can?/5, so it never needs a DB read.
  defp strong_check?(_config_module, _action, entity_id, _opts)
       when not is_entity_id(entity_id),
       do: false

  defp strong_check?(config_module, action, _entity_id, opts),
    do: config_module.strong_action?(action) and opts != [strong: false]

  # Only this entity's rows, straight from the DB: a strong check never trusts
  # the cache and never writes to it.
  defp fresh_document(edict_config, user_id, entity_type, entity_id) do
    rows =
      Edict.Core.list_entity_roles(
        edict_config,
        user_id,
        to_string(entity_type),
        to_string(entity_id)
      )

    Document.new(user_id, rows, make_ref())
  end

  @doc """
  Check permission using an entity struct (via Edict.Entity protocol).

  Reads only `document` and ignores strong actions; enforcement uses
  `authorized?/6`.
  """
  @spec can?(Document.t(), atom(), struct(), module()) :: boolean()
  def can?(document, action, entity, config_module) when is_struct(entity) do
    entity_type = Edict.Entity.entity_type(entity)
    entity_id = Edict.Entity.entity_id(entity)
    can?(document, action, entity_type, entity_id, config_module)
  end

  @doc """
  Check permission using entity_type and entity_id directly.

  Reads only `document` and ignores strong actions; enforcement uses
  `authorized?/6`. Only a non-empty string or an integer is an entity ID:
  anything else, such as `nil`, `""` or an array request param, is denied.
  """
  @spec can?(Document.t(), atom(), atom(), term(), module()) :: boolean()
  def can?(_document, _action, _entity_type, entity_id, _config_module)
      when not is_entity_id(entity_id),
      do: false

  def can?(document, action, entity_type, entity_id, config_module) do
    roles = Document.roles_for(document, entity_type, to_string(entity_id))

    Enum.any?(roles, fn role ->
      action in config_module.actions_for(role, entity_type)
    end)
  end
end
