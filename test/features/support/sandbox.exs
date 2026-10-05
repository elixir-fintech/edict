defmodule Edict.Features.Support.Sandbox do
  @moduledoc """
  Per-scenario setup for Edict's feature tests.

  Checks out an Ecto SQL sandbox connection and starts a uniquely named
  Cachex instance, then seeds the scenario context with the Edict config
  the step definitions read.
  """

  use Cucumber.Hooks

  alias Edict.Test.Repo

  before_scenario context do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    cache = :"cucumber_cache_#{System.unique_integer([:positive])}"
    {:ok, _} = Cachex.start_link(cache)

    {:ok,
     Map.merge(context, %{
       repo: Repo,
       config: %{repo: Repo, cache: cache, config_module: Edict.Test.StrongConfig},
       documents: %{}
     })}
  end
end
