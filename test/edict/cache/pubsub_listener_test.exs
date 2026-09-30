defmodule Edict.Cache.PubSubListenerTest do
  use ExUnit.Case

  alias Edict.Cache.{PubSubListener, Store}

  setup do
    cache_name = :"edict_cache_#{:erlang.unique_integer([:positive])}"
    pubsub_name = :"edict_pubsub_#{:erlang.unique_integer([:positive])}"

    {:ok, _} = Cachex.start_link(cache_name)
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    {:ok, _pid} =
      PubSubListener.start_link(
        cache: cache_name,
        pubsub: pubsub_name,
        topic: "edict:versions",
        name: :"listener_#{:erlang.unique_integer([:positive])}"
      )

    %{cache: cache_name, pubsub: pubsub_name}
  end

  describe "handling version bump broadcasts" do
    test "drops the cached document when receiving a broadcast", %{
      cache: cache,
      pubsub: pubsub
    } do
      doc = %Edict.Cache.Document{user_id: "user-1", version: 0, roles: %{}}
      Store.put_document(cache, "user-1", doc)

      Phoenix.PubSub.broadcast(
        pubsub,
        "edict:versions",
        {:edict_version_bump, "user-1", make_ref()}
      )

      Process.sleep(50)

      assert :miss = Store.get_document(cache, "user-1")
    end

    test "ignores a bump whose version is not a reference", %{cache: cache, pubsub: pubsub} do
      version = make_ref()
      Store.set_version(cache, "user-1", version)

      Phoenix.PubSub.broadcast(pubsub, "edict:versions", {:edict_version_bump, "user-1", 0})

      Process.sleep(50)

      assert {:ok, ^version} = Store.get_version(cache, "user-1")
    end

    # A document built before any role change is tagged 0; replaying 0 after a
    # revocation must not make that document current again.
    test "a replayed old version cannot resurrect a revoked document", %{
      cache: cache,
      pubsub: pubsub
    } do
      doc = %Edict.Cache.Document{
        user_id: "user-1",
        version: 0,
        roles: %{{:project, "7"} => [:admin]}
      }

      Store.put_document(cache, "user-1", doc)
      {:ok, _version} = Store.bump_version(cache, "user-1")

      Phoenix.PubSub.broadcast(pubsub, "edict:versions", {:edict_version_bump, "user-1", 0})

      Process.sleep(50)

      assert :miss = Store.get_document(cache, "user-1")
    end

    test "updates local cache version when receiving a broadcast", %{
      cache: cache,
      pubsub: pubsub
    } do
      Store.set_version(cache, "user-1", make_ref())
      new_version = make_ref()

      Phoenix.PubSub.broadcast(
        pubsub,
        "edict:versions",
        {:edict_version_bump, "user-1", new_version}
      )

      Process.sleep(50)

      assert {:ok, ^new_version} = Store.get_version(cache, "user-1")
    end

    test "handles version bump for user with no prior version", %{
      cache: cache,
      pubsub: pubsub
    } do
      new_version = make_ref()

      Phoenix.PubSub.broadcast(
        pubsub,
        "edict:versions",
        {:edict_version_bump, "new-user", new_version}
      )

      Process.sleep(50)

      assert {:ok, ^new_version} = Store.get_version(cache, "new-user")
    end

    test "ignores unrelated messages", %{cache: cache, pubsub: pubsub} do
      version = make_ref()
      Store.set_version(cache, "user-1", version)

      Phoenix.PubSub.broadcast(pubsub, "edict:versions", {:unrelated, "data"})

      Process.sleep(50)

      assert {:ok, ^version} = Store.get_version(cache, "user-1")
    end
  end
end
