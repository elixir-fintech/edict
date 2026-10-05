defmodule Edict.Features.StepDefinitions.PlugSteps do
  @moduledoc """
  Step definitions for plug_enforcement.feature.
  """

  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias Edict.Cache.{Document, Store}
  alias Edict.Enforcement.Plug, as: EdictPlug

  step "the plug guards {string} on {string} from param {string}",
       %{
         args: [action, entity, param]
       } = context do
    opts =
      EdictPlug.init(
        edict_config: context.project_config,
        action: String.to_existing_atom(action),
        entity_type: String.to_existing_atom(entity),
        param: param
      )

    context |> Map.put(:plug_opts, opts) |> Map.put(:plug_param, param)
  end

  step "{word} requests the project {string} page", %{args: [user, id]} = context do
    Map.put(context, :conn, run_plug(context, user_id(user), %{context.plug_param => id}))
  end

  step "{word} requests the page without the project param", %{args: [user]} = context do
    Map.put(context, :conn, run_plug(context, user_id(user), %{}))
  end

  step "{word} requests the page with project params {string} and {string}",
       %{args: [user, first, second]} = context do
    Map.put(
      context,
      :conn,
      run_plug(context, user_id(user), %{context.plug_param => [first, second]})
    )
  end

  step "a request without a user asks for project {string}", %{args: [id]} = context do
    Map.put(context, :conn, run_plug(context, nil, %{context.plug_param => id}))
  end

  step "{word} requests the project {string} page for action {string}",
       %{args: [user, id, action]} = context do
    outcome =
      try do
        # The typo must not exist as an atom, so String.to_atom/1 is deliberate.
        run_plug(
          %{context | plug_opts: %{context.plug_opts | action: String.to_atom(action)}},
          user_id(user),
          %{context.plug_param => id}
        )
      rescue
        e in ArgumentError -> {:raised, e}
      end

    Map.put(context, :outcome, outcome)
  end

  step "the database holds a blank-user document for project {string}", %{args: [id]} = context do
    doc = %Document{user_id: "", version: 1, roles: %{{:project, id} => [:admin]}}
    Store.put_document(context.cache, "", doc)
    Store.set_version(context.cache, "", 1)
    context
  end

  step "the request passes with her authorization document assigned", context do
    refute context.conn.halted
    assert %Document{} = context.conn.assigns[:current_user_roles]
    context
  end

  step "the request is halted with status {int}", %{args: [status]} = context do
    assert context.conn.halted
    assert context.conn.status == status
    context
  end

  step "the request raises ArgumentError", context do
    assert match?({:raised, %ArgumentError{}}, context.outcome)
    context
  end

  defp run_plug(context, user_id, params) do
    Plug.Test.conn(:get, "/projects", %{})
    |> Map.put(:params, params)
    |> Plug.Conn.assign(:current_user, %{id: user_id})
    |> EdictPlug.call(context.plug_opts)
  end

  # Feature names double as user IDs.
  defp user_id(user), do: user
end
