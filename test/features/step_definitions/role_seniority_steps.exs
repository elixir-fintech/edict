defmodule Edict.Features.StepDefinitions.RoleSenioritySteps do
  @moduledoc """
  Step definitions for role_seniority.feature.

  The scenarios run against `Edict.Test.Config`, whose viewer/editor/admin
  roles are chained with `extends`. The compile-failure scenarios build
  throwaway config modules and keep the outcome in the scenario context for
  the `Then` steps to assert on.
  """

  use Cucumber.StepDefinition
  import Ecto.Query
  import ExUnit.Assertions

  alias Edict.Cache.Document
  alias Edict.Enforcement.Helpers
  alias Edict.Schema.UserRole

  @config Edict.Test.Config

  step "the role {string} grants {string} on {string}",
       %{args: [role, permission, entity_type]} = context do
    assert grants?(role, permission, entity_type)
    context
  end

  step "the role {string} extends {string} and grants {string} on {string}",
       %{args: [role, parent, permission, entity_type]} = context do
    assert grants?(role, permission, entity_type)
    assert inherits?(role, parent, entity_type)
    context
  end

  step "the role {string} extends {string}", %{args: [role, parent]} = context do
    # The scenarios' entity: one linear check, no filtering to pass trivially.
    assert inherits?(role, parent, "project")
    context
  end

  step "{word} holds only the role {string} on project {string}",
       %{args: [user, role, id]} = context do
    {:ok, _} = Edict.assign_role(user, String.to_existing_atom(role), :project, id)

    # Rows store the role as a string; the document is where atoms live.
    assert [%UserRole{role: assigned}] = Edict.list_roles(user)
    assert assigned == role

    track_user(context, user, id)
  end

  # "alice is assigned {string} on project {string}" is shared with
  # role_writes.feature; defined once in role_write_steps.exs.

  step "the database holds a single role row for {word} on project {string}",
       %{args: [user, id]} = context do
    count =
      context.repo.aggregate(
        from(ur in UserRole,
          where: ur.user_id == ^user and ur.entity_type == "project" and ur.entity_id == ^id
        ),
        :count
      )

    assert count == 1
    track_user(context, user, id)
  end

  step "her document lists only {string}", %{args: [role]} = context do
    document = Helpers.load_document(context.project_config, context.seniority_user)

    assert Document.roles_for(document, :project, context.seniority_project_id) == [
             String.to_existing_atom(role)
           ]

    context
  end

  step "a role extends the undefined role {string}", %{args: [parent]} = context do
    compile_role_extending(context, manager: parent)
  end

  step "compilation fails naming {string}", %{args: [name]} = context do
    assert {%CompileError{}, description} = context.compilation
    assert description =~ name
    context
  end

  step "the role {string} extends {string} and the role {string} extends {string}",
       %{args: [first, second, other_first, other_second]} = context do
    compile_role_extending(context, [{first, second}, {other_first, other_second}])
  end

  step "compilation fails naming the cycle", context do
    assert {%CompileError{}, description} = context.compilation
    assert description =~ "cycle"
    assert description =~ ":a" and description =~ ":b"
    context
  end

  defp grants?(role, permission, entity_type) do
    String.to_existing_atom(permission) in @config.permissions_for(
      String.to_existing_atom(role),
      String.to_existing_atom(entity_type)
    )
  end

  # A role extending `parent` inherits everything it declares, so the parent's
  # effective permissions are a subset of the role's on every entity type.
  # The entity type arrives from the feature file as a string and must be an
  # atom, or permissions_for/2 falls through to [] and the check passes
  # vacuously.
  defp inherits?(role, parent, entity_type) do
    parent_permissions =
      @config.permissions_for(
        String.to_existing_atom(parent),
        String.to_existing_atom(entity_type)
      )

    role_permissions =
      @config.permissions_for(String.to_existing_atom(role), String.to_existing_atom(entity_type))

    parent_permissions -- role_permissions == []
  end

  defp track_user(context, user, project_id) do
    context
    |> Map.put(:seniority_user, user)
    |> Map.put(:seniority_project_id, project_id)
  end

  defp compile_role_extending(context, extends) do
    declarations =
      Enum.map_join(extends, "\n", fn {role, parent} ->
        """
        role :#{role} do
          extends :#{parent}
          on(:project, permissions: [:read])
        end
        """
      end)

    Map.put(context, :compilation, try_compile(declarations))
  end

  defp try_compile(role_declarations) do
    module = "Edict.Features.Seniority.Compiled#{System.unique_integer([:positive])}"

    try do
      Code.compile_string("""
      defmodule #{module} do
        use Edict.Config

        entity_types do
          entity(:project)
        end

        role :viewer do
          on(:project, permissions: [:read])
        end

      #{role_declarations}
      end
      """)

      :compiled
    rescue
      e in CompileError -> {e, e.description}
    end
  end
end
