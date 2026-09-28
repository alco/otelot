# Getting started

This guide wires Otelot into an application so that metrics and logs end up in an
OpenTelemetry backend. It assumes you already have an OTLP/HTTP endpoint to send data to —
a local [OpenTelemetry Collector](#trying-it-locally-with-an-otel-collector) is the easiest
way to try things out.

## 1. Add the dependency

```elixir
# mix.exs
def deps do
  [
    {:otelot, "~> 0.5"}
  ]
end
```

Otelot starts its own application (an HTTP connection pool) automatically; the exporters
themselves are started by your code.

## 2. Configure the endpoint

Settings shared by metrics and logs live under `config :otelot`. Typically you set them
in `config/runtime.exs`:

```elixir
# config/runtime.exs
import Config

config :otelot,
  otlp_endpoint: System.get_env("OTLP_ENDPOINT", "http://localhost:4318"),
  otlp_headers: %{"x-api-key" => System.get_env("OTLP_API_KEY", "")},
  resource: %{
    service: %{name: "my_app", version: System.get_env("RELEASE_VSN", "dev")},
    deployment: %{environment: config_env() |> to_string()}
  }
```

`otlp_endpoint` is the **base URL** of the OTLP/HTTP receiver: Otelot appends `/v1/metrics`
and `/v1/logs` to it.

Nested `resource` maps are flattened into dotted attribute names, so the example above
produces `service.name`, `service.version` and `deployment.environment`.

Instead of (or in addition to) app config you can use the standard `OTEL_*` environment
variables such as `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS` and
`OTEL_SERVICE_NAME`. See the [Configuration](configuration.md) guide for the full list and
the precedence rules.

## 3. Export metrics

Define your metrics with [`Telemetry.Metrics`](https://hexdocs.pm/telemetry_metrics) and
start `Otelot.MetricExporter` in your supervision tree. If you generated your app with
Phoenix, you already have a `MyAppWeb.Telemetry` module with a `metrics/0` function — just
add the exporter next to the existing reporters:

```elixir
defmodule MyAppWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      {Otelot.MetricExporter, metrics: metrics(), export_period: :timer.seconds(30)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix
      distribution("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [5, 10, 25, 50, 100, 250, 500, 1000, 2500]]
      ),
      counter("phoenix.router_dispatch.stop.duration", tags: [:route]),

      # Ecto
      distribution("my_app.repo.query.total_time", unit: {:native, :millisecond}),

      # VM
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.total_run_queue_lengths.total")
    ]
  end

  defp periodic_measurements, do: []
end
```

Metrics are aggregated in memory and sent to the backend every `export_period`
milliseconds (one minute by default). See the [Metrics](metrics.md) guide for how each
`Telemetry.Metrics` type is mapped to an OTel data point.

Metrics that don't originate from a library can be emitted from your own code with
`:telemetry.execute/3`:

```elixir
:telemetry.execute([:my_app, :checkout], %{amount: 1999}, %{currency: "EUR"})

# ...matched by
sum("my_app.checkout.amount", tags: [:currency])
```

## 4. Export logs

`Otelot.LogHandler` is a regular `:logger` handler. Declare it in your app config:

```elixir
# config/config.exs
config :my_app, :logger, [
  {:handler, :otel, Otelot.LogHandler,
   %{
     config: %{
       # Logger metadata keys to attach to each log record as attributes
       metadata: [:mfa, :pid],
       # Metadata keys to attach under a different attribute name
       metadata_map: %{request_id: "http.request.id"}
     }
   }}
]
```

and attach it when your application starts:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  Logger.add_handlers(:my_app)
  # ...
end
```

The handler picks up `otlp_*` and `resource` settings from `config :otelot` and batches log
records before sending them. Handler-specific options (batching, overload protection,
per-handler endpoint overrides) are documented in `Otelot.LogHandler`.

If your app also uses the official `opentelemetry` tracing library, log records emitted
inside a span carry its trace and span IDs, so backends can correlate logs with traces.

## Trying it locally with an OTel Collector

The quickest way to see what Otelot sends is to run a collector that prints everything it
receives to stdout. Save this as `otel-collector.yaml`:

```yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318

exporters:
  debug:
    verbosity: detailed

service:
  pipelines:
    metrics:
      receivers: [otlp]
      exporters: [debug]
    logs:
      receivers: [otlp]
      exporters: [debug]
```

and start the collector:

```sh
docker run --rm -p 4318:4318 \
  -v "$PWD/otel-collector.yaml:/etc/otelcol/config.yaml" \
  otel/opentelemetry-collector:latest
```

Then, in `iex -S mix`:

```elixir
Otelot.MetricExporter.start_link(
  otlp_endpoint: "http://localhost:4318",
  export_period: 5_000,
  metrics: [Telemetry.Metrics.counter("demo.event.count")]
)

:telemetry.execute([:demo, :event], %{})
```

Within five seconds the collector should print a `demo.event.count` sum metric.

## Troubleshooting

**Nothing arrives at the backend.**
Check the application logs for `Failed to export metrics: ...` errors — they include the
HTTP status or transport error. Remember that `otlp_endpoint` is a base URL: use
`http://collector:4318`, not `http://collector:4318/v1/metrics` (only the per-signal
`metrics: [otlp_endpoint: ...]` / `logs: [otlp_endpoint: ...]` overrides take a full URL, see
the Configuration guide). Also double-check that the
endpoint speaks OTLP over **HTTP** (usually port 4318); gRPC endpoints (port 4317) are not
supported.

**Environment variables seem to be ignored.**
If `OTEL_EXPORTER_OTLP_PROTOCOL` (or a signal-specific variant) is set to `grpc` or
`http/json`, the whole set of environment defaults is discarded. Unset the variable or set
it to `http/protobuf`. Malformed values in other variables are logged as warnings at startup.

**A metric never shows up.**
Make sure the event name matches: by default `Telemetry.Metrics` derives the event name by
dropping the last segment of the metric name (`"phoenix.endpoint.stop.duration"` listens to
`[:phoenix, :endpoint, :stop]` and reads the `:duration` measurement). Events for which the
metric's `:keep` function returns `false` are skipped.

**`start_link` returns `{:error, %NimbleOptions.ValidationError{}}`.**
The error message names the offending option. `Telemetry.Metrics.summary/2` metrics are
rejected because OTel's Summary type is not supported — use `distribution/2` instead.

**Log export errors are hard to see.**
To avoid feedback loops, failures to deliver logs are reported at `:debug` level only. Lower
your logger level temporarily to see them.
