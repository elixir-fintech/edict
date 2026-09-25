defmodule Edict.Enforcement.Plug do
  @moduledoc """
  A Plug that enforces authorization by checking cached permissions.

  Extracts the user ID from assigns, loads the authorization document from
  cache (rebuilding if stale or missing), and checks the requested action.

  ## Options

    * `:action` — the action atom to check (e.g., `:read`, `:write`)
    * `:entity_type` — the entity type atom (e.g., `:project`)
    * `:param` — the name of the request param holding the entity ID (e.g., `"project_id"`)
    * `:entity_from` — used when `:param` is not given: a function `(conn -> entity_id)`.
      Must be a remote capture (`&MyModule.fun/1`), since plug options are stored
      at compile time and anonymous functions cannot be
    * `:edict_config` — (optional) override config map. Defaults to app env via `Edict.config/0`

  A missing param yields no entity ID, so the check fails and the request is unauthorized.

  Strong actions (see `Edict.Config.strong_actions/1`) are always checked against
  the database. The `:strong` option is rejected: only `Edict.can?` may opt out.

  Missing `:action`, `:entity_type`, or both `:param` and `:entity_from` raise
  `ArgumentError` when the plug is initialized, so a pipeline fails at compile time.
  An action the config does not define for the entity type raises `ArgumentError`
  on the request, instead of silently denying it.

  The connection is always halted on denial, even if `on_unauthorized` does not halt it.
  """

  @behaviour Plug

  alias Edict.Enforcement.Helpers

  @impl Plug
  def init(opts) when is_list(opts), do: opts |> Map.new() |> init()

  def init(opts) when is_map(opts) do
    Helpers.validate_enforcement_opts!(opts, "Edict.Plug")
    opts
  end

  @impl Plug
  def call(conn, opts) do
    {edict_config, user_id} = Helpers.resolve(opts, conn.assigns)
    entity_type = opts.entity_type
    Helpers.validate_action!(edict_config.config_module, opts.action, entity_type)
    entity_id = entity_id(opts, conn)

    document = Helpers.load_document(edict_config, user_id)

    if Helpers.authorized?(edict_config, document, opts.action, entity_type, entity_id, []) do
      Plug.Conn.assign(conn, :current_user_roles, document)
    else
      unauthorized(conn, edict_config.config_module)
    end
  end

  defp entity_id(%{param: param}, conn), do: conn.params[param]
  defp entity_id(%{entity_from: entity_from}, conn), do: entity_from.(conn)

  # Halt regardless of the callback: it shapes the response, not whether
  # enforcement happens.
  defp unauthorized(conn, config_module) do
    config_module.on_unauthorized().(conn, %{})
    |> Plug.Conn.halt()
  end
end
