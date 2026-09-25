defmodule Edict.Enforcement.AuthorizeTest do
  use ExUnit.Case, async: true

  alias Edict.Cache.Document

  defmodule TestLiveView do
    # Simulate a LiveView module with handle_event/3
    use Edict.Enforcement.Authorize

    authorize("delete", action: :delete, entity_from_assigns: :project_id, entity_type: :project)
    authorize("update", action: :write, entity_from_assigns: :project_id, entity_type: :project)
    authorize("typo", action: :aprove, entity_from_assigns: :project_id, entity_type: :project)

    def handle_event("delete", _params, socket) do
      {:noreply, Map.update!(socket, :assigns, &Map.put(&1, :deleted, true))}
    end

    def handle_event("update", _params, socket) do
      {:noreply, Map.update!(socket, :assigns, &Map.put(&1, :updated, true))}
    end

    def handle_event("typo", _params, socket), do: {:noreply, socket}

    def handle_event("ping", _params, socket) do
      {:noreply, Map.update!(socket, :assigns, &Map.put(&1, :pinged, true))}
    end
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

  test "admin can delete — handler runs", %{edict_config: edict_config, admin_doc: admin_doc} do
    socket =
      build_socket(%{
        project_id: "7",
        current_user_roles: admin_doc,
        edict_config: edict_config
      })

    {:noreply, result} = TestLiveView.handle_event("delete", %{}, socket)

    assert result.assigns[:deleted] == true
  end

  test "viewer cannot delete — on_unauthorized called", %{
    edict_config: edict_config,
    viewer_doc: viewer_doc
  } do
    socket =
      build_socket(%{
        project_id: "7",
        current_user_roles: viewer_doc,
        edict_config: edict_config
      })

    {:noreply, result} = TestLiveView.handle_event("delete", %{}, socket)

    assert result.redirected
  end

  test "unguarded ping passes through normally", %{
    edict_config: edict_config,
    viewer_doc: viewer_doc
  } do
    socket =
      build_socket(%{
        project_id: "7",
        current_user_roles: viewer_doc,
        edict_config: edict_config
      })

    {:noreply, result} = TestLiveView.handle_event("ping", %{}, socket)

    assert result.assigns[:pinged] == true
  end

  defp build_socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}}, assigns),
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
  end

  test "authorize without :action fails to compile" do
    assert_raise ArgumentError, ~r/:action/, fn ->
      compile_authorize(
        ~s|authorize("delete", entity_from_assigns: :project_id, entity_type: :project)|
      )
    end
  end

  test "authorize without :entity_from_assigns fails to compile" do
    assert_raise ArgumentError, ~r/:entity_from_assigns/, fn ->
      compile_authorize(~s|authorize("delete", action: :delete, entity_type: :project)|)
    end
  end

  test "authorize without :entity_type fails to compile" do
    assert_raise ArgumentError, ~r/:entity_type/, fn ->
      compile_authorize(
        ~s|authorize("delete", action: :delete, entity_from_assigns: :project_id)|
      )
    end
  end

  test "authorize with strong: true fails to compile" do
    assert_raise ArgumentError, ~r/:strong/, fn ->
      compile_authorize(
        ~s|authorize("delete", action: :delete, entity_from_assigns: :project_id, entity_type: :project, strong: true)|
      )
    end
  end

  test "authorize with strong: false fails to compile" do
    assert_raise ArgumentError, ~r/Edict\.can\?/, fn ->
      compile_authorize(
        ~s|authorize("delete", action: :delete, entity_from_assigns: :project_id, entity_type: :project, strong: false)|
      )
    end
  end

  test "an event guard raises for an action the entity type does not define", %{
    edict_config: edict_config,
    admin_doc: admin_doc
  } do
    socket =
      build_socket(%{project_id: "7", current_user_roles: admin_doc, edict_config: edict_config})

    assert_raise ArgumentError, ~r/:aprove/, fn ->
      TestLiveView.handle_event("typo", %{}, socket)
    end
  end

  defp compile_authorize(declaration) do
    module = "Edict.AuthorizeTest.Compiled#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{module} do
      use Edict.Enforcement.Authorize
      #{declaration}
      def handle_event(_event, _params, socket), do: {:noreply, socket}
    end
    """)
  end
end
