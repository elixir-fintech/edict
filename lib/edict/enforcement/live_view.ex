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
  """

  import Phoenix.Component, only: [assign: 3]

  alias Edict.Enforcement.Helpers

  def on_mount(opts, params, _session, socket) do
    opts = Map.new(opts)
    edict_config = opts[:edict_config] || socket.assigns[:edict_config] || Edict.config()
    config_module = edict_config.config_module
    user_id = config_module.user_id_from_assigns(socket.assigns) |> to_string()
    entity_type = opts.entity_type
    entity_id = entity_id(opts, params)

    document = Helpers.load_document(edict_config, user_id)

    if Helpers.can?(document, opts.action, entity_type, entity_id, config_module) do
      socket =
        socket
        |> assign(:current_user_roles, document)
        |> maybe_subscribe(edict_config, user_id)
        |> maybe_attach_hook(edict_config)

      {:cont, socket}
    else
      socket = config_module.on_unauthorized().(socket, %{})
      {:halt, socket}
    end
  end

  defp entity_id(%{param: param}, params), do: params[param]
  defp entity_id(%{entity_from: entity_from}, params), do: entity_from.(params)

  defp maybe_subscribe(socket, edict_config, user_id) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(edict_config.pubsub, "edict:user:#{user_id}")
    end

    socket
  end

  defp maybe_attach_hook(socket, edict_config) do
    Phoenix.LiveView.attach_hook(socket, :edict_version_bump, :handle_info, fn
      {:edict_version_bump, user_id, _new_version}, socket ->
        doc = Helpers.load_document(edict_config, user_id)
        {:cont, assign(socket, :current_user_roles, doc)}

      _msg, socket ->
        {:cont, socket}
    end)
  end
end
