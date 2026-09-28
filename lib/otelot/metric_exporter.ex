defmodule Otelot.MetricExporter do
  use Supervisor
  require Logger
  alias Otelot.OtelApi
  alias Otelot.MetricStore
  alias Otelot.TelemetryHandlers
  alias Telemetry.Metrics

  @moduledoc """
  This is a `telemetry` exporter that collects specified metrics
  and then exports them to an OTel endpoint. It uses metric definitions
  from `:telemetry_metrics` library.

  Example usage:

      Otelot.MetricExporter.start_link(
        otlp_protocol: :http_protobuf,
        otlp_endpoint: otlp_endpoint,
        otlp_headers: headers,
        otlp_compression: :gzip,
        export_period: :timer.seconds(30),
        metrics: [
          Telemetry.Metrics.counter("plug.request.stop.duration"),
          Telemetry.Metrics.sum("plug.request.stop.duration"),
          Telemetry.Metrics.last_value("plug.request.stop.duration"),
          Telemetry.Metrics.distribution("plug.request.stop.duration",
            reporter_options: [buckets: [0, 10, 100, 1000]] # Optional histogram buckets.
          ),
        ]
      )

  Default histogram buckets are `#{inspect(MetricStore.default_buckets())}`

  See all available options in `start_link/1` documentation. Options provided to the `start_link/1`
  function will be merged with the options provided via `config :otelot` configuration.
  """

  @type protocol :: :http_protobuf | :http_json
  @type compression :: :gzip | nil

  @supported_metrics [
    Metrics.Counter,
    Metrics.Sum,
    Metrics.LastValue,
    Metrics.Distribution
  ]

  @options_schema NimbleOptions.new!(
                    [
                      metrics: [
                        type: {:list, {:or, for(x <- @supported_metrics, do: {:struct, x})}},
                        type_spec: quote(do: list(Metrics.t())),
                        required: true,
                        doc: "List of telemetry metrics to track."
                      ],
                      export_period: [
                        type: :pos_integer,
                        default: :timer.minutes(1),
                        doc: "Period in milliseconds between metric exports."
                      ],
                      name: [
                        type: :atom,
                        default: :otelot,
                        doc:
                          "If you require multiple exporters, give each exporter a unique name."
                      ]
                    ] ++ OtelApi.public_options()
                  )

  @type option() :: unquote(NimbleOptions.option_typespec(@options_schema))

  @doc """
  Start the exporter. It maintains some pieces of global state keyed by the `:name` option: a named
  ETS table and a `:persistent_term` key. To run several exporters at once, give each of them a
  unique `:name` (and a unique child id when starting them under the same supervisor).

  ## Options

  Options can be provided directly or specified in the `config :otelot` configuration. It's recommended
  to configure global options in `:otelot` config, and specify metrics where you add this module to the
  supervision tree.

  #{NimbleOptions.docs(@options_schema)}
  """
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts) do
    opts = combine_opts(opts)

    with {:ok, validated} <- NimbleOptions.validate(opts, @options_schema) do
      Supervisor.start_link(__MODULE__, Map.new(validated))
    end
  end

  defp combine_opts(opts) do
    config_opts = Application.get_all_env(:otelot)

    config_opts
    |> Keyword.merge(opts)
    |> Keyword.put(
      :otlp_headers,
      deep_merge_maps(config_opts[:otlp_headers], opts[:otlp_headers])
    )
    |> Keyword.put(:resource, deep_merge_maps(config_opts[:resource], opts[:resource]))
  end

  defp deep_merge_maps(nil, nil), do: %{}
  defp deep_merge_maps(nil, map), do: map
  defp deep_merge_maps(map, nil), do: map

  defp deep_merge_maps(map1, map2) do
    Map.merge(map1, map2, fn
      _key, val1, val2 when is_map(val1) and is_map(val2) ->
        deep_merge_maps(val1, val2)

      _key, _val1, val2 ->
        val2
    end)
  end

  @impl true
  def init(config) do
    children = [
      {MetricStore, config},
      {TelemetryHandlers, config}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  def handle_metric(_event_name, measurements, metadata, %{
        metrics: metrics,
        name: name,
        handler_id: handler_id
      }) do
    for metric <- metrics do
      record_metric(name, metric, measurements, metadata)
    end

    :ok
  rescue
    e in ArgumentError ->
      if MetricStore.table_exists?(name) do
        reraise e, __STACKTRACE__
      end

      Logger.warning("Otelot.MetricExporter failed to process event due to ETS table missing")
      :telemetry.detach(handler_id)
      :ok
  end

  # Records a single metric. A metric that can't be recorded is skipped with a warning (logged
  # once per exporter, metric and kind of failure) instead of raising: `:telemetry` detaches a
  # handler that raises, which would stop recording every metric attached to the same event.
  defp record_metric(name, metric, measurements, metadata) do
    if is_nil(metric.keep) || metric.keep.(metadata) do
      value = extract_measurement(metric, measurements, metadata)

      if valid_value?(metric, value) do
        tags = extract_tags(metric, metadata)
        metric_name = "#{Enum.join(metric.name, ".")}"
        MetricStore.write_metric(name, metric, metric_name, value, tags)
      else
        warn_once(name, metric, :invalid_value, fn metric_name ->
          "Otelot.MetricExporter skipped an invalid measurement for metric #{metric_name}: " <>
            "expected a number, got #{inspect(value)}. Further invalid measurements for " <>
            "this metric will be skipped silently."
        end)
      end
    end
  rescue
    e ->
      # Without the ETS table nothing can be recorded; let `handle_metric/4` detach the handler.
      stacktrace = __STACKTRACE__
      if not MetricStore.table_exists?(name), do: reraise(e, stacktrace)

      warn_once(name, metric, {:exception, e.__struct__}, fn metric_name ->
        "Otelot.MetricExporter failed to record metric #{metric_name}: " <>
          Exception.format(:error, e, stacktrace) <>
          "\nFurther failures of this kind for this metric will be skipped silently."
      end)
  end

  # Counters count events and ignore the measurement value.
  defp valid_value?(%Metrics.Counter{}, _value), do: true
  defp valid_value?(_metric, value), do: is_number(value)

  defp warn_once(name, metric, kind, message_fun) do
    metric_name = Enum.join(metric.name, ".")

    if MetricStore.first_warning?(name, {metric_name, metric.__struct__, kind}) do
      Logger.warning(fn -> message_fun.(metric_name) end)
    end

    :ok
  end

  defp extract_measurement(metric, measurements, metadata) do
    case metric.measurement do
      fun when is_function(fun, 1) -> fun.(measurements)
      fun when is_function(fun, 2) -> fun.(measurements, metadata)
      key -> Map.get(measurements, key)
    end
  end

  defp extract_tags(metric, metadata) do
    metadata
    |> metric.tag_values.()
    |> Map.take(metric.tags)
  end
end
