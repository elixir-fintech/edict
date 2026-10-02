defmodule Edict.Features.StrongActionsTest do
  use Chabis.Feature, async: false, file: "strong_actions.feature"

  import Ecto.Query

  alias Edict.Enforcement.Helpers
  alias Edict.Schema.UserRole
  alias Edict.Test.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    cache = :"strong_cache_#{System.unique_integer([:positive])}"
    {:ok, _} = Cachex.start_link(cache)

    %{
      config: %{repo: Repo, cache: cache, config_module: Edict.Test.StrongConfig},
      documents: %{}
    }
  end

  defgiven ~r/^"(?<action>[^"]+)" is a strong action$/, %{action: action}, _state do
    assert Edict.Test.StrongConfig.strong_action?(String.to_existing_atom(action))
  end

  defgiven ~r/^user "(?<user>[^"]+)" has the role "(?<role>[^"]+)" on account "(?<id>[^"]+)"$/,
           %{user: user, role: role, id: id},
           _state do
    Repo.insert!(%UserRole{user_id: user, role: role, entity_type: "account", entity_id: id})
  end

  defgiven ~r/^user "(?<user>[^"]+)" has no roles$/, %{user: user}, _state do
    assert Repo.all(from ur in UserRole, where: ur.user_id == ^user) == []
  end

  defgiven ~r/^(?<user>\w+)'s authorization document is cached$/,
           %{user: user},
           %{config: config, documents: documents} do
    {:ok, %{documents: Map.put(documents, user, Helpers.load_document(config, user))}}
  end

  defwhen ~r/^(?<user>\w+)'s "(?<role>[^"]+)" role on account "(?<id>[^"]+)" is revoked without notifying the cache$/,
          %{user: user, role: role, id: id},
          _state do
    Repo.delete_all(
      from ur in UserRole,
        where:
          ur.user_id == ^user and ur.role == ^role and ur.entity_type == "account" and
            ur.entity_id == ^id
    )
  end

  defwhen ~r/^(?<user>\w+) is given the role "(?<role>[^"]+)" on account "(?<id>[^"]+)" without notifying the cache$/,
          %{user: user, role: role, id: id},
          _state do
    Repo.insert!(%UserRole{user_id: user, role: role, entity_type: "account", entity_id: id})
  end

  defthen ~r/^(?<user>\w+) cannot "(?<action>[^"]+)" on account "(?<id>[^"]+)"$/,
          %{user: user, action: action, id: id},
          %{config: config, documents: documents} do
    refute Helpers.authorized?(
             config,
             documents[user],
             String.to_existing_atom(action),
             :account,
             id,
             []
           )
  end

  defthen ~r/^(?<user>\w+) can "(?<action>[^"]+)" on account "(?<id>[^"]+)" with strong: false$/,
          %{user: user, action: action, id: id},
          %{config: config, documents: documents} do
    assert Helpers.authorized?(
             config,
             documents[user],
             String.to_existing_atom(action),
             :account,
             id,
             strong: false
           )
  end

  defthen ~r/^(?<user>\w+) can "(?<action>[^"]+)" on account "(?<id>[^"]+)"$/,
          %{user: user, action: action, id: id},
          %{config: config, documents: documents} do
    assert Helpers.authorized?(
             config,
             documents[user],
             String.to_existing_atom(action),
             :account,
             id,
             []
           )
  end
end
