defmodule Edict.LiveView do
  @moduledoc """
  Convenience alias for `Edict.Enforcement.LiveView`.

  ## Usage

      on_mount {Edict.LiveView,
        action: :read,
        entity_type: :project,
        param: "project_id"}
  """

  @doc "See `Edict.Enforcement.LiveView.on_mount/4`."
  @spec on_mount(keyword() | map(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  defdelegate on_mount(opts, params, session, socket), to: Edict.Enforcement.LiveView
end
