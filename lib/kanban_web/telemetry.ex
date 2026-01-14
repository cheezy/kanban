defmodule KanbanWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children =
      [
        # Telemetry poller will execute the given period measurements
        # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
        {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      ] ++ metrics_storage_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Only start MetricsStorage in non-test environments to avoid database sandbox issues
  defp metrics_storage_children do
    if Application.get_env(:kanban, :env) == :test do
      []
    else
      [{KanbanWeb.Telemetry.MetricsStorage, metrics()}]
    end
  end

  def metrics do
    phoenix_metrics() ++
      application_metrics() ++
      database_metrics() ++
      vm_metrics()
  end

  defp phoenix_metrics do
    [
      summary("phoenix.endpoint.start.system_time", unit: {:native, :millisecond}),
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration", unit: {:native, :millisecond}),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration", unit: {:native, :millisecond}),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      )
    ]
  end

  defp application_metrics do
    user_metrics() ++ board_metrics() ++ task_metrics() ++ api_metrics()
  end

  defp user_metrics do
    [
      sum("kanban.user.registration.count",
        description: "Total number of user registrations"
      ),
      counter("kanban.user.login.count", description: "Total number of user logins")
    ]
  end

  defp board_metrics do
    [
      sum("kanban.board.creation.count", description: "Total number of boards created")
    ]
  end

  defp task_metrics do
    [
      sum("kanban.api.task_created.count",
        description: "Total number of tasks created via API"
      ),
      sum("kanban.api.task_completed.count",
        description: "Total number of tasks completed via API"
      ),
      counter("kanban.api.task_claimed.count",
        description: "Total number of tasks claimed by agents"
      ),
      counter("kanban.api.task_unclaimed.count",
        description: "Total number of tasks unclaimed by agents"
      ),
      counter("kanban.api.task_marked_done.count",
        description: "Total number of tasks marked as done after review"
      ),
      counter("kanban.api.task_returned_to_doing.count",
        description: "Total number of tasks returned to doing from review"
      ),
      counter("kanban.api.next_task_fetched.count",
        description: "Total number of next task requests"
      )
    ]
  end

  defp api_metrics do
    [
      counter("kanban.api.request.count",
        tags: [:endpoint, :method],
        description: "Total number of API requests by endpoint and method"
      ),
      summary("kanban.api.request.duration",
        tags: [:endpoint, :method],
        unit: {:native, :millisecond},
        description: "API request duration by endpoint and method"
      ),
      counter("kanban.api.error.count",
        tags: [:endpoint, :status],
        description: "API errors by endpoint and status code"
      )
    ]
  end

  defp database_metrics do
    [
      summary("kanban.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("kanban.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("kanban.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("kanban.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("kanban.repo.query.idle_time",
        unit: {:native, :millisecond},
        description: "The time the connection spent waiting before being checked out for the query"
      )
    ]
  end

  defp vm_metrics do
    [
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {KanbanWeb, :count_users, []}
    ]
  end
end
