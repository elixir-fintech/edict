defmodule Mix.Tasks.Edict.Install do
  @moduledoc """
  Generates the Edict migration for the `user_roles` table.

      mix edict.install
  """

  use Mix.Task

  @shortdoc "Generates Edict migration for user_roles table"

  @impl true
  def run(_args) do
    repo = get_repo()
    repo_module = inspect(repo)
    migrations_path = Path.join(["priv", "repo", "migrations"])

    File.mkdir_p!(migrations_path)

    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    filename = "#{timestamp}_create_edict_user_roles.exs"
    filepath = Path.join(migrations_path, filename)

    existing =
      migrations_path
      |> File.ls!()
      |> Enum.any?(&String.contains?(&1, "create_edict_user_roles"))

    if existing do
      Mix.shell().info("Migration already exists. Skipping.")
    else
      template_path =
        :edict
        |> Application.app_dir("priv/templates/create_user_roles.exs.eex")

      content = EEx.eval_file(template_path, assigns: [repo_module: repo_module])

      File.write!(filepath, content)
      Mix.shell().info("Generated migration: #{filepath}")
    end
  end

  defp get_repo do
    case Application.get_env(:edict, :repo) do
      nil ->
        Mix.raise("No repo configured for Edict. Add: config :edict, repo: MyApp.Repo")

      repo ->
        repo
    end
  end
end
