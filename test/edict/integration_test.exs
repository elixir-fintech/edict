defmodule Edict.IntegrationTest do
  use ExUnit.Case

  alias Edict.Cache.{Document, PubSubListener, Store}
  alias Edict.Enforcement.Helpers
  alias Edict.Enforcement.LiveView, as: EdictLiveView
  alias Edict.Enforcement.Plug, as: EdictPlug
  alias Edict.Schema.UserRole

  setup do
    cache_name = :"int_cache_#{:erlang.unique_integer([:positive])}"
    pubsub_name = :"int_pubsub_#{:erlang.unique_integer([:positive])}"

    {:ok, _} = Cachex.start_link(cache_name)
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Edict.Test.Repo)

    config = %{
      repo: Edict.Test.Repo,
      cache: cache_name,
      config_module: Edict.Test.Config,
      pubsub: pubsub_name,
      topic: "edict:versions"
    }

    %{config: config, cache: cache_name, pubsub: pubsub_name}
  end

  defp insert_role!(user_id, role, entity_type, entity_id) do
    Edict.Test.Repo.insert!(%UserRole{
      user_id: user_id,
      entity_type: entity_type,
      entity_id: entity_id,
      role: role
    })
  end

  defp build_socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}}, assigns),
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
  end

  # T5 — LiveView version bump hook reloads document
  describe "LiveView version bump hook" do
    test "reloads document when version bump arrives", %{config: config, cache: cache} do
      insert_role!("user-1", "admin", "project", "7")

      # Prime the cache
      Store.set_version(cache, "user-1", 1)
      doc = Helpers.load_document(config, "user-1")
      assert [:admin] = Document.roles_for(doc, :project, "7")

      # Mount LiveView to attach the hook
      socket = build_socket(%{current_user: %{id: "user-1"}})

      opts = %{
        edict_config: config,
        action: :read,
        entity_type: :project,
        entity_from: fn params -> params["id"] end
      }

      {:cont, mounted_socket} = EdictLiveView.on_mount(opts, %{"id" => "7"}, %{}, socket)

      # Add a new role in DB and bump version
      insert_role!("user-1", "editor", "project", "7")
      Store.bump_version(cache, "user-1")

      # Extract the attached hook function and invoke it
      [hook] = mounted_socket.private.lifecycle.handle_info

      {:cont, updated_socket} =
        hook.function.({:edict_version_bump, "user-1", 2}, mounted_socket)

      # Verify the document was reloaded with the new role
      updated_doc = updated_socket.assigns.current_user_roles
      roles = Document.roles_for(updated_doc, :project, "7")
      assert :admin in roles
      assert :editor in roles
    end
  end

  # T6 — Plug and LiveView with DB-backed state (cold cache)
  describe "Plug integration with DB" do
    test "loads document from DB on cold cache", %{config: config} do
      insert_role!("user-1", "admin", "project", "7")

      conn =
        Plug.Test.conn(:get, "/projects/7", %{})
        |> Map.put(:params, %{"id" => "7"})
        |> Plug.Conn.assign(:current_user, %{id: "user-1"})

      opts =
        EdictPlug.init(
          edict_config: config,
          action: :read,
          entity_type: :project,
          entity_from: fn conn -> conn.params["id"] end
        )

      result = EdictPlug.call(conn, opts)

      refute result.halted
      assert %Document{} = doc = result.assigns[:current_user_roles]
      assert [:admin] = Document.roles_for(doc, :project, "7")
    end

    test "denies access when user lacks permission in DB", %{config: config} do
      insert_role!("user-1", "viewer", "project", "7")

      conn =
        Plug.Test.conn(:get, "/projects/7", %{})
        |> Map.put(:params, %{"id" => "7"})
        |> Plug.Conn.assign(:current_user, %{id: "user-1"})

      opts =
        EdictPlug.init(
          edict_config: config,
          action: :delete,
          entity_type: :project,
          entity_from: fn conn -> conn.params["id"] end
        )

      result = EdictPlug.call(conn, opts)

      assert result.halted
      assert result.status == 403
    end
  end

  describe "LiveView integration with DB" do
    test "loads document from DB on cold cache", %{config: config} do
      insert_role!("user-1", "editor", "project", "7")

      socket = build_socket(%{current_user: %{id: "user-1"}})

      opts = %{
        edict_config: config,
        action: :read,
        entity_type: :project,
        entity_from: fn params -> params["id"] end
      }

      {:cont, result_socket} = EdictLiveView.on_mount(opts, %{"id" => "7"}, %{}, socket)

      assert %Document{} = doc = result_socket.assigns[:current_user_roles]
      assert [:editor] = Document.roles_for(doc, :project, "7")
    end

    test "denies access when user lacks permission in DB", %{config: config} do
      insert_role!("user-1", "viewer", "project", "7")

      socket = build_socket(%{current_user: %{id: "user-1"}})

      opts = %{
        edict_config: config,
        action: :delete,
        entity_type: :project,
        entity_from: fn params -> params["id"] end
      }

      {:halt, result_socket} = EdictLiveView.on_mount(opts, %{"id" => "7"}, %{}, socket)

      assert result_socket.redirected
    end
  end

  # T7 — Cross-node: PubSubListener bumps version, next check rebuilds from DB
  describe "cross-node invalidation" do
    test "PubSubListener bumps version, next load_document rebuilds from DB", %{
      config: config,
      cache: cache,
      pubsub: pubsub
    } do
      # Insert role and prime cache
      insert_role!("user-1", "admin", "project", "7")
      Store.set_version(cache, "user-1", 1)
      doc = Helpers.load_document(config, "user-1")
      assert doc.version == 1

      # Start PubSubListener (simulates another node's listener)
      {:ok, _pid} =
        PubSubListener.start_link(
          cache: cache,
          pubsub: pubsub,
          topic: "edict:versions",
          name: :"listener_#{:erlang.unique_integer([:positive])}"
        )

      # Simulate a role change on "another node" — insert directly into DB
      insert_role!("user-1", "editor", "project", "7")

      # Broadcast version bump (as if from another node)
      Phoenix.PubSub.broadcast(
        pubsub,
        "edict:versions",
        {:edict_version_bump, "user-1", 2}
      )

      # Wait for PubSubListener to process
      Process.sleep(50)

      # Verify local version was bumped
      {:ok, local_version} = Store.get_version(cache, "user-1")
      assert local_version == 2

      # Next load_document detects mismatch (doc.version=1, current=2) and rebuilds
      new_doc = Helpers.load_document(config, "user-1")
      roles = Document.roles_for(new_doc, :project, "7")
      assert :admin in roles
      assert :editor in roles
    end
  end

  # T8 — Cache expiry: simulates TTL expiration by clearing cache entries
  # Cachex 4.x TTL is enforced by background janitor, not on read.
  # We simulate expiry by deleting entries directly, which exercises
  # the same code path (cache miss → rebuild from DB).
  describe "cache expiry and rebuild" do
    test "rebuilds document from DB after cache eviction", %{config: config, cache: cache} do
      insert_role!("user-1", "admin", "project", "7")
      Store.set_version(cache, "user-1", 1)

      # Build and cache the document
      doc = Helpers.load_document(config, "user-1")
      assert [:admin] = Document.roles_for(doc, :project, "7")
      assert {:ok, _} = Store.get_document(cache, "user-1")

      # Simulate TTL expiry by clearing cache
      Store.delete(cache, "user-1")
      assert :miss = Store.get_document(cache, "user-1")

      # Add a new role while cache is empty
      insert_role!("user-1", "editor", "project", "7")

      # Next load rebuilds from DB
      new_doc = Helpers.load_document(config, "user-1")
      roles = Document.roles_for(new_doc, :project, "7")
      assert :admin in roles
      assert :editor in roles
    end

    test "rebuilds when version is evicted but document remains", %{
      config: config,
      cache: cache
    } do
      insert_role!("user-1", "viewer", "organization", "1")
      Store.set_version(cache, "user-1", 1)

      doc = Helpers.load_document(config, "user-1")
      assert doc.version == 1

      # Simulate partial expiry: version evicted, document remains
      Cachex.del(cache, {:auth_version, "user-1"})
      {:ok, version} = Store.get_version(cache, "user-1")
      assert version == 0

      # Document still in cache with version 1, but current version is 0
      # This mismatch triggers a rebuild
      insert_role!("user-1", "admin", "organization", "1")

      new_doc = Helpers.load_document(config, "user-1")
      roles = Document.roles_for(new_doc, :organization, "1")
      assert :viewer in roles
      assert :admin in roles
    end
  end
end
