defmodule Edict.Enforcement.AuthorizeTest do
  use ExUnit.Case, async: true

  alias Edict.Cache.Document

  defmodule TestLiveView do
    # Simulate a LiveView module with handle_event/3
    use Edict.Enforcement.Authorize

    authorize "delete", action: :delete, entity_from_assigns: :project_id, entity_type: :project
    authorize "update", action: :write, entity_from_assigns: :project_id, entity_type: :project

    def handle_event("delete", _params, socket) do
      {:noreply, Map.update!(socket, :assigns, &Map.put(&1, :deleted, true))}
    end

    def handle_event("update", _params, socket) do
      {:noreply, Map.update!(socket, :assigns, &Map.put(&1, :updated, true))}
    end

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
    socket = %{
      assigns: %{
        project_id: "7",
        edict_document: admin_doc,
        edict_config: edict_config
      }
    }

    {:noreply, result} = TestLiveView.handle_event("delete", %{}, socket)

    assert result.assigns[:deleted] == true
  end

  test "viewer cannot delete — handler blocked", %{
    edict_config: edict_config,
    viewer_doc: viewer_doc
  } do
    socket = %{
      assigns: %{
        project_id: "7",
        edict_document: viewer_doc,
        edict_config: edict_config
      }
    }

    {:noreply, result} = TestLiveView.handle_event("delete", %{}, socket)

    refute Map.has_key?(result.assigns, :deleted)
  end

  test "unguarded ping passes through normally", %{
    edict_config: edict_config,
    viewer_doc: viewer_doc
  } do
    socket = %{
      assigns: %{
        project_id: "7",
        edict_document: viewer_doc,
        edict_config: edict_config
      }
    }

    {:noreply, result} = TestLiveView.handle_event("ping", %{}, socket)

    assert result.assigns[:pinged] == true
  end
end
