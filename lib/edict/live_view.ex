defmodule Edict.LiveView do
  # Internal: the name Edict.Router wires, delegating to Edict.Enforcement.LiveView.
  @moduledoc false

  @spec on_mount(keyword() | map(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  defdelegate on_mount(opts, params, session, socket), to: Edict.Enforcement.LiveView
end
