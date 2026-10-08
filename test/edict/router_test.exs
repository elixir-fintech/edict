defmodule Edict.RouterTest do
  @moduledoc """
  Unit tests for `Edict.Router`.

  The features in `test/features/` cover derivation, completeness and live
  routes end to end; these pin the edges: `use` ordering, the
  missing-config-module warning path, option validation and nesting.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Edict.Test.RouterFactory

  setup do
    Application.put_env(:edict, :config_module, Edict.Test.Config)

    on_exit(fn ->
      Application.delete_env(:edict, :config_module)
    end)

    :ok
  end

  describe "use Edict.Router" do
    test "requires use Phoenix.Router first" do
      assert_raise CompileError, ~r/use Phoenix.Router/, fn ->
        Code.compile_string("""
        defmodule Edict.RouterTest.NoPhoenix#{System.unique_integer([:positive])} do
          use Edict.Router

          scope "/" do
            unguarded do
              get "/health", Edict.Test.EchoPlug, :health
            end
          end
        end
        """)
      end
    end
  end

  describe "without a config module at compile time" do
    test "warns and falls back to the raw action name for derived routes" do
      Application.delete_env(:edict, :config_module)

      assert capture_io(:stderr, fn ->
               router = RouterFactory.compile_edict_route("project", "show", [])
               send(self(), {:router, router})
             end) =~ "config_module is not available"

      assert_received {:router, router}

      [guard] = router.__edict_routes__()
      # :show has no permission meaning here; the runtime
      # validate_permission!/3 backstop raises on the first request instead.
      assert guard.permission == :show
    end

    test "an explicit route permission still compiles" do
      Application.delete_env(:edict, :config_module)

      assert capture_io(:stderr, fn ->
               router = RouterFactory.compile_edict_route("project", "show", permission: :read)
               send(self(), {:router, router})
             end) =~ "config_module is not available"

      assert_received {:router, router}

      [guard] = router.__edict_routes__()
      assert guard.permission == :read
    end
  end

  describe "edict/3 option validation" do
    test "rejects a non-atom entity type" do
      assert_raise CompileError, ~r/entity type atom/, fn ->
        RouterFactory.compile("""
        edict "project", [param: "project_id"] do
          get "/things/:project_id", Edict.Test.EchoPlug, :show
        end
        """)
      end
    end

    test "rejects a non-string param" do
      assert_raise CompileError, ~r/param: must be a string/, fn ->
        RouterFactory.compile("""
        edict :project, [param: :project_id] do
          get "/things/:project_id", Edict.Test.EchoPlug, :show
        end
        """)
      end
    end

    test "rejects unknown options" do
      assert_raise CompileError, ~r/unknown options/, fn ->
        RouterFactory.compile("""
        edict :project, [param: "project_id", entity: "thing"] do
          get "/things/:project_id", Edict.Test.EchoPlug, :show
        end
        """)
      end
    end
  end

  describe "block nesting" do
    test "edict blocks cannot nest" do
      assert_raise CompileError, ~r/cannot be nested/, fn ->
        RouterFactory.compile("""
        edict :project, [param: "project_id"] do
          edict :team, [param: "team_id"] do
            get "/things/:project_id", Edict.Test.EchoPlug, :show
          end
        end
        """)
      end
    end

    test "unguarded blocks cannot nest" do
      assert_raise CompileError, ~r/cannot be nested/, fn ->
        RouterFactory.compile("""
        unguarded do
          unguarded do
            get "/health", Edict.Test.EchoPlug, :health
          end
        end
        """)
      end
    end
  end

  describe "__edict_routes__/0" do
    test "records controller, live and unguarded routes with their guards" do
      router =
        RouterFactory.compile("""
        edict :project, [param: "project_id", permission: :read] do
          get "/things/:project_id", Edict.Test.EchoPlug, :show
          live "/things/:project_id/live", Edict.Test.RouterLive
        end

        unguarded do
          get "/health", Edict.Test.EchoPlug, :health
        end
        """)

      routes = router.__edict_routes__()

      [controller] = Enum.filter(routes, &(&1.kind == :controller))
      assert controller.permission == :read
      assert controller.entity_type == :project
      assert controller.guard[:param] == "project_id"

      [live] = Enum.filter(routes, &(&1.kind == :live))
      assert live.on_mount[:permission] == :read
      assert live.on_mount[:entity_type] == :project
      assert live.on_mount[:param] == "project_id"

      [unguarded] = Enum.filter(routes, &(&1.kind == :unguarded))
      assert unguarded.path == "/health"
    end
  end
end
