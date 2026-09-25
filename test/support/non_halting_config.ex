defmodule Edict.Test.NonHaltingConfig do
  # Denial callbacks that forget to enforce: the Plug one sends a response
  # without halting, the LiveView one returns the socket without redirecting
  use Edict.Config

  user_from_assigns(fn assigns -> assigns.current_user.id end)

  on_unauthorized(fn
    %Plug.Conn{} = conn, _context ->
      Plug.Conn.send_resp(conn, 403, "Forbidden")

    %Phoenix.LiveView.Socket{} = socket, _context ->
      socket
  end)

  entity_types do
    entity(:project)
  end

  role :viewer do
    on(:project, actions: [:read])
  end
end
