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
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # What the pipeline had produced by the time the sentinel ran: security
    # headers belong on the denial too, while anything added later came from
    # code that never passed an Edict decision.
    baseline = {conn.resp_headers, conn.resp_cookies}
    Plug.Conn.register_before_send(conn, &verify(&1, baseline))
  end

  # The stamp is set during the request, before any send, so this check sees
  # it regardless of callback ordering.
  defp verify(%Plug.Conn{private: %{edict: stamp}} = conn, _baseline) when not is_nil(stamp),
    do: conn

  # Rewrites the pending response instead of sending one: Plug runs this
  # callback while sending, so a send from here would recurse. Post-sentinel
  # headers and cookies are dropped — Plug merges response cookies after
  # these callbacks, so anything kept would still reach the client — while
  # the pipeline's own headers and cookies are restored from the baseline.
  defp verify(conn, {headers, cookies}) do
    conn
    |> reset_response(headers, cookies)
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.resp(403, "Forbidden")
    |> Plug.Conn.halt()
  end

  defp reset_response(conn, headers, cookies),
    do: %{conn | resp_headers: headers, resp_cookies: cookies}
end
