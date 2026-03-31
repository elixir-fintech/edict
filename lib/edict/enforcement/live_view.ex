defmodule Edict.Enforcement.LiveView do
  @moduledoc """
  LiveView `on_mount` hook that enforces authorization.

  Loads the authorization document from cache, checks permissions,
  and subscribes to PubSub for version bump notifications.

  ## Usage

      on_mount {Edict.Enforcement.LiveView, %{
        edict_config: @edict_config,
        action: :read,
        entity_type: :project,
        entity_from: fn params -> params["id"] end
      }}
  """

  import Phoenix.Component, only: [assign: 3]

  alias Edict.Cache.{Document, Store}
  alias Edict.Enforcement.Helpers

  def on_mount(opts, params, _session, socket) do
    edict_config = opts[:edict_config] || socket.assigns[:edict_config]
    config_module = edict_config.config_module
    user_id = config_module.user_id_from_assigns(socket.assigns)
    entity_type = opts.entity_type
    entity_id = opts.entity_from.(params)

    document = load_document(edict_config, user_id)

    if Helpers.can?(document, opts.action, entity_type, to_string(entity_id), config_module) do
      roles = Document.roles_for(document, entity_type, to_string(entity_id))

      socket =
        socket
        |> assign(:edict_document, document)
        |> assign(:current_user_roles, roles)

      socket = maybe_subscribe(socket, edict_config)
      socket = maybe_attach_hook(socket, edict_config)

      {:cont, socket}
    else
      socket = config_module.on_unauthorized().(socket, %{})
      {:halt, socket}
    end
  end

  defp maybe_subscribe(socket, edict_config) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(edict_config.pubsub, edict_config.topic)
    end

    socket
  rescue
    _ -> socket
  end

  defp maybe_attach_hook(socket, edict_config) do
    Phoenix.LiveView.attach_hook(socket, :edict_version_bump, :handle_info, fn
      {:edict_version_bump, user_id, _new_version}, socket ->
        config_module = edict_config.config_module
        current_user_id = config_module.user_id_from_assigns(socket.assigns)

        if user_id == current_user_id do
          doc = reload_document(edict_config, user_id)
          {:cont, assign(socket, :edict_document, doc)}
        else
          {:cont, socket}
        end
    end)
  rescue
    _ -> socket
  end

  defp load_document(config, user_id) do
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

  defp reload_document(config, user_id) do
    case Store.get_document(config.cache, user_id) do
      {:ok, doc} -> doc
      :miss -> rebuild_document(config, user_id)
    end
  end

  defp rebuild_document(config, user_id) do
    role_rows = Edict.Core.list_roles(config, user_id)
    {:ok, version} = Store.get_version(config.cache, user_id)
    doc = Document.new(user_id, role_rows, version)
    Store.put_document(config.cache, user_id, doc)
    doc
  end
end
