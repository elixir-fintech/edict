defmodule Edict.LiveView do
  @moduledoc """
  Convenience alias for `Edict.Enforcement.LiveView`.

  ## Usage

      on_mount {Edict.LiveView,
        action: :read,
        entity_type: :project,
        entity_from: &(&1["project_id"])}
  """

  defdelegate on_mount(opts, params, session, socket), to: Edict.Enforcement.LiveView
end
