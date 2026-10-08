defmodule Edict.Router.Declaration do
  @moduledoc """
  Stamps `conn.private[:edict]` with the router's declaration.

  Emitted by `Edict.Router` around live routes — whose check happens in
  `on_mount`, on the socket, not in a plug — and around `unguarded` blocks.
  A declaration is not a decision: when `Edict.Plug` runs it overwrites the
  stamp with its decision, and a present stamp simply marks the request as
  declared. Options are a keyword list, since plug options in `pipe_through`
  must survive `Macro.escape/1`.
  """

  @behaviour Plug

  @impl true
  def init(declaration), do: declaration

  @impl true
  def call(conn, declaration), do: Plug.Conn.put_private(conn, :edict, declaration)
end
