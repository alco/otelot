# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-09-28

Otelot continues the development of
[`otel_metric_exporter`](https://github.com/electric-sql/elixir-otel-metric-exporter) under a
new name. Entries below this one describe releases of `otel_metric_exporter`.

### Breaking changes

- The package and OTP application are now called `otelot`. Replace
  `{:otel_metric_exporter, ...}` with `{:otelot, "~> 0.5"}` in your deps and
  `config :otel_metric_exporter` with `config :otelot`.
- Modules moved under the `Otelot` namespace. The metrics exporter formerly started as
  `OtelMetricExporter` is now `Otelot.MetricExporter`, and `OtelMetricExporter.LogHandler`
  is now `Otelot.LogHandler`.
- The default `:name` of a metric exporter is now `:otelot`.
- Exported data now reports `otelot` as its instrumentation scope name.

### Fixed

- Boolean attribute values (tags, log metadata, resource attributes) are exported as OTLP
  booleans instead of the strings `"true"`/`"false"`.

### Documentation

- New guides: Getting started, Metrics, Configuration.

## [0.4.4] - 2026-04-30

- Populate min and max values on histogram data points
- Treat `:undefined` last values the same as `nil` instead of crashing
- Don't crash the log handler on unexpected messages
- Update dependencies

## [0.4.3] - 2025-12-10

- Export integer measurements as integers and floats as doubles, and fall back to doubles for
  integers that don't fit into 64 bits

## [0.4.2] - 2025-11-19

- Merge OTLP headers passed as explicit options with those configured via app env

## [0.4.1] - 2025-11-12

- Send metrics from a separate task so a stuck HTTP request doesn't block the exporter
- Don't crash when the metrics ETS table is gone during shutdown

## [0.4.0] - 2025-11-11

- Encode trace and span IDs on log records as raw bytes, as required by OTLP
- Fix the log handler and its tests
- Update dependencies

## [0.3.12] - 2025-09-30

- Include the offending data in protobuf encoding errors

## [0.3.11] - 2025-07-10

- Detach telemetry handlers when the exporter stops
- Update dependencies

## [0.3.10] - 2025-06-17

- Lower the log handler's default `debounce_ms` to 1 second and `max_buffer_size` to 5,000

## [0.3.9] - 2025-05-28

- Support configuration via the standard `OTEL_*` environment variables

## [0.3.8] - 2025-05-22

- Make `exception.type` labels for process exits clearer

## [0.3.7] - 2025-04-30

- Return the actual error after retries are exhausted
- Don't crash when handling some `:EXIT` log events

## [0.3.6] - 2025-04-08

- Fix protobuf encoding of `:logger.report()` events

## [0.3.5] - 2025-04-07

- Fix race conditions registering metrics handlers before `MetricStore` is ready
- Add retries to HTTP POST metric data
