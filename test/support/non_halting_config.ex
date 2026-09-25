defmodule Edict.Test.NonHaltingConfig do
  # A denial callback that sends a response but forgets to halt,
  # like a redirect built with Phoenix.Controller.redirect/2
  use Edict.Config

  user_from_assigns(fn assigns -> assigns.current_user.id end)

  on_unauthorized(fn
    %Plug.Conn{} = conn, _context ->
      Plug.Conn.send_resp(conn, 403, "Forbidden")

    %Phoenix.LiveView.Socket{} = socket, _context ->
      Phoenix.LiveView.redirect(socket, to: "/unauthorized")
  end)

  entity_types do
    entity(:project)
  end

  role :viewer do
    on(:project, actions: [:read])
  end
end
