# Otelot

[![CI](https://github.com/alco/otelot/actions/workflows/ci.yml/badge.svg)](https://github.com/alco/otelot/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/otelot.svg)](https://hex.pm/packages/otelot)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/otelot)

Export your Elixir app's metrics and logs to any OpenTelemetry backend over OTLP — without
rewriting your instrumentation.

- **Metrics**: reuse the [`Telemetry.Metrics`](https://hexdocs.pm/telemetry_metrics)
  definitions you already have (Phoenix, Ecto, Oban, your own `:telemetry` events). Otelot
  aggregates them in-process and exports them as OTel sums, gauges and histograms.
- **Logs**: a `:logger` handler that batches log events and ships them as OTel log records,
  with trace/span correlation when the official tracing SDK is in use.

## Installation

```elixir
def deps do
  [
    {:otelot, "~> 0.5"}
  ]
end
```

## Quickstart

Point Otelot at an OTLP/HTTP endpoint:

```elixir
# config/runtime.exs
config :otelot,
  otlp_endpoint: "http://localhost:4318",
  resource: %{service: %{name: "my_app"}}
```

Export metrics by adding the exporter to your supervision tree, e.g. in the `Telemetry`
module that Phoenix generates:

```elixir
children = [
  {Otelot.MetricExporter, metrics: metrics(), export_period: :timer.seconds(30)}
]
```

Export logs by registering the handler:

```elixir
# config/config.exs
config :my_app, :logger, [
  {:handler, :otel, Otelot.LogHandler, %{config: %{metadata: [:request_id]}}}
]

# lib/my_app/application.ex, in start/2
Logger.add_handlers(:my_app)
```

The standard `OTEL_EXPORTER_OTLP_*`, `OTEL_SERVICE_NAME` and `OTEL_RESOURCE_ATTRIBUTES`
environment variables are honoured too.

## Documentation

- [Getting started](https://hexdocs.pm/otelot/getting-started.html) — full setup, a local
  collector for experimenting, troubleshooting.
- [Metrics](https://hexdocs.pm/otelot/metrics.html) — how `Telemetry.Metrics` types map to
  OTel, export semantics, differences from the official SDK.
- [Configuration](https://hexdocs.pm/otelot/configuration.html) — all options and
  environment variables.

## How it differs from the official OpenTelemetry SDK

Otelot trades API compliance for fitting into the existing Elixir ecosystem:

- Metrics are defined with `Telemetry.Metrics`, not the OTel Metrics API.
- `summary` metrics and OTel's `ExponentialHistogram` are not supported.
- Transport is OTLP over HTTP with protobuf encoding; gRPC and HTTP/JSON are not supported.
- To create and export OTel spans, use [`opentelemetry`](https://hex.pm/packages/opentelemetry).
  The two work fine side by side.

## Compatibility

Otelot requires Elixir 1.17+ and is tested in CI against:

| Elixir | Erlang/OTP |
| ------ | ---------- |
| 1.17   | 27         |
| 1.19   | 28         |
| 1.20   | 29         |

It works with any OTLP/HTTP receiver: the OpenTelemetry Collector, Grafana Cloud,
Honeycomb, Datadog, etc.

## Development

```sh
mix deps.get
mix test
mix format --check-formatted
```

See [CONTRIBUTING.md](https://github.com/alco/otelot/blob/main/CONTRIBUTING.md) before opening an issue or a pull request.

## Maintenance

Otelot is maintained by [Oleksii Sholik](https://github.com/alco) on a best-effort basis.
It follows [semantic versioning](https://semver.org); while it is on 0.x, minor releases
may contain breaking changes, which are always called out in the [changelog](CHANGELOG.md).

## License

Copyright 2026 Oleksii Sholik

Otelot is derived from
[`otel_metric_exporter`](https://github.com/electric-sql/elixir-otel-metric-exporter),
copyright 2024–2026 its contributors, which was used in production at
[Electric](https://electric-sql.com). It has been modified since the fork. Both are
licensed under the Apache License, Version 2.0 (the "License"); you may not use this
software except in compliance with the License. You may obtain a copy of the License in
[LICENSE](https://github.com/alco/otelot/blob/main/LICENSE) or at
<http://www.apache.org/licenses/LICENSE-2.0>.

Unless required by applicable law or agreed to in writing, software distributed under the
License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
either express or implied. See the License for the specific language governing permissions
and limitations under the License.
