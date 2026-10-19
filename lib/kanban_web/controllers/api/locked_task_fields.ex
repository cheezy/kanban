defmodule KanbanWeb.API.LockedTaskFields do
  @moduledoc """
  The REST side of the paid task fields (`telemetry_event` and
  `metrics_to_track`) for `POST /api/tasks`, `POST /api/tasks/batch` and
  `PATCH /api/tasks/:id`.

  On a locked board (a free board while paid plans are enforced) the request
  still succeeds: `strip/2` removes the fields through
  `Kanban.Plans.strip_locked_task_fields/3`, which emits
  `[:kanban, :plan, :feature_refused]` with surface `:rest`, and records one
  warning on the conn. The success renderers add it as a top-level `warnings`
  list through `put_warnings/2` (and `KanbanWeb.API.TaskJSON.show/1`). A
  request that sent neither field gets no `warnings` key.

  The warning is fixed, translated text that names only the dropped field
  names, never the submitted values. These fields are not on
  `KanbanWeb.API.TaskParamFilter`'s forbidden lists: that path refuses or logs
  mass assignment, while these are accepted and not stored.
  """

  use Gettext, backend: KanbanWeb.Gettext

  import Plug.Conn, only: [assign: 3]

  alias Kanban.Plans

  @doc """
  Strips the paid task fields from `params` (a task map, a goal with its
  `"tasks"`, or a list of goals) for the conn's board. Returns `{conn,
  params}`, with the warning assigned on `conn` when anything was dropped.
  """
  @spec strip(Plug.Conn.t(), term()) :: {Plug.Conn.t(), term()}
  def strip(conn, params) do
    case Plans.strip_locked_task_fields(params, conn.assigns.current_board, surface: :rest) do
      {params, []} -> {conn, params}
      {params, dropped} -> {assign(conn, :plan_warnings, [warning(dropped)]), params}
    end
  end

  @doc "The warning for the dropped field names."
  @spec warning([String.t()]) :: String.t()
  def warning(dropped) do
    ngettext(
      "%{fields} needs a board in an Organization and was not stored.",
      "%{fields} need a board in an Organization and were not stored.",
      length(dropped),
      fields: Enum.join(dropped, ", ")
    )
  end

  @doc "Adds the conn's warnings to a response body as `warnings`, when there are any."
  @spec put_warnings(map(), Plug.Conn.t() | map()) :: map()
  def put_warnings(body, %Plug.Conn{assigns: assigns}), do: put_warnings(body, assigns)

  def put_warnings(body, %{plan_warnings: [_ | _] = warnings}),
    do: Map.put(body, :warnings, warnings)

  def put_warnings(body, _assigns), do: body
end
