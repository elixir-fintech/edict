defmodule Edict.Features.StepDefinitions.LiveViewDeclarationSteps do
  @moduledoc """
  Step definitions for live_view_declarations.feature.

  Each scenario compiles a throwaway LiveView with the declared
  `edict_entity` and `authorize` sugar, then asserts the exact
  `__edict_authorizations__/0` map the sugar expanded to.
  """

  use Cucumber.StepDefinition
  import ExUnit.Assertions

  step ~r/^a LiveView declared "edict_entity :(?<type>\w+), from: :(?<assign>\w+)"$/,
       %{args: [type, assign]} = context do
    context
    |> Map.put(:entity_type, String.to_atom(type))
    |> Map.put(:entity_assign, String.to_atom(assign))
  end

  step ~r/^it declares 'authorize "(?<event>\w+)", :(?<permission>\w+)'$/,
       %{args: [event, permission]} = context do
    context
    |> compile_view(~s|authorize "#{event}", :#{permission}|)
    |> Map.put(
      :expected,
      %{event => {String.to_atom(permission), context.entity_assign, context.entity_type}}
    )
  end

  step ~r/^it declares 'authorize \[(?<events>[^\]]+)\], :(?<permission>\w+)'$/,
       %{args: [events, permission]} = context do
    names = events |> String.split(", ") |> Enum.map(&String.replace(&1, ~s("), ""))
    quoted_names = Enum.map_join(names, ", ", &"\"#{&1}\"")
    guard = {String.to_atom(permission), context.entity_assign, context.entity_type}

    context
    |> compile_view("authorize [#{quoted_names}], :#{permission}")
    |> Map.put(:expected, Map.new(names, &{&1, guard}))
  end

  step "the {string} event is guarded with permission {string} on entity type {string} from assign {string}",
       %{args: [event, permission, entity_type, assign]} = context do
    assert context.module.__edict_authorizations__() == %{
             event =>
               {String.to_atom(permission), String.to_atom(assign), String.to_atom(entity_type)}
           }

    context
  end

  step "the {string} and {string} events are guarded with permission {string} on entity type {string}",
       %{args: [first, second, permission, entity_type]} = context do
    pair = {String.to_atom(permission), context.entity_assign, String.to_atom(entity_type)}

    assert context.module.__edict_authorizations__() == %{first => pair, second => pair}
    context
  end

  defp compile_view(context, declaration) do
    module = "Edict.Features.Declarations.Compiled#{System.unique_integer([:positive])}"

    [{compiled, _binary}] =
      Code.compile_string("""
      defmodule #{module} do
        use Phoenix.LiveView
        use Edict.Enforcement.Authorize

        edict_entity #{inspect(context.entity_type)}, from: #{inspect(context.entity_assign)}
        #{declaration}

        def render(assigns), do: ~H""

        def handle_event(_event, _params, socket), do: {:noreply, socket}
      end
      """)

    Map.put(context, :module, compiled)
  end
end
