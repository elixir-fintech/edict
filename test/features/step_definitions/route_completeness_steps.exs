defmodule Edict.Features.StepDefinitions.RouteCompletenessSteps do
  @moduledoc """
  Step definitions for route_completeness.feature.

  Compile-failure scenarios build throwaway routers and keep the outcome in
  the scenario context; the unguarded scenario dispatches a real request
  through a compiled router.
  """

  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias Edict.Test.RouterFactory

  step "the router uses Edict.Router", context do
    context
  end

  step "a route is declared outside any edict block", context do
    Map.put(context, :compilation, RouterFactory.try_compile(route_body()))
  end

  step "compilation fails instructing to declare it or use unguarded", context do
    {:error, %CompileError{} = error} = context.compilation
    description = error.description

    assert description =~ "/outside"
    assert description =~ "edict"
    assert description =~ "unguarded"
    context
  end

  step "a route is declared inside an unguarded block", context do
    router =
      RouterFactory.compile("""
      unguarded do
        get "/health", Edict.Test.EchoPlug, :health
      end
      """)

    context
    |> Map.put(:router, router)
    |> Map.put(:request_path, "/health")
  end

  # "any user requests that route" is shared with sentinel.feature; defined
  # once, in sentinel_steps.exs.

  step "the request passes without an Edict decision", context do
    conn = context.conn

    assert conn.status == 200
    # A declaration stamp is not a decision: nothing allowed or denied here.
    assert conn.private[:edict][:decision] == nil
    context
  end

  step "a live route is declared outside any edict block", context do
    Map.put(context, :compilation, RouterFactory.try_compile(live_body()))
  end

  step "a live route is declared inside an edict block without a permission", context do
    compilation =
      RouterFactory.try_compile("""
      edict :project, [param: "project_id"] do
        live "/things/:project_id", Edict.Test.RouterLive
      end
      """)

    Map.put(context, :compilation, compilation)
  end

  step "compilation fails instructing to declare the block's permission", context do
    {:error, %CompileError{} = error} = context.compilation

    assert error.description =~ "permission"
    assert error.description =~ "/things/:project_id"
    context
  end

  step "the application also has a plain Phoenix router", context do
    context
  end

  step "a route is declared in it outside any edict block", context do
    Map.put(
      context,
      :compilation,
      {:ok, RouterFactory.compile_plain_router(route_body())}
    )
  end

  step "that router compiles without Edict errors", context do
    assert {:ok, _router} = context.compilation
    context
  end

  step "a resources declaration is made inside an edict block", context do
    Map.put(
      context,
      :compilation,
      RouterFactory.try_compile("""
      edict :project, [param: "project_id"] do
        resources "/things", Edict.Test.EchoPlug
      end
      """)
    )
  end

  step "compilation fails instructing to declare routes individually", context do
    {:error, %CompileError{} = error} = context.compilation

    assert error.description =~ "resources"
    assert error.description =~ "individually"
    context
  end

  step "a match route is declared inside an edict block", context do
    Map.put(
      context,
      :compilation,
      RouterFactory.try_compile("""
      edict :project, [param: "project_id"] do
        match :get, "/things/:project_id", Edict.Test.EchoPlug, :show
      end
      """)
    )
  end

  step "compilation fails instructing to use the verb macros", context do
    {:error, %CompileError{} = error} = context.compilation

    assert error.description =~ "match"
    assert error.description =~ "verb macros"
    context
  end

  step "a forward is declared outside an unguarded block", context do
    Map.put(
      context,
      :compilation,
      RouterFactory.try_compile(~s|forward "/admin", Edict.Test.EchoPlug|)
    )
  end

  step "compilation fails instructing to wrap it in unguarded", context do
    {:error, %CompileError{} = error} = context.compilation

    assert error.description =~ "outside every edict block"
    assert error.description =~ "unguarded"
    context
  end

  step "a resources declaration is made inside an unguarded block", context do
    router =
      RouterFactory.compile("""
      unguarded do
        resources "/things", Edict.Test.EchoPlug
      end
      """)

    Map.put(context, :compilation, {:ok, router})
  end

  defp route_body, do: ~s|get "/outside", Edict.Test.EchoPlug, :show|
  defp live_body, do: ~s|live "/outside", Edict.Test.RouterLive|
end
