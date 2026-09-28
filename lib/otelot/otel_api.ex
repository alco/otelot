defmodule Otelot.OtelApi do
  @moduledoc false

  import Retry.DelayStreams

  alias Otelot.OtelApi.Config
  alias Otelot.Protocol

  require Logger

  @schema NimbleOptions.new!(
            finch: [
              type: {:or, [:atom, :pid]},
              required: true,
              doc: "Finch process pid or registered name to use for sending requests."
            ],
            retry: [
              type: :boolean,
              default: true,
              doc: "Retry HTTP requests when receiving a transient error"
            ]
          )

  defstruct [:finch, :retry, :config, :scope]

  def public_options, do: Config.public_options()

  def new(opts, scope) do
    with {:ok, config, rest} <- Config.validate_for_scope(opts, scope),
         {own_opts, rest} <- Map.split(rest, [:finch, :retry]),
         {:ok, validated} <- NimbleOptions.validate(own_opts, @schema) do
      {:ok,
       %__MODULE__{
         config: config,
         scope: scope,
         finch: validated.finch,
         retry: validated.retry
       }, rest}
    end
  end

  def send_log_events(%__MODULE__{config: config} = api, events) do
    events
    |> Protocol.build_log_service_request(config.resource)
    |> send_proto("/v1/logs", api)
  end

  def send_metrics(%__MODULE__{config: config} = api, metrics) do
    metrics
    |> Protocol.build_metric_service_request(config.resource)
    |> send_proto("/v1/metrics", api)
  end

  @spec send_proto(struct(), String.t(), %__MODULE__{}) :: :ok | {:error, any()}
  defp send_proto(body, path, %__MODULE__{} = api) do
    # Per the OTel spec, `otlp_timeout` is the maximum time to wait for each
    # batch export, retries included.
    deadline = now() + api.config.otlp_timeout

    body
    |> encode_to_iodata()
    |> build_finch_request(path, api)
    |> make_finch_request(api.finch, deadline, with_retry?: api.retry)
  end

  def encode_to_iodata(body) do
    Protobuf.encode_to_iodata(body)
  rescue
    e in Protobuf.EncodeError ->
      raise Protobuf.EncodeError,
        message: """
        Failed to encode body: #{e.message}

        Body:

        #{inspect(body, pretty: true, limit: :infinity, printable_limit: :infinity)}
        """
  end

  defp build_finch_request(body, path, %__MODULE__{} = api) do
    Finch.build(
      :post,
      url(api, path),
      Map.to_list(headers(api)),
      maybe_compress(body, api)
    )
  end

  defp make_finch_request(request, finch_pool, deadline, with_retry?: true) do
    delays = exponential_backoff(1_000) |> randomize()
    do_make_finch_request_with_retry(request, finch_pool, deadline, delays)
  end

  defp make_finch_request(request, finch_pool, deadline, with_retry?: false) do
    finch_request(request, finch_pool, deadline)
  end

  defp do_make_finch_request_with_retry(request, finch_pool, deadline, delays) do
    case finch_request(request, finch_pool, deadline) do
      :ok ->
        :ok

      {:error, {:unexpected_status, %{status: status} = response}} = error
      when status in [408, 429, 500, 502, 503, 504] ->
        maybe_retry(request, finch_pool, deadline, delays, error, fn ->
          Logger.warning(
            "Got transient error #{status} from server #{inspect(response)}, retrying...",
            request_path: request.path
          )
        end)

      {:error, {:unexpected_status, _response}} = permanent_error ->
        # This will be logged by the caller
        permanent_error

      {:error, reason} = error ->
        maybe_retry(request, finch_pool, deadline, delays, error, fn ->
          Logger.warning(
            "Got connection/transport error when sending metrics #{inspect(reason)}, retrying...",
            request_path: request.path
          )
        end)
    end
  end

  # Retry after a backoff delay, unless the delay would run past the deadline,
  # in which case give up and return the last error.
  defp maybe_retry(request, finch_pool, deadline, delays, error, log_fun) do
    [delay] = Enum.take(delays, 1)

    if now() + delay < deadline do
      log_fun.()
      Process.sleep(delay)
      do_make_finch_request_with_retry(request, finch_pool, deadline, Stream.drop(delays, 1))
    else
      error
    end
  end

  defp finch_request(request, finch_pool, deadline) do
    timeout = max(deadline - now(), 0)

    request
    |> Finch.request(finch_pool, receive_timeout: timeout, request_timeout: timeout)
    |> case do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, response} ->
        {:error, {:unexpected_status, response}}

      {:error, _reason} = error ->
        error
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp url(%__MODULE__{config: config}, path), do: config.otlp_endpoint <> path

  defp headers(%__MODULE__{config: %Config{otlp_compression: compression} = config}) do
    [:content_type, :accept, :compression]
    |> Enum.reduce(%{}, fn
      :content_type, acc -> Map.put(acc, "content-type", "application/x-protobuf")
      :accept, acc -> Map.put(acc, "accept", "application/x-protobuf")
      :compression, acc when compression == :gzip -> Map.put(acc, "content-encoding", "gzip")
      _, acc -> acc
    end)
    |> Map.merge(config.otlp_headers)
  end

  defp maybe_compress(body, %__MODULE__{config: %Config{otlp_compression: :gzip}}),
    do: :zlib.gzip(body)

  defp maybe_compress(body, _), do: body
end
