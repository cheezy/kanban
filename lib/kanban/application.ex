defmodule Kanban.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      KanbanWeb.Telemetry,
      Kanban.Repo,
      {DNSCluster, query: Application.get_env(:kanban, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Kanban.PubSub},
      # Start a worker by calling: Kanban.Worker.start_link(arg)
      # {Kanban.Worker, arg},
      # ChromicPDF for server-side PDF generation
      {ChromicPDF, chromic_pdf_options()},
      # Start to serve requests, typically the last entry
      KanbanWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Kanban.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KanbanWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp chromic_pdf_options do
    base = [
      no_sandbox: true,
      discard_stderr: false,
      chrome_args: "--disable-dev-shm-usage --disable-gpu",
      session_pool: [timeout: 30_000, init_timeout: 30_000, checkout_timeout: 30_000]
    ]

    case System.find_executable("google-chrome-stable") do
      nil -> base
      path -> [{:chrome_executable, path} | base]
    end
  end
end
