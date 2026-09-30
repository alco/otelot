defmodule Otelot.MetricExporterTest do
  use ExUnit.Case
  alias Telemetry.Metrics
  import ExUnit.CaptureLog
  require Logger

  setup do
    on_exit(fn ->
      Enum.each(:telemetry.list_handlers([:test]), fn handler ->
        :telemetry.detach(handler.id)
      end)
    end)

    :ok
  end

  @name :otelot_test

  @base_config [
    otlp_protocol: :http_protobuf,
    otlp_endpoint: "http://localhost:4318",
    otlp_headers: %{},
    otlp_compression: nil,
    export_period: 1000,
    name: @name
  ]

  describe "start_link/1" do
    test "starts with valid config" do
      metrics = [
        Metrics.counter("test.counter", tags: [:test]),
        Metrics.sum("test.sum", tags: [:test]),
        Metrics.last_value("test.last_value", tags: [:test]),
        Metrics.distribution("test.distribution", tags: [:test])
      ]

      assert pid =
               start_link_supervised!({Otelot.MetricExporter, @base_config ++ [metrics: metrics]})

      assert Process.alive?(pid)
    end

    test "fails with invalid config" do
      assert {:error, _} = Otelot.MetricExporter.start_link([])
      assert {:error, _} = Otelot.MetricExporter.start_link(otlp_protocol: :invalid)
    end
  end

  describe "telemetry integration" do
    test "handles telemetry events" do
      metrics = [
        Telemetry.Metrics.sum("test.event.value", event_name: [:test, :event])
      ]

      start_supervised!({Otelot.MetricExporter, @base_config ++ [metrics: metrics]})

      :telemetry.execute([:test, :event], %{value: 42}, %{test: "value"})

      # Give the GenServer time to process the event
      Process.sleep(100)

      metrics = Otelot.MetricStore.get_metrics(@name)
      assert %{{:sum, "test.event.value"} => %{%{} => 42}} = metrics
    end

    test "handles events with keep function" do
      metrics = [
        Telemetry.Metrics.counter(
          "test.filtered.value",
          event_name: [:test, :filtered],
          measurement: :value,
          tags: [:test],
          keep: &(&1.test == "keep")
        )
      ]

      start_supervised!({Otelot.MetricExporter, @base_config ++ [metrics: metrics]})

      # This one should be kept
      :telemetry.execute([:test, :filtered], %{value: 1}, %{test: "keep"})
      # This one should be filtered out
      :telemetry.execute([:test, :filtered], %{value: 2}, %{test: "drop"})

      # Give the GenServer time to process the event
      Process.sleep(100)

      metrics = Otelot.MetricStore.get_metrics(@name)
      assert get_in(metrics, [{:counter, "test.filtered.value"}, %{test: "keep"}]) == 1
      assert get_in(metrics, [{:counter, "test.filtered.value"}, %{test: "drop"}]) == nil
    end

    test "handles measurement functions" do
      metrics = [
        Telemetry.Metrics.sum(
          "test.measured",
          measurement: fn measurements -> measurements.value * 2 end,
          tags: [:test]
        ),
        Telemetry.Metrics.sum(
          "test.measured_with_metadata",
          measurement: fn measurements, metadata -> measurements.value * metadata.multiplier end,
          tags: [:test]
        )
      ]

      start_supervised!({Otelot.MetricExporter, @base_config ++ [metrics: metrics]})

      :telemetry.execute([:test], %{value: 21}, %{test: "value", multiplier: 3})

      # Give the GenServer time to process the event
      Process.sleep(100)

      metrics = Otelot.MetricStore.get_metrics(@name)
      assert get_in(metrics, [{:sum, "test.measured"}, %{test: "value"}]) == 42

      assert get_in(metrics, [{:sum, "test.measured_with_metadata"}, %{test: "value"}]) ==
               63
    end

    test "handles tag functions" do
      metrics = [
        Telemetry.Metrics.counter(
          "test.tags.value",
          measurement: :value,
          tags: [:dynamic],
          tag_values: fn metadata ->
            Map.put(metadata, :dynamic, "computed_#{metadata.input}")
          end
        )
      ]

      start_supervised!({Otelot.MetricExporter, @base_config ++ [metrics: metrics]})

      :telemetry.execute([:test, :tags], %{value: 42}, %{input: "test"})

      # Give the GenServer time to process the event
      Process.sleep(100)

      metrics = Otelot.MetricStore.get_metrics(@name)
      assert get_in(metrics, [{:counter, "test.tags.value"}, %{dynamic: "computed_test"}]) == 1
    end

    test "handles detaching of handlers on shutdown" do
      test_event = :"event_#{inspect(self())}"

      metrics = [
        Telemetry.Metrics.sum("test.event.value", event_name: [:test, test_event])
      ]

      start_supervised!({Otelot.MetricExporter, @base_config ++ [metrics: metrics]})

      stop_supervised!(Otelot.MetricExporter)

      log =
        capture_log(fn ->
          :telemetry.execute([:test, test_event], %{value: 42}, %{test: "value"})
          # Give logger a moment to flush
          Process.sleep(50)
        end)

      refute log =~ "[:test, #{inspect(test_event)}]} has failed and has been detached."
    end

    test "handles detaching of handlers if ETS table missing" do
      test_event = :"event_#{inspect(self())}"

      metrics = [
        Telemetry.Metrics.sum("test.event.value", event_name: [:test, test_event])
      ]

      start_supervised!({Otelot.MetricExporter, @base_config ++ [metrics: metrics]})

      :ets.delete(@name)

      log =
        capture_log(fn ->
          :telemetry.execute([:test, test_event], %{value: 42}, %{test: "value"})
          # Give logger a moment to flush
          Process.sleep(50)
        end)

      assert log =~ "Otelot.MetricExporter failed to process event due to ETS table missing"
      refute log =~ "[:test, #{inspect(test_event)}]} has failed and has been detached."
    end
  end

  describe "invalid measurements" do
    for type <- [:sum, :last_value, :distribution],
        {label, measurements} <- [
          {"missing", quote(do: %{other: 1})},
          {"nil", quote(do: %{value: nil, other: 1})},
          {"undefined", quote(do: %{value: :undefined, other: 1})},
          {"non-numeric", quote(do: %{value: "abc", other: 1})}
        ] do
      test "#{type}: a #{label} measurement is skipped without detaching the handler" do
        event = [:test, :"event_#{System.unique_integer([:positive])}"]

        metrics = [
          apply(Metrics, unquote(type), ["test.bad.value", [event_name: event]]),
          Metrics.counter("test.good.count", event_name: event, measurement: :other)
        ]

        start_supervised!({Otelot.MetricExporter, @base_config ++ [metrics: metrics]})

        log =
          capture_log(fn ->
            :telemetry.execute(event, unquote(measurements), %{})
            :telemetry.execute(event, unquote(measurements), %{})
            Logger.flush()
          end)

        refute log =~ "has been detached"
        assert [_] = :telemetry.list_handlers(event)

        assert [_] =
                 Regex.scan(~r/Otelot.MetricExporter skipped an invalid measurement/, log)

        assert log =~ "test.bad.value"

        :telemetry.execute(event, %{value: 5, other: 1}, %{})

        metrics = Otelot.MetricStore.get_metrics(@name)
        assert %{%{} => 3} = metrics[{:counter, "test.good.count"}]
        assert metrics[{unquote(type), "test.bad.value"}] |> Map.fetch!(%{}) |> recorded_once?()
      end
    end

    test "a counter counts events regardless of the measurement" do
      event = [:test, :"event_#{System.unique_integer([:positive])}"]
      metrics = [Metrics.counter("test.count", event_name: event, measurement: :value)]

      start_supervised!({Otelot.MetricExporter, @base_config ++ [metrics: metrics]})

      :telemetry.execute(event, %{}, %{})
      :telemetry.execute(event, %{value: nil}, %{})

      assert %{{:counter, "test.count"} => %{%{} => 2}} = Otelot.MetricStore.get_metrics(@name)
    end

    test "a metric that fails to record does not affect other metrics on the same event" do
      event = [:test, :"event_#{System.unique_integer([:positive])}"]

      metrics = [
        Metrics.sum("test.raising.value",
          event_name: event,
          measurement: fn _ -> raise "boom" end
        ),
        Metrics.counter("test.good.count", event_name: event, measurement: :other)
      ]

      start_supervised!({Otelot.MetricExporter, @base_config ++ [metrics: metrics]})

      log =
        capture_log(fn ->
          :telemetry.execute(event, %{other: 1}, %{})
          :telemetry.execute(event, %{other: 1}, %{})
          Logger.flush()
        end)

      refute log =~ "has been detached"
      assert [_] = :telemetry.list_handlers(event)
      assert [_] = Regex.scan(~r/Otelot.MetricExporter failed to record metric/, log)
      assert log =~ "boom"

      assert %{{:counter, "test.good.count"} => %{%{} => 2}} =
               Otelot.MetricStore.get_metrics(@name)
    end
  end

  # Only the valid event at the end of each test has been recorded
  defp recorded_once?(5), do: true

  defp recorded_once?(%{} = buckets),
    do: buckets |> Map.drop([:min, :max]) |> Map.values() == [{1, 5}]

  defp recorded_once?(_), do: false
end
