defmodule Edict.Enforcement.LiveView do
  # Internal: the mount hook Edict.Router installs in every live edict block.
  # Not a supported entry point; LiveViews are guarded by routing them in an
  # edict block.
  #
  # LiveView `on_mount` hook that enforces authorization.
  #
  # Loads the authorization document from the cache (rebuilding it if stale or
  # missing) and checks the permission. On a connected socket it first subscribes
  # to the user's version bumps, so none is missed while mounting. Strong permissions are checked against
  # the database. On success the document is assigned as `current_user_roles`,
  # which `Edict.Enforcement.Authorize` guards and `Edict.can?` read.
  #
  # ## Options
  #
  #   * `:permission` — the permission atom to check (e.g., `:read`, `:write`)
  #   * `:entity_type` — the entity type atom (e.g., `:project`)
  #   * `:param` — the name of the route param holding the entity ID (e.g., `"id"`)
  #   * `:entity_from` — used when `:param` is not given: a function `(params -> entity_id)`.
  #     Must be a remote capture (`&MyModule.fun/1`), since `on_mount` options are
  #     stored at compile time and anonymous functions cannot be
  #   * `:edict_config` — (optional) config map, mainly for tests. It falls back to
  #     `socket.assigns[:edict_config]`, then `Edict.config/0`, and is used for this
  #     mount check, its PubSub subscription and the re-checks after version bumps.
  #     `authorize` guards read only `socket.assigns[:edict_config]` and `Edict.can?`
  #     always uses `Edict.config/0`, so neither sees this option
  #
  # A missing param yields no entity ID, so the check fails and the user is unauthorized.
  # A permission the config does not define for the entity type raises `ArgumentError`
  # on mount, instead of silently denying.
  #
  # Strong permissions (see `Edict.Config.strong_permissions/1`) are always checked against
  # the database. The `:strong` option is rejected: only `Edict.can?` may opt out.
  #
  # Missing `:permission`, `:entity_type`, or both `:param` and `:entity_from` raise
  # `ArgumentError` on mount, before any cache or DB access.
  #
  # After mount, every version bump for the user re-runs the same check against
  # the user's roles read from the database, not the cache. If it
  # fails, `on_unauthorized` is called and must redirect the socket with
  # `redirect` or `push_navigate`; if it does not, or only uses `push_patch`, which
  # keeps this LiveView open, the LiveView raises so the client remounts and is
  # denied. When the check passes, the bump message stops here and never reaches
  # the view's own `handle_info/2`.
  #
  # The re-check runs only when this node receives the version bump. A node that
  # missed it keeps the LiveView open, even for a strong permission, so guard every
  # event that performs a strong permission with `Edict.Enforcement.Authorize`.
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias Edict.Cache.Document
  alias Edict.Enforcement.Helpers

  @doc """
  Checks the permission described by `opts` and attaches the version-bump hook.

  Returns `{:cont, socket}` with `current_user_roles` assigned, or `{:halt, socket}`
  from `on_unauthorized`, which must redirect: LiveView raises on a halted mount
  without a redirect.
  """
  @spec on_mount(keyword() | map(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_mount(opts, params, _session, socket) do
    opts = Map.new(opts)
    Helpers.validate_enforcement_opts!(opts, "Edict.LiveView")
    {edict_config, user_id} = Helpers.resolve(opts, socket.assigns)
    Helpers.validate_permission!(edict_config.config_module, opts.permission, opts.entity_type)

    policy = {opts.permission, opts.entity_type, entity_id(opts, params)}
    mount(socket, edict_config, user_id, policy)
  end

  defp mount(socket, edict_config, nil, _policy), do: unauthorized(socket, edict_config)

  defp mount(socket, edict_config, user_id, policy) do
    # Subscribe before loading: a revocation that lands while mounting then
    # waits in the mailbox for the version hook instead of being missed.
    socket = maybe_subscribe(socket, edict_config, user_id)
    document = Helpers.load_document(edict_config, user_id)

    case authorize(socket, edict_config, document, policy) do
      {:cont, socket} ->
        {:cont, attach_version_hook(socket, edict_config, user_id, policy)}

      halted ->
        halted
    end
  end

  defp entity_id(%{param: param}, params), do: params[param]
  defp entity_id(%{entity_from: entity_from}, params), do: entity_from.(params)

  defp authorize(socket, edict_config, document, {permission, entity_type, entity_id}) do
    if Helpers.authorized?(edict_config, document, permission, entity_type, entity_id, []) do
      {:cont, assign(socket, :current_user_roles, document)}
    else
      unauthorized(socket, edict_config)
    end
  end

  defp unauthorized(socket, edict_config) do
    {:halt, edict_config.config_module.on_unauthorized().(socket, %{})}
  end

  defp maybe_subscribe(socket, edict_config, user_id) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(edict_config.pubsub, Edict.Invalidator.user_topic(user_id))
    end

    socket
  end

  # Re-runs the mount policy on every version bump, so a LiveView whose
  # permission was revoked stops instead of staying open. The document comes
  # straight from the DB: on a remote node this bump can arrive before
  # PubSubListener has copied the new version into the cache, and a stale
  # document in socket assigns would never expire.
  defp attach_version_hook(socket, edict_config, user_id, policy) do
    Phoenix.LiveView.attach_hook(socket, :edict_version_bump, :handle_info, fn
      {:edict_version_bump, ^user_id, new_version}, socket ->
        document =
          Document.new(user_id, Edict.Core.list_roles(edict_config, user_id), new_version)

        socket
        |> authorize(edict_config, document, policy)
        |> consume_bump()

      _msg, socket ->
        {:cont, socket}
    end)
  end

  # The bump is Edict's own message: halt so it never reaches the view's
  # handle_info/2, which need not expect it.
  defp consume_bump({:cont, socket}), do: {:halt, socket}

  # LiveView stops on a redirect or push_navigate. Without one, or with a
  # push_patch that keeps this LiveView, the user would keep the page, so fail
  # closed: the crash makes the client remount, which is denied.
  defp consume_bump({:halt, %{redirected: nil}}), do: raise_not_redirected()
  defp consume_bump({:halt, %{redirected: {:live, :patch, _opts}}}), do: raise_not_redirected()
  defp consume_bump({:halt, _socket} = halted), do: halted

  defp raise_not_redirected do
    raise "on_unauthorized must redirect the LiveView socket when access is revoked " <>
            "(redirect or push_navigate; push_patch keeps the LiveView open)"
  end
end
