defmodule Edict.Test.EventMacros do
  @moduledoc """
  Generates a `handle_event/3` clause from a macro, for the scenario
  pinning that the compile-time event check sees macro-generated clauses.
  """

  defmacro handle(event) do
    quote do
      def handle_event(unquote(event), _params, socket), do: {:noreply, socket}
    end
  end
end
