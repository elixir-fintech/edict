defmodule Edict.Features.StepDefinitions.LiveViewDeclarationSteps do
  @moduledoc """
  Step definitions for live_view_declarations.feature.

  Each scenario compiles a throwaway LiveView with the declared
  `edict_entity` and `authorize` sugar, then asserts the exact
  `__edict_authorizations__/0` map the sugar expanded to. The audit scenario
  instead scans a fixture source with `Edict.Audit` — the module behind
  `mix edict.audit` — and asserts its finding and exit decision.
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

  step ~r/^a LiveView with handle_event clauses for "(?<first>\w+)" and "(?<second>\w+)"$/,
       %{args: [first, second]} = context do
    Map.put(context, :audit_events, [first, second])
  end

  step ~r/^only "(?<event>\w+)" is declared$/, %{args: [event]} = context do
    Map.put(context, :audit_declarations, [event])
  end

  # The scan runs against a fixture built from the scenario's events and
  # declarations, never the repo's own sources.
  step ~r/^"mix edict.audit" runs$/, context do
    findings = Edict.Audit.scan_source(audit_source(context), "audit_live.ex")

    context
    |> Map.put(:audit_findings, findings)
    |> Map.put(:audit_exit, Edict.Audit.exit_status(findings))
  end

  step ~r/^it reports "(?<event>\w+)" as undeclared and exits non-zero$/,
       %{args: [event]} = context do
    [finding] = context.audit_findings

    assert finding.undeclared == [event]
    assert context.audit_exit == {:shutdown, 1}
    context
  end

  defp audit_source(context) do
    declarations =
      Enum.map_join(context.audit_declarations, "\n", &"authorize \"#{&1}\", :write")

    handlers =
      Enum.map_join(context.audit_events, "\n", fn event ->
        "def handle_event(\"#{event}\", _params, socket), do: {:noreply, socket}"
      end)

    """
    defmodule MyAppWeb.AuditLive do
      use Phoenix.LiveView
      use Edict.Enforcement.Authorize

      edict_entity :project, from: :project_id
      #{declarations}

      #{handlers}
    end
    """
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
