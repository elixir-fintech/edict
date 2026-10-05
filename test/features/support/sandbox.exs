defmodule Edict.Features.Support.Sandbox do
  @moduledoc """
  Per-scenario setup for Edict's feature tests.

  Checks out an Ecto SQL sandbox connection, starts a uniquely named
  Cachex instance and PubSub, then seeds the scenario context with the
  Edict configs the step definitions read:

  - `:config` — the strong-actions config (account entity)
  - `:project_config` — the general config (project entity and friends)
  """

  use Cucumber.Hooks

  alias Edict.Test.Repo

  before_scenario context do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    cache = :"cucumber_cache_#{System.unique_integer([:positive])}"
    {:ok, _} = Cachex.start_link(cache)
    pubsub = :"cucumber_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: pubsub}], strategy: :one_for_one)

    # The Edict.Multi and Edict.* write APIs read app env, so point it at
    # this scenario's cache and PubSub. Scenarios run synchronously, so no
    # scenario can observe another one's values.
    Application.put_env(:edict, :repo, Repo)
    Application.put_env(:edict, :config_module, Edict.Test.Config)
    Application.put_env(:edict, :cache, cache)
    Application.put_env(:edict, :pubsub, pubsub)

    {:ok,
     Map.merge(context, %{
       repo: Repo,
       cache: cache,
       pubsub: pubsub,
       config: %{repo: Repo, cache: cache, config_module: Edict.Test.StrongConfig},
       project_config: %{
         repo: Repo,
         cache: cache,
         config_module: Edict.Test.Config,
         pubsub: pubsub,
         topic: "edict:versions"
       },
       documents: %{}
     })}
  end
end
