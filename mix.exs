defmodule Shiina.MixProject do
  use Mix.Project

  def project do
    [
      app: :shiina,
      version: "0.1.0",
      elixir: "~> 1.8",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Shiina,[]},
      applications: app_list(Mix.env),
      # extra_applications: [:logger]
    ]
  end

  def app_list(:dev), do: [:dotenv | app_list()]
  def app_list(_), do: app_list()
  def app_list, do: [:logger, :alchemy, :edeliver, :poolboy, :mongodb, :gproc, :timex, :httpoison]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
      {:edeliver, "~> 1.6.0"},
      {:distillery, "~> 2.0", warn_missing: false},
      # {:alchemy, "~> 0.6.3", hex: :discord_alchemy},
      {:alchemy, git: "https://github.com/curz46/alchemy.git", branch: "fix/channel-cache"},
      {:mongodb, "~> 0.5.1"},
      {:poolboy, "~> 1.5.2"},
      {:dotenv, "~> 3.0.0"},
      {:poison, "~> 4.0.1"},
      {:gproc, "~> 0.5.0"},
      {:timex, "~> 3.5"},
      {:httpoison, "~> 1.5"}
    ]
  end
end
