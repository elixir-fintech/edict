defmodule Edict.Features.StepDefinitions.LiveRoutesSteps do
  @moduledoc """
  Step definitions for live_routes.feature.

  The `edict` block wraps its live routes in a `live_session` whose
  `on_mount` is `{Edict.LiveView, block options}`. The steps compile a
  router, read the recorded mount options off `__edict_routes__/0`, and run
  the mount hook exactly as Phoenix would.
  """

  use Cucumber.StepDefinition

  alias Edict.Test.{LiveSocket, RouterFactory}

  step "a live route for {string} with permission {string} inside an edict block",
       %{args: [entity_type, permission]} = context do
    router =
      RouterFactory.compile("""
      edict :#{entity_type}, [param: "project_id", permission: :#{permission}] do
        live "/things/:project_id", Edict.Test.RouterLive
      end
      """)

    Map.put(context, :router, router)
  end

  step "{word} mounts the view with a granted role", %{args: [user]} = context do
    {:ok, _} = Edict.assign_role(user, :admin, :project, "7")
    Map.put(context, :mount, mount_live(context, user))
  end

  step "{word} mounts the view", %{args: [user]} = context do
    Map.put(context, :mount, mount_live(context, user))
  end

  defp mount_live(context, user) do
    [live] = Enum.filter(context.router.__edict_routes__(), &(&1.kind == :live))

    socket = LiveSocket.build(%{current_user: %{id: user}, edict_config: context.project_config})

    Edict.Enforcement.LiveView.on_mount(live.on_mount, %{"project_id" => "7"}, %{}, socket)
  end
end
