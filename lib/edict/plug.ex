defmodule Edict.Plug do
  @moduledoc """
  Convenience alias for `Edict.Enforcement.Plug`.

  ## Usage

      plug Edict.Plug,
        permission: :manage,
        entity_type: :project,
        param: "project_id"
  """

  @doc "Validates the options; see `Edict.Enforcement.Plug` for them."
  @spec init(keyword() | map()) :: map()
  defdelegate init(opts), to: Edict.Enforcement.Plug

  @doc "Checks the permission; see `Edict.Enforcement.Plug`."
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  defdelegate call(conn, opts), to: Edict.Enforcement.Plug
end
