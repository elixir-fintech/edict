defmodule Edict.Supervisor do
  @moduledoc """
  OTP supervisor for Edict.

  Starts:
  - Cachex instance for authorization documents
  - PubSub listener for cross-node version bumps

  On start it validates the configured config module with
  `Edict.validate_config!/1`, which also loads it.

  ## Configuration

      config :edict,
        repo: MyApp.Repo,
        config_module: MyApp.AuthConfig,
        pubsub: MyApp.PubSub

      # Optional, with defaults:
      # cache: :edict_cache,
      # topic: "edict:versions",
      # ttl: :timer.minutes(10)

  ## Usage

      children = [
        MyApp.Repo,
        {Phoenix.PubSub, name: MyApp.PubSub},
        Edict.Supervisor,
        MyAppWeb.Endpoint
      ]

  It takes no options: Edict reads all settings from the `:edict` app config.
  """

  use Supervisor

  @doc "Starts the Edict supervisor. It takes no options; pass none (or `[]`)."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init([]) do
    config = Edict.config()

    # Loads the config module at startup: documents keep only roles whose atoms
    # exist, and they exist once the module is loaded.
    Edict.validate_config!(config.config_module)

    children = [
      {Cachex, name: config.cache},
      {Edict.Cache.PubSubListener,
       cache: config.cache, pubsub: config.pubsub, topic: config.topic}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 30)
  end

  # Checks read their settings through Edict.config/0, so options given here
  # would configure a supervisor nothing else agrees with.
  def init(_opts) do
    raise ArgumentError,
          "Edict.Supervisor takes no options; configure :edict in your app config"
  end
end
