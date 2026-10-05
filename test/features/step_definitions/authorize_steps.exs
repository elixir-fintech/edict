defmodule Edict.Features.GuardedProjectLive do
  @moduledoc """
  LiveView under test for authorize_events.feature.
  """

  use Phoenix.LiveView
  use Edict.Enforcement.Authorize

  authorize("delete", action: :delete, entity_from_assigns: :project_id, entity_type: :project)
  authorize("update", action: :write, entity_from_assigns: :project_id, entity_type: :project)
  authorize("typo", action: :aprove, entity_from_assigns: :project_id, entity_type: :project)

  def render(assigns), do: ~H""

  def handle_event(_event, _params, socket), do: {:noreply, socket}
end

defmodule Edict.Features.StepDefinitions.AuthorizeSteps do
  @moduledoc """
  Step definitions for authorize_events.feature.
  """

  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias Edict.Enforcement.Authorize
  alias Edict.Enforcement.Helpers
  alias Edict.Features.GuardedProjectLive
  alias Edict.Test.LiveSocket

  step "a LiveView guarding {string} with {string} and {string} with {string} on project from assign {string}",
       %{args: [_e1, _a1, _e2, _a2, _key]} = context do
    # The steps below only guard the right operations if the LiveView is
    # compiled with exactly these declarations — so the Background checks it.
    assert GuardedProjectLive.__edict_authorizations__() == %{
             "delete" => {:delete, :project_id, :project},
             "update" => {:write, :project_id, :project},
             "typo" => {:aprove, :project_id, :project}
           }

    context
  end

  step "the socket has no authorization document", context do
    Map.put(context, :documentless, true)
  end

  step "{word} sends the {string} event for project {string}",
       %{args: [user, event, id]} = context do
    assigns = %{current_user: %{id: user}, project_id: id, edict_config: context.project_config}

    assigns =
      if context[:documentless],
        do: assigns,
        else: Map.put(assigns, :current_user_roles, document(context, user))

    Map.put(context, :event, run_event(LiveSocket.build(assigns), event))
  end

  step "{word} sends the undeclared {string} event for project {string}",
       %{args: [user, event, id]} = context do
    socket =
      LiveSocket.build(%{
        current_user: %{id: user},
        project_id: id,
        current_user_roles: document(context, user),
        edict_config: context.project_config
      })

    Map.put(context, :event, run_event(socket, event))
  end

  step "{word} sends the {string} event without the project assign",
       %{args: [user, event]} = context do
    socket =
      LiveSocket.build(%{
        current_user: %{id: user},
        current_user_roles: document(context, user),
        edict_config: context.project_config
      })

    Map.put(context, :event, run_event(socket, event))
  end

  step "the event continues to the handler", context do
    assert match?({:cont, _}, context.event)
    context
  end

  step "the event halts with a redirect", context do
    assert match?({:halt, _}, context.event)
    {:halt, socket} = context.event
    assert socket.redirected
    context
  end

  step "the event raises instead of reaching the handler", context do
    assert match?({:raised, _}, context.event)
    context
  end

  step "the event raises ArgumentError", context do
    assert match?({:raised, %ArgumentError{}}, context.event)
    context
  end

  defp document(context, user), do: Helpers.load_document(context.project_config, user)

  defp run_event(socket, event) do
    {:cont, mounted} = Authorize.on_mount(GuardedProjectLive, %{}, %{}, socket)
    [hook] = mounted.private.lifecycle.handle_event

    try do
      hook.function.(event, %{}, mounted)
    rescue
      e -> {:raised, e}
    end
  end
end
