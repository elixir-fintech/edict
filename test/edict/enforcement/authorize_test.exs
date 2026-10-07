defmodule Edict.Enforcement.AuthorizeTest do
  use ExUnit.Case, async: true

  alias Edict.Cache.Document
  alias Edict.Enforcement.Authorize

  defmodule TestLiveView do
    use Phoenix.LiveView
    use Edict.Enforcement.Authorize

    authorize("delete",
      permission: :delete,
      entity_from_assigns: :project_id,
      entity_type: :project
    )

    authorize("update",
      permission: :write,
      entity_from_assigns: :project_id,
      entity_type: :project
    )

    authorize("typo",
      permission: :aprove,
      entity_from_assigns: :project_id,
      entity_type: :project
    )

    def render(assigns), do: ~H""

    def handle_event(_event, _params, socket), do: {:noreply, socket}
  end

  setup do
    edict_config = %{
      config_module: Edict.Test.Config
    }

    admin_doc = %Document{
      user_id: "user-1",
      version: 1,
      roles: %{
        {:project, "7"} => [:admin]
      }
    }

    viewer_doc = %Document{
      user_id: "user-2",
      version: 1,
      roles: %{
        {:project, "7"} => [:viewer]
      }
    }

    %{edict_config: edict_config, admin_doc: admin_doc, viewer_doc: viewer_doc}
  end

  test "admin can delete — the event continues to the handler", %{
    edict_config: edict_config,
    admin_doc: admin_doc
  } do
    socket =
      build_socket(%{project_id: "7", current_user_roles: admin_doc, edict_config: edict_config})

    assert {:cont, _socket} = run_hook("delete", socket)
  end

  test "viewer cannot delete — on_unauthorized called", %{
    edict_config: edict_config,
    viewer_doc: viewer_doc
  } do
    socket =
      build_socket(%{project_id: "7", current_user_roles: viewer_doc, edict_config: edict_config})

    {:halt, result} = run_hook("delete", socket)

    assert result.redirected
  end

  test "an undeclared event passes through", %{edict_config: edict_config, viewer_doc: viewer_doc} do
    socket =
      build_socket(%{project_id: "7", current_user_roles: viewer_doc, edict_config: edict_config})

    {:cont, result} = run_hook("ping", socket)

    refute result.redirected
  end

  test "an event guard raises for a permission the entity type does not define", %{
    edict_config: edict_config,
    admin_doc: admin_doc
  } do
    socket =
      build_socket(%{project_id: "7", current_user_roles: admin_doc, edict_config: edict_config})

    assert_raise ArgumentError, ~r/:aprove/, fn -> run_hook("typo", socket) end
  end

  test "authorize without :permission fails to compile" do
    assert_raise ArgumentError, ~r/:permission/, fn ->
      compile_authorize(
        ~s|authorize("delete", entity_from_assigns: :project_id, entity_type: :project)|
      )
    end
  end

  test "authorize without :entity_from_assigns fails to compile" do
    assert_raise ArgumentError, ~r/:entity_from_assigns/, fn ->
      compile_authorize(~s|authorize("delete", permission: :delete, entity_type: :project)|)
    end
  end

  test "authorize without :entity_type fails to compile" do
    assert_raise ArgumentError, ~r/:entity_type/, fn ->
      compile_authorize(
        ~s|authorize("delete", permission: :delete, entity_from_assigns: :project_id)|
      )
    end
  end

  test "authorize with strong: true fails to compile" do
    assert_raise ArgumentError, ~r/:strong/, fn ->
      compile_authorize(
        ~s|authorize("delete", permission: :delete, entity_from_assigns: :project_id, entity_type: :project, strong: true)|
      )
    end
  end

  test "authorize with strong: false fails to compile" do
    assert_raise ArgumentError, ~r/Edict\.can\?/, fn ->
      compile_authorize(
        ~s|authorize("delete", permission: :delete, entity_from_assigns: :project_id, entity_type: :project, strong: false)|
      )
    end
  end

  test "a declared event without current_user_roles fails closed", %{edict_config: edict_config} do
    socket = build_socket(%{project_id: "7", edict_config: edict_config})

    assert_raise ArgumentError, ~r/current_user_roles/, fn -> run_hook("delete", socket) end
  end

  test "use registers the hook as an on_mount" do
    mount_ids = Enum.map(TestLiveView.__live__().lifecycle.mount, & &1.id)

    assert {Authorize, TestLiveView} in mount_ids
  end

  test "a non-string event name fails to compile" do
    assert_raise CompileError, ~r/string/, fn ->
      compile_authorize(
        ~s|authorize(:delete, permission: :delete, entity_from_assigns: :project_id, entity_type: :project)|
      )
    end
  end

  test "declaring an event twice fails to compile" do
    assert_raise CompileError, ~r/more than once/, fn ->
      compile_authorize("""
      authorize("delete", permission: :delete, entity_from_assigns: :project_id, entity_type: :project)
      authorize("delete", permission: :write, entity_from_assigns: :project_id, entity_type: :project)
      """)
    end
  end

  test "using authorize without Phoenix.LiveView fails to compile" do
    assert_raise CompileError, ~r/Phoenix\.LiveView/, fn ->
      Code.compile_string("""
      defmodule Edict.AuthorizeTest.NoLiveView#{System.unique_integer([:positive])} do
        use Edict.Enforcement.Authorize
      end
      """)
    end
  end

  defp build_socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}}, assigns),
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
  end

  defp run_hook(event, socket) do
    {:cont, mounted} = Authorize.on_mount(TestLiveView, %{}, %{}, socket)
    [hook] = mounted.private.lifecycle.handle_event
    hook.function.(event, %{}, mounted)
  end

  defp compile_authorize(declaration) do
    module = "Edict.AuthorizeTest.Compiled#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{module} do
      use Phoenix.LiveView
      use Edict.Enforcement.Authorize
      #{declaration}
      def render(assigns), do: ~H""
    end
    """)
  end
end
