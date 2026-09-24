defmodule Edict.Plug do
  @moduledoc """
  Convenience alias for `Edict.Enforcement.Plug`.

  ## Usage

      plug Edict.Plug,
        action: :manage,
        entity_type: :project,
        param: "project_id"
  """

  defdelegate init(opts), to: Edict.Enforcement.Plug
  defdelegate call(conn, opts), to: Edict.Enforcement.Plug
end
