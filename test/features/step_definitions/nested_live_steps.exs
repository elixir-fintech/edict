defmodule Edict.Features.StepDefinitions.NestedLiveSteps do
  @moduledoc """
  Step definitions for event_guard.feature's nested-child scenario.

  This pins Phoenix behavior the event guard relies on: `live_session`
  hooks reach only the root view the router mounts, never a `live_render`
  child. It therefore runs a real mount — static render and connected
  mount — through `Phoenix.LiveViewTest` and `Edict.Test.Endpoint`, rather
  than simulating the lifecycle.
  """

  use Cucumber.StepDefinition
  import ExUnit.Assertions
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Edict.Test.RouterFactory

  @endpoint Edict.Test.Endpoint

  step "a LiveView routed in an edict block that renders a nested LiveView", context do
    Map.put(context, :parent_module, unique_name("Parent"))
  end

  step "the nested LiveView does not use Edict.Enforcement.Authorize", context do
    child = compile_view(unique_name("Child"), ~s|def render(assigns), do: ~H"<p>child</p>"|)

    parent =
      compile_view(context.parent_module, """
      use Edict.Enforcement.Authorize

      def render(assigns) do
        ~H"<div>{live_render(@socket, #{inspect(child)}, id: \\"child\\")}</div>"
      end
      """)

    router =
      RouterFactory.compile_top("""
      pipeline :browser do
        plug :fetch_session
      end

      scope "/" do
        pipe_through(:browser)

        edict :project, param: "project_id", permission: :read, on_mount: Edict.Test.SessionUser do
          live "/things/:project_id", #{inspect(parent)}
        end
      end
      """)

    Map.put(context, :router, router)
  end

  # Edict.Test.SessionUser signs alice in on the socket. The LiveView
  # processes are spawned by Phoenix, so the scenario's sandbox connection is
  # shared with them; feature scenarios run synchronously.
  step ~r/^(?<user>\w+) opens the routed view in a browser$/, %{args: [user]} = context do
    Ecto.Adapters.SQL.Sandbox.mode(context.repo, {:shared, self()})
    {:ok, _} = Edict.assign_role(user, :viewer, :project, "7")

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_private(:edict_test_router, context.router)

    Map.put(context, :live, live(conn, "/things/7"))
  end

  step "the nested LiveView mounts", context do
    {:ok, view, _html} = context.live

    child = find_live_child(view, "child")
    assert render(child) =~ "child"
    context
  end

  defp unique_name(prefix),
    do: "Edict.Features.Nested.#{prefix}#{System.unique_integer([:positive])}"

  defp compile_view(module, body) do
    [{compiled, _binary}] =
      Code.compile_string("""
      defmodule #{module} do
        use Phoenix.LiveView
        #{body}
      end
      """)

    compiled
  end
end
