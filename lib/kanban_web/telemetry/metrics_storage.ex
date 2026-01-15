defmodule KanbanWeb.Telemetry.MetricsStorage do
  @moduledoc """
  Stores telemetry metrics history in PostgreSQL for unlimited persistence.
  """
  use GenServer
  import Ecto.Query
  alias Kanban.Repo

  def start_link(metrics) do
    GenServer.start_link(__MODULE__, metrics, name: __MODULE__)
  end

  @doc """
  Retrieves metrics history for a specific metric for LiveDashboard.
  Returns a list of maps with :label, :measurement, and :time keys.
  """
  def metrics_history(metric) do
    metric_name = format_label(metric.name)

    query =
      from m in "metrics_events",
        where: m.metric_name == ^metric_name,
        order_by: [asc: m.recorded_at],
        select: %{
          label: m.metric_name,
          measurement: m.measurement,
          time: m.recorded_at
        }

    Repo.all(query)
    |> Enum.map(fn entry ->
      # Convert the timestamp to Unix time (handle both DateTime and NaiveDateTime)
      unix_time =
        case entry.time do
          %DateTime{} = dt ->
            DateTime.to_unix(dt)

          %NaiveDateTime{} = ndt ->
            ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

          _ ->
            System.system_time(:second)
        end

      %{
        label: entry.label,
        measurement: entry.measurement,
        time: unix_time
      }
    end)
  end

  @impl true
  def init(metrics) do
    for metric <- metrics do
      event_name = metric.event_name

      :telemetry.attach(
        {__MODULE__, event_name, self()},
        event_name,
        &__MODULE__.handle_event/4,
        %{metric: metric}
      )
    end

    {:ok, %{metrics: metrics}}
  end

  @impl true
  def handle_info({:telemetry_event, metric_name, measurement_value, metadata}, state) do
    metric_name_str = format_label(metric_name)

    # Sanitize metadata to only include JSON-serializable values
    safe_metadata = sanitize_metadata(metadata)

    Repo.insert_all(
      "metrics_events",
      [
        %{
          metric_name: metric_name_str,
          measurement: measurement_value,
          metadata: safe_metadata,
          recorded_at: DateTime.utc_now(),
          inserted_at: DateTime.utc_now()
        }
      ]
    )

    {:noreply, state}
  end

  def handle_event(_event_name, measurements, metadata, %{metric: metric}) do
    # Skip database queries on metrics_events table to prevent recursive metrics collection
    # Also skip VM metrics as they're high-frequency and low business value
    if metrics_table_query?(metadata) or vm_metric?(metric.name) do
      :ok
    else
      measurement_value = extract_measurement(measurements, metric.measurement)

      if measurement_value do
        metric_name = metric.name
        send(__MODULE__, {:telemetry_event, metric_name, measurement_value, metadata})
      end
    end
  end

  defp vm_metric?(metric_name) when is_list(metric_name) do
    case metric_name do
      [:vm | _] -> true
      _ -> false
    end
  end

  defp vm_metric?(_), do: false

  defp metrics_table_query?(metadata) do
    # Check if this is a query against the metrics_events table
    case metadata do
      %{source: "metrics_events"} -> true
      %{query: query} when is_binary(query) -> String.contains?(query, "metrics_events")
      _ -> false
    end
  end

  defp extract_measurement(measurements, measurement) when is_function(measurement) do
    measurement.(measurements)
  rescue
    _ -> nil
  end

  defp extract_measurement(measurements, measurement) when is_atom(measurement) do
    Map.get(measurements, measurement)
  end

  defp extract_measurement(_measurements, _measurement), do: nil

  defp format_label(metric_name) when is_list(metric_name) do
    Enum.map_join(metric_name, ".", &to_string/1)
  end

  defp format_label(metric_name), do: to_string(metric_name)

  defp sanitize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.map(fn {key, value} -> {to_string(key), sanitize_value(value)} end)
    |> Enum.into(%{})
  end

  defp sanitize_metadata(_metadata), do: %{}

  defp sanitize_value(value) when is_binary(value) do
    # Check if binary is valid UTF-8, otherwise base64 encode it
    if String.valid?(value) do
      value
    else
      Base.encode64(value)
    end
  end

  defp sanitize_value(value) when is_number(value), do: value
  defp sanitize_value(value) when is_boolean(value), do: value
  defp sanitize_value(value) when is_atom(value), do: to_string(value)

  # Handle DateTime and NaiveDateTime structs
  defp sanitize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp sanitize_value(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)

  defp sanitize_value(value) when is_list(value), do: Enum.map(value, &sanitize_value/1)

  # Handle maps (but not structs)
  defp sanitize_value(value) when is_map(value) do
    # Check if it's a struct (all structs have a __struct__ key)
    if Map.has_key?(value, :__struct__) do
      # For unknown structs, convert to string
      inspect(value)
    else
      # For regular maps, recursively sanitize
      Enum.map(value, fn {k, v} -> {to_string(k), sanitize_value(v)} end)
      |> Enum.into(%{})
    end
  end

  defp sanitize_value(_value), do: nil

  if Mix.env() == :test do
    def __format_label__(metric_name), do: format_label(metric_name)
    def __extract_measurement__(measurements, measurement), do: extract_measurement(measurements, measurement)
    def __sanitize_value__(value), do: sanitize_value(value)
    def __sanitize_metadata__(metadata), do: sanitize_metadata(metadata)
    def __metrics_table_query__?(metadata), do: metrics_table_query?(metadata)
    def __vm_metric__?(metric_name), do: vm_metric?(metric_name)
  end
end
