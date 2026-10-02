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
        {:project, ""} => [:admin],
        # An array param must never be joined into "78"
        {:project, "78"} => [:admin]
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
    conn =
      Plug.Test.conn(:get, "/projects/8", %{})
      |> Map.put(:params, %{"id" => "8"})
      |> Plug.Conn.assign(:current_user, %{id: "user-1"})

    result = EdictPlug.call(conn, opts)

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
      Plug.Test.conn(:get, "/projects/8", %{})
      |> Map.put(:params, %{"project_id" => "8"})
      |> Plug.Conn.assign(:current_user, %{id: "user-1"})
      |> Plug.Conn.assign(:edict_config, edict_config)

    result = Edict.Test.ReadProjectPipeline.call(conn, [])

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

    result = Edict.Test.ReadProjectThenMarkPipeline.call(conn, [])

    assert result.halted
    refute result.assigns[:downstream_ran]
  end

  test "init rejects strong: true" do
    assert_raise ArgumentError, ~r/:strong/, fn ->
      EdictPlug.init(action: :read, entity_type: :project, param: "id", strong: true)
    end
  end

  test "init rejects strong: false" do
    assert_raise ArgumentError, ~r/Edict\.can\?/, fn ->
      EdictPlug.init(action: :read, entity_type: :project, param: "id", strong: false)
    end
  end

  test "init rejects missing :action" do
    assert_raise ArgumentError, ~r/:action/, fn ->
      EdictPlug.init(entity_type: :project, param: "id")
    end
  end

  test "init rejects missing :entity_type" do
    assert_raise ArgumentError, ~r/:entity_type/, fn ->
      EdictPlug.init(action: :read, param: "id")
    end
  end

  test "init rejects a missing entity ID source" do
    assert_raise ArgumentError, ~r/:param or :entity_from/, fn ->
      EdictPlug.init(action: :read, entity_type: :project)
    end
  end

  test "array param is denied", %{edict_config: edict_config} do
    conn =
      Plug.Test.conn(:get, "/projects", %{})
      |> Map.put(:params, %{"project_id" => ["7", "8"]})
      |> Plug.Conn.assign(:current_user, %{id: "user-1"})
      |> Plug.Conn.assign(:edict_config, edict_config)

    result = Edict.Test.ReadProjectPipeline.call(conn, [])

    assert result.halted
    assert result.status == 403
  end

  test "an action the entity type does not define raises", %{opts: opts} do
    typo_opts = Map.put(opts, :action, :aprove)

    conn =
      Plug.Test.conn(:get, "/projects/7", %{})
      |> Map.put(:params, %{"id" => "7"})
      |> Plug.Conn.assign(:current_user, %{id: "user-1"})

    assert_raise ArgumentError, ~r/:aprove/, fn -> EdictPlug.call(conn, typo_opts) end
  end

  # Tables created without the CHECK constraints can hold rows for a blank
  # user; a request without a user must never be checked against them.
  defp seed_blank_user_document(cache) do
    doc = %Document{user_id: "", version: 1, roles: %{{:project, "7"} => [:admin]}}
    Store.put_document(cache, "", doc)
    Store.set_version(cache, "", 1)
  end

  test "a request with a nil user ID is halted with 403", %{
    edict_config: edict_config,
    opts: opts
  } do
    seed_blank_user_document(edict_config.cache)

    conn =
      Plug.Test.conn(:get, "/projects/7", %{})
      |> Map.put(:params, %{"id" => "7"})
      |> Plug.Conn.assign(:current_user, %{id: nil})

    result = EdictPlug.call(conn, opts)

    assert result.halted
    assert result.status == 403
  end

  test "a request with a blank user ID is halted with 403", %{
    edict_config: edict_config,
    opts: opts
  } do
    seed_blank_user_document(edict_config.cache)

    conn =
      Plug.Test.conn(:get, "/projects/7", %{})
      |> Map.put(:params, %{"id" => "7"})
      |> Plug.Conn.assign(:current_user, %{id: ""})

    result = EdictPlug.call(conn, opts)

    assert result.halted
    assert result.status == 403
  end
end
