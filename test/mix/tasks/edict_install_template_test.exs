defmodule Mix.Tasks.Edict.InstallTemplateTest do
  use ExUnit.Case, async: true

  @template Path.expand("../../../priv/templates/create_user_roles.exs.eex", __DIR__)

  setup do
    %{migration: EEx.eval_file(@template, assigns: [repo_module: "MyApp.Repo"])}
  end

  test "creates the edict_user_roles table", %{migration: migration} do
    assert migration =~ "create table(:edict_user_roles"
  end

  test "names the not-blank constraints after the table", %{migration: migration} do
    assert migration =~ ~S|:"edict_user_roles_#{column}_not_blank"|
  end
end
