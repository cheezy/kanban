defmodule KanbanWeb.TaskLive.Form.TelemetryLock do
  @moduledoc """
  Tells the user when a task form save could not store the paid task fields.

  On a free board while paid plans are enforced, the form shows the
  `:telemetry` lock instead of the Telemetry Event and Metrics to Track
  inputs, and `KanbanWeb.TaskLive.Form.ParamNormalizer` drops both fields from
  every save. A form opened before enforcement was switched on, or before the
  board left its Organization, still shows the inputs, so a user can type a
  change that is then not saved. `warn_lost/2` turns that silent drop into a
  flash, records the refusal like every other entry point, and switches the
  form to the lock in case it renders again.
  """

  use Gettext, backend: KanbanWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Kanban.Plans
  alias KanbanWeb.TaskLive.Form.ParamNormalizer

  @doc """
  Normalizes a save's params with `ParamNormalizer.normalize_params/3` for the
  socket's board and task, then passes any lost paid-field changes to
  `warn_lost/2`. Returns `{params, socket}`.
  """
  @spec normalize_params(Phoenix.LiveView.Socket.t(), map()) ::
          {map(), Phoenix.LiveView.Socket.t()}
  def normalize_params(socket, params) do
    %{board: board, task: task} = socket.assigns
    {params, lost} = ParamNormalizer.normalize_params(params, board, task)
    {params, warn_lost(socket, lost)}
  end

  @doc """
  Returns `socket` unchanged when `lost` is empty. Otherwise emits
  `[:kanban, :plan, :feature_refused]` for `:telemetry` with surface
  `:live_view`, flashes that the changes were not saved, and sets
  `:telemetry_locked?`.
  """
  @spec warn_lost(Phoenix.LiveView.Socket.t(), [String.t()]) :: Phoenix.LiveView.Socket.t()
  def warn_lost(socket, []), do: socket

  def warn_lost(socket, [_ | _]) do
    _refused = Plans.check_board(socket.assigns.board, :telemetry, surface: :live_view)

    socket
    |> put_flash(:error, message())
    |> assign(:telemetry_locked?, true)
  end

  @doc "The flash shown when changes to the paid task fields were not saved."
  @spec message() :: String.t()
  def message do
    gettext(
      "Telemetry Event and Metrics to Track need a board in an Organization, so your changes to them were not saved."
    )
  end
end
