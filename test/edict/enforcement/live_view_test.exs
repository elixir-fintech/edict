defmodule Edict.Enforcement.LiveViewTest do
  use ExUnit.Case, async: true

  alias Edict.Cache.{Document, Store}
  alias Edict.Enforcement.LiveView, as: EdictLiveView

  setup do
    cache_name = :"lv_cache_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = Cachex.start_link(cache_name)

    edict_config = %{
      cache: cache_name,
      config_module: Edict.Test.Config,
      repo: Edict.Test.Repo,
      pubsub: Edict.Test.PubSub,
      topic: "edict:versions"
    }

    doc = %Document{
      user_id: "user-1",
      version: 1,
      roles: %{
        {:project, "7"} => [:admin],
        # A blank entity ID must never match a request missing its param
        {:project, ""} => [:admin]
      }
    }

    Store.put_document(cache_name, "user-1", doc)
    Store.set_version(cache_name, "user-1", 1)

    opts = %{
      edict_config: edict_config,
      action: :read,
      entity_type: :project,
      entity_from: fn params -> params["id"] end
    }

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_user: %{id: "user-1"}},
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }

    params = %{"id" => "7"}

    %{opts: opts, socket: socket, params: params}
  end

  test "authorized user gets :cont with document", %{
    opts: opts,
    socket: socket,
    params: params
  } do
    {:cont, result_socket} = EdictLiveView.on_mount(opts, params, %{}, socket)

    assert %Document{} = result_socket.assigns[:current_user_roles]
  end

  test "unauthorized user gets :halt", %{opts: opts, socket: socket, params: params} do
    billing_opts = Map.put(opts, :action, :billing)

    {:halt, result_socket} = EdictLiveView.on_mount(billing_opts, params, %{}, socket)

    assert result_socket.redirected
  end

  test "authorized user gets :cont with keyword list opts", %{
    opts: opts,
    socket: socket,
    params: params
  } do
    keyword_opts = Map.to_list(opts)

    {:cont, result_socket} = EdictLiveView.on_mount(keyword_opts, params, %{}, socket)

    assert %Document{} = result_socket.assigns[:current_user_roles]
  end

  test "unauthorized user gets :halt with keyword list opts", %{
    opts: opts,
    socket: socket,
    params: params
  } do
    keyword_opts = opts |> Map.put(:action, :billing) |> Map.to_list()

    {:halt, result_socket} = EdictLiveView.on_mount(keyword_opts, params, %{}, socket)

    assert result_socket.redirected
  end

  test "authorized user gets :cont with param option", %{
    opts: opts,
    socket: socket,
    params: params
  } do
    param_opts = opts |> Map.delete(:entity_from) |> Map.put(:param, "id")

    {:cont, result_socket} = EdictLiveView.on_mount(param_opts, params, %{}, socket)

    assert %Document{} = result_socket.assigns[:current_user_roles]
  end

  test "unauthorized user gets :halt with param option", %{
    opts: opts,
    socket: socket,
    params: params
  } do
    param_opts =
      opts
      |> Map.delete(:entity_from)
      |> Map.put(:param, "id")
      |> Map.put(:action, :billing)

    {:halt, result_socket} = EdictLiveView.on_mount(param_opts, params, %{}, socket)

    assert result_socket.redirected
  end

  test "version bump hook passes unrelated messages through", %{
    opts: opts,
    socket: socket,
    params: params
  } do
    {:cont, mounted_socket} = EdictLiveView.on_mount(opts, params, %{}, socket)
    [hook] = mounted_socket.private.lifecycle.handle_info

    assert {:cont, ^mounted_socket} = hook.function.(:unrelated_message, mounted_socket)
  end

  test "user with a role on a blank entity is halted when the param is missing", %{
    opts: opts,
    socket: socket
  } do
    param_opts = opts |> Map.delete(:entity_from) |> Map.put(:param, "id")

    {:halt, result_socket} = EdictLiveView.on_mount(param_opts, %{}, %{}, socket)

    assert result_socket.redirected
  end

  test "mount rejects strong: false", %{opts: opts, socket: socket, params: params} do
    strong_opts = Map.put(opts, :strong, false)

    assert_raise ArgumentError, ~r/Edict\.can\?/, fn ->
      EdictLiveView.on_mount(strong_opts, params, %{}, socket)
    end
  end

  test "mount rejects missing :action", %{opts: opts, socket: socket, params: params} do
    assert_raise ArgumentError, ~r/:action/, fn ->
      EdictLiveView.on_mount(Map.delete(opts, :action), params, %{}, socket)
    end
  end

  test "mount rejects missing :entity_type", %{opts: opts, socket: socket, params: params} do
    assert_raise ArgumentError, ~r/:entity_type/, fn ->
      EdictLiveView.on_mount(Map.delete(opts, :entity_type), params, %{}, socket)
    end
  end

  test "mount rejects a missing entity ID source", %{opts: opts, socket: socket, params: params} do
    assert_raise ArgumentError, ~r/:param or :entity_from/, fn ->
      EdictLiveView.on_mount(Map.delete(opts, :entity_from), params, %{}, socket)
    end
  end
end
