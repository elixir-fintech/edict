defmodule Edict.Enforcement.PlugTest do
  use ExUnit.Case, async: true

  alias Edict.Cache.{Document, Store}
  alias Edict.Enforcement.Plug, as: EdictPlug

  @cache_name :plug_test_cache

  setup do
    {:ok, _} = Cachex.start_link(@cache_name)

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

    opts =
      EdictPlug.init(
        edict_config: edict_config,
        action: :read,
        entity_type: :project,
        entity_from: fn conn -> conn.params["id"] end
      )

    %{edict_config: edict_config, opts: opts}
  end

  test "authorized request assigns document and roles", %{opts: opts} do
    conn =
      Plug.Test.conn(:get, "/projects/7", %{})
      |> Map.put(:params, %{"id" => "7"})
      |> Plug.Conn.assign(:current_user, %{id: "user-1"})

    result = EdictPlug.call(conn, opts)

    refute result.halted
    assert %Document{} = result.assigns[:edict_document]
    assert :admin in result.assigns[:current_user_roles]
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
end
