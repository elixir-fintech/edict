defmodule Edict.InvalidatorTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Edict.Invalidator

  setup do
    cache_name = :"edict_cache_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = Cachex.start_link(cache_name)

    config = %{cache: cache_name, topic: "edict:versions"}

    %{config: config}
  end

  describe "invalidate/2 when the global broadcast fails" do
    @describetag :capture_log

    setup %{config: config} do
      failing_pubsub = :"failing_pubsub_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec(
          {Phoenix.PubSub, name: failing_pubsub, adapter: Edict.Test.FailingPubSubAdapter},
          id: failing_pubsub
        )
      )

      %{failing_config: Map.put(config, :pubsub, failing_pubsub)}
    end

    test "returns :ok, since the DB change has committed", %{failing_config: failing_config} do
      assert :ok = Invalidator.invalidate(failing_config, "user-1")
    end

    test "emits a broadcast failed telemetry event", %{failing_config: failing_config} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:edict, :invalidation, :broadcast_failed]])

      Invalidator.invalidate(failing_config, "user-1")

      assert_received {[:edict, :invalidation, :broadcast_failed], ^ref, %{count: 1},
                       %{user_id: "user-1", topic: "edict:versions", reason: :down}}
    end

    test "logs an error", %{failing_config: failing_config} do
      log = capture_log(fn -> Invalidator.invalidate(failing_config, "user-1") end)

      assert log =~ "Edict invalidation broadcast failed"
    end
  end
end
