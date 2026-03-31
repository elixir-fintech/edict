defmodule Edict.Supervisor do
  @moduledoc """
  OTP supervisor for Edict.

  Starts:
  - Cachex instance for authorization documents
  - PubSub listener for cross-node version bumps

  ## Usage

      children = [
        MyApp.Repo,
        {Phoenix.PubSub, name: MyApp.PubSub},
        {Edict.Supervisor, pubsub: MyApp.PubSub},
        MyAppWeb.Endpoint
      ]
  """

  use Supervisor

  @doc "Starts the Edict supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    cache_name = Keyword.get(opts, :cache_name, :edict_cache)
    topic = Keyword.get(opts, :topic, "edict:versions")
    ttl = Keyword.get(opts, :ttl, Application.get_env(:edict, :ttl, :timer.minutes(10)))

    Application.put_env(:edict, :cache, cache_name)
    Application.put_env(:edict, :pubsub, pubsub)
    Application.put_env(:edict, :topic, topic)
    Application.put_env(:edict, :ttl, ttl)

    children = [
      {Cachex, name: cache_name},
      {Edict.Cache.PubSubListener, cache: cache_name, pubsub: pubsub, topic: topic}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 30)
  end

  @doc "Returns the default cache name."
  @spec cache_name() :: atom()
  def cache_name, do: :edict_cache
end
