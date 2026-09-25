defmodule Edict.Enforcement.LiveView do
  @moduledoc """
  LiveView `on_mount` hook that enforces authorization.

  Loads the authorization document from cache, checks permissions,
  and subscribes to PubSub for version bump notifications.

  ## Usage

      on_mount {Edict.Enforcement.LiveView,
        action: :read,
        entity_type: :project,
        param: "id"}

  ## Options

    * `:action` — the action atom to check (e.g., `:read`, `:write`)
    * `:entity_type` — the entity type atom (e.g., `:project`)
    * `:param` — the name of the route param holding the entity ID (e.g., `"id"`)
    * `:entity_from` — used when `:param` is not given: a function `(params -> entity_id)`.
      Must be a remote capture (`&MyModule.fun/1`), since `on_mount` options are
      stored at compile time and anonymous functions cannot be
    * `:edict_config` — (optional) override config map. Defaults to app env via `Edict.config/0`

  A missing param yields no entity ID, so the check fails and the user is unauthorized.

  Strong actions (see `Edict.Config.strong_actions/1`) are always checked against
  the database. The `:strong` option is rejected: only `Edict.can?` may opt out.

  Missing `:action`, `:entity_type`, or both `:param` and `:entity_from` raise
  `ArgumentError` on mount, before any cache or DB access.

  After mount, every version bump for the user re-runs the same check against
  the user's roles read from the database, not the cache. If it
  fails, `on_unauthorized` is called and must redirect the socket; if it does
  not, the LiveView raises so the client remounts and is denied.

  The re-check runs only when this node receives the version bump. A node that
  missed it keeps the LiveView open, even for a strong action, so guard every
  event that performs a strong action with `Edict.Enforcement.Authorize`.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Edict.Cache.Document
  alias Edict.Enforcement.Helpers

  def on_mount(opts, params, _session, socket) do
    opts = Map.new(opts)
    Helpers.validate_enforcement_opts!(opts, "Edict.LiveView")
    edict_config = opts[:edict_config] || socket.assigns[:edict_config] || Edict.config()
    user_id = edict_config.config_module.user_id_from_assigns(socket.assigns) |> to_string()

    policy = {opts.action, opts.entity_type, entity_id(opts, params)}

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

  defp authorize(socket, edict_config, document, {action, entity_type, entity_id}) do
    config_module = edict_config.config_module

    if Helpers.authorized?(edict_config, document, action, entity_type, entity_id, []) do
      {:cont, assign(socket, :current_user_roles, document)}
    else
      {:halt, config_module.on_unauthorized().(socket, %{})}
    end
  end

  defp maybe_subscribe(socket, edict_config, user_id) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(edict_config.pubsub, "edict:user:#{user_id}")
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
        |> ensure_redirected()

      _msg, socket ->
        {:cont, socket}
    end)
  end

  # LiveView stops on a redirect. Without one the user would keep the page,
  # so fail closed: the crash makes the client remount, which is denied.
  defp ensure_redirected({:halt, %{redirected: nil}}) do
    raise "on_unauthorized must redirect the LiveView socket when access is revoked"
  end

  defp ensure_redirected(result), do: result
end
