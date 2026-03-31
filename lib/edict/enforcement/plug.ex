defmodule Edict.Enforcement.Plug do
  @moduledoc """
  A Plug that enforces authorization by checking cached permissions.

  Extracts the user ID from assigns, loads the authorization document from
  cache (rebuilding if stale or missing), and checks the requested action.

  ## Options

    * `:edict_config` — the Edict config map (or read from `conn.assigns[:edict_config]`)
    * `:action` — the action atom to check (e.g., `:read`, `:write`)
    * `:entity_type` — the entity type atom (e.g., `:project`)
    * `:entity_from` — a function `(conn -> entity_id)` to extract the entity ID from the conn
  """

  @behaviour Plug

  alias Edict.Cache.{Document, Store}
  alias Edict.Enforcement.Helpers

  @impl Plug
  def init(opts) when is_list(opts), do: Map.new(opts)
  def init(opts) when is_map(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    edict_config = opts[:edict_config] || conn.assigns[:edict_config]
    config_module = edict_config.config_module
    user_id = config_module.user_id_from_assigns(conn.assigns)
    entity_type = opts.entity_type
    entity_id = opts.entity_from.(conn)

    document = load_document(edict_config, user_id)

    if Helpers.can?(document, opts.action, entity_type, to_string(entity_id), config_module) do
      roles = Document.roles_for(document, entity_type, to_string(entity_id))

      conn
      |> Plug.Conn.assign(:edict_document, document)
      |> Plug.Conn.assign(:current_user_roles, roles)
    else
      unauthorized(conn, config_module)
    end
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

  defp rebuild_document(config, user_id) do
    role_rows = Edict.Core.list_roles(config, user_id)
    {:ok, version} = Store.get_version(config.cache, user_id)
    doc = Document.new(user_id, role_rows, version)
    Store.put_document(config.cache, user_id, doc)
    doc
  end

  defp unauthorized(conn, config_module) do
    config_module.on_unauthorized().(conn, %{})
  end
end
