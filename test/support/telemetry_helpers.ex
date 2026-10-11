defmodule Kanban.TelemetryHelpers do
  @moduledoc """
  Test helper for asserting on telemetry events.

      import Kanban.TelemetryHelpers

      test "emits an event" do
        attach_telemetry([:kanban, :task, :changed_files_missing])
        # ... run the code under test ...
        assert_receive {:telemetry_event, [:kanban, :task, :changed_files_missing],
                        %{count: 1}, %{task_id: 7}}
      end

  `attach_telemetry/2` attaches a handler with a unique id, so async tests
  never collide on a handler id, and detaches it in `on_exit`. Telemetry
  dispatch is global, so a unique id alone does not stop one async test from
  receiving another test's events. The handler therefore forwards an event
  only when it was emitted by the owning test process or by a process that
  test started (one that lists it in `$callers`, such as a `Task`). Pass
  `any_process: true` for events emitted by unrelated processes, such as an
  Oban job or a GenServer, and use distinguishing metadata to tell events
  apart.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Attaches to one event (a list of atoms) or to a list of events, and sends
  `{:telemetry_event, event, measurements, metadata}` to the owning process for
  each matching event. Returns the handler id.

  Options:

    * `:pid` - the owning process; defaults to `self()`.
    * `:any_process` - forward events from every process, not just the owner
      and the processes it started; defaults to `false`.
  """
  @spec attach_telemetry([atom()] | [[atom()]], keyword()) :: String.t()
  def attach_telemetry(event_or_events, opts \\ [])

  def attach_telemetry([first | _rest] = event, opts) when is_atom(first) do
    attach_telemetry([event], opts)
  end

  def attach_telemetry(events, opts) when is_list(events) do
    unique = System.unique_integer([:positive, :monotonic])
    handler_id = "kanban-telemetry-helper-#{unique}"
    owner = Keyword.get(opts, :pid, self())
    config = %{pid: owner, any_process: Keyword.get(opts, :any_process, false)}

    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, config)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    handler_id
  end

  @doc false
  def handle_event(event, measurements, metadata, %{pid: pid} = config) do
    if config.any_process or owned_by?(pid) do
      send(pid, {:telemetry_event, event, measurements, metadata})
    end

    :ok
  end

  # The handler runs in the emitting process, so `self()` is the emitter.
  defp owned_by?(pid) do
    callers = Process.get(:"$callers", [])
    self() == pid or pid in callers
  end
end
