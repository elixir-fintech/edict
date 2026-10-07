defmodule Edict.Test.Config do
  use Edict.Config

  user_from_assigns(fn assigns -> assigns.current_user.id end)

  on_unauthorized(fn
    %Plug.Conn{} = conn, _context ->
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(403, "Forbidden")
      |> Plug.Conn.halt()

    %Phoenix.LiveView.Socket{} = socket, _context ->
      Phoenix.LiveView.redirect(socket, to: "/unauthorized")
  end)

  entity_types do
    entity(:organization, struct: Edict.Test.Organization)
    entity(:team, struct: Edict.Test.Team)
    entity(:project, struct: Edict.Test.Project)
    entity(:resource, struct: Edict.Test.Resource, id_field: :uuid)
  end

  role :admin do
    on(:organization, permissions: [:read, :write, :delete, :manage, :billing])
    on(:team, permissions: [:read, :write, :delete, :manage])
    on(:project, permissions: [:read, :write, :delete, :manage])
    on(:resource, permissions: [:read, :write, :delete])
  end

  role :editor do
    on(:organization, permissions: [:read, :write])
    on(:team, permissions: [:read, :write])
    on(:project, permissions: [:read, :write])
    on(:resource, permissions: [:read, :write])
  end

  role :viewer do
    on(:organization, permissions: [:read])
    on(:team, permissions: [:read])
    on(:project, permissions: [:read])
    on(:resource, permissions: [:read])
  end

  role :billing_manager do
    on(:organization, permissions: [:read, :billing])
  end
end
