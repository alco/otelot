# Metrics

`Otelot.MetricExporter` takes metric definitions from
[`Telemetry.Metrics`](https://hexdocs.pm/telemetry_metrics), aggregates matching
`:telemetry` events in memory (ETS) and periodically exports the aggregated values as OTLP
metrics.

This is a deliberate departure from the
[OTel Metrics API](https://opentelemetry.io/docs/specs/otel/metrics/api/): instead of
instruments created through `:opentelemetry_api`, you reuse the metric definitions that the
Elixir ecosystem (Phoenix, Ecto, Oban, LiveDashboard, ...) already emits and describes. The
trade-offs are listed [below](#differences-from-the-official-opentelemetry-sdk).

## Type mapping

| `Telemetry.Metrics`  | OTel data point | Notes |
| -------------------- | --------------- | ----- |
| `counter/2`          | Sum, monotonic, delta | Counts events; the measurement value is ignored. |
| `sum/2`              | Sum, non-monotonic, delta | Adds up measurement values. |
| `last_value/2`       | Gauge           | Keeps the latest measurement value. |
| `distribution/2`     | Histogram (explicit buckets), delta | Count, sum, min, max and per-bucket counts. |
| `summary/2`          | —               | Not supported; rejected at startup. |

Integer values are exported as integers and floats as doubles. Integers that don't fit into
a signed 64-bit integer are exported as doubles.

### Names, units and descriptions

* The metric name is the `Telemetry.Metrics` name joined with dots, e.g.
  `"phoenix.endpoint.stop.duration"`.
* `:description` is passed through as-is.
* `:unit` is translated to [UCUM](https://ucum.org/) codes where there is a well-known
  equivalent: `:second` → `s`, `:millisecond` → `ms`, `:microsecond` → `us`,
  `:nanosecond` → `ns`, `:byte` → `By`, `:kilobyte` → `kBy`, `:megabyte` → `MBy`,
  `:gigabyte` → `GBy`, `:terabyte` → `TBy`. Other atoms are exported verbatim and `:unit`
  (the default) is omitted. Unit conversions such as `unit: {:native, :millisecond}` are
  applied to the measurement before aggregation, as usual with `Telemetry.Metrics`.

### Attributes

Each metric's `:tags` become data point attributes. Values are extracted from event metadata
(after applying `:tag_values`, if given), and every distinct combination of tag values
produces its own data point — keep tag cardinality under control.

The `:keep` and `:drop` options work as documented in `Telemetry.Metrics`.

### Histogram buckets

Bucket boundaries for a distribution are set via `reporter_options`:

```elixir
distribution("my_app.repo.query.total_time",
  unit: {:native, :millisecond},
  reporter_options: [buckets: [1, 5, 10, 50, 100, 500, 1000]]
)
```

Boundaries are upper-inclusive, and values above the last boundary go into an extra overflow
bucket. Without `:buckets`, the default boundaries are
`[0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000]`.

## Export cycle

Every `export_period` milliseconds the exporter sends everything recorded since the last
**successful** export as a single OTLP request. Each data point carries the start and end
time of the window it covers.

* On success, the exported values are dropped from memory and aggregation starts from zero.
* On failure, the values are kept and included in the next export attempt, so a temporarily
  unreachable backend doesn't lose data (at the cost of memory while it is down).
* Transient HTTP errors (408, 429, 5xx) and connection errors are retried with exponential
  backoff for up to 20 seconds before the attempt is considered failed.

### Aggregation temporality

Because aggregation restarts from zero after every successful export, Sum and Histogram data
points are exported with **delta** temporality (`AGGREGATION_TEMPORALITY_DELTA`): each data
point holds only what was recorded between its `start_time_unix_nano` and `time_unix_nano`,
not a running total since startup. Backends with native delta support (Honeycomb, New Relic,
Datadog, ...) can ingest these directly.

Cumulative temporality is not currently supported. Prometheus, which only understands
cumulative counters and histograms, needs the OpenTelemetry Collector's
[`deltatocumulative`](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/deltatocumulativeprocessor)
processor (or an equivalent) between Otelot and Prometheus.

## Running several exporters

Each exporter keeps its state in a named ETS table. To run more than one — for example to
send different metrics to different backends — give each a unique `:name` and child id:

```elixir
children = [
  Supervisor.child_spec(
    {Otelot.MetricExporter, name: :app_metrics, metrics: app_metrics()},
    id: :app_metrics
  ),
  Supervisor.child_spec(
    {Otelot.MetricExporter,
     name: :billing_metrics,
     metrics: billing_metrics(),
     otlp_endpoint: "https://billing-collector.internal:4318"},
    id: :billing_metrics
  )
]
```

## Differences from the official OpenTelemetry SDK

If you are choosing between Otelot and the official
[`opentelemetry-erlang`](https://github.com/open-telemetry/opentelemetry-erlang) metrics
SDK, these are the trade-offs:

* **Telemetry-first.** Metrics are defined with `Telemetry.Metrics`, not with the OTel
  Metrics API. There is no Meter, no instruments and no Views; aggregation is fixed per
  metric type as described above.
* **No Exemplars.** Otelot does not integrate with `:opentelemetry_api`, so data points
  don't link to traces or spans.
* **Limited data point types.** `ExponentialHistogram` and `Summary` are not produced.
* **Delta temporality only.** Sums and histograms are always exported as deltas; see
  [Aggregation temporality](#aggregation-temporality).
* **OTLP over HTTP with protobuf only.** gRPC and HTTP/JSON transports are not supported.
* **In-process aggregation.** Values are aggregated in ETS inside your node. This is cheap on
  the hot path (a few ETS operations per metric per event) but means each node exports its own
  series; tag them via `resource` attributes (e.g. `service.instance.id`) to tell them apart.
