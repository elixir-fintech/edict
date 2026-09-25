defmodule Edict.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/elixir-fintech/edict"

  def project do
    [
      app: :edict,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      description: "Cached authorization for Phoenix applications",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto_sql, "~> 3.10"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:cachex, "~> 4.0"},
      {:telemetry, "~> 1.0"},

      # Dev/test
      {:postgrex, ">= 0.0.0", only: :test},
      {:cabbage, "~> 0.4", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_url: @source_url,
      groups_for_modules: [
        "Public API": [Edict],
        Configuration: [Edict.Config, Edict.Entity],
        Enforcement: [
          Edict.Plug,
          Edict.LiveView,
          Edict.Enforcement.Plug,
          Edict.Enforcement.LiveView,
          Edict.Enforcement.Authorize
        ],
        Cache: [Edict.Cache.Document, Edict.Cache.Store, Edict.Cache.PubSubListener],
        Testing: [Edict.TestHelpers]
      ]
    ]
  end

  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
