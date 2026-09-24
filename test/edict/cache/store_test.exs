defmodule Edict.Cache.StoreTest do
  use ExUnit.Case

  alias Edict.Cache.{Document, Store}

  setup do
    cache_name = :"edict_cache_#{:erlang.unique_integer([:positive])}"
    {:ok, _pid} = Cachex.start_link(cache_name)

    %{cache: cache_name}
  end

  describe "put_document/3 and get_document/2" do
    test "stores and retrieves a document", %{cache: cache} do
      doc = %Document{user_id: "user-1", version: 1, roles: %{{:org, "1"} => [:admin]}}

      :ok = Store.put_document(cache, "user-1", doc)
      assert {:ok, ^doc} = Store.get_document(cache, "user-1")
    end

    test "returns :miss for unknown user", %{cache: cache} do
      assert :miss = Store.get_document(cache, "unknown")
    end
  end

  describe "get_version/2 and bump_version/2" do
    test "bump_version returns a different version each time", %{cache: cache} do
      {:ok, v1} = Store.bump_version(cache, "user-1")
      {:ok, v2} = Store.bump_version(cache, "user-1")

      assert v1 != v2
    end

    test "get_version returns current version", %{cache: cache} do
      {:ok, version} = Store.bump_version(cache, "user-1")
      assert {:ok, ^version} = Store.get_version(cache, "user-1")
    end

    test "get_version returns 0 for unknown user", %{cache: cache} do
      assert {:ok, 0} = Store.get_version(cache, "unknown")
    end
  end

  describe "set_version/3" do
    test "sets a specific version value", %{cache: cache} do
      :ok = Store.set_version(cache, "user-1", 42)
      assert {:ok, 42} = Store.get_version(cache, "user-1")
    end
  end

  describe "delete/2" do
    test "removes document and version", %{cache: cache} do
      doc = %Document{user_id: "user-1", version: 1, roles: %{}}
      Store.put_document(cache, "user-1", doc)
      Store.bump_version(cache, "user-1")

      :ok = Store.delete(cache, "user-1")

      assert :miss = Store.get_document(cache, "user-1")
      assert {:ok, 0} = Store.get_version(cache, "user-1")
    end
  end
end
