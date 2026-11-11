defmodule Kanban.AuditLog.SignedExport.Sweeper do
  @moduledoc """
  Runs `Kanban.AuditLog.SignedExport.Scratch.sweep/0` when it starts and then
  on a timer, for as long as the VM runs.

  The sweep removes only directories more than an hour old, so a sweep at
  boot alone would keep what a VM killed seconds earlier left behind, and
  nothing would look again until some later boot. The timer closes that gap:
  a directory left by a killed VM is gone within an hour and a quarter of its
  last change, whatever the uptime.

  Each sweep runs as a task under `Kanban.TaskSupervisor`, so a sweep that
  fails cannot take this process, or the application's supervisor, down with
  it.

  ## Options

    * `:interval` - milliseconds between sweeps. Defaults to 15 minutes.
    * `:name` - the name to register under. `Kanban.Application` starts one
      under this module's name.
  """

  use GenServer

  alias Kanban.AuditLog.SignedExport.Scratch

  @default_interval :timer.minutes(15)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.validate!(opts, [:name, interval: @default_interval])

    GenServer.start_link(__MODULE__, opts[:interval], Keyword.take(opts, [:name]))
  end

  @impl true
  def init(interval), do: {:ok, interval, {:continue, :sweep}}

  @impl true
  def handle_continue(:sweep, interval), do: sweep(interval)

  @impl true
  def handle_info(:sweep, interval), do: sweep(interval)
  def handle_info(_other, interval), do: {:noreply, interval}

  defp sweep(interval) do
    Task.Supervisor.start_child(Kanban.TaskSupervisor, Scratch, :sweep, [])
    Process.send_after(self(), :sweep, interval)

    {:noreply, interval}
  end
end
