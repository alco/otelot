defmodule Otelot.LogHandlerSupervisorTest do
  use ExUnit.Case

  alias Otelot.Opentelemetry.Proto.Logs.V1.LogRecord
  alias Otelot.Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceRequest
  alias Otelot.LogAccumulator
  alias Otelot.LogHandlerSupervisor

  setup do
    bypass = Passby.open()

    {:ok, config} =
      LogAccumulator.check_config(
        %{
          otlp_endpoint: "http://localhost:#{bypass.port}",
          resource: %{instance: %{id: "test"}},
          debounce_ms: 100,
          max_buffer_size: 20
        },
        :test_log_handler_supervisor
      )

    # The supervisor is linked to the test process and shuts down asynchronously once the
    # test exits. Wait for it to terminate so the next test can reuse its registered name.
    on_exit(fn ->
      if pid = Process.whereis(:test_log_handler_supervisor) do
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 15_000
      end
    end)

    {:ok, %{bypass: bypass, config: config}}
  end

  test "starts the supervisor and the accumulator with overload protection", %{config: config} do
    {:ok, supervisor_pid, olp} =
      LogHandlerSupervisor.start_link(
        name: :test_log_handler_supervisor,
        accumulator_config: config,
        olp_config: %{}
      )

    assert Process.alive?(supervisor_pid)
    assert :logger_olp.get_pid(olp) |> Process.alive?()
  end

  test "sends logs after debounce period has passed", %{bypass: bypass, config: config} do
    {:ok, _, olp} =
      LogHandlerSupervisor.start_link(
        name: :test_log_handler_supervisor,
        accumulator_config: config,
        olp_config: %{}
      )

    parent = self()

    Passby.expect_once(bypass, "POST", "/v1/logs", fn conn ->
      body = conn.req_body

      assert {"content-type", "application/x-protobuf"} in conn.req_headers
      assert {"accept", "application/x-protobuf"} in conn.req_headers
      assert {"content-encoding", "gzip"} in conn.req_headers
      assert body != ""

      %ExportLogsServiceRequest{resource_logs: [%{scope_logs: [%{log_records: logs}]}]} =
        body |> :zlib.gunzip() |> Protobuf.decode(ExportLogsServiceRequest)

      assert length(logs) == 5

      assert Enum.all?(
               logs,
               &match?(%LogRecord{body: %{value: {:string_value, "test log" <> _}}}, &1)
             )

      send(parent, :done)

      Passby.resp(conn, 200, "")
    end)

    for i <- 1..5 do
      :logger_olp.load(
        olp,
        LogAccumulator.prepare_log_event(
          %{
            level: :info,
            msg: {:string, "test log #{i}"},
            meta: %{time: System.system_time(:millisecond)}
          },
          config
        )
      )
    end

    assert_receive :done, 1000
    Process.sleep(100)
  end

  test "sends logs immediately once the limit is hit", %{bypass: bypass, config: config} do
    {:ok, _, olp} =
      LogHandlerSupervisor.start_link(
        name: :test_log_handler_supervisor,
        accumulator_config: %{config | max_buffer_size: 5, debounce_ms: 30_000},
        olp_config: %{}
      )

    parent = self()

    Passby.expect_once(bypass, "POST", "/v1/logs", fn conn ->
      body = conn.req_body

      assert {"content-type", "application/x-protobuf"} in conn.req_headers
      assert {"accept", "application/x-protobuf"} in conn.req_headers
      assert {"content-encoding", "gzip"} in conn.req_headers
      assert body != ""

      %ExportLogsServiceRequest{resource_logs: [%{scope_logs: [%{log_records: logs}]}]} =
        body |> :zlib.gunzip() |> Protobuf.decode(ExportLogsServiceRequest)

      assert length(logs) == 5

      assert Enum.all?(
               logs,
               &match?(%LogRecord{body: %{value: {:string_value, "test log" <> _}}}, &1)
             )

      send(parent, :done)

      Passby.resp(conn, 200, "")
    end)

    for i <- 1..5 do
      :logger_olp.load(
        olp,
        LogAccumulator.prepare_log_event(
          %{
            level: :info,
            msg: {:string, "test log #{i}"},
            meta: %{
              time: System.system_time(:millisecond),
              otel_trace_id: ~C"00000000000000000000000000000000"
            }
          },
          config
        )
      )
    end

    assert_receive :done, 1000
    Process.sleep(100)
  end
end
