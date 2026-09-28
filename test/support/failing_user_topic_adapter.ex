defmodule Edict.Test.FailingUserTopicAdapter do
  # A PubSub adapter that fails broadcasts to per-user topics only, so the
  # global topic succeeds while the user's LiveViews are never told.
  @behaviour Phoenix.PubSub.Adapter

  @impl true
  def child_spec(opts) do
    %{id: opts[:adapter_name], start: {Agent, :start_link, [fn -> :ok end]}}
  end

  @impl true
  def node_name(_adapter_name), do: node()

  @impl true
  def broadcast(_adapter_name, "edict:user:" <> _user_id, _message, _dispatcher),
    do: {:error, :down}

  def broadcast(_adapter_name, _topic, _message, _dispatcher), do: :ok

  @impl true
  def direct_broadcast(_adapter_name, _node_name, _topic, _message, _dispatcher), do: :ok
end
