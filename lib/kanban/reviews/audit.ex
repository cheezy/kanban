defmodule Kanban.Reviews.Audit do
  @moduledoc """
  The audit events `Kanban.Reviews` writes for every committed review, made
  on the web or in the app (`docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md`
  §9.5):

    * `:review_approved` for an approval, and
    * `:review_changes_requested` for a request for changes.

  Each row carries the task's `task_id`, `identifier` and `board_id`, where
  the review was made (`via`: `web`, `ios` or `android`), the device for an
  app review (`device_id`, `device_class`, `app_version`), the change size
  from `Kanban.Reviews.MobileGuard` (`files`, `changed_lines`) and, on an
  approval only, `approval_key`: `true` when the caller verified the device's
  approval signature. Metadata holds ids, fixed labels and counts only —
  never the review notes or the task title.

  The row's Organization is the one whose workspace holds the board, so the
  event shows on that Organization's `/org/audit`. A board in a personal
  workspace has none.

  `Kanban.Reviews` calls `record/4` inside the review transaction, so a
  rolled-back or refused review leaves no row. The task edit form sets a
  verdict without `Kanban.Reviews`, so it calls `record_change/3` once its
  save has committed, and writes the same events.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.Boards.Board
  alias Kanban.Devices.Device
  alias Kanban.Repo
  alias Kanban.Reviews.MobileGuard
  alias Kanban.Tasks.Task

  @vias [:web, :ios, :android]

  @type via :: :web | :ios | :android

  @type context :: %{
          via: via(),
          device_id: integer() | nil,
          device_class: :phone | :tablet | nil,
          app_version: String.t() | nil,
          approval_key: boolean()
        }

  @doc """
  Builds the review context from the caller's `opts`:

    * `:device` — the `Kanban.Devices.Device` the review was made on, or
      `nil` for the web. It must belong to `reviewer`.
    * `:via` — `:web`, `:ios` or `:android`. Defaults to the device's
      platform, or `:web` without a device. With a device it must match the
      device's platform.
    * `:approval_key` — `true` only when the caller verified the device's
      approval signature; any other value records `false`.

  Raises `ArgumentError` when the options contradict each other or the
  device belongs to someone else: those are caller bugs, never user input.
  """
  @spec context(keyword(), User.t() | %{id: integer()}) :: context()
  def context(opts, %{id: reviewer_id}) do
    device = Keyword.get(opts, :device)
    via = Keyword.get(opts, :via, default_via(device))

    validate!(via, device, reviewer_id)

    %{
      via: via,
      device_id: device && device.id,
      device_class: device && device.device_class,
      app_version: device && device.app_version,
      approval_key: Keyword.get(opts, :approval_key) == true
    }
  end

  @doc "The `via` and `device_class` the review telemetry carries."
  @spec telemetry_metadata(context()) :: %{via: via(), device_class: atom() | nil}
  def telemetry_metadata(%{via: via, device_class: device_class}),
    do: %{via: via, device_class: device_class}

  @doc """
  Writes the audit event for a committed `decision` on `task` (the fresh
  record with its `:column` preloaded) by `reviewer`. Returns `:ok`.
  """
  @spec record(:approved | :changes_requested, Task.t(), %{id: integer()}, context()) :: :ok
  def record(:approved, %Task{} = task, reviewer, context) do
    AuditLog.event(
      :review_approved,
      metadata(task, reviewer, context) ++ [approval_key: context.approval_key]
    )
  end

  def record(:changes_requested, %Task{} = task, reviewer, context) do
    AuditLog.event(:review_changes_requested, metadata(task, reviewer, context))
  end

  @doc """
  Writes the audit event for a verdict set outside `Kanban.Reviews`: the
  Review Status field of the task edit form. `stored` is the task as it was
  before the save and `saved` the task the save returned; call it once the
  save has committed.

  Writes `:review_approved` or `:review_changes_requested` only when the
  saved `review_status` is `:approved` or `:changes_requested` and differs
  from the stored one, so a save that leaves the verdict alone writes no
  row. A form review is always `via: :web`, with no device and no approval
  key. Returns `:ok`.
  """
  @spec record_change(Task.t(), Task.t(), %{id: integer()}) :: :ok
  def record_change(%Task{review_status: status}, %Task{review_status: status}, _reviewer),
    do: :ok

  def record_change(%Task{}, %Task{review_status: status} = saved, reviewer)
      when status in [:approved, :changes_requested] do
    record(status, Repo.preload(saved, :column), reviewer, context([via: :web], reviewer))
  end

  def record_change(%Task{}, %Task{}, _reviewer), do: :ok

  defp metadata(%Task{column: %{board_id: board_id}} = task, reviewer, context) do
    size = MobileGuard.size(task)

    [
      user_id: reviewer.id,
      organization_id: organization_id(board_id),
      task_id: task.id,
      identifier: task.identifier,
      board_id: board_id,
      via: context.via,
      device_id: context.device_id,
      device_class: context.device_class,
      app_version: context.app_version,
      files: size.files,
      changed_lines: size.changed_lines
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp organization_id(board_id) do
    from(b in Board,
      join: w in assoc(b, :workspace),
      where: b.id == ^board_id,
      select: w.organization_id
    )
    |> Repo.one()
  end

  defp default_via(%Device{platform: platform}), do: platform
  defp default_via(_device), do: :web

  defp validate!(via, _device, _reviewer_id) when via not in @vias,
    do: raise(ArgumentError, "unknown review via: #{inspect(via)}")

  defp validate!(_via, nil, _reviewer_id), do: :ok

  defp validate!(_via, %Device{user_id: user_id}, reviewer_id) when user_id != reviewer_id,
    do: raise(ArgumentError, "the review device belongs to another user")

  defp validate!(via, %Device{platform: via}, _reviewer_id), do: :ok

  defp validate!(via, %Device{platform: platform}, _reviewer_id),
    do: raise(ArgumentError, "review via #{inspect(via)} does not match the device's #{platform}")

  defp validate!(_via, _device, _reviewer_id),
    do: raise(ArgumentError, "the review device must be a Kanban.Devices.Device or nil")
end
