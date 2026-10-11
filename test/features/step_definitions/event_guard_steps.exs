defmodule Edict.Features.StepDefinitions.EventGuardSteps do
  @moduledoc """
  Step definitions for event_guard.feature.

  Each scenario compiles throwaway LiveViews and a router routing them in an
  `edict` block, mounts a view through the hooks the compiled router really
  carries (`Edict.Test.RouterFactory.mount_routed/3`), and sends events
  through the view's `handle_event` hooks with `Phoenix.LiveView.Lifecycle`,
  as Phoenix does. Views end in a catch-all `handle_event/3` that records the
  event, so the compile-time check passes and only the runtime guard decides.
  """

  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias Edict.Test.RouterFactory
  alias Phoenix.LiveView.Lifecycle

  step ~r/^a LiveView routed in an edict block that authorizes "(?<event>\w+)"$/,
       %{args: [event]} = context do
    route_one(context, view([~s|authorize "#{event}", :read|]))
  end

  step ~r/^a LiveView routed in an edict block that lists "(?<event>\w+)" in unguarded_events$/,
       %{args: [event]} = context do
    route_one(context, view([~s|unguarded_events ["#{event}"]|]))
  end

  step ~r/^a LiveView routed in an edict block that authorizes "(?<event>\w+)" with permission "(?<permission>\w+)"$/,
       %{args: [event, permission]} = context do
    route_one(context, view([~s|authorize "#{event}", :#{permission}|]))
  end

  step "a LiveView routed in an edict block that does not use Edict.Enforcement.Authorize",
       context do
    route_one(context, view_without_authorize())
  end

  step "an edict block routing two LiveViews", context do
    context
  end

  step ~r/^the first authorizes "(?<first>\w+)" and the second authorizes "(?<second>\w+)"$/,
       %{args: [first, second]} = context do
    first_view = view([~s|authorize "#{first}", :read|])
    second_view = view([~s|authorize "#{second}", :read|])

    router =
      RouterFactory.compile("""
      edict :project, [param: "project_id", permission: :read] do
        live "/first/:project_id", #{inspect(first_view)}
        live "/second/:project_id", #{inspect(second_view)}
      end
      """)

    context
    |> Map.put(:router, router)
    |> Map.put(:path, "/first/7")
  end

  step ~r/^(?<user>\w+) holds the role "(?<role>\w+)" on project "(?<id>\w+)"$/,
       %{args: [user, role, id]} = context do
    {:ok, _} = Edict.assign_role(user, String.to_existing_atom(role), :project, id)
    context
  end

  # The block's mount permission is :read, so the sender needs at least the
  # viewer role on project 7 to get past the mount to the event.
  step ~r/^(?<user>\w+) sends the event "(?<event>\w+)"$/, %{args: [user, event]} = context do
    {:ok, _} = Edict.assign_role(user, :viewer, :project, "7")
    send_to_mounted(context, user, event)
  end

  step ~r/^(?<user>\w+) sends "(?<event>\w+)" to the first view$/,
       %{args: [user, event]} = context do
    {:ok, _} = Edict.assign_role(user, :viewer, :project, "7")
    send_to_mounted(context, user, event)
  end

  step ~r/^(?<user>\w+) mounts the routed view$/, %{args: [user]} = context do
    {:ok, _} = Edict.assign_role(user, :viewer, :project, "7")
    Map.put(context, :mount, mount(context, user))
  end

  step "the event fails naming {string} and both remedies", %{args: [event]} = context do
    {:raised, %ArgumentError{message: message}} = context.event

    assert message =~ ~s("#{event}")
    assert message =~ "authorize"
    assert message =~ "unguarded_events"
    context
  end

  step "the view's handle_event never runs", context do
    # deliver/2 calls the view only after every hook continued; a raise
    # means no hook chain result ever reached it.
    assert match?({:raised, _}, context.event)
    context
  end

  step "the view's handle_event runs", context do
    {:noreply, socket} = context.event
    assert socket.assigns.handled == "validate"
    context
  end

  step "the event is denied through on_unauthorized", context do
    {:halt, socket} = context.event
    assert socket.redirected
    context
  end

  step "the mount fails naming the module and {string}", %{args: [remedy]} = context do
    {:raised, %ArgumentError{message: message}} = context.mount

    assert message =~ inspect(context.view)
    assert message =~ remedy
    context
  end

  defp route_one(context, view) do
    router =
      RouterFactory.compile("""
      edict :project, [param: "project_id", permission: :read] do
        live "/things/:project_id", #{inspect(view)}
      end
      """)

    context
    |> Map.put(:router, router)
    |> Map.put(:view, view)
    |> Map.put(:path, "/things/7")
  end

  defp send_to_mounted(context, user, event) do
    {:cont, socket} =
      RouterFactory.mount_routed(context.router, context.path, assigns(context, user))

    Map.put(context, :event, deliver(socket, event))
  end

  defp mount(context, user) do
    RouterFactory.mount_routed(context.router, context.path, assigns(context, user))
  rescue
    e in ArgumentError -> {:raised, e}
  end

  # The hook chain, then — only when every hook continued — the view itself.
  defp deliver(socket, event) do
    with {:cont, socket} <- Lifecycle.handle_event(event, %{}, socket) do
      socket.view.handle_event(event, %{}, socket)
    end
  rescue
    e in ArgumentError -> {:raised, e}
  end

  defp assigns(context, user),
    do: %{current_user: %{id: user}, edict_config: context.project_config}

  defp view(declarations) do
    compile_view("""
    use Edict.Enforcement.Authorize
    edict_entity :project, from: :project_id
    #{Enum.join(declarations, "\n")}

    def mount(%{"project_id" => id}, _session, socket), do: {:ok, assign(socket, :project_id, id)}
    def handle_event(event, _params, socket), do: {:noreply, assign(socket, :handled, event)}
    """)
  end

  defp view_without_authorize do
    compile_view("""
    def mount(%{"project_id" => id}, _session, socket), do: {:ok, assign(socket, :project_id, id)}
    def handle_event(event, _params, socket), do: {:noreply, assign(socket, :handled, event)}
    """)
  end

  defp compile_view(body) do
    module = "Edict.Features.EventGuard.View#{System.unique_integer([:positive])}"

    [{compiled, _binary}] =
      Code.compile_string("""
      defmodule #{module} do
        use Phoenix.LiveView
        #{body}
        def render(assigns), do: ~H""
      end
      """)

    compiled
  end
end
