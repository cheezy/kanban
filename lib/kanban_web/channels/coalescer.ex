defmodule KanbanWeb.Coalescer do
  @moduledoc """
  Coalesces bursts of change messages into one rebuild per interval, for the
  app's live channels (`KanbanWeb.InboxChannel`, `KanbanWeb.AgentsChannel`,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.7).

  It is a plain struct the channel keeps in its assigns, not a process. The
  first `request/2` schedules `message` (`:rebuild` by default) to the owning
  process after `interval` milliseconds; every further request while one is
  pending changes nothing. When the message arrives, the channel calls
  `fired/1` and rebuilds, so a burst of any size costs one rebuild, at most
  one per interval, and the last change in a burst is always covered by the
  rebuild that follows it.

  The interval is one second unless `new/1` is given `:interval`, or the
  `:kanban, KanbanWeb.Coalescer, :interval_ms` application env is set (the
  channel tests shorten it). It is read when `new/1` runs, never at compile
  time.
  """

  @default_interval 1_000

  defstruct interval: @default_interval, message: :rebuild, timer: nil

  @type t :: %__MODULE__{
          interval: pos_integer(),
          message: term(),
          timer: reference() | nil
        }

  @doc """
  A coalescer with nothing pending. Options: `:interval` in milliseconds
  (default: the `:interval_ms` application env, else one second) and
  `:message`, what is sent when the interval ends (default `:rebuild`).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      interval: Keyword.get_lazy(opts, :interval, &configured_interval/0),
      message: Keyword.get(opts, :message, :rebuild)
    }
  end

  @doc """
  Asks for a rebuild. Schedules the coalescer's message to `pid` (default the
  caller) after its interval unless one is already pending, in which case it
  returns the coalescer unchanged.
  """
  @spec request(t(), pid()) :: t()
  def request(coalescer, pid \\ self())

  def request(%__MODULE__{timer: nil} = coalescer, pid) do
    %{coalescer | timer: Process.send_after(pid, coalescer.message, coalescer.interval)}
  end

  def request(%__MODULE__{} = coalescer, _pid), do: coalescer

  @doc """
  Marks the pending message as delivered, so the next `request/2` schedules
  again. Call it when the message arrives, before rebuilding.
  """
  @spec fired(t()) :: t()
  def fired(%__MODULE__{} = coalescer), do: %{coalescer | timer: nil}

  @doc "True while a message is scheduled and has not been marked `fired/1`."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{timer: timer}), do: not is_nil(timer)

  defp configured_interval do
    :kanban
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:interval_ms, @default_interval)
  end
end
