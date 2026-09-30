defmodule Otelot.MetricStoreTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Otelot.Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest
  alias Telemetry.Metrics
  alias Otelot.MetricStore

  @name :metric_store_test
  @default_buckets [0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000]

  setup do
    bypass = Passby.open()
    {:ok, _} = start_supervised({Finch, name: TestFinch})

    config = %{
      otlp_protocol: :http_protobuf,
      otlp_endpoint: "http://localhost:#{bypass.port}",
      otlp_headers: %{},
      otlp_compression: nil,
      resource: %{instance: %{id: "test"}},
      export_period: 1000,
      default_buckets: @default_buckets,
      metrics: [],
      finch_pool: TestFinch,
      retry: false,
      name: @name
    }

    {:ok, bypass: bypass, store_config: config}
  end

  describe "recording metrics" do
    setup %{store_config: config}, do: {:ok, store: start_supervised!({MetricStore, config})}

    test "records counter metrics" do
      metric = Metrics.counter("test.value")
      tags = %{test: "value"}

      MetricStore.write_metric(@name, metric, 1, tags)
      MetricStore.write_metric(@name, metric, 2, tags)

      metrics = MetricStore.get_metrics(@name)

      assert %{{:counter, "test.value"} => %{^tags => 2}} = metrics
    end

    test "records sum metrics" do
      metric = Metrics.sum("test.value")
      tags = %{test: "value"}

      MetricStore.write_metric(@name, metric, 1, tags)
      MetricStore.write_metric(@name, metric, 2, tags)

      metrics = MetricStore.get_metrics(@name)

      assert %{{:sum, "test.value"} => %{^tags => 3}} = metrics
    end

    test "records last value metrics" do
      metric = Metrics.last_value("test.value")
      tags = %{test: "value"}

      MetricStore.write_metric(@name, metric, 1, tags)
      MetricStore.write_metric(@name, metric, 2, tags)

      metrics = MetricStore.get_metrics(@name)

      assert %{{:last_value, "test.value"} => %{^tags => 2}} = metrics
    end

    test "records distribution metrics" do
      metric = Metrics.distribution("test.value", reporter_options: [buckets: [2, 4]])
      tags = %{test: "value"}

      MetricStore.write_metric(@name, metric, 2, tags)
      MetricStore.write_metric(@name, metric, 3, tags)
      MetricStore.write_metric(@name, metric, 5, tags)
      MetricStore.write_metric(@name, metric, 5, tags)

      metrics = MetricStore.get_metrics(@name)

      assert %{
               {:distribution, "test.value"} => %{
                 ^tags => %{0 => {1, 2}, 1 => {1, 3}, 2 => {2, 10}, min: {2, nil}, max: {5, nil}}
               }
             } = metrics
    end

    test "handles different tag sets independently" do
      metric = Metrics.sum("test.value")
      tags1 = %{test: "value1"}
      tags2 = %{test: "value2"}

      MetricStore.write_metric(@name, metric, 1, tags1)
      MetricStore.write_metric(@name, metric, 2, tags2)
      MetricStore.write_metric(@name, metric, 2, tags1)

      metrics = MetricStore.get_metrics(@name)

      assert %{
               {:sum, "test.value"} => %{^tags1 => 3, ^tags2 => 2}
             } = metrics
    end
  end

  describe "export flow" do
    test "exports all metrics in protobuf format", %{bypass: bypass, store_config: config} do
      metrics =
        [metric1, metric2, metric_lv_int, metric_lv_bigint, metric_lv_float, metric4] =
        [
          Metrics.sum("test.sum"),
          Metrics.counter("test.counter"),
          Metrics.last_value("test.last_value.int"),
          Metrics.last_value("test.last_value.bigint"),
          Metrics.last_value("test.last_value.float"),
          Metrics.distribution("test.distribution")
        ]

      start_supervised!({MetricStore, %{config | metrics: metrics}})

      tags = %{test: "value"}

      Passby.expect_once(bypass, "POST", "/v1/metrics", fn conn ->
        body = conn.req_body

        assert {"content-type", "application/x-protobuf"} in conn.req_headers
        assert {"accept", "application/x-protobuf"} in conn.req_headers

        assert body != ""

        # Decodes withouth raising
        ExportMetricsServiceRequest.decode(body)

        Passby.resp(conn, 200, "")
      end)

      MetricStore.write_metric(@name, metric1, 1, tags)
      MetricStore.write_metric(@name, metric2, 2, tags)
      MetricStore.write_metric(@name, metric_lv_int, 2 ** 63 - 1, tags)
      MetricStore.write_metric(@name, metric_lv_bigint, 2 ** 70, tags)
      MetricStore.write_metric(@name, metric_lv_float, -1.5, tags)
      MetricStore.write_metric(@name, metric4, 4, tags)
      MetricStore.write_metric(@name, metric4, 2000, tags)

      metrics = MetricStore.get_metrics(@name)
      assert map_size(metrics) > 0

      # Export metrics synchronously
      assert :ok = MetricStore.export_sync(@name)

      # Verify metrics were cleared
      assert MetricStore.get_metrics(@name, 0) == %{}
    end

    test "exports nil and :undefined last_value as a nil data point without crashing", %{
      bypass: bypass,
      store_config: config
    } do
      metric_undef = Metrics.last_value("test.last_value.undefined")
      metric_nil = Metrics.last_value("test.last_value.nil")
      tags = %{test: "value"}
      start_supervised!({MetricStore, %{config | metrics: [metric_undef, metric_nil]}})

      Passby.expect_once(bypass, "POST", "/v1/metrics", fn conn ->
        body = conn.req_body
        decoded = ExportMetricsServiceRequest.decode(body)

        assert [%{scope_metrics: [%{metrics: exported_metrics}]}] = decoded.resource_metrics

        Enum.each(exported_metrics, fn metric ->
          assert {:gauge, %{data_points: [point]}} = metric.data
          # protobuf elides the nil inner value, so the oneof decodes as nil
          assert point.value == nil
        end)

        Passby.resp(conn, 200, "")
      end)

      # `:telemetry` emits `:undefined` for uninitialised values
      MetricStore.write_metric(@name, metric_undef, :undefined, tags)

      # A `nil` value may slip in just as well
      MetricStore.write_metric(@name, metric_nil, nil, tags)

      assert :ok = MetricStore.export_sync(@name)
    end

    test "handles server errors gracefully", %{bypass: bypass, store_config: config} do
      metric = Metrics.sum("test.sum")
      tags = %{test: "value"}
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      Passby.expect_once(bypass, "POST", "/v1/metrics", fn conn ->
        Passby.resp(conn, 500, "Internal Server Error")
      end)

      MetricStore.write_metric(@name, metric, 1, tags)

      metrics = MetricStore.get_metrics(@name)

      # Export metrics synchronously
      assert capture_log(fn -> MetricStore.export_sync(@name) end) =~ "Failed to export metrics"

      # Verify metrics were not cleared due to error
      assert MetricStore.get_metrics(@name, 0) == metrics
    end

    test "handles connection errors gracefully", %{bypass: bypass, store_config: config} do
      metric = Metrics.sum("test.sum")
      tags = %{test: "value"}
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      Passby.down(bypass)

      MetricStore.write_metric(@name, metric, 1, tags)

      metrics = MetricStore.get_metrics(@name)

      # Export metrics synchronously
      assert capture_log(fn -> MetricStore.export_sync(@name) end) =~ "Failed to export metrics"

      # Verify metrics were not cleared due to error
      assert MetricStore.get_metrics(@name, 0) == metrics
    end

    test "preserves metrics across generations on failed exports", %{
      bypass: bypass,
      store_config: config
    } do
      metric = Metrics.sum("test.sum")
      tags = %{test: "value"}
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      # First generation
      MetricStore.write_metric(@name, metric, 1, tags)

      # First export fails
      Passby.expect_once(bypass, "POST", "/v1/metrics", fn conn ->
        Passby.resp(conn, 500, "Internal Server Error")
      end)

      capture_log(fn -> MetricStore.export_sync(@name) end)

      # Second generation
      MetricStore.write_metric(@name, metric, 2, tags)

      # Second export succeeds and should include both generations
      Passby.expect_once(bypass, "POST", "/v1/metrics", fn conn ->
        body = conn.req_body
        metrics = ExportMetricsServiceRequest.decode(body)

        # Verify that we have one metric with sum = 3 (1 from first generation + 2 from second)
        assert [%{scope_metrics: [%{metrics: [metric]}]}] = metrics.resource_metrics

        assert {:sum, %{data_points: [point1, point2]}} = metric.data
        assert {:as_int, 1} = point1.value
        assert {:as_int, 2} = point2.value

        assert point1.time_unix_nano < point2.time_unix_nano
        assert point2.start_time_unix_nano > point1.time_unix_nano

        Passby.resp(conn, 200, "")
      end)

      assert :ok = MetricStore.export_sync(@name)

      # Both generations should be cleared after successful export
      assert MetricStore.get_metrics(@name, 0) == %{}
      assert MetricStore.get_metrics(@name, 1) == %{}
    end
  end

  describe "generations" do
    @other_name :metric_store_test_other

    setup %{store_config: config} do
      # Exports are triggered explicitly in these tests
      {:ok, store_config: %{config | export_period: :timer.minutes(10)}}
    end

    defp start_store(config, name) do
      start_supervised!(Supervisor.child_spec({MetricStore, %{config | name: name}}, id: name))
    end

    defp expect_exports(bypass) do
      test_pid = self()

      Bypass.expect(bypass, "POST", "/v1/metrics", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:exported, ExportMetricsServiceRequest.decode(body)})
        Plug.Conn.resp(conn, 200, "")
      end)
    end

    defp exported_sum_values(request) do
      for %{scope_metrics: scope_metrics} <- request.resource_metrics,
          %{metrics: metrics} <- scope_metrics,
          %{data: {:sum, %{data_points: points}}} <- metrics,
          %{value: {:as_int, value}} <- points,
          reduce: 0 do
        acc -> acc + value
      end
    end

    defp collect_exported_sum(acc \\ 0) do
      receive do
        {:exported, request} -> collect_exported_sum(acc + exported_sum_values(request))
      after
        0 -> acc
      end
    end

    defp export_until_stopped do
      :ok = MetricStore.export_sync(@name)

      receive do
        :stop -> :ok
      after
        0 -> export_until_stopped()
      end
    end

    test "rotating one store does not affect another", %{bypass: bypass, store_config: config} do
      metric = Metrics.sum("test.sum")
      tags = %{test: "value"}
      config = %{config | metrics: [metric]}

      start_store(config, @name)
      start_store(config, @other_name)

      MetricStore.write_metric(@name, metric, 1, tags)
      MetricStore.write_metric(@other_name, metric, 5, tags)

      expect_exports(bypass)

      assert :ok = MetricStore.export_sync(@name)
      assert_received {:exported, request}
      assert exported_sum_values(request) == 1

      assert MetricStore.get_metrics(@name) == %{}

      # The other store keeps its data and is still writing into its first generation
      MetricStore.write_metric(@other_name, metric, 2, tags)
      assert %{{:sum, "test.sum"} => %{^tags => 7}} = MetricStore.get_metrics(@other_name, 0)

      # Stopping and restarting the first store leaves the other one intact
      :ok = stop_supervised(@name)
      start_store(config, @name)

      MetricStore.write_metric(@name, metric, 3, tags)
      assert %{{:sum, "test.sum"} => %{^tags => 3}} = MetricStore.get_metrics(@name, 0)
      assert %{{:sum, "test.sum"} => %{^tags => 7}} = MetricStore.get_metrics(@other_name, 0)

      assert :ok = MetricStore.export_sync(@other_name)
      assert_received {:exported, request}
      assert exported_sum_values(request) == 7
    end

    test "does not write to persistent_term on export", %{bypass: bypass, store_config: config} do
      metric = Metrics.sum("test.sum")
      store = start_store(%{config | metrics: [metric]}, @name)

      expect_exports(bypass)

      traced = [{:persistent_term, :put, 2}, {:persistent_term, :erase, 1}]
      for mfa <- traced, do: :erlang.trace_pattern(mfa, true, [:global])
      :erlang.trace(store, true, [:call, {:tracer, self()}])

      on_exit(fn -> for mfa <- traced, do: :erlang.trace_pattern(mfa, false, [:global]) end)

      for i <- 1..3 do
        MetricStore.write_metric(@name, metric, i, %{})
        assert :ok = MetricStore.export_sync(@name)
      end

      refute_received {:trace, ^store, :call, {:persistent_term, _, _}}

      assert collect_exported_sum() == 6
    end

    test "concurrent writers never lose data to a rotating generation", %{
      bypass: bypass,
      store_config: config
    } do
      metric = Metrics.counter("test.counter")
      start_store(%{config | metrics: [metric]}, @name)

      expect_exports(bypass)

      writers = 8
      writes_per_writer = 20_000

      exporter = Task.async(fn -> export_until_stopped() end)

      tasks =
        for w <- 1..writers do
          Task.async(fn ->
            for _ <- 1..writes_per_writer do
              MetricStore.write_metric(@name, metric, 1, %{writer: w})
            end
          end)
        end

      Task.await_many(tasks, 60_000)
      send(exporter.pid, :stop)
      Task.await(exporter, 60_000)

      # Final export picks up whatever was written after the last concurrent export
      assert :ok = MetricStore.export_sync(@name)

      assert collect_exported_sum() == writers * writes_per_writer

      # No metric rows are left behind in drained generations
      assert :ets.select_count(@name, [{{{:_, :_, :_, :_, :_}, :_, :_}, [], [true]}]) == 0
    end

    test "an export waits for a writer that entered the generation being drained", %{
      bypass: bypass,
      store_config: config
    } do
      metric = Metrics.sum("test.sum")
      tags = %{test: "value"}
      start_store(%{config | metrics: [metric]}, @name)

      expect_exports(bypass)

      test_pid = self()

      # A writer that has picked a generation but has not inserted anything yet
      writer =
        Task.async(fn ->
          MetricStore.in_generation(@name, fn generation ->
            send(test_pid, {:entered, generation})
            assert_receive :resume, 5_000
            key = {generation, "test.sum", :sum, tags, nil}
            :ets.update_counter(@name, key, 42, {key, 0, nil})
          end)
        end)

      assert_receive {:entered, 0}

      exporter = Task.async(fn -> MetricStore.export_sync(@name) end)

      # The export does not drain the generation while the writer is still in it
      refute Task.yield(exporter, 200)

      # New writes already go to the next generation
      MetricStore.write_metric(@name, metric, 1, tags)
      assert %{{:sum, "test.sum"} => %{^tags => 1}} = MetricStore.get_metrics(@name, 1)

      send(writer.pid, :resume)
      Task.await(writer)

      assert :ok = Task.await(exporter)
      assert_received {:exported, request}
      assert exported_sum_values(request) == 42

      assert MetricStore.get_metrics(@name, 0) == %{}
      assert %{{:sum, "test.sum"} => %{^tags => 1}} = MetricStore.get_metrics(@name)
    end
  end
end
