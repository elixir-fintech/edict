defmodule Edict.Enforcement.PlugTest do
  use ExUnit.Case, async: true

  alias Edict.Cache.{Document, Store}
  alias Edict.Enforcement.Plug, as: EdictPlug

  setup do
    cache_name = :"plug_cache_#{:erlang.unique_integer([:positive])}"
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

    opts =
      EdictPlug.init(
        edict_config: edict_config,
        action: :read,
        entity_type: :project,
        entity_from: fn conn -> conn.params["id"] end
      )

    %{edict_config: edict_config, opts: opts}
  end

  test "authorized request assigns document", %{opts: opts} do
    conn =
      Plug.Test.conn(:get, "/projects/7", %{})
      |> Map.put(:params, %{"id" => "7"})
      |> Plug.Conn.assign(:current_user, %{id: "user-1"})

    result = EdictPlug.call(conn, opts)

    refute result.halted
    assert %Document{} = result.assigns[:current_user_roles]
  end

  test "unauthorized request is halted with 403", %{opts: opts} do
    billing_opts = Map.put(opts, :action, :billing)

    conn =
      Plug.Test.conn(:get, "/projects/7", %{})
      |> Map.put(:params, %{"id" => "7"})
      |> Plug.Conn.assign(:current_user, %{id: "user-1"})

    result = EdictPlug.call(conn, billing_opts)

    assert result.halted
    assert result.status == 403
  end

  test "pipeline with param option assigns document for authorized request", %{
    edict_config: edict_config
  } do
    conn =
      Plug.Test.conn(:get, "/projects/7", %{})
      |> Map.put(:params, %{"project_id" => "7"})
      |> Plug.Conn.assign(:current_user, %{id: "user-1"})
      |> Plug.Conn.assign(:edict_config, edict_config)

    result = Edict.Test.ReadProjectPipeline.call(conn, [])

    refute result.halted
    assert %Document{} = result.assigns[:current_user_roles]
  end

  test "pipeline with param option halts unauthorized request with 403", %{
    edict_config: edict_config
  } do
    conn =
      Plug.Test.conn(:get, "/projects/7", %{})
      |> Map.put(:params, %{"project_id" => "7"})
      |> Plug.Conn.assign(:current_user, %{id: "user-1"})
      |> Plug.Conn.assign(:edict_config, edict_config)

    result = Edict.Test.BillingProjectPipeline.call(conn, [])

    assert result.halted
    assert result.status == 403
  end

  test "user with a role on a blank entity is halted when the param is missing", %{
    edict_config: edict_config
  } do
    conn =
      Plug.Test.conn(:get, "/projects", %{})
      |> Map.put(:params, %{})
      |> Plug.Conn.assign(:current_user, %{id: "user-1"})
      |> Plug.Conn.assign(:edict_config, edict_config)

    result = Edict.Test.ReadProjectPipeline.call(conn, [])

    assert result.halted
    assert result.status == 403
  end

  test "unauthorized request is halted when on_unauthorized does not halt", %{
    edict_config: edict_config
  } do
    non_halting_config = Map.put(edict_config, :config_module, Edict.Test.NonHaltingConfig)

    conn =
      Plug.Test.conn(:get, "/projects/7", %{})
      |> Map.put(:params, %{"project_id" => "7"})
      |> Plug.Conn.assign(:current_user, %{id: "user-1"})
      |> Plug.Conn.assign(:edict_config, non_halting_config)

    result = Edict.Test.BillingProjectThenMarkPipeline.call(conn, [])

    assert result.halted
    refute result.assigns[:downstream_ran]
  end

  test "init rejects strong: true" do
    assert_raise ArgumentError, ~r/:strong/, fn ->
      EdictPlug.init(action: :read, entity_type: :project, param: "id", strong: true)
    end
  end
end
