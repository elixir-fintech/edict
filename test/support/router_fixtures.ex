defmodule Edict.Test.EchoPlug do
  @moduledoc """
  Sends a plain 200; routes in the router features point here.
  """

  def init(opts), do: opts

  def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "ok")
end

defmodule Edict.Test.RouterLive do
  @moduledoc """
  Minimal LiveView for live route features.
  """

  use Phoenix.LiveView

  def render(assigns), do: ~H""
end
