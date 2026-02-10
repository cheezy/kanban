defmodule KanbanWeb.MetricsPdfController do
  use KanbanWeb, :controller

  import Ecto.Query

  alias Kanban.Boards
  alias Kanban.Metrics
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias KanbanWeb.MetricsLive.Helpers

  @metric_templates %{
    "throughput" => :throughput,
    "cycle-time" => :cycle_time,
    "lead-time" => :lead_time,
    "wait-time" => :wait_time
  }

  @valid_metrics Map.keys(@metric_templates)

  def export(conn, %{"id" => board_id, "metric" => metric} = params) do
    user = conn.assigns.current_scope.user
    board = Boards.get_board!(board_id, user)

    if board.ai_optimized_board do
      generate_and_send_pdf(conn, board, metric, params)
    else
      conn
      |> put_flash(:error, "Metrics are only available for AI-optimized boards.")
      |> redirect(to: ~p"/boards/#{board}")
    end
  end

  defp generate_and_send_pdf(conn, board, metric, params) do
    opts = build_metric_options(params)
    {:ok, agents} = Metrics.get_agents(board.id)
    data = load_metric_data(metric, board.id, opts)

    assigns = build_assigns(board, metric, opts, agents, data)
    html_content = render_metric_html(metric, assigns)

    case ChromicPDF.print_to_pdf({:html, html_content}, print_to_pdf: %{printBackground: true}) do
      {:ok, pdf_base64} ->
        pdf_binary = Base.decode64!(pdf_base64)
        send_pdf_response(conn, board, metric, opts[:time_range], pdf_binary)

      {:error, reason} ->
        handle_pdf_error(conn, board.id, metric, reason)
    end
  end

  defp build_metric_options(params) do
    time_range = Helpers.parse_time_range(params["time_range"])
    agent_name = Helpers.parse_agent_name(params["agent_name"])
    exclude_weekends = Helpers.parse_exclude_weekends(params["exclude_weekends"])

    opts = [
      time_range: time_range,
      exclude_weekends: exclude_weekends
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
      generated_at: DateTime.utc_now()
    }
  end

  defp send_pdf_response(conn, board, metric, time_range, pdf_binary) do
    filename = generate_filename(board, metric, time_range)

    conn
    |> put_resp_content_type("application/pdf")
    |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
    |> send_resp(200, pdf_binary)
  end

  defp handle_pdf_error(conn, board_id, metric, reason) do
    conn
    |> put_flash(:error, "Failed to generate PDF: #{inspect(reason)}")
    |> redirect(to: get_redirect_path(conn, board_id, metric))
  end

  defp load_metric_data("throughput", board_id, opts) do
    {:ok, throughput} = Metrics.get_throughput(board_id, opts)
    stats = calculate_throughput_stats(throughput)
    tasks = get_throughput_tasks(board_id, opts)
    grouped_tasks = group_tasks_by_field(tasks, :completed_at)
    goals = get_completed_goals(board_id, opts)

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
    tasks = get_cycle_time_tasks(board_id, opts)
    grouped_tasks = Helpers.group_tasks_by_completion_date(tasks)
    daily_cycle_times = Helpers.calculate_daily_times(tasks, :cycle_time_seconds)

    %{
      summary_stats: stats,
      tasks: tasks,
      grouped_tasks: grouped_tasks,
      daily_cycle_times: daily_cycle_times
    }
  end

  defp load_metric_data("lead-time", board_id, opts) do
    {:ok, stats} = Metrics.get_lead_time_stats(board_id, opts)
    tasks = get_lead_time_tasks(board_id, opts)
    grouped_tasks = Helpers.group_tasks_by_completion_date(tasks)
    daily_lead_times = Helpers.calculate_daily_times(tasks, :lead_time_seconds)

    %{
      summary_stats: stats,
      tasks: tasks,
      grouped_tasks: grouped_tasks,
      daily_lead_times: daily_lead_times
    }
  end

  defp load_metric_data("wait-time", board_id, opts) do
    {:ok, stats} = Metrics.get_wait_time_stats(board_id, opts)
    review_tasks = get_review_wait_tasks(board_id, opts)
    backlog_tasks = get_backlog_wait_tasks(board_id, opts)
    grouped_review_tasks = group_tasks_by_field(review_tasks, :reviewed_at)
    grouped_backlog_tasks = group_tasks_by_field(backlog_tasks, :claimed_at)

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

  defp generate_filename(board, metric, time_range) do
    board_name = String.replace(board.name, ~r/[^a-zA-Z0-9_-]/, "_")
    date_str = Date.to_string(Date.utc_today())
    metric_name = String.replace(metric, "-", "_")
    time_range_str = Atom.to_string(time_range)

    "#{board_name}_#{metric_name}_#{time_range_str}_#{date_str}.pdf"
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

  defp base_task_query(board_id, opts) do
    start_date =
      opts
      |> Keyword.get(:time_range, :last_30_days)
      |> Helpers.get_start_date()

    agent_name = Keyword.get(opts, :agent_name)

    query =
      Task
      |> join(:inner, [t], c in assoc(t, :column))
      |> where([t, c], c.board_id == ^board_id)

    query =
      if agent_name do
        where(query, [t], t.completed_by_agent == ^agent_name)
      else
        query
      end

    {query, start_date}
  end

  defp get_throughput_tasks(board_id, opts) do
    {query, start_date} = base_task_query(board_id, opts)

    query
    |> where([t], not is_nil(t.completed_at))
    |> where([t], t.completed_at >= ^start_date)
    |> where([t], t.type != ^:goal)
    |> order_by([t], desc: t.completed_at)
    |> select([t], %{
      id: t.id,
      identifier: t.identifier,
      title: t.title,
      inserted_at: t.inserted_at,
      claimed_at: t.claimed_at,
      completed_at: t.completed_at,
      completed_by_agent: t.completed_by_agent
    })
    |> Repo.all()
  end

  defp get_completed_goals(board_id, opts) do
    {query, start_date} = base_task_query(board_id, opts)

    query
    |> where([t], t.type == ^:goal)
    |> where([t], not is_nil(t.completed_at))
    |> where([t], t.completed_at >= ^start_date)
    |> order_by([t], desc: t.completed_at)
    |> select([t], %{
      id: t.id,
      identifier: t.identifier,
      title: t.title,
      inserted_at: t.inserted_at,
      completed_at: t.completed_at,
      completed_by_agent: t.completed_by_agent
    })
    |> Repo.all()
  end

  defp get_cycle_time_tasks(board_id, opts) do
    {query, start_date} = base_task_query(board_id, opts)

    query
    |> where([t], not is_nil(t.completed_at) and not is_nil(t.claimed_at))
    |> where([t], t.completed_at >= ^start_date)
    |> where([t], t.type != ^:goal)
    |> order_by([t], desc: t.completed_at)
    |> select([t], %{
      id: t.id,
      identifier: t.identifier,
      title: t.title,
      claimed_at: t.claimed_at,
      completed_at: t.completed_at,
      completed_by_agent: t.completed_by_agent,
      cycle_time_seconds: fragment("EXTRACT(EPOCH FROM (? - ?))", t.completed_at, t.claimed_at)
    })
    |> Repo.all()
  end

  defp get_lead_time_tasks(board_id, opts) do
    {query, start_date} = base_task_query(board_id, opts)

    query
    |> where([t], not is_nil(t.completed_at))
    |> where([t], t.completed_at >= ^start_date)
    |> where([t], t.type != ^:goal)
    |> order_by([t], desc: t.completed_at)
    |> select([t], %{
      id: t.id,
      identifier: t.identifier,
      title: t.title,
      inserted_at: t.inserted_at,
      completed_at: t.completed_at,
      completed_by_agent: t.completed_by_agent,
      lead_time_seconds: fragment("EXTRACT(EPOCH FROM (? - ?))", t.completed_at, t.inserted_at)
    })
    |> Repo.all()
  end

  defp get_review_wait_tasks(board_id, opts) do
    {query, start_date} = base_task_query(board_id, opts)

    query
    |> where([t], not is_nil(t.completed_at) and not is_nil(t.reviewed_at))
    |> where([t], t.reviewed_at >= ^start_date)
    |> order_by([t], desc: t.reviewed_at)
    |> select([t], %{
      id: t.id,
      identifier: t.identifier,
      title: t.title,
      completed_at: t.completed_at,
      reviewed_at: t.reviewed_at,
      completed_by_agent: t.completed_by_agent,
      review_wait_seconds: fragment("EXTRACT(EPOCH FROM (? - ?))", t.reviewed_at, t.completed_at)
    })
    |> Repo.all()
  end

  defp get_backlog_wait_tasks(board_id, opts) do
    {query, start_date} = base_task_query(board_id, opts)

    query
    |> where([t], not is_nil(t.claimed_at))
    |> where([t], t.claimed_at >= ^start_date)
    |> order_by([t], desc: t.claimed_at)
    |> select([t], %{
      id: t.id,
      identifier: t.identifier,
      title: t.title,
      inserted_at: t.inserted_at,
      claimed_at: t.claimed_at,
      completed_by_agent: t.completed_by_agent,
      backlog_wait_seconds: fragment("EXTRACT(EPOCH FROM (? - ?))", t.claimed_at, t.inserted_at)
    })
    |> Repo.all()
  end

  defp group_tasks_by_field(tasks, field) do
    tasks
    |> Enum.group_by(fn task -> Map.get(task, field) |> DateTime.to_date() end)
    |> Enum.sort_by(fn {date, _tasks} -> date end, {:desc, Date})
    |> Enum.map(fn {date, day_tasks} ->
      {date, Enum.sort_by(day_tasks, &Map.get(&1, field), {:desc, DateTime})}
    end)
  end
end
