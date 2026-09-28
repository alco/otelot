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
`otlp_endpoint`, `otlp_protocol`, `otlp_headers`, `otlp_timeout` and `exporter`.

Setting `exporter: :none` disables a signal without having to change your supervision tree
or logger setup, e.g. to turn off export in dev and test or on some nodes:

* `logs: [exporter: :none]` turns the log handler into a no-op.
* `metrics: [exporter: :none]` makes `Otelot.MetricExporter.start_link/1` return `:ignore`:
  no telemetry handlers are attached, nothing is aggregated and nothing is exported. The
  rest of your supervision tree starts as usual. `otlp_endpoint` is not required in this
  case.

The same can be done with the `OTEL_LOGS_EXPORTER=none` and `OTEL_METRICS_EXPORTER=none`
environment variables.

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

Two deviations from the OTel specification to be aware of:

* Signal-specific endpoints (`OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`, ...) are treated as base
  URLs, same as the generic one, so the `/v1/<signal>` path is still appended.
* Malformed values are skipped with a warning, but a well-formed value that Otelot doesn't
  support — e.g. `OTEL_EXPORTER_OTLP_PROTOCOL=grpc` — causes *all* environment-derived
  settings to be ignored.
