defmodule Edict.SupervisorTest do
  # Not async: sets the global :edict app env
  use ExUnit.Case

  setup do
    Application.put_env(:edict, :repo, Edict.Test.Repo)
    Application.put_env(:edict, :pubsub, :edict_unused_pubsub)

    on_exit(fn ->
      Application.delete_env(:edict, :repo)
      Application.delete_env(:edict, :pubsub)
      Application.delete_env(:edict, :config_module)
    end)
  end

  test "init rejects a config module missing required functions" do
    Application.put_env(:edict, :config_module, Edict.Test.Account)

    assert_raise ArgumentError, ~r/missing required functions/, fn ->
      Edict.Supervisor.init([])
    end
  end

  test "init requires a config module when none is configured" do
    assert_raise ArgumentError, ~r/:config_module/, fn ->
      Edict.Supervisor.init([])
    end
  end

  test "init rejects options, since checks only read the app config" do
    Application.put_env(:edict, :config_module, Edict.Test.Config)

    assert_raise ArgumentError, ~r/app config/, fn ->
      Edict.Supervisor.init(cache_name: :edict_unused_cache)
    end
  end
end
