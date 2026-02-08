defmodule KanbanWeb.MetricsPdfController do
  use KanbanWeb, :controller

  alias Kanban.Boards
  alias Kanban.Metrics
  alias KanbanWeb.MetricsLive.Helpers

  def export(conn, %{"id" => board_id, "metric" => metric} = params) do
    user = conn.assigns.current_scope.user
    board = Boards.get_board!(board_id, user)

    unless board.ai_optimized_board do
      conn
      |> put_flash(:error, "Metrics are only available for AI-optimized boards.")
      |> redirect(to: ~p"/boards/#{board}")
    else
      time_range = Helpers.parse_time_range(params["time_range"])
      agent_name = Helpers.parse_agent_name(params["agent_name"])
      exclude_weekends = Helpers.parse_exclude_weekends(params["exclude_weekends"])

      opts = [
        time_range: time_range,
        exclude_weekends: exclude_weekends
      ]

      opts =
        if agent_name do
          Keyword.put(opts, :agent_name, agent_name)
        else
          opts
        end

      {:ok, agents} = Metrics.get_agents(board.id)

      data = load_metric_data(metric, board.id, opts)

      assigns = %{
        board: board,
        metric: metric,
        time_range: time_range,
        agent_name: agent_name,
        exclude_weekends: exclude_weekends,
        agents: agents,
        data: data,
        generated_at: DateTime.utc_now()
      }

      html_content = render_metric_html(metric, assigns)

      case ChromicPDF.print_to_pdf({:html, html_content}) do
        {:ok, pdf_binary} ->
          filename = generate_filename(board, metric, time_range)

          conn
          |> put_resp_content_type("application/pdf")
          |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
          |> send_resp(200, pdf_binary)

        {:error, reason} ->
          conn
          |> put_flash(:error, "Failed to generate PDF: #{inspect(reason)}")
          |> redirect(to: get_redirect_path(conn, board_id, metric))
      end
    end
  end

  defp load_metric_data("throughput", board_id, opts) do
    {:ok, throughput} = Metrics.get_throughput(board_id, opts)
    stats = calculate_throughput_stats(throughput)

    %{
      throughput: throughput,
      summary_stats: stats
    }
  end

  defp load_metric_data("cycle-time", board_id, opts) do
    {:ok, stats} = Metrics.get_cycle_time_stats(board_id, opts)

    %{
      summary_stats: stats
    }
  end

  defp load_metric_data("lead-time", board_id, opts) do
    {:ok, stats} = Metrics.get_lead_time_stats(board_id, opts)

    %{
      summary_stats: stats
    }
  end

  defp load_metric_data("wait-time", board_id, opts) do
    {:ok, stats} = Metrics.get_wait_time_stats(board_id, opts)

    %{
      review_wait_stats: stats.review_wait,
      backlog_wait_stats: stats.backlog_wait
    }
  end

  defp load_metric_data(_metric, _board_id, _opts), do: %{}

  defp render_metric_html("throughput", assigns) do
    KanbanWeb.MetricsPdfHTML.throughput(assigns)
  end

  defp render_metric_html("cycle-time", assigns) do
    KanbanWeb.MetricsPdfHTML.cycle_time(assigns)
  end

  defp render_metric_html("lead-time", assigns) do
    KanbanWeb.MetricsPdfHTML.lead_time(assigns)
  end

  defp render_metric_html("wait-time", assigns) do
    KanbanWeb.MetricsPdfHTML.wait_time(assigns)
  end

  defp render_metric_html(_metric, _assigns),
    do: "<html><body><h1>Unknown metric</h1></body></html>"

  defp generate_filename(board, metric, time_range) do
    board_name = String.replace(board.name, ~r/[^a-zA-Z0-9_-]/, "_")
    date_str = Date.to_string(Date.utc_today())
    metric_name = String.replace(metric, "-", "_")
    time_range_str = Atom.to_string(time_range)

    "#{board_name}_#{metric_name}_#{time_range_str}_#{date_str}.pdf"
  end

  defp get_redirect_path(conn, board_id, "throughput") do
    time_range = Map.get(conn.params, "time_range", "last_30_days")
    agent_name = Map.get(conn.params, "agent_name", "")
    exclude_weekends = Map.get(conn.params, "exclude_weekends", "false")

    ~p"/boards/#{board_id}/metrics/throughput?time_range=#{time_range}&agent_name=#{agent_name}&exclude_weekends=#{exclude_weekends}"
  end

  defp get_redirect_path(conn, board_id, "cycle-time") do
    time_range = Map.get(conn.params, "time_range", "last_30_days")
    agent_name = Map.get(conn.params, "agent_name", "")
    exclude_weekends = Map.get(conn.params, "exclude_weekends", "false")

    ~p"/boards/#{board_id}/metrics/cycle-time?time_range=#{time_range}&agent_name=#{agent_name}&exclude_weekends=#{exclude_weekends}"
  end

  defp get_redirect_path(conn, board_id, "lead-time") do
    time_range = Map.get(conn.params, "time_range", "last_30_days")
    agent_name = Map.get(conn.params, "agent_name", "")
    exclude_weekends = Map.get(conn.params, "exclude_weekends", "false")

    ~p"/boards/#{board_id}/metrics/lead-time?time_range=#{time_range}&agent_name=#{agent_name}&exclude_weekends=#{exclude_weekends}"
  end

  defp get_redirect_path(conn, board_id, "wait-time") do
    time_range = Map.get(conn.params, "time_range", "last_30_days")
    agent_name = Map.get(conn.params, "agent_name", "")
    exclude_weekends = Map.get(conn.params, "exclude_weekends", "false")

    ~p"/boards/#{board_id}/metrics/wait-time?time_range=#{time_range}&agent_name=#{agent_name}&exclude_weekends=#{exclude_weekends}"
  end

  defp get_redirect_path(_conn, board_id, _metric) do
    ~p"/boards/#{board_id}/metrics"
  end

  defp calculate_throughput_stats([_ | _] = throughput) do
    total = Enum.reduce(throughput, 0, fn day, acc -> acc + day.count end)
    days_count = length(throughput)
    avg_per_day = if days_count > 0, do: total / days_count, else: 0.0

    peak = Enum.max_by(throughput, & &1.count, fn -> %{date: nil, count: 0} end)

    %{
      total: total,
      avg_per_day: Float.round(avg_per_day, 1),
      peak_day: peak.date,
      peak_count: peak.count
    }
  end

  defp calculate_throughput_stats(_),
    do: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0}
end
