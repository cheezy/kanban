defmodule KanbanWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  alias KanbanWeb.Telemetry.CatalogMetrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    # Logs token routes' request lines with the token redacted.
    :ok = KanbanWeb.RequestLog.attach()

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

  @doc """
  Returns every metric LiveDashboard shows and `MetricsStorage` may store.

  The application metrics are generated from `Kanban.Telemetry.Catalog` by
  `KanbanWeb.Telemetry.CatalogMetrics`. Phoenix, LiveView, Ecto, Oban, Swoosh
  and VM metrics are defined here. LiveView, Oban and Swoosh metrics carry
  `reporter_options: [persist: false]`: they fire on every page load, click,
  job or email, so they are shown live and never stored.
  """
  def metrics do
    phoenix_metrics() ++
      live_view_metrics() ++
      CatalogMetrics.metrics() ++
      database_metrics() ++
      oban_metrics() ++
      swoosh_metrics() ++
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

  # Tagged by LiveView module only. The handle_event `event` name comes from
  # the client, so it is not a safe, bounded label.
  defp live_view_metrics do
    [
      summary("phoenix.live_view.mount.stop.duration",
        tags: [:view],
        tag_values: &__MODULE__.live_view_tags/1,
        unit: {:native, :millisecond},
        reporter_options: [persist: false],
        description: "LiveView mount time by view"
      ),
      summary("phoenix.live_view.handle_event.stop.duration",
        tags: [:view],
        tag_values: &__MODULE__.live_view_tags/1,
        unit: {:native, :millisecond},
        reporter_options: [persist: false],
        description: "LiveView handle_event time by view"
      )
    ]
  end

  @doc false
  # Called by reporters inside telemetry handlers, so it must never raise.
  def live_view_tags(%{socket: %{view: view}}) when is_atom(view), do: %{view: inspect(view)}
  def live_view_tags(_metadata), do: %{}

  # Oban puts the worker and queue names, both strings, at the top level of
  # the job metadata. The job id, args and attempt are never tags.
  defp oban_metrics do
    [
      summary("oban.job.stop.duration",
        tags: [:worker, :queue],
        unit: {:native, :millisecond},
        reporter_options: [persist: false],
        description: "Background job run time by worker and queue"
      ),
      summary("oban.job.exception.duration",
        tags: [:worker, :queue],
        unit: {:native, :millisecond},
        reporter_options: [persist: false],
        description: "Run time of background jobs that raised, by worker and queue"
      )
    ]
  end

  # Swoosh metadata carries the email and the mailer config, so only the
  # mailer module is a tag. An {:error, _} delivery still ends in :stop;
  # :exception is a raise.
  defp swoosh_metrics do
    [
      summary("swoosh.deliver.stop.duration",
        tags: [:mailer],
        unit: {:native, :millisecond},
        reporter_options: [persist: false],
        description: "Email delivery time by mailer"
      ),
      summary("swoosh.deliver.exception.duration",
        tags: [:mailer],
        unit: {:native, :millisecond},
        reporter_options: [persist: false],
        description: "Time of email deliveries that raised, by mailer"
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
        description:
          "The time the connection spent waiting before being checked out for the query"
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
      # This function must emit through Kanban.Telemetry.emit/3, and its event must be
      # declared in Kanban.Telemetry.Catalog, which generates its metric.
      # {KanbanWeb, :count_users, []}
    ]
  end
end
