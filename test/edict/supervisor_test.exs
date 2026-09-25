defmodule Edict.SupervisorTest do
  use ExUnit.Case, async: true

  test "init rejects a config module missing required functions" do
    assert_raise ArgumentError, ~r/missing required functions/, fn ->
      Edict.Supervisor.init(
        pubsub: :edict_unused_pubsub,
        cache_name: :edict_unused_cache,
        config_module: Edict.Test.Account
      )
    end
  end
end
