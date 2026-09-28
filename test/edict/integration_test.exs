defmodule Edict.IntegrationTest do
  use ExUnit.Case

  defmodule StrongEventLiveView do
    use Phoenix.LiveView
    use Edict.Enforcement.Authorize

    authorize("approve",
      action: :approve_transfer,
      entity_from_assigns: :account_id,
      entity_type: :account
    )

    def render(assigns), do: ~H""

    def handle_event("approve", _params, socket), do: {:noreply, socket}
  end

  import ExUnit.CaptureLog

  alias Edict.Cache.{Document, PubSubListener, Store}
  alias Edict.Enforcement.Authorize
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

      {:halt, updated_socket} =
        hook.function.({:edict_version_bump, "user-1", 2}, mounted_socket)

      # Verify the document was reloaded with the new role
      updated_doc = updated_socket.assigns.current_user_roles
      roles = Document.roles_for(updated_doc, :project, "7")
      assert :admin in roles
      assert :editor in roles
    end

    test "receives a revocation that lands while the connected LiveView mounts", %{
      config: config
    } do
      start_supervised!(
        Supervisor.child_spec({Phoenix.PubSub, name: :edict_revoke_pubsub},
          id: :edict_revoke_pubsub
        )
      )

      insert_role!("user-1", "admin", "project", "7")

      racing_config = %{
        config
        | repo: Edict.Test.RevokeDuringLoadRepo,
          pubsub: :edict_revoke_pubsub
      }

      # A transport pid makes the socket connected, so the hook subscribes
      socket = %{build_socket(%{current_user: %{id: "user-1"}}) | transport_pid: self()}
      opts = %{edict_config: racing_config, action: :read, entity_type: :project, param: "id"}

      {:cont, _socket} = EdictLiveView.on_mount(opts, %{"id" => "7"}, %{}, socket)

      assert_received {:edict_version_bump, "user-1", _version}
    end

    # On a remote node the per-user bump can reach the LiveView before
    # PubSubListener has copied the new version into the cache.
    test "halts on a bump that arrives before the cache version changes", %{config: config} do
      insert_role!("user-1", "admin", "project", "7")
      socket = build_socket(%{current_user: %{id: "user-1"}})
      opts = %{edict_config: config, action: :read, entity_type: :project, param: "id"}
      {:cont, mounted_socket} = EdictLiveView.on_mount(opts, %{"id" => "7"}, %{}, socket)

      Edict.Test.Repo.delete_all(UserRole)
      [hook] = mounted_socket.private.lifecycle.handle_info

      {:halt, result_socket} =
        hook.function.({:edict_version_bump, "user-1", make_ref()}, mounted_socket)

      assert result_socket.redirected
    end

    test "assigns roles from the DB on a bump that arrives before the cache version changes", %{
      config: config
    } do
      insert_role!("user-1", "admin", "project", "7")
      socket = build_socket(%{current_user: %{id: "user-1"}})
      opts = %{edict_config: config, action: :read, entity_type: :project, param: "id"}
      {:cont, mounted_socket} = EdictLiveView.on_mount(opts, %{"id" => "7"}, %{}, socket)

      insert_role!("user-1", "editor", "project", "7")
      [hook] = mounted_socket.private.lifecycle.handle_info

      {:halt, updated_socket} =
        hook.function.({:edict_version_bump, "user-1", make_ref()}, mounted_socket)

      assert :editor in Document.roles_for(
               updated_socket.assigns.current_user_roles,
               :project,
               "7"
             )
    end

    test "raises when on_unauthorized only patches after revocation", %{
      config: config,
      cache: cache
    } do
      insert_role!("user-1", "viewer", "project", "7")
      patching_config = Map.put(config, :config_module, Edict.Test.PatchingConfig)
      socket = build_socket(%{current_user: %{id: "user-1"}})
      opts = %{edict_config: patching_config, action: :read, entity_type: :project, param: "id"}
      {:cont, mounted_socket} = EdictLiveView.on_mount(opts, %{"id" => "7"}, %{}, socket)

      Edict.Test.Repo.delete_all(UserRole)
      {:ok, version} = Store.bump_version(cache, "user-1")
      [hook] = mounted_socket.private.lifecycle.handle_info

      assert_raise RuntimeError, ~r/redirect/, fn ->
        hook.function.({:edict_version_bump, "user-1", version}, mounted_socket)
      end
    end

    test "halts with a redirect when the mounted permission is revoked", %{
      config: config,
      cache: cache
    } do
      insert_role!("user-1", "admin", "project", "7")
      socket = build_socket(%{current_user: %{id: "user-1"}})
      opts = %{edict_config: config, action: :read, entity_type: :project, param: "id"}
      {:cont, mounted_socket} = EdictLiveView.on_mount(opts, %{"id" => "7"}, %{}, socket)

      Edict.Test.Repo.delete_all(UserRole)
      {:ok, version} = Store.bump_version(cache, "user-1")
      [hook] = mounted_socket.private.lifecycle.handle_info

      {:halt, result_socket} =
        hook.function.({:edict_version_bump, "user-1", version}, mounted_socket)

      assert result_socket.redirected
    end

    test "raises when on_unauthorized does not redirect after revocation", %{
      config: config,
      cache: cache
    } do
      insert_role!("user-1", "viewer", "project", "7")
      non_redirecting_config = Map.put(config, :config_module, Edict.Test.NonHaltingConfig)
      socket = build_socket(%{current_user: %{id: "user-1"}})

      opts = %{
        edict_config: non_redirecting_config,
        action: :read,
        entity_type: :project,
        param: "id"
      }

      {:cont, mounted_socket} = EdictLiveView.on_mount(opts, %{"id" => "7"}, %{}, socket)

      Edict.Test.Repo.delete_all(UserRole)
      {:ok, version} = Store.bump_version(cache, "user-1")
      [hook] = mounted_socket.private.lifecycle.handle_info

      assert_raise RuntimeError, ~r/redirect/, fn ->
        hook.function.({:edict_version_bump, "user-1", version}, mounted_socket)
      end
    end
  end

  describe "load_document when the cache is not running" do
    @describetag :capture_log

    test "returns the roles from the DB", %{config: config} do
      insert_role!("user-1", "admin", "project", "7")
      down_config = Map.put(config, :cache, :edict_cache_not_started)

      doc = Helpers.load_document(down_config, "user-1")

      assert [:admin] = Document.roles_for(doc, :project, "7")
    end

    test "emits a cache unavailable telemetry event", %{config: config} do
      down_config = Map.put(config, :cache, :edict_cache_not_started)
      ref = :telemetry_test.attach_event_handlers(self(), [[:edict, :cache, :unavailable]])

      Helpers.load_document(down_config, "user-1")

      assert_received {[:edict, :cache, :unavailable], ^ref, %{count: 1},
                       %{user_id: "user-1", reason: :no_cache}}
    end

    test "logs an error", %{config: config} do
      down_config = Map.put(config, :cache, :edict_cache_not_started)

      log = capture_log(fn -> Helpers.load_document(down_config, "user-1") end)

      assert log =~ "Edict cache unavailable"
    end
  end

  describe "strong actions in Plug and LiveView" do
    setup %{config: config} do
      insert_role!("alice", "treasurer", "account", "7")
      strong_config = Map.put(config, :config_module, Edict.Test.StrongConfig)
      # Document.new/3 only keeps roles whose atoms exist, and they exist once
      # the config module is loaded; nothing else loads it before priming
      Code.ensure_loaded!(Edict.Test.StrongConfig)
      # Prime the cache, then revoke without notifying it: a stale cache
      Helpers.load_document(strong_config, "alice")
      Edict.Test.Repo.delete_all(UserRole)

      %{strong_config: strong_config}
    end

    test "Plug denies a strong action revoked in the DB", %{strong_config: strong_config} do
      opts =
        EdictPlug.init(
          edict_config: strong_config,
          action: :approve_transfer,
          entity_type: :account,
          param: "id"
        )

      conn =
        Plug.Test.conn(:post, "/accounts/7/approve", %{})
        |> Map.put(:params, %{"id" => "7"})
        |> Plug.Conn.assign(:current_user, %{id: "alice"})

      result = EdictPlug.call(conn, opts)

      assert result.halted
      assert result.status == 403
    end

    test "LiveView mount halts on a strong action revoked in the DB", %{
      strong_config: strong_config
    } do
      socket = build_socket(%{current_user: %{id: "alice"}})

      opts = %{
        edict_config: strong_config,
        action: :approve_transfer,
        entity_type: :account,
        param: "id"
      }

      {:halt, result_socket} = EdictLiveView.on_mount(opts, %{"id" => "7"}, %{}, socket)

      assert result_socket.redirected
    end

    test "authorize event denies a strong action revoked in the DB", %{
      strong_config: strong_config
    } do
      # Still grants treasurer: the setup revoked without notifying the cache
      stale_doc = Helpers.load_document(strong_config, "alice")

      socket =
        build_socket(%{
          account_id: "7",
          current_user_roles: stale_doc,
          edict_config: strong_config
        })

      {:cont, mounted} =
        Authorize.on_mount(StrongEventLiveView, %{}, %{}, socket)

      [hook] = mounted.private.lifecycle.handle_event

      {:halt, result} = hook.function.("approve", %{}, mounted)

      assert result.redirected
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

  # A version only marks a document fresh when it equals the current version,
  # so a version value must never be reused while a document carrying it is
  # still cached.
  describe "version reuse" do
    test "a role change after the version key expires does not revive a cached document",
         %{config: config, cache: cache} do
      {:ok, _} = Edict.Core.assign_role(config, "user-1", "admin", "project", "7")
      Helpers.load_document(config, "user-1")

      # Simulate TTL expiry of the version key while the document stays cached
      Cachex.del(cache, {:auth_version, "user-1"})
      {:ok, :revoked} = Edict.Core.revoke_role(config, "user-1", "admin", "project", "7")

      doc = Helpers.load_document(config, "user-1")

      assert [] == Document.roles_for(doc, :project, "7")
    end

    test "role changes on two nodes do not reuse a version on a third node",
         %{config: config, cache: cache, pubsub: pubsub} do
      node_a_cache = :"node_a_#{:erlang.unique_integer([:positive])}"
      node_b_cache = :"node_b_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Cachex.start_link(node_a_cache)
      {:ok, _} = Cachex.start_link(node_b_cache)
      node_a = %{config | cache: node_a_cache}
      node_b = %{config | cache: node_b_cache}

      listener =
        start_supervised!(
          {PubSubListener,
           cache: cache,
           pubsub: pubsub,
           topic: "edict:versions",
           name: :"listener_#{:erlang.unique_integer([:positive])}"}
        )

      {:ok, _} = Edict.Core.assign_role(node_b, "user-1", "admin", "project", "7")
      :sys.get_state(listener)
      Helpers.load_document(config, "user-1")

      {:ok, _} = Edict.Core.assign_role(node_a, "user-1", "editor", "project", "7")
      :sys.get_state(listener)
      doc = Helpers.load_document(config, "user-1")

      assert [:admin, :editor] == doc |> Document.roles_for(:project, "7") |> Enum.sort()
    end
  end

  # A role change can commit between the rebuild's role query and its version
  # read. Ecto emits the query telemetry event in the calling process right
  # after the query runs, so a one-shot handler performs the concurrent role
  # change at exactly that point.
  describe "rebuild racing a role change" do
    test "roles read before a concurrent role change are not tagged with the newer version",
         %{config: config, cache: cache} do
      insert_role!("user-1", "admin", "project", "7")
      Store.set_version(cache, "user-1", 1)
      handler_id = "concurrent-role-change"
      on_exit(fn -> :telemetry.detach(handler_id) end)

      :telemetry.attach(
        handler_id,
        [:edict, :test, :repo, :query],
        fn _event, _measurements, _metadata, _handler_config ->
          :telemetry.detach(handler_id)
          insert_role!("user-1", "editor", "project", "7")
          Store.bump_version(cache, "user-1")
        end,
        nil
      )

      Helpers.load_document(config, "user-1")
      doc = Helpers.load_document(config, "user-1")

      assert 2 == length(Edict.Core.list_roles(config, "user-1"))
      assert [:admin, :editor] == doc |> Document.roles_for(:project, "7") |> Enum.sort()
    end
  end
end
