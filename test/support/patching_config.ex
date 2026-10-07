defmodule Edict.Test.PatchingConfig do
  # A LiveView denial handler that patches instead of redirecting: the
  # LiveView stays open, so enforcement must not accept it.
  use Edict.Config

  user_from_assigns(fn assigns -> assigns.current_user.id end)

  on_unauthorized(fn
    %Plug.Conn{} = conn, _context ->
      Plug.Conn.send_resp(conn, 403, "Forbidden")

    %Phoenix.LiveView.Socket{} = socket, _context ->
      Phoenix.LiveView.push_patch(socket, to: "/projects")
  end)

  entity_types do
    entity(:project)
  end

  role :viewer do
    on(:project, permissions: [:read])
  end
end
