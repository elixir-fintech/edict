defmodule Edict.TestHelpersTest do
  use ExUnit.Case

  setup do
    cache_name = :"edict_cache_#{:erlang.unique_integer([:positive])}"
    pubsub_name = :"edict_pubsub_#{:erlang.unique_integer([:positive])}"

    {:ok, _} = Cachex.start_link(cache_name)
    start_supervised!({Phoenix.PubSub, name: pubsub_name})
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Edict.Test.Repo)

    Application.put_env(:edict, :repo, Edict.Test.Repo)
    Application.put_env(:edict, :config_module, Edict.Test.Config)
    Application.put_env(:edict, :cache, cache_name)
    Application.put_env(:edict, :pubsub, pubsub_name)

    on_exit(fn ->
      Application.delete_env(:edict, :repo)
      Application.delete_env(:edict, :config_module)
      Application.delete_env(:edict, :cache)
      Application.delete_env(:edict, :pubsub)
    end)

    %{}
  end

  describe "grant_role/3" do
    test "assigns a role using entity struct" do
      org = %Edict.Test.Organization{id: "42", name: "Acme"}
      assert :ok = Edict.TestHelpers.grant_role("user-1", :admin, org)

      doc = Edict.load_document("user-1")
      assert Edict.can?(doc, :billing, org)
    end
  end

  describe "assert_can/3" do
    test "passes when user has permission" do
      org = %Edict.Test.Organization{id: "42", name: "Acme"}
      Edict.TestHelpers.grant_role("user-1", :admin, org)

      Edict.TestHelpers.assert_can("user-1", :read, org)
    end
  end

  describe "refute_can/3" do
    test "passes when user lacks permission" do
      org = %Edict.Test.Organization{id: "42", name: "Acme"}

      Edict.TestHelpers.refute_can("user-1", :read, org)
    end
  end

  describe "assert_can/3 with a strong permission" do
    test "reports the roles found in the database" do
      Application.put_env(:edict, :config_module, Edict.Test.StrongConfig)
      account = %Edict.Test.Account{id: "7"}
      Edict.TestHelpers.grant_role("alice", :treasurer, account)
      Edict.load_document("alice")
      # Revoke without notifying the cache: the cached document still grants
      Edict.Test.Repo.delete_all(Edict.Schema.UserRole)

      assert_raise ExUnit.AssertionError, ~r/Roles in the database: \[\]/, fn ->
        Edict.TestHelpers.assert_can("alice", :approve_transfer, account)
      end
    end
  end
end
