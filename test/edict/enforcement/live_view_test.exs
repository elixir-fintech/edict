defmodule Edict.Enforcement.LiveViewTest do
  use ExUnit.Case, async: true

  alias Edict.Cache.{Document, Store}
  alias Edict.Enforcement.LiveView, as: EdictLiveView

  @cache_name :live_view_test_cache

  setup do
    case Cachex.start_link(@cache_name) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    edict_config = %{
      cache: @cache_name,
      config_module: Edict.Test.Config,
      repo: Edict.Test.Repo,
      pubsub: Edict.Test.PubSub,
      topic: "edict:versions"
    }

    doc = %Document{
      user_id: "user-1",
      version: 1,
      roles: %{
        {:project, "7"} => [:admin]
      }
    }

    Store.put_document(@cache_name, "user-1", doc)
    Store.set_version(@cache_name, "user-1", 1)

    opts = %{
      edict_config: edict_config,
      action: :read,
      entity_type: :project,
      entity_from: fn params -> params["id"] end
    }

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_user: %{id: "user-1"}}
    }

    params = %{"id" => "7"}

    %{opts: opts, socket: socket, params: params}
  end

  test "authorized user gets :cont with document and roles", %{
    opts: opts,
    socket: socket,
    params: params
  } do
    {:cont, result_socket} = EdictLiveView.on_mount(opts, params, %{}, socket)

    assert %Document{} = result_socket.assigns[:edict_document]
    assert :admin in result_socket.assigns[:current_user_roles]
  end

  test "unauthorized user gets :halt", %{opts: opts, socket: socket, params: params} do
    billing_opts = Map.put(opts, :action, :billing)

    {:halt, result_socket} = EdictLiveView.on_mount(billing_opts, params, %{}, socket)

    assert result_socket.redirected
  end
end
