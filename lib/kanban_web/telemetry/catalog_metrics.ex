defmodule KanbanWeb.Telemetry.CatalogMetrics do
  @moduledoc """
  Builds the application's `Telemetry.Metrics` definitions from
  `Kanban.Telemetry.Catalog`, so every catalogued event has a metric and a new
  event cannot be left without one.

  Each `{type, measurement}` pair in an entry's `:metrics` becomes one metric:

    * an event's metric is named after the event plus the measurement, such as
      `kanban.api.task_claimed.count`;
    * a span's metric is named after its `:stop` event plus the measurement,
      such as `kanban.export.stop.duration`.

  A `:summary` of `:duration` is reported in milliseconds. The entry's `:tags`
  become the metric's tags, and its description the metric's description.

  Only an entry's first metric can be stored: it carries
  `reporter_options: [persist: entry.persist]` and every later one
  `persist: false`. `KanbanWeb.Telemetry.MetricsStorage` attaches one handler
  per event, so before this module existed only the first metric of an event
  was ever stored, and this keeps that.
  """

  alias Kanban.Telemetry.Catalog

  @doc """
  Returns the metrics for the given catalog entries, by default the whole
  catalog, in catalog order.
  """
  @spec metrics([Catalog.entry()]) :: [Telemetry.Metrics.t()]
  def metrics(entries \\ Catalog.events()) do
    Enum.flat_map(entries, &entry_metrics/1)
  end

  defp entry_metrics(entry) do
    entry.metrics
    |> Enum.with_index()
    |> Enum.map(fn {{type, measurement}, index} ->
      build(type, metric_name(entry, measurement), options(entry, type, measurement, index))
    end)
  end

  defp metric_name(%{kind: :span, name: prefix}, measurement), do: prefix ++ [:stop, measurement]
  defp metric_name(%{name: name}, measurement), do: name ++ [measurement]

  defp build(:counter, name, options), do: Telemetry.Metrics.counter(name, options)
  defp build(:sum, name, options), do: Telemetry.Metrics.sum(name, options)
  defp build(:summary, name, options), do: Telemetry.Metrics.summary(name, options)

  defp options(entry, type, measurement, index) do
    [
      description: entry.description,
      tags: Map.get(entry, :tags, []),
      reporter_options: [persist: entry.persist and index == 0]
    ]
    |> put_unit(type, measurement)
  end

  defp put_unit(options, :summary, :duration),
    do: Keyword.put(options, :unit, {:native, :millisecond})

  defp put_unit(options, _type, _measurement), do: options
end
