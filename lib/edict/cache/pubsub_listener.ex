defmodule Edict.Cache.PubSubListener do
  @moduledoc """
  GenServer that listens for cross-node version bump broadcasts.

  When a role change happens on another node, this process receives the
  PubSub message and updates the local Cachex version so the next
  permission check detects the staleness.
  """

  use GenServer

  @doc "Starts the PubSub listener."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @impl true
  def init(opts) do
    cache = Keyword.fetch!(opts, :cache)
    pubsub = Keyword.fetch!(opts, :pubsub)
    topic = Keyword.get(opts, :topic, "edict:versions")

    {:ok, %{cache: cache, pubsub: pubsub, topic: topic}, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    Phoenix.PubSub.subscribe(state.pubsub, state.topic)
    {:noreply, state}
  end

  @impl true
  def handle_info({:edict_version_bump, user_id, new_version}, state) do
    Edict.Cache.Store.set_version(state.cache, user_id, new_version)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
