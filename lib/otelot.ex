defmodule Otelot do
  @moduledoc """
  OpenTelemetry for Elixir apps, built on `:telemetry` and `:logger`.

  Otelot exports telemetry data to any OTLP-compatible backend over HTTP:

    * `Otelot.MetricExporter` aggregates `Telemetry.Metrics` definitions in-process
      and periodically exports them as OTel metrics.
    * `Otelot.LogHandler` is a `:logger` handler that batches log events and exports
      them as OTel log records.

  Shared settings (endpoint, headers, resource attributes, ...) are read from
  `config :otelot` and from the standard `OTEL_*` environment variables.
  """
end
