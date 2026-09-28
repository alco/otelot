defmodule Otelot.OtelApi.ConfigTest do
  use ExUnit.Case, async: false

  alias Otelot.OtelApi.Config

  @touched_envs ~w|OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_PROTOCOL OTEL_EXPORTER_OTLP_HEADERS OTEL_EXPORTER_OTLP_TIMEOUT| ++
                  ~w|OTEL_RESOURCE_ATTRIBUTES OTEL_SERVICE_NAME| ++
                  ~w|OTEL_EXPORTER_OTLP_LOGS_ENDPOINT OTEL_EXPORTER_OTLP_LOGS_PROTOCOL OTEL_EXPORTER_OTLP_LOGS_HEADERS OTEL_EXPORTER_OTLP_LOGS_TIMEOUT| ++
                  ~w|OTEL_EXPORTER_OTLP_METRICS_ENDPOINT OTEL_EXPORTER_OTLP_METRICS_PROTOCOL OTEL_EXPORTER_OTLP_METRICS_HEADERS OTEL_EXPORTER_OTLP_METRICS_TIMEOUT| ++
                  ~w|OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER|

  setup do
    on_exit(fn ->
      for env <- @touched_envs do
        System.delete_env(env)
      end

      Application.get_all_env(:otelot)
      |> Keyword.keys()
      |> Enum.each(fn key ->
        Application.delete_env(:otelot, key)
      end)
    end)

    :ok
  end

  describe "defaults" do
    test "returns the default values" do
      assert Otelot.OtelApi.Config.defaults() ==
               {:ok,
                %{
                  logs: %{
                    exporter: :otlp
                  },
                  metrics: %{
                    exporter: :otlp
                  },
                  otlp_compression: :gzip,
                  otlp_concurrent_requests: 10,
                  resource: %{},
                  otlp_headers: %{},
                  otlp_protocol: :http_protobuf,
                  otlp_timeout: 10000
                }}
    end

    test "can be overridden by env vars" do
      System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")
      System.put_env("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "http://localhost:4318")
      System.put_env("OTEL_EXPORTER_OTLP_METRICS_HEADERS", "key1=value1,key2=value2")
      System.put_env("OTEL_EXPORTER_OTLP_TIMEOUT", "10000")
      System.put_env("OTEL_METRICS_EXPORTER", "none")

      assert Otelot.OtelApi.Config.defaults() ==
               {:ok,
                %{
                  logs: %{
                    exporter: :otlp,
                    otlp_endpoint: "http://localhost:4318"
                  },
                  metrics: %{
                    exporter: :none,
                    otlp_headers: %{"key1" => "value1", "key2" => "value2"}
                  },
                  otlp_compression: :gzip,
                  otlp_concurrent_requests: 10,
                  resource: %{},
                  otlp_headers: %{},
                  otlp_protocol: :http_protobuf,
                  otlp_timeout: 10000,
                  otlp_endpoint: "http://localhost:4317"
                }}
    end

    test "can be set by application config that overrides env vars" do
      System.put_env("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "http://localhost:1010")
      System.put_env("OTEL_EXPORTER_OTLP_METRICS_HEADERS", "key1=value1,key2=value2")

      Application.put_env(:otelot, :otlp_endpoint, "http://localhost:4317")

      Application.put_env(:otelot, :logs, otlp_endpoint: "http://localhost:4318")

      Application.put_env(:otelot, :metrics, %{exporter: :none})

      assert Otelot.OtelApi.Config.defaults() ==
               {:ok,
                %{
                  logs: %{
                    exporter: :otlp,
                    otlp_endpoint: "http://localhost:4318"
                  },
                  metrics: %{
                    exporter: :none,
                    otlp_headers: %{"key1" => "value1", "key2" => "value2"}
                  },
                  otlp_compression: :gzip,
                  otlp_concurrent_requests: 10,
                  resource: %{},
                  otlp_headers: %{},
                  otlp_protocol: :http_protobuf,
                  otlp_timeout: 10000,
                  otlp_endpoint: "http://localhost:4317"
                }}
    end
  end

  describe "validate_for_scope/2" do
    test "returns error if otlp endpoint is not provided" do
      assert {:error, %{key: :otlp_endpoint}} =
               Otelot.OtelApi.Config.validate_for_scope(
                 %{logs: %{exporter: :otlp}},
                 :logs
               )
    end

    test "merges the base config with the scope specific config" do
      System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
      System.put_env("OTEL_EXPORTER_OTLP_TIMEOUT", "5")

      Application.put_env(:otelot, :logs,
        otlp_headers: %{"key1" => "value1", "key2" => "value2"},
        otlp_timeout: 10
      )

      assert {:ok,
              %Otelot.OtelApi.Config{
                exporter: :otlp,
                otlp_endpoint: "http://localhost:4318",
                otlp_headers: %{"key1" => "value1", "key2" => "value2"},
                otlp_timeout: 10
              }, %{}} =
               Otelot.OtelApi.Config.validate_for_scope(
                 %{logs: %{exporter: :otlp}},
                 :logs
               )
    end

    test "appends the signal path to the generic endpoint from env" do
      System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")

      assert {:ok, %Config{url: "http://localhost:4318/v1/logs"}, %{}} =
               Config.validate_for_scope(%{}, :logs)

      assert {:ok, %Config{url: "http://localhost:4318/v1/metrics"}, %{}} =
               Config.validate_for_scope(%{}, :metrics)
    end

    test "uses signal-specific endpoints from env as-is" do
      System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
      System.put_env("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "http://logs.example.com/custom/logs")

      assert {:ok,
              %Config{
                otlp_endpoint: "http://logs.example.com/custom/logs",
                url: "http://logs.example.com/custom/logs"
              }, %{}} = Config.validate_for_scope(%{}, :logs)

      assert {:ok, %Config{url: "http://localhost:4318/v1/metrics"}, %{}} =
               Config.validate_for_scope(%{}, :metrics)
    end

    test "appends the signal path to the generic endpoint from app config" do
      Application.put_env(:otelot, :otlp_endpoint, "http://localhost:4318")

      assert {:ok, %Config{url: "http://localhost:4318/v1/metrics"}, %{}} =
               Config.validate_for_scope(%{}, :metrics)
    end

    test "uses signal-specific endpoints from app config as-is" do
      Application.put_env(:otelot, :otlp_endpoint, "http://localhost:4318")
      Application.put_env(:otelot, :metrics, otlp_endpoint: "http://metrics.example.com/ingest")

      assert {:ok, %Config{url: "http://metrics.example.com/ingest"}, %{}} =
               Config.validate_for_scope(%{}, :metrics)

      assert {:ok, %Config{url: "http://localhost:4318/v1/logs"}, %{}} =
               Config.validate_for_scope(%{}, :logs)
    end

    test "app config signal-specific endpoint wins over the generic env endpoint" do
      System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
      Application.put_env(:otelot, :logs, otlp_endpoint: "http://logs.example.com/ingest")

      assert {:ok, %Config{url: "http://logs.example.com/ingest"}, %{}} =
               Config.validate_for_scope(%{}, :logs)
    end

    test "treats a directly provided endpoint as a base URL" do
      System.put_env("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "http://metrics.example.com/ingest")

      assert {:ok, %Config{url: "http://localhost:4318/v1/metrics"}, %{}} =
               Config.validate_for_scope(%{otlp_endpoint: "http://localhost:4318"}, :metrics)
    end

    test "doesn't return an error if exporter is set to :none" do
      Application.put_env(:otelot, :logs, exporter: :none)

      assert {:ok, %Otelot.OtelApi.Config{exporter: :none}, %{}} =
               Otelot.OtelApi.Config.validate_for_scope(
                 %{},
                 :logs
               )
    end
  end
end
