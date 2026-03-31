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
    test "updates local cache version when receiving a broadcast", %{
      cache: cache,
      pubsub: pubsub
    } do
      Store.set_version(cache, "user-1", 5)

      Phoenix.PubSub.broadcast(pubsub, "edict:versions", {:edict_version_bump, "user-1", 10})

      Process.sleep(50)

      assert {:ok, 10} = Store.get_version(cache, "user-1")
    end

    test "handles version bump for user with no prior version", %{
      cache: cache,
      pubsub: pubsub
    } do
      Phoenix.PubSub.broadcast(pubsub, "edict:versions", {:edict_version_bump, "new-user", 1})

      Process.sleep(50)

      assert {:ok, 1} = Store.get_version(cache, "new-user")
    end

    test "ignores unrelated messages", %{cache: cache, pubsub: pubsub} do
      Store.set_version(cache, "user-1", 5)

      Phoenix.PubSub.broadcast(pubsub, "edict:versions", {:unrelated, "data"})

      Process.sleep(50)

      assert {:ok, 5} = Store.get_version(cache, "user-1")
    end
  end
end
