defmodule Edict.Features.StepDefinitions.ActionDerivationSteps do
  @moduledoc """
  Step definitions for action_derivation.feature.

  Every scenario compiles a throwaway router (see `Edict.Test.RouterFactory`)
  and inspects the guards `use Edict.Router` recorded, or the compile error
  it raised. The app env points at `Edict.Test.Config` for the whole scenario,
  so the router's compile-time validation sees the test config.
  """

  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias Edict.Test.RouterFactory

  @config Edict.Test.Config

  step "{string} is aliased to {string} in the config",
       %{args: [action, permission]} = context do
    assert @config.permission_alias(String.to_existing_atom(action)) ==
             String.to_existing_atom(permission)

    context
  end

  step "{string} has no alias in the config", %{args: [action]} = context do
    assert is_nil(@config.permission_alias(String.to_existing_atom(action)))
    context
  end

  step "a {string} route for {string} is declared inside an edict block",
       %{args: [action, entity_type]} = context do
    compilation = try_compile_edict_route(entity_type, action)
    Map.put(context, :compilation, compilation)
  end

  step "a {string} route for {string} is declared inside an edict block without {string}",
       %{args: [action, entity_type, _permission_option]} = context do
    compilation = try_compile_edict_route(entity_type, action)
    Map.put(context, :compilation, compilation)
  end

  step "a {string} route declares {string}", %{args: [action, declaration]} = context do
    # The declaration reads "permission: :billing"; :billing is only granted on
    # :organization, so that is the entity type the route is declared for.
    permission = declaration |> String.trim_leading("permission: :") |> String.to_atom()
    compilation = try_compile_edict_route("organization", action, permission: permission)
    Map.put(context, :compilation, compilation)
  end

  step "the route is guarded with permission {string} on entity type {string}",
       %{args: [permission, entity_type]} = context do
    {:ok, router} = context.compilation
    [guard] = router.__edict_routes__()

    assert guard.kind == :controller
    assert guard.permission == String.to_existing_atom(permission)
    assert guard.entity_type == String.to_existing_atom(entity_type)
    context
  end

  step "the route is guarded with permission {string}", %{args: [permission]} = context do
    {:ok, router} = context.compilation
    [guard] = router.__edict_routes__()

    assert guard.kind == :controller
    assert guard.permission == String.to_existing_atom(permission)
    context
  end

  defp try_compile_edict_route(entity_type, action, route_opts \\ []) do
    {:ok, RouterFactory.compile_edict_route(entity_type, action, route_opts)}
  rescue
    e in CompileError -> {:error, e}
  end

  step "compilation fails mentioning {string} and both remedies", %{args: [action]} = context do
    {:error, %CompileError{} = error} = context.compilation
    description = error.description

    assert description =~ action
    assert description =~ "permission:" <> ""
    assert description =~ "permission_aliases"
    context
  end

  step "no role grants {string} on {string}", %{args: [permission, entity_type]} = context do
    refute @config.valid_permission?(
             String.to_existing_atom(permission),
             String.to_atom(entity_type)
           )

    context
  end

  step "compilation fails mentioning the entity type and the permission", context do
    {:error, %CompileError{} = error} = context.compilation

    assert error.description =~ ":spaceship"
    assert error.description =~ ":read"
    context
  end
end
