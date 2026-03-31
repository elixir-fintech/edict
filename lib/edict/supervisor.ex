defmodule Edict.Supervisor do
  @moduledoc """
  OTP supervisor for Edict.

  Starts:
  - Cachex instance for authorization documents
  - PubSub listener for cross-node version bumps

  ## Configuration

  The consuming application must set Edict config before starting the supervisor:

      config :edict,
        repo: MyApp.Repo,
        config_module: MyApp.AuthConfig,
        pubsub: MyApp.PubSub

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
    cache_name = Keyword.get(opts, :cache_name, Application.get_env(:edict, :cache, :edict_cache))
    topic = Keyword.get(opts, :topic, Application.get_env(:edict, :topic, "edict:versions"))

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
