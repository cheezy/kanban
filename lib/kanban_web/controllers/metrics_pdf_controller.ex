defmodule KanbanWeb.MetricsPdfController do
  use KanbanWeb, :controller

  import Ecto.Query

  alias Kanban.Boards
  alias Kanban.Metrics
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias KanbanWeb.MetricsLive.Helpers

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
    grouped_tasks = group_tasks_by_date(tasks)
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
    assigns
    |> KanbanWeb.MetricsPdfHTML.throughput()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp render_metric_html("cycle-time", assigns) do
    assigns
    |> KanbanWeb.MetricsPdfHTML.cycle_time()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp render_metric_html("lead-time", assigns) do
    assigns
    |> KanbanWeb.MetricsPdfHTML.lead_time()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp render_metric_html("wait-time", assigns) do
    assigns
    |> KanbanWeb.MetricsPdfHTML.wait_time()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
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

  defp get_throughput_tasks(board_id, opts) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    agent_name = Keyword.get(opts, :agent_name)
    start_date = Helpers.get_start_date(time_range)

    query =
      Task
      |> join(:inner, [t], c in assoc(t, :column))
      |> where([t, c], c.board_id == ^board_id)
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

    query =
      if agent_name do
        where(query, [t], t.completed_by_agent == ^agent_name)
      else
        query
      end

    Repo.all(query)
  end

  defp get_completed_goals(board_id, opts) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    agent_name = Keyword.get(opts, :agent_name)
    start_date = Helpers.get_start_date(time_range)

    query =
      Task
      |> join(:inner, [t], c in assoc(t, :column))
      |> where([t, c], c.board_id == ^board_id)
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

    query =
      if agent_name do
        where(query, [t], t.completed_by_agent == ^agent_name)
      else
        query
      end

    Repo.all(query)
  end

  defp get_cycle_time_tasks(board_id, opts) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    agent_name = Keyword.get(opts, :agent_name)
    start_date = Helpers.get_start_date(time_range)

    query =
      Task
      |> join(:inner, [t], c in assoc(t, :column))
      |> where([t, c], c.board_id == ^board_id)
      |> where([t], not is_nil(t.completed_at))
      |> where([t], not is_nil(t.claimed_at))
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
        cycle_time_seconds:
          fragment(
            "EXTRACT(EPOCH FROM (? - ?))",
            t.completed_at,
            t.claimed_at
          )
      })

    query =
      if agent_name do
        where(query, [t], t.completed_by_agent == ^agent_name)
      else
        query
      end

    Repo.all(query)
  end

  defp group_tasks_by_date(tasks) do
    tasks
    |> Enum.group_by(fn task ->
      task.completed_at
      |> DateTime.to_date()
    end)
    |> Enum.sort_by(fn {date, _tasks} -> date end, {:desc, Date})
    |> Enum.map(fn {date, day_tasks} ->
      {date, Enum.sort_by(day_tasks, & &1.completed_at, {:desc, DateTime})}
    end)
  end
end
