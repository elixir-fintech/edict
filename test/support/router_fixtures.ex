defmodule Edict.Test.EchoPlug do
  @moduledoc """
  Sends a plain 200; routes in the router features point here.
  """

  def init(opts), do: opts

  def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "ok")
end

defmodule Edict.Test.EntityIds do
  @moduledoc """
  A resolver for `entity_from:` router scenarios: block options need a
  remote capture of a real function.
  """

  def project_id(conn), do: conn.params["project_id"]
end

defmodule Edict.Test.Identify do
  @moduledoc """
  Test auth plug: assigns `current_user` from the `x-test-user` header, the
  way an app's pipeline would after real authentication.
  """

  def init(opts), do: opts

  def call(conn, _opts) do
    [user | _] = Plug.Conn.get_req_header(conn, "x-test-user")
    Plug.Conn.assign(conn, :current_user, %{id: user})
  end
end

defmodule Edict.Test.SessionUser do
  @moduledoc """
  Test auth `on_mount`: puts `current_user` on the socket before Edict's
  mount hook runs, the way an app's live_session hook would.
  """

  def on_mount(_arg, _params, _session, socket) do
    {:cont, Phoenix.Component.assign_new(socket, :current_user, fn -> %{id: "alice"} end)}
  end
end

defmodule Edict.Test.RouterLive do
  @moduledoc """
  Minimal LiveView for live route features. Views routed in an `edict`
  block must use `Edict.Enforcement.Authorize`; this one handles no events.
  """

  use Phoenix.LiveView
  use Edict.Enforcement.Authorize

  def render(assigns), do: ~H""
end

defmodule Edict.Test.Endpoint do
  @moduledoc """
  Minimal Phoenix endpoint: live routes need one to complete their initial
  render. Configured under `config :edict, Edict.Test.Endpoint`.

  For `Phoenix.LiveViewTest` scenarios it also serves the LiveView socket
  and dispatches each request to the router the scenario compiled, which the
  conn carries in `conn.private[:edict_test_router]`.
  """

  use Phoenix.Endpoint, otp_app: :edict

  socket "/live", Phoenix.LiveView.Socket

  plug :dispatch

  def dispatch(conn, _opts) do
    router = conn.private.edict_test_router
    router.call(conn, router.init([]))
  end
end
