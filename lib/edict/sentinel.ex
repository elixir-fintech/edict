defmodule Edict.Sentinel do
  @moduledoc """
  Response-time defense in depth: requests with no Edict declaration are
  denied.

  The router compiler (`Edict.Router`) is the primary control. The sentinel
  covers what it cannot see: apps wiring `Edict.Plug` by hand without
  `Edict.Router`, and any dispatch that bypasses the router's `edict` blocks.

      pipeline :browser do
        ...
        plug Edict.Sentinel
      end

  `Edict.Plug` stamps `conn.private[:edict]` with its decision when it runs,
  and the router's declaration plugs stamp declared live and `unguarded`
  routes. In a `register_before_send/2` callback the sentinel verifies the
  stamp:

    * stamp present → pass through; a declared-but-denied request keeps the
      denial `Edict.Plug` already produced (the stamp records the decision)
    * stamp absent → the pending response is replaced with a `403`
      `text/plain` "Forbidden" and the conn is halted

  Sentinel denials do not use the config's `on_unauthorized`: a
  `before_send` callback may only change the pending response, never send
  one, and the handlers send. Calling one there would re-enter the
  `before_send` chain without end.

  **Honest limitation:** a sentinel denial happens at response time, so for
  manually-wired apps it blocks the *response*, not the handler's side
  effects. That is acceptable only because it is the second line; the
  compiler is the first. Apps that use `Edict.Router` get the strong
  guarantee.
  """

  @behaviour Plug

  @impl true
  def init(opts) when is_list(opts), do: Map.new(opts)

  @impl true
  def call(conn, _opts) do
    Plug.Conn.register_before_send(conn, &verify/1)
  end

  # before_send callbacks run in reverse registration order, and the sentinel
  # registers in a pipeline, before any per-route guard runs — so the stamp is
  # in place by the time this verifies it.
  defp verify(%Plug.Conn{private: %{edict: stamp}} = conn) when not is_nil(stamp), do: conn

  # Rewrites the pending response instead of sending one: Plug runs this
  # callback while sending, so a send from here would recurse.
  defp verify(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.resp(403, "Forbidden")
    |> Plug.Conn.halt()
  end
end
