# Configuration

Both `Otelot.MetricExporter` and `Otelot.LogHandler` share the same set of OTLP settings.
Each setting can come from three places, highest precedence first:

1. Options passed directly to `Otelot.MetricExporter.start_link/1` or in the log handler's
   `config` map.
2. Application config under `config :otelot`.
3. Standard `OTEL_*` environment variables.

The `resource` map is merged across these sources rather than replaced, so you can, for
instance, set `service.name` globally and add an extra resource attribute for one exporter.

## Options

| Option | Default | Description |
| ------ | ------- | ----------- |
| `otlp_endpoint` | — (required) | Base URL of the OTLP/HTTP receiver. `/v1/metrics` and `/v1/logs` are appended to it. |
| `otlp_protocol` | `:http_protobuf` | Only `:http_protobuf` is supported. |
| `otlp_headers` | `%{}` | Extra HTTP headers, typically for authentication. |
| `otlp_compression` | `:gzip` | `:gzip` or `nil`. |
| `otlp_concurrent_requests` | `10` | Maximum number of in-flight requests (used by the log handler). |
| `resource` | `%{}` | Resource attributes. Nested maps are flattened into dotted keys. |
| `metrics` / `logs` | — | Per-signal overrides, see below. |

The complete, generated reference lives in the `Otelot.MetricExporter` and
`Otelot.LogHandler` module docs, together with the options specific to each.

## Per-signal overrides

The `metrics` and `logs` keys override the shared settings for one signal only. They accept
`otlp_endpoint`, `otlp_protocol`, `otlp_headers`, `otlp_timeout` and `exporter`. Setting
`logs: [exporter: :none]` turns the log handler into a no-op. (For metrics, simply don't start
`Otelot.MetricExporter`.)

```elixir
config :otelot,
  otlp_endpoint: "https://otlp.example.com",
  otlp_headers: %{"authorization" => "Bearer " <> System.fetch_env!("OTLP_TOKEN")},
  resource: %{service: %{name: "my_app"}},
  # Send metrics to a different collector
  metrics: [otlp_endpoint: "https://metrics.example.com"],
  # ...and don't export logs from this node at all
  logs: [exporter: :none]
```

## Environment variables

Otelot reads the following
[OTel SDK environment variables](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/):

| Variable | Maps to |
| -------- | ------- |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `otlp_endpoint` |
| `OTEL_EXPORTER_OTLP_HEADERS` | `otlp_headers` (`key1=value1,key2=value2`) |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `otlp_protocol` (only `http/protobuf` is usable) |
| `OTEL_EXPORTER_OTLP_TIMEOUT` | `otlp_timeout` |
| `OTEL_EXPORTER_OTLP_METRICS_*`, `OTEL_EXPORTER_OTLP_LOGS_*` | the same settings under `metrics` / `logs` |
| `OTEL_METRICS_EXPORTER`, `OTEL_LOGS_EXPORTER` | `exporter` under `metrics` / `logs` (`otlp` or `none`) |
| `OTEL_RESOURCE_ATTRIBUTES` | `resource` (`key1=value1,key2=value2`) |
| `OTEL_SERVICE_NAME` | the `service.name` resource attribute |

Signal-specific endpoints (`OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`, ...) deviate from the OTel
specification: they are treated as base URLs, same as the generic one, so the `/v1/<signal>`
path is still appended.

A variable with a malformed or unsupported value — e.g. `OTEL_EXPORTER_OTLP_PROTOCOL=grpc` —
is ignored with a logged warning; all other environment variables still apply.
