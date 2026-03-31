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
    on(:organization, actions: [:read, :write, :delete, :manage, :billing])
    on(:team, actions: [:read, :write, :delete, :manage])
    on(:project, actions: [:read, :write, :delete, :manage])
    on(:resource, actions: [:read, :write, :delete])
  end

  role :editor do
    on(:organization, actions: [:read, :write])
    on(:team, actions: [:read, :write])
    on(:project, actions: [:read, :write])
    on(:resource, actions: [:read, :write])
  end

  role :viewer do
    on(:organization, actions: [:read])
    on(:team, actions: [:read])
    on(:project, actions: [:read])
    on(:resource, actions: [:read])
  end

  role :billing_manager do
    on(:organization, actions: [:read, :billing])
  end
end
