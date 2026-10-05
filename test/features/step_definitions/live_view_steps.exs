defmodule Edict.Features.StepDefinitions.LiveViewSteps do
  @moduledoc """
  Step definitions for live_view_mount.feature.
  """

  use Cucumber.StepDefinition
  import Ecto.Query
  import ExUnit.Assertions

  alias Edict.Cache.Store
  alias Edict.Enforcement.LiveView, as: EdictLiveView
  alias Edict.Schema.UserRole
  alias Edict.Test.LiveSocket

  step "the LiveView guards {string} on {string} from param {string}",
       %{
         args: [action, entity, param]
       } = context do
    context
    |> Map.put(:lv_action, String.to_existing_atom(action))
    |> Map.put(:lv_entity, String.to_existing_atom(entity))
    |> Map.put(:lv_param, param)
  end

  step "{word} mounts the LiveView for project {string}", %{args: [user, id]} = context do
    Map.put(context, :mount, mount(context, user, %{context.lv_param => id}))
  end

  step "{word} mounts the LiveView without the project param", %{args: [user]} = context do
    Map.put(context, :mount, mount(context, user, %{}))
  end

  step "{word} mounts the LiveView with project params {string} and {string}",
       %{args: [user, first, second]} = context do
    Map.put(context, :mount, mount(context, user, %{context.lv_param => [first, second]}))
  end

  step "{word} mounts the LiveView for project {string} with action {string}",
       %{args: [user, id, action]} = context do
    outcome =
      try do
        mount(%{context | lv_action: String.to_atom(action)}, user, %{context.lv_param => id})
      rescue
        e in ArgumentError -> {:raised, e}
      end

    Map.put(context, :outcome, outcome)
  end

  step "{word} mounted the LiveView for project {string}", %{args: [user, id]} = context do
    {:cont, socket} = mount(context, user, %{context.lv_param => id})
    Map.put(context, :mounted_socket, socket)
  end

  step ~r/^(\w+)'s roles are revoked and a version bump arrives$/, %{args: [user]} = context do
    context.repo.delete_all(from ur in UserRole, where: ur.user_id == ^user)
    {:ok, version} = Store.bump_version(context.cache, user)

    Map.put(context, :bump, run_bump_hook(context.mounted_socket, user, version))
  end

  step ~r/^an unrelated role change bumps (\w+)'s version$/, %{args: [user]} = context do
    {:ok, _} = Edict.assign_role(user, :viewer, :project, "9")
    {:ok, version} = Store.bump_version(context.cache, user)

    Map.put(context, :bump, run_bump_hook(context.mounted_socket, user, version))
  end

  step "the mount continues with her authorization document assigned", context do
    assert match?({:cont, _}, context.mount)
    {:cont, socket} = context.mount
    assert %Edict.Cache.Document{} = socket.assigns[:current_user_roles]
    context
  end

  step "the mount halts with a redirect", context do
    assert match?({:halt, _}, context.mount)
    {:halt, socket} = context.mount
    assert socket.redirected
    context
  end

  step "the LiveView halts with a redirect", context do
    assert match?({:halt, _}, context.bump)
    {:halt, socket} = context.bump
    assert socket.redirected
    context
  end

  step "the LiveView stays open and the bump never reaches handle_info", context do
    # A passing re-check halts the hook chain with an unredirected socket:
    # consumed by Edict, invisible to the view's handle_info/2.
    assert match?({:halt, _}, context.bump)
    {:halt, socket} = context.bump
    refute socket.redirected
    assert %Edict.Cache.Document{} = socket.assigns[:current_user_roles]
    context
  end

  step "the mount raises ArgumentError", context do
    assert match?({:raised, %ArgumentError{}}, context.outcome)
    context
  end

  defp mount(context, user, params) do
    opts = %{
      edict_config: context.project_config,
      action: context.lv_action,
      entity_type: context.lv_entity,
      param: context.lv_param
    }

    socket = LiveSocket.build(%{current_user: %{id: user}})
    EdictLiveView.on_mount(opts, params, %{}, socket)
  end

  defp run_bump_hook(socket, user, version) do
    [hook] = socket.private.lifecycle.handle_info
    hook.function.({:edict_version_bump, user, version}, socket)
  end
end
