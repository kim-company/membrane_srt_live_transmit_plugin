defmodule Membrane.SRTLT.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_srt_live_transmit,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:membrane_core, "~> 1.2"},
      {:erlexec, "~> 2.0"}
    ]
  end
end
