defmodule Membrane.SRTLT.MixProject do
  use Mix.Project

  @version "0.1.0"
  @github_url "https://github.com/video-taxi/membrane_srt_live_transmit_plugin"

  def project do
    [
      app: :membrane_srt_live_transmit,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @github_url,
      homepage_url: @github_url
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "Membrane source element for SRT streams via the srt-live-transmit CLI tool."
  end

  defp package do
    [
      maintainers: ["KIM Keep In Mind GmbH"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @github_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "docs/srt-live-transmit-reference.md"],
      source_ref: "v#{@version}"
    ]
  end

  defp deps do
    [
      {:membrane_core, "~> 1.2"},
      {:erlexec, "~> 2.0"},
      {:telemetry, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
