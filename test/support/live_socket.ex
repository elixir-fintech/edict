defmodule Edict.Test.LiveSocket do
  @moduledoc """
  Builds bare LiveView sockets for feature steps, mirroring the unit tests.
  """

  @doc "Builds a disconnected socket with the given assigns."
  @spec build(map()) :: Phoenix.LiveView.Socket.t()
  def build(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}}, assigns),
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
  end
end
