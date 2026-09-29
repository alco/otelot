defmodule Otelot.MixProject do
  use Mix.Project

  @version "0.5.0"

  def project do
    [
      app: :otelot,
      name: "Otelot",
      description:
        "Export Telemetry.Metrics and Logger events to any OpenTelemetry (OTLP) backend",
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      source_url: "https://github.com/alco/otelot",
      homepage_url: "https://hexdocs.pm/otelot",
      deps: deps(),
      docs: &docs/0,
      package: [
        licenses: ["Apache-2.0"],
        links: %{
          "GitHub" => "https://github.com/alco/otelot",
          "Changelog" => "https://github.com/alco/otelot/blob/main/CHANGELOG.md"
        },
        files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Otelot.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:protobuf, "~> 0.15"},
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:finch, "~> 0.19"},
      {:retry, "~> 0.19"},
      {:passby, "~> 0.2", only: [:test]},
      {:opentelemetry, "~> 1.5", only: [:test]},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev], runtime: false}
    ]
  end

  def cli do
    [preferred_envs: ["test.watch": :test]]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "guides/getting-started.md",
        "guides/metrics.md",
        "guides/configuration.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Guides: ~r"guides/"
      ],
      api_reference: false
    ]
  end
end
