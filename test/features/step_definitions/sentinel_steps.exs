defmodule Edict.Features.StepDefinitions.SentinelSteps do
  @moduledoc """
  Step definitions for sentinel.feature.

  Every scenario compiles a router whose pipeline carries
  `Edict.Test.Identify` (test auth) and `Edict.Sentinel`, then dispatches a
  real request: a declared edict route guards through the per-route
  `Edict.Plug`, a declared live route through its block's declaration stamp,
  and the undeclared scenario uses a plain Phoenix router wired by hand.
  """

  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias Edict.Test.RouterFactory

  step "the sentinel is in the pipeline", context do
    context
  end

  step "the sentinel is in the pipeline and the guard is in the scope", context do
    # The sentinel registers in the pipeline; the per-route Edict.Plug guard
    # runs later, in the scope — the ordering the scenario pins.
    router = RouterFactory.compile_top(sentinel_router(controller_block("project")))

    context
    |> Map.put(:router, router)
    |> Map.put(:request_path, "/things/7")
  end

  step "a {string} route is declared inside an edict block for {string}",
       %{args: [_action, entity_type]} = context do
    router = RouterFactory.compile_top(sentinel_router(controller_block(entity_type)))

    context
    |> Map.put(:router, router)
    |> Map.put(:request_path, "/things/7")
  end

  step "a live route for {string} with permission {string} is declared inside an edict block",
       %{args: [entity_type, permission]} = context do
    router =
      RouterFactory.compile_top("""
      pipeline :guarded do
        plug Edict.Test.Identify
        plug Edict.Sentinel
      end

      scope "/" do
        pipe_through([:guarded])

        edict :#{entity_type}, [param: "project_id", permission: :#{permission}, on_mount: Edict.Test.SessionUser] do
          live "/things/:project_id", Edict.Test.RouterLive
        end
      end
      """)

    context
    |> Map.put(:router, router)
    |> Map.put(:request_path, "/things/7")
  end

  step "a manually wired controller without an Edict guard handles a route", context do
    # Hand wiring, no Edict.Router: exactly the case the sentinel covers.
    router =
      RouterFactory.compile_plain_router("""
      pipeline :guarded do
        plug Edict.Test.Identify
        plug Edict.Sentinel
      end

      scope "/" do
        pipe_through([:guarded])
        get "/legacy", Edict.Test.EchoPlug, :legacy
      end
      """)

    context
    |> Map.put(:router, router)
    |> Map.put(:request_path, "/legacy")
  end

  step "{word} requests that route with a granted role", %{args: [user]} = context do
    {:ok, _} = Edict.assign_role(user, :admin, :project, "7")
    Map.put(context, :conn, RouterFactory.request_as(context.router, context.request_path, user))
  end

  step "{word} requests that route without a granted role", %{args: [user]} = context do
    Map.put(context, :conn, RouterFactory.request_as(context.router, context.request_path, user))
  end

  step "{word} requests a declared route with a granted role", %{args: [user]} = context do
    {:ok, _} = Edict.assign_role(user, :admin, :project, "7")
    Map.put(context, :conn, RouterFactory.request_as(context.router, context.request_path, user))
  end

  # Shared with route_completeness.feature: defined once, globally unique.
  step "any user requests that route", context do
    Map.put(
      context,
      :conn,
      RouterFactory.request_as(context.router, context.request_path, "carol")
    )
  end

  step "the request passes", context do
    conn = context.conn

    assert conn.status == 200

    # A controller route records its decision; a live route its declaration.
    assert conn.private[:edict][:decision] == :allow or
             conn.private[:edict][:declaration] == :edict

    context
  end

  step "the denial response from the guard is kept", context do
    assert context.conn.status == 403
    assert context.conn.private[:edict][:decision] == :deny
    assert context.conn.resp_body == "Forbidden"
    context
  end

  step "the request is denied with a 403", context do
    assert context.conn.status == 403
    assert context.conn.halted
    # Nothing Edict-related ran: the sentinel produced the denial itself.
    assert context.conn.private[:edict] == nil
    context
  end

  defp sentinel_router(block) do
    """
    pipeline :guarded do
      plug Edict.Test.Identify
      plug Edict.Sentinel
    end

    scope "/" do
      pipe_through([:guarded])
      #{block}
    end
    """
  end

  defp controller_block(entity_type) do
    """
    edict :#{entity_type}, [param: "project_id"] do
      get "/things/:project_id", Edict.Test.EchoPlug, :show
    end
    """
  end
end
