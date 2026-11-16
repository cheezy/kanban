defmodule KanbanWeb.MetricsPdfController do
  use KanbanWeb, :controller

  alias Kanban.Boards
  alias Kanban.Metrics
  alias Kanban.Metrics.TaskQueries
  alias KanbanWeb.MetricsExcelExport
  alias KanbanWeb.MetricsLive.Helpers
  alias KanbanWeb.Timezone

  require Logger

  @metric_templates %{
    "throughput" => :throughput,
    "cycle-time" => :cycle_time,
    "lead-time" => :lead_time,
    "wait-time" => :wait_time
  }

  @valid_metrics Map.keys(@metric_templates)

  # Reject an unknown metric up front so an unvalidated value never reaches
  # generate_filename/4 (where it is interpolated into the content-disposition
  # header) or the metric template lookups (W1432). @valid_metrics is the same
  # allow-list get_redirect_path/3 and render_metric_html/2 already use.
  def export(conn, %{"metric" => metric}) when metric not in @valid_metrics do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Unknown metric"})
  end

  def export(conn, %{"id" => board_id, "metric" => metric} = params) do
    user = conn.assigns.current_scope.user

    case Boards.get_board(board_id, user) do
      {:ok, board} ->
        export_board(conn, board, metric, params)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Board not found"})
    end
  end

  # Timed as the [:kanban, :export] span. Only the export kind and file format
  # are reported: never the board, its name or the metric filters.
  defp export_board(conn, board, metric, params) do
    format = export_format(params)

    Kanban.Telemetry.span([:kanban, :export], %{kind: :metrics_pdf, format: format}, fn ->
      conn = dispatch_export_format(conn, board, metric, format, params)
      {conn, %{kind: :metrics_pdf, format: format}}
    end)
  end

  defp export_format(%{"format" => "excel"}), do: :xlsx
  defp export_format(_params), do: :pdf

  defp dispatch_export_format(conn, board, metric, :xlsx, params) do
    generate_and_send_excel(conn, board, metric, params)
  end

  defp dispatch_export_format(conn, board, metric, :pdf, params) do
    generate_and_send_pdf(conn, board, metric, params)
  end

  defp generate_and_send_pdf(conn, board, metric, params) do
    opts = build_metric_options(conn, params)
    html_content = pdf_html(board, metric, opts)

    case ChromicPDF.print_to_pdf({:html, html_content}, print_to_pdf: %{printBackground: true}) do
      {:ok, pdf_base64} ->
        pdf_binary = Base.decode64!(pdf_base64)
        send_pdf_response(conn, board, metric, opts, pdf_binary)

      {:error, reason} ->
        handle_pdf_error(conn, board.id, metric, reason)
    end
  end

  # The HTML the PDF is printed from, for `opts` as build_metric_options/2
  # returns them. Exposed for testing, so a test can assert on the rendered
  # dates without driving the headless renderer.
  @doc false
  def pdf_html(board, metric, opts) do
    {:ok, agents} = Metrics.get_agents(board.id)
    data = load_metric_data(metric, board.id, opts)

    assigns = build_assigns(board, metric, opts, agents, data)
    render_metric_html(metric, assigns)
  end

  defp generate_and_send_excel(conn, board, metric, params) do
    opts = build_metric_options(conn, params)
    data = load_metric_data(metric, board.id, opts)

    case MetricsExcelExport.generate(board, metric, opts, data) do
      {:ok, excel_binary} ->
        filename = generate_filename(board, metric, opts, ".xlsx")

        conn
        |> put_resp_content_type(
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        )
        |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
        |> send_resp(200, excel_binary)

      {:error, reason} ->
        handle_pdf_error(conn, board.id, metric, reason)
    end
  end

  # The zone is the session's (refreshed from the stride_tz cookie by
  # KanbanWeb.Plugs.Timezone), then a `timezone` param, then UTC — validated
  # either way, so only a known zone reaches the queries and formatters.
  defp build_metric_options(conn, params) do
    time_range = Helpers.parse_time_range(params["time_range"])
    agent_name = Helpers.parse_agent_name(params["agent_name"])
    exclude_weekends = Helpers.parse_exclude_weekends(params["exclude_weekends"])
    timezone = conn |> get_session(:timezone) |> Timezone.request_timezone(params)

    opts = [
      time_range: time_range,
      exclude_weekends: exclude_weekends,
      timezone: timezone
    ]

    if agent_name do
      Keyword.put(opts, :agent_name, agent_name)
    else
      opts
    end
  end

  defp build_assigns(board, metric, opts, agents, data) do
    %{
      board: board,
      metric: metric,
      time_range: opts[:time_range],
      agent_name: opts[:agent_name],
      exclude_weekends: opts[:exclude_weekends],
      agents: agents,
      data: data,
      timezone: opts[:timezone],
      generated_at: DateTime.utc_now()
    }
  end

  defp send_pdf_response(conn, board, metric, opts, pdf_binary) do
    filename = generate_filename(board, metric, opts)

    conn
    |> put_resp_content_type("application/pdf")
    |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
    |> send_resp(200, pdf_binary)
  end

  # Log the raw reason for operators (ChromicPDF port output, internal
  # tuples, paths, etc.) but show the user a generic localized message —
  # never interpolate inspect/1 into a response body or flash. Exposed
  # for testing.
  @doc false
  def handle_pdf_error(conn, board_id, metric, reason) do
    Logger.error(
      "PDF/export generation failed (board_id=#{board_id}, metric=#{inspect(metric)}, reason=#{inspect(reason)})"
    )

    conn
    |> put_flash(:error, pdf_error_flash_message())
    |> redirect(to: get_redirect_path(conn, board_id, metric))
  end

  @doc false
  def pdf_error_flash_message do
    gettext("Failed to generate the export. Please try again or contact support.")
  end

  defp load_metric_data("throughput", board_id, opts) do
    {:ok, throughput} = Metrics.get_throughput(board_id, opts)
    stats = calculate_throughput_stats(throughput)
    tasks = TaskQueries.get_throughput_tasks(board_id, opts)
    grouped_tasks = group_tasks_by_field(tasks, :completed_at, opts[:timezone])
    goals = TaskQueries.get_completed_goals(board_id, opts)

    %{
      throughput: throughput,
      summary_stats: stats,
      tasks: tasks,
      grouped_tasks: grouped_tasks,
      completed_goals: goals
    }
  end

  defp load_metric_data("cycle-time", board_id, opts) do
    {:ok, stats} = Metrics.get_cycle_time_stats(board_id, opts)
    tasks = TaskQueries.get_cycle_time_tasks(board_id, opts)
    grouped_tasks = Helpers.group_tasks_by_completion_date(tasks, opts[:timezone])

    daily_cycle_times =
      Helpers.calculate_daily_times(tasks, :cycle_time_seconds, opts[:timezone])

    %{
      summary_stats: stats,
      tasks: tasks,
      grouped_tasks: grouped_tasks,
      daily_cycle_times: daily_cycle_times
    }
  end

  defp load_metric_data("lead-time", board_id, opts) do
    {:ok, stats} = Metrics.get_lead_time_stats(board_id, opts)
    tasks = TaskQueries.get_lead_time_tasks(board_id, opts)
    grouped_tasks = Helpers.group_tasks_by_completion_date(tasks, opts[:timezone])
    daily_lead_times = Helpers.calculate_daily_times(tasks, :lead_time_seconds, opts[:timezone])

    %{
      summary_stats: stats,
      tasks: tasks,
      grouped_tasks: grouped_tasks,
      daily_lead_times: daily_lead_times
    }
  end

  defp load_metric_data("wait-time", board_id, opts) do
    {:ok, stats} = Metrics.get_wait_time_stats(board_id, opts)
    review_tasks = TaskQueries.get_review_wait_tasks(board_id, opts)
    backlog_tasks = TaskQueries.get_backlog_wait_tasks(board_id, opts)
    grouped_review_tasks = group_tasks_by_field(review_tasks, :reviewed_at, opts[:timezone])
    grouped_backlog_tasks = group_tasks_by_field(backlog_tasks, :claimed_at, opts[:timezone])

    %{
      review_wait_stats: stats.review_wait,
      backlog_wait_stats: stats.backlog_wait,
      grouped_review_tasks: grouped_review_tasks,
      grouped_backlog_tasks: grouped_backlog_tasks
    }
  end

  defp load_metric_data(_metric, _board_id, _opts), do: %{}

  defp render_metric_html(metric, assigns) do
    case Map.get(@metric_templates, metric) do
      nil ->
        "<html><body><h1>Unknown metric</h1></body></html>"

      template_fn ->
        apply(KanbanWeb.MetricsPdfHTML, template_fn, [assigns])
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()
    end
  end

  # Named by the requester's local day, as the workspace export already is.
  defp generate_filename(board, metric, opts, extension \\ ".pdf") do
    board_name = String.replace(board.name, ~r/[^a-zA-Z0-9_-]/, "_")
    date_str = opts[:timezone] |> Kanban.Timezone.local_today() |> Date.to_string()
    metric_name = String.replace(metric, "-", "_")
    time_range_str = Atom.to_string(opts[:time_range])

    "#{board_name}_#{metric_name}_#{time_range_str}_#{date_str}#{extension}"
  end

  defp get_redirect_path(conn, board_id, metric) when metric in @valid_metrics do
    time_range = Map.get(conn.params, "time_range", "last_30_days")
    agent_name = Map.get(conn.params, "agent_name", "")
    exclude_weekends = Map.get(conn.params, "exclude_weekends", "false")

    "/boards/#{board_id}/metrics/#{metric}?" <>
      URI.encode_query(%{
        "time_range" => time_range,
        "agent_name" => agent_name,
        "exclude_weekends" => exclude_weekends
      })
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

  # Day headings are the requester's local days, matching the local
  # timestamps printed under them.
  defp group_tasks_by_field(tasks, field, timezone) do
    tasks
    |> Enum.group_by(fn task -> task |> Map.get(field) |> to_date(timezone) end)
    |> Enum.sort_by(fn {date, _tasks} -> date end, {:desc, Date})
    |> Enum.map(fn {date, day_tasks} ->
      {date, Enum.sort_by(day_tasks, &Map.get(&1, field), :desc)}
    end)
  end

  defp to_date(%DateTime{} = dt, timezone), do: Kanban.Timezone.local_date(dt, timezone)

  defp to_date(%NaiveDateTime{} = ndt, timezone),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> Kanban.Timezone.local_date(timezone)
end
