defmodule Edict.Plug do
  # Internal: the name Edict.Router wires, delegating to Edict.Enforcement.Plug.
  @moduledoc false

  @spec init(keyword() | map()) :: map()
  defdelegate init(opts), to: Edict.Enforcement.Plug

  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  defdelegate call(conn, opts), to: Edict.Enforcement.Plug
end
