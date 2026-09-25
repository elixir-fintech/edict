defmodule Edict.Test.FailingPubSubAdapter do
  # A PubSub adapter that fails broadcasts to the global topic, like a Redis
  # adapter that lost its connection. Per-user broadcasts still succeed.
  @behaviour Phoenix.PubSub.Adapter

  @impl true
  def child_spec(opts) do
    %{id: opts[:adapter_name], start: {Agent, :start_link, [fn -> :ok end]}}
  end

  @impl true
  def node_name(_adapter_name), do: node()

  @impl true
  def broadcast(_adapter_name, "edict:versions", _message, _dispatcher), do: {:error, :down}
  def broadcast(_adapter_name, _topic, _message, _dispatcher), do: :ok

  @impl true
  def direct_broadcast(_adapter_name, _node_name, _topic, _message, _dispatcher), do: :ok
end
