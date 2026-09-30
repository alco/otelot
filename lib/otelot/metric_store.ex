defmodule Otelot.MetricStore do
  @moduledoc false

  use GenServer

  require Logger

  alias Telemetry.Metrics

  alias Otelot.Opentelemetry.Proto.Metrics.V1.{
    Metric,
    NumberDataPoint,
    HistogramDataPoint,
    Sum,
    Gauge,
    Histogram
  }

  alias Otelot.OtelApi

  import Otelot.OtlpUtils, only: [build_kv: 1]

  @default_buckets [0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000]

  # Generations
  #
  # Metric rows are keyed by `{generation, ...}`. On every export the store bumps the current
  # generation, waits for writers still inside the previous one to finish, then exports and
  # deletes every generation up to the previous one.
  #
  # The current generation and the number of writers inside each generation live in a
  # per-store `:atomics` array whose reference is kept in a single row of the store's own
  # metrics table. Nothing is written to `:persistent_term`, so exports do not trigger global
  # `persistent_term` updates, and stores do not interfere with each other.
  #
  # A writer enters a generation by incrementing that generation's writers counter and then
  # re-reading the current generation. If the generation has changed in the meantime, it backs
  # off and retries with the new one. The exporter bumps the generation first and only then
  # waits for the writers counter of the old generation to drop to zero. Because all atomics
  # operations are mutually ordered, a writer either sees the new generation (and moves on to
  # it), or its increment is seen by the exporter, which then waits for its write to complete.
  # No write can land in a generation after it has been drained.
  #
  # Writers counters are indexed by the generation's parity: once the exporter is done with
  # generation N, no writer can enter it any more, so its counter is reused for N + 2.

  # The key is an atom, so this row never matches the `{generation, ...}` patterns of metric rows
  @counters_key :"$otelot_generation_counters"
  @generation_ix 1
  @writers_ix_base 2

  # How long the exporter waits for writers to leave a generation before giving up on them.
  # Writers only spend a few ETS operations inside a generation, so this is only reached if a
  # writer process is killed mid-write.
  @writers_wait_ms 1_000

  defmodule State do
    @moduledoc false
    defstruct [
      :config,
      :api,
      :metrics,
      :metrics_table,
      :last_export,
      :generations_table,
      :counters
    ]

    @type t :: %__MODULE__{
            config: map(),
            api: struct(),
            metrics: list(),
            metrics_table: atom(),
            generations_table: :ets.tid(),
            counters: :atomics.atomics_ref(),
            last_export: nil | DateTime.t()
          }
  end

  @doc false
  def default_buckets, do: @default_buckets

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: config.name)
  end

  def get_metrics(metrics_table, generation \\ nil) do
    generation = generation || current_generation(metrics_table)

    :ets.match_object(metrics_table, {{generation, :_, :_, :_, :_}, :_, :_})
    |> Enum.reduce(%{}, fn
      {{_, name, :distribution, tags, bucket}, count, sum}, acc ->
        Map.update(
          acc,
          {:distribution, name},
          %{tags => %{bucket => {count, sum}}},
          fn all_tags ->
            Map.update(all_tags, tags, %{bucket => {count, sum}}, fn all_buckets ->
              Map.put(all_buckets, bucket, {count, sum})
            end)
          end
        )

      {{_, name, type, tags, _}, value, _}, acc ->
        Map.update(acc, {type, name}, %{tags => value}, fn all_tags ->
          Map.put(all_tags, tags, value)
        end)
    end)
  end

  defp current_generation(metrics_table) do
    metrics_table
    |> :ets.lookup_element(@counters_key, 2)
    |> :atomics.get(@generation_ix)
  end

  @doc false
  # Calls `fun` with the current generation. The generation is guaranteed not to be exported
  # and drained until `fun` returns, so `fun` may safely write metric rows for it.
  def in_generation(metrics_table, fun) do
    counters = :ets.lookup_element(metrics_table, @counters_key, 2)
    {generation, writers_ix} = enter_generation(counters)

    try do
      fun.(generation)
    after
      :atomics.sub(counters, writers_ix, 1)
    end
  end

  defp enter_generation(counters) do
    generation = :atomics.get(counters, @generation_ix)
    ix = writers_ix(generation)
    :atomics.add(counters, ix, 1)

    if :atomics.get(counters, @generation_ix) == generation do
      {generation, ix}
    else
      # The generation was rotated between the two reads; retry with the new one
      :atomics.sub(counters, ix, 1)
      enter_generation(counters)
    end
  end

  defp writers_ix(generation), do: @writers_ix_base + rem(generation, 2)

  def export_sync(name) do
    GenServer.call(name, :export_sync, :infinity)
  end

  defp metric_type(%Metrics.Counter{}), do: :counter
  defp metric_type(%Metrics.Sum{}), do: :sum
  defp metric_type(%Metrics.LastValue{}), do: :last_value
  defp metric_type(%Metrics.Distribution{}), do: :distribution

  def write_metric(metrics_table, metric, value, tags),
    do: write_metric(metrics_table, metric, Enum.join(metric.name, "."), value, tags)

  def write_metric(metrics_table, metric, string_name, value, tags) do
    in_generation(metrics_table, fn generation ->
      write_metric(metrics_table, generation, metric, string_name, value, tags)
    end)
  end

  defp write_metric(metrics_table, generation, %Metrics.Counter{} = metric, string_name, _, tags) do
    ets_key = {generation, string_name, metric_type(metric), tags, nil}

    :ets.update_counter(metrics_table, ets_key, 1, {ets_key, 0, nil})
  end

  defp write_metric(metrics_table, generation, %Metrics.Sum{} = metric, string_name, value, tags) do
    ets_key = {generation, string_name, metric_type(metric), tags, nil}

    :ets.update_counter(metrics_table, ets_key, value, {ets_key, 0, nil})
  end

  defp write_metric(
         metrics_table,
         generation,
         %Metrics.LastValue{} = metric,
         string_name,
         value,
         tags
       ) do
    ets_key = {generation, string_name, metric_type(metric), tags, nil}
    :ets.update_element(metrics_table, ets_key, {2, value}, {ets_key, value, nil})
  end

  defp write_metric(
         metrics_table,
         generation,
         %Metrics.Distribution{} = metric,
         string_name,
         value,
         tags
       ) do
    bucket = find_bucket(metric, value)
    ets_key = {generation, string_name, metric_type(metric), tags, bucket}
    update_counter_op = {2, 1}
    update_sum_op = {3, round(value)}

    :ets.update_counter(
      metrics_table,
      ets_key,
      [update_counter_op, update_sum_op],
      {ets_key, 0, 0}
    )

    update_min_max(metrics_table, {generation, string_name, metric_type(metric), tags}, value)
  end

  def table_exists?(metrics_table) do
    case :ets.whereis(metrics_table) do
      :undefined -> false
      tid when is_reference(tid) -> true
    end
  end

  defp find_bucket(%Metrics.Distribution{reporter_options: opts}, value) do
    bucket_bounds = Keyword.get(opts, :buckets, @default_buckets)

    case Enum.find_index(bucket_bounds, &(value <= &1)) do
      # Overflow bucket
      nil -> length(bucket_bounds)
      idx -> idx
    end
  end

  defp update_min_max(metrics_table, base_key, value) do
    min_key = Tuple.insert_at(base_key, tuple_size(base_key), :min)

    unless :ets.insert_new(metrics_table, {min_key, value, nil}) do
      case :ets.lookup(metrics_table, min_key) do
        [{_, current, _}] when value < current ->
          :ets.insert(metrics_table, {min_key, value, nil})

        _ ->
          :ok
      end
    end

    max_key = Tuple.insert_at(base_key, tuple_size(base_key), :max)

    unless :ets.insert_new(metrics_table, {max_key, value, nil}) do
      case :ets.lookup(metrics_table, max_key) do
        [{_, current, _}] when value > current ->
          :ets.insert(metrics_table, {max_key, value, nil})

        _ ->
          :ok
      end
    end
  end

  @impl true
  def init(config) do
    metrics = Map.get(config, :metrics, [])
    metrics_table = config.name
    finch_pool = Map.get(config, :finch_pool, Otelot.Finch)
    Process.send_after(self(), :export, config.export_period)

    # Create ETS table for metrics
    :ets.new(metrics_table, [:ordered_set, :public, :named_table, {:write_concurrency, true}])

    counters = :atomics.new(@writers_ix_base + 1, signed: true)
    :ets.insert(metrics_table, {@counters_key, counters, nil})

    generations_table = :ets.new(:generations, [:ordered_set, :private])
    :ets.insert(generations_table, {0, System.system_time(:nanosecond), 0})

    with {:ok, api, config} <- OtelApi.new(Map.put(config, :finch, finch_pool), :metrics) do
      {:ok,
       %State{
         config: config,
         api: api,
         metrics: metrics,
         metrics_table: metrics_table,
         generations_table: generations_table,
         counters: counters
       }}
    end
  end

  @impl true
  def handle_call(:export_sync, _from, state) do
    case export_metrics(state) do
      :ok ->
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:export, state) do
    {duration, _} = :timer.tc(fn -> export_metrics(state) end, :millisecond)

    # schedule after we've sent to avoid problems when there's some kind of
    # problem sending and we get into a retry loop but take into account
    # time taken to send so we keep flushing the data on a regular interval
    Process.send_after(self(), :export, max(state.config.export_period - duration, 100))

    {:noreply, state}
  end

  defp rotate_generation(%State{counters: counters} = state) do
    current_gen = :atomics.add_get(counters, @generation_ix, 1) - 1
    await_writers(counters, writers_ix(current_gen), @writers_wait_ms)

    :ets.update_element(
      state.generations_table,
      current_gen,
      {3, System.system_time(:nanosecond)}
    )

    :ets.insert(state.generations_table, {current_gen + 1, System.system_time(:nanosecond), nil})

    current_gen
  end

  defp await_writers(counters, ix, attempts_left) do
    cond do
      :atomics.get(counters, ix) == 0 ->
        :ok

      attempts_left == 0 ->
        Logger.warning(
          "Otelot.MetricStore gave up waiting for metric writers to leave the exported generation"
        )

        :atomics.put(counters, ix, 0)

      true ->
        Process.sleep(1)
        await_writers(counters, ix, attempts_left - 1)
    end
  end

  defp export_metrics(%State{} = state) do
    current_gen = rotate_generation(state)

    earliest_gen =
      case :ets.first(state.generations_table) do
        :"$end_of_table" -> 0
        x -> x
      end

    earliest_gen..current_gen//1
    |> Enum.reduce(%{}, fn gen, acc ->
      {_, start, finish} = List.first(:ets.lookup(state.generations_table, gen), {nil, nil, nil})

      get_metrics(state.metrics_table, gen)
      |> Map.new(fn {metric_key, values} ->
        {metric_key, Enum.map(values, fn {tags, value} -> {{start, finish}, tags, value} end)}
      end)
      |> Map.merge(acc, fn _k, v1, v2 -> v2 ++ v1 end)
    end)
    |> Enum.map(fn {{type, name}, tagged_values} ->
      metric =
        Enum.find(state.metrics, &(Enum.join(&1.name, ".") == name and metric_type(&1) == type))

      convert_metric(metric, tagged_values)
    end)
    |> then(fn payload ->
      task = Task.async(fn -> OtelApi.send_metrics(state.api, payload) end)

      case Task.yield(task, 20_000) || Task.shutdown(task) do
        {:ok, result} -> result
        {:exit, reason} -> {:error, reason}
        nil -> {:error, :timeout}
      end
    end)
    |> case do
      :ok ->
        # Clear exported metrics
        for x <- earliest_gen..current_gen//1 do
          :ets.match_delete(state.metrics_table, {{x, :_, :_, :_, :_}, :_, :_})
          :ets.delete(state.generations_table, x)
        end

        :ok

      {:error, reason} ->
        Logger.error("Failed to export metrics: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp convert_metric(
         %{name: name, description: description, unit: unit} = metric,
         values
       ) do
    %Metric{
      name: Enum.join(name, "."),
      description: description,
      unit: convert_unit(unit),
      data: convert_data(metric, values)
    }
  end

  defp convert_data(%Metrics.Counter{}, values) do
    {:sum,
     %Sum{
       data_points:
         Enum.map(values, fn {{from, to}, tags, value} ->
           %NumberDataPoint{
             attributes: build_kv(tags),
             start_time_unix_nano: from,
             time_unix_nano: to,
             value: convert_value(value, :int)
           }
         end),
       aggregation_temporality: :AGGREGATION_TEMPORALITY_CUMULATIVE,
       is_monotonic: true
     }}
  end

  defp convert_data(%Metrics.Sum{}, values) do
    {:sum,
     %Sum{
       data_points:
         Enum.map(values, fn {{from, to}, tags, value} ->
           %NumberDataPoint{
             attributes: build_kv(tags),
             start_time_unix_nano: from,
             time_unix_nano: to,
             value: convert_value(value, :int)
           }
         end),
       aggregation_temporality: :AGGREGATION_TEMPORALITY_CUMULATIVE,
       is_monotonic: false
     }}
  end

  defp convert_data(%Metrics.LastValue{}, values) do
    {:gauge,
     %Gauge{
       data_points:
         Enum.map(values, fn {{from, to}, tags, value} ->
           %NumberDataPoint{
             attributes: build_kv(tags),
             start_time_unix_nano: from,
             time_unix_nano: to,
             value: convert_value(value, :double)
           }
         end)
     }}
  end

  defp convert_data(%Metrics.Distribution{reporter_options: opts}, values) do
    bucket_bounds = Keyword.get(opts, :buckets, @default_buckets)
    total_bucket_bounds = length(bucket_bounds)

    {:histogram,
     %Histogram{
       data_points:
         Enum.map(values, fn {{from, to}, tags, bucket_values} ->
           {min_value, _} = Map.get(bucket_values, :min, {nil, nil})
           {max_value, _} = Map.get(bucket_values, :max, {nil, nil})
           bucket_values = Map.drop(bucket_values, [:min, :max])

           {total_count, total_sum} =
             Enum.reduce(bucket_values, {0, 0.0}, fn {_, {count, sum}},
                                                     {total_count, total_sum} ->
               {total_count + count, total_sum + sum}
             end)

           bucket_counts =
             Enum.map(0..total_bucket_bounds//1, &elem(Map.get(bucket_values, &1, {0, 0}), 0))

           %HistogramDataPoint{
             attributes: build_kv(tags),
             start_time_unix_nano: from,
             time_unix_nano: to,
             count: total_count,
             sum: total_sum,
             bucket_counts: bucket_counts,
             explicit_bounds: bucket_bounds,
             min: min_value && min_value / 1,
             max: max_value && max_value / 1
           }
         end),
       aggregation_temporality: :AGGREGATION_TEMPORALITY_CUMULATIVE
     }}
  end

  defp convert_unit(:unit), do: nil
  defp convert_unit(:second), do: "s"
  defp convert_unit(:millisecond), do: "ms"
  defp convert_unit(:microsecond), do: "us"
  defp convert_unit(:nanosecond), do: "ns"
  defp convert_unit(:byte), do: "By"
  defp convert_unit(:kilobyte), do: "kBy"
  defp convert_unit(:megabyte), do: "MBy"
  defp convert_unit(:gigabyte), do: "GBy"
  defp convert_unit(:terabyte), do: "TBy"
  defp convert_unit(x) when is_atom(x), do: Atom.to_string(x)

  # These clauses are here to preserve the current behaviour of the library and avoid
  # introducing unexpected errors. Ideally, we would filter these nil/:undefined values higher
  # up in the call stack and stop short of exporting metrics with nil values.
  #
  # `:telemetry` emits `:undefined` for uninitialised values, so we treat it the same as `nil`.
  defp convert_value(nil, :int), do: {:as_int, nil}
  defp convert_value(nil, :double), do: {:as_double, nil}
  defp convert_value(:undefined, :int), do: {:as_int, nil}
  defp convert_value(:undefined, :double), do: {:as_double, nil}

  @signed_int64_max 2 ** 63 - 1
  @signed_int64_min -2 ** 63
  defp convert_value(int, _preferred_type)
       when is_integer(int) and int >= @signed_int64_min and int <= @signed_int64_max,
       do: {:as_int, int}

  # The OpenTelemetry protocol has no supporrt for bigint, so the best we can do is convert to
  # double at the cost of losing some precision.
  defp convert_value(bigint_or_float, _preferred_type)
       when is_integer(bigint_or_float) or is_float(bigint_or_float),
       do: {:as_double, bigint_or_float / 1}
end
