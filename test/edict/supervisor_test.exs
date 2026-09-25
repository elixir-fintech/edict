defmodule Edict.SupervisorTest do
  # Not async: reads the global :edict app env
  use ExUnit.Case

  test "init rejects a config module missing required functions" do
    assert_raise ArgumentError, ~r/missing required functions/, fn ->
      Edict.Supervisor.init(
        pubsub: :edict_unused_pubsub,
        cache_name: :edict_unused_cache,
        config_module: Edict.Test.Account
      )
    end
  end

  test "init requires a config module when none is configured" do
    assert_raise ArgumentError, ~r/:config_module/, fn ->
      Edict.Supervisor.init(pubsub: :edict_unused_pubsub, cache_name: :edict_unused_cache)
    end
  end
end
