defmodule Otelot.OtelApiTest do
  use ExUnit.Case, async: false
  alias Otelot.OtelApi
  alias Otelot.OtelApi.Config

  setup do
    on_exit(fn ->
      System.delete_env("OTEL_SERVICE_NAME")
      System.delete_env("OTEL_RESOURCE_ATTRIBUTES")
    end)
  end

  describe "new/1" do
    test "creates a new OtelApi struct" do
      assert {:ok, %OtelApi{config: %Config{otlp_endpoint: "http://localhost:4317"}}, %{}} =
               OtelApi.new(%{finch: :test_finch, otlp_endpoint: "http://localhost:4317"}, :logs)
    end

    test "returns unrecognized options" do
      assert {:ok, %OtelApi{}, %{unknown_option: "value"}} =
               OtelApi.new(
                 %{
                   finch: :test_finch,
                   otlp_endpoint: "http://localhost:4317",
                   unknown_option: "value"
                 },
                 :logs
               )
    end

    test "normalizes the resource" do
      assert {:ok, %OtelApi{config: %Config{resource: %{"service.name" => "test"}}}, %{}} =
               OtelApi.new(
                 %{
                   finch: :test_finch,
                   otlp_endpoint: "http://localhost:4317",
                   resource: %{service: %{name: "test"}}
                 },
                 :logs
               )
    end

    test "puts service name from env" do
      System.put_env("OTEL_SERVICE_NAME", "test")

      assert {:ok, %OtelApi{config: %Config{resource: %{"service.name" => "test"}}}, %{}} =
               OtelApi.new(
                 %{
                   finch: :test_finch,
                   otlp_endpoint: "http://localhost:4317",
                   resource: %{}
                 },
                 :logs
               )
    end

    test "gives priority to provided config over env for service name" do
      System.put_env("OTEL_SERVICE_NAME", "test")

      assert {:ok, %OtelApi{config: %Config{resource: %{"service.name" => "test2"}}}, %{}} =
               OtelApi.new(
                 %{
                   finch: :test_finch,
                   otlp_endpoint: "http://localhost:4317",
                   resource: %{service: %{name: "test2"}}
                 },
                 :logs
               )
    end

    test "puts resource attributes from env" do
      System.put_env("OTEL_RESOURCE_ATTRIBUTES", "test=test2,test2=test3")

      assert {:ok, %OtelApi{config: %Config{resource: %{"test" => "test2", "test2" => "test3"}}},
              %{}} =
               OtelApi.new(%{finch: :test_finch, otlp_endpoint: "http://localhost:4317"}, :logs)
    end

    test "gives priority to provided config over env for resource attributes" do
      System.put_env("OTEL_RESOURCE_ATTRIBUTES", "test=test2")

      assert {:ok, %OtelApi{config: %Config{resource: %{"test" => "test3"}}}, %{}} =
               OtelApi.new(
                 %{
                   finch: :test_finch,
                   otlp_endpoint: "http://localhost:4317",
                   resource: %{test: "test3"}
                 },
                 :metrics
               )
    end
  end

  describe "otlp_timeout" do
    setup do
      bypass = Bypass.open()
      finch = :"otel_api_test_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch})

      {:ok, bypass: bypass, finch: finch}
    end

    defp new_api(server, finch, opts) do
      {:ok, api, %{}} =
        %{finch: finch, otlp_endpoint: "http://localhost:#{server.port}"}
        |> Map.merge(Map.new(opts))
        |> OtelApi.new(:metrics)

      api
    end

    # Bypass can't cleanly handle a request that is still in flight when the
    # test exits, so use a bare TCP server that accepts connections and never
    # responds to simulate a hung collector.
    defp start_unresponsive_server do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: true, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      start_supervised!(
        {Task, fn -> accept_loop(listen, []) end},
        id: :unresponsive_server
      )

      %{port: port}
    end

    defp accept_loop(listen, sockets) do
      {:ok, socket} = :gen_tcp.accept(listen)
      accept_loop(listen, [socket | sockets])
    end

    test "bounds a single request to a slow server", %{finch: finch} do
      api = new_api(start_unresponsive_server(), finch, otlp_timeout: 200, retry: false)

      {elapsed, result} = :timer.tc(fn -> OtelApi.send_metrics(api, []) end, :millisecond)

      assert {:error, _} = result
      assert elapsed < 1_000
    end

    test "bounds log exports as well", %{finch: finch} do
      server = start_unresponsive_server()

      {:ok, api, %{}} =
        OtelApi.new(
          %{
            finch: finch,
            otlp_endpoint: "http://localhost:#{server.port}",
            otlp_timeout: 200,
            retry: false
          },
          :logs
        )

      {elapsed, result} = :timer.tc(fn -> OtelApi.send_log_events(api, []) end, :millisecond)

      assert {:error, _} = result
      assert elapsed < 1_000
    end

    test "bounds the whole export including retries", %{finch: finch} do
      api = new_api(start_unresponsive_server(), finch, otlp_timeout: 1_500, retry: true)

      {elapsed, result} =
        :timer.tc(
          fn -> ExUnit.CaptureLog.with_log(fn -> OtelApi.send_metrics(api, []) end) end,
          :millisecond
        )

      assert {{:error, _}, _log} = result
      assert elapsed >= 1_000
      assert elapsed < 2_500
    end

    test "stops retrying transient errors once the timeout is exhausted", %{
      bypass: bypass,
      finch: finch
    } do
      Bypass.stub(bypass, "POST", "/v1/metrics", &Plug.Conn.resp(&1, 503, ""))
      api = new_api(bypass, finch, otlp_timeout: 500, retry: true)

      {elapsed, result} =
        :timer.tc(
          fn -> ExUnit.CaptureLog.with_log(fn -> OtelApi.send_metrics(api, []) end) end,
          :millisecond
        )

      assert {{:error, {:unexpected_status, %{status: 503}}}, _log} = result
      assert elapsed < 1_000
    end

    test "honours OTEL_EXPORTER_OTLP_TIMEOUT", %{finch: finch} do
      System.put_env("OTEL_EXPORTER_OTLP_TIMEOUT", "200")
      on_exit(fn -> System.delete_env("OTEL_EXPORTER_OTLP_TIMEOUT") end)

      api = new_api(start_unresponsive_server(), finch, retry: false)
      assert api.config.otlp_timeout == 200

      {elapsed, result} = :timer.tc(fn -> OtelApi.send_metrics(api, []) end, :millisecond)

      assert {:error, _} = result
      assert elapsed < 1_000
    end
  end
end
