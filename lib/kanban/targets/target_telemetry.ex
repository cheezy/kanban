defmodule Kanban.Targets.TargetTelemetry do
  @moduledoc """
  Emits the delivery target telemetry events through `Kanban.Telemetry`.

  Every event is emitted only after the change it reports has been saved, so
  a refused, invalid or stale change emits nothing. The functions take a
  result and return it unchanged, so they can sit at the end of a pipe
  without changing what the caller sees. A change that saves nothing new
  (an edit that changes no field, re-archiving an archived target, assigning
  a goal to the target it already has, or recording the status a target
  already has) emits nothing either.

  Creating, editing, archiving and unarchiving are owner-only, so the
  target's `owner_id` is the actor. A delivery target has no board of its
  own; only the goal assignment events carry a `board_id`, the goal's.
  Metadata carries ids, field names and status atoms only. A target's name
  and description are never sent.
  """

  alias Kanban.Accounts.User
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks.Task

  @edited_fields [:name, :target_date, :description]

  # A fixed lookup, so a stored status string can never create an atom.
  @statuses %{
    "on_track" => :on_track,
    "at_risk" => :at_risk,
    "missed" => :missed,
    "complete" => :complete
  }

  @doc """
  Emits `[:kanban, :target, :created]` when `result` is a saved target.
  Returns `result`.
  """
  @spec created(result) :: result when result: term()
  def created({:ok, %DeliveryTarget{} = target} = result) do
    Kanban.Telemetry.emit([:kanban, :target, :created], %{count: 1}, %{
      target_id: target.id,
      actor_user_id: target.owner_id
    })

    result
  end

  def created(result), do: result

  @doc """
  Emits `[:kanban, :target, :updated]` when `result` is a saved target whose
  editable fields differ from `before`, the target as it was. `fields` lists
  the changed field names, never their values. Returns `result`.
  """
  @spec updated(result, DeliveryTarget.t()) :: result when result: term()
  def updated({:ok, %DeliveryTarget{} = target} = result, %DeliveryTarget{} = before) do
    case Enum.filter(@edited_fields, &(Map.get(target, &1) != Map.get(before, &1))) do
      [] ->
        result

      fields ->
        Kanban.Telemetry.emit([:kanban, :target, :updated], %{count: 1}, %{
          target_id: target.id,
          actor_user_id: target.owner_id,
          fields: fields
        })

        result
    end
  end

  def updated(result, _before), do: result

  @doc """
  Emits `[:kanban, :target, :archived]` when `result` is a saved target and
  `before`, the target as it was, was active. Returns `result`.
  """
  @spec archived(result, DeliveryTarget.t()) :: result when result: term()
  def archived({:ok, %DeliveryTarget{} = target} = result, %DeliveryTarget{archived_at: nil}) do
    Kanban.Telemetry.emit([:kanban, :target, :archived], %{count: 1}, %{
      target_id: target.id,
      actor_user_id: target.owner_id
    })

    result
  end

  def archived(result, _before), do: result

  @doc """
  Emits `[:kanban, :target, :unarchived]` when `result` is a saved target and
  `before`, the target as it was, was archived. Returns `result`.
  """
  @spec unarchived(result, DeliveryTarget.t()) :: result when result: term()
  def unarchived(
        {:ok, %DeliveryTarget{} = target} = result,
        %DeliveryTarget{archived_at: %DateTime{}}
      ) do
    Kanban.Telemetry.emit([:kanban, :target, :unarchived], %{count: 1}, %{
      target_id: target.id,
      actor_user_id: target.owner_id
    })

    result
  end

  def unarchived(result, _before), do: result

  @doc """
  Emits `[:kanban, :target, :goal_assigned]` when `result` is a saved goal
  whose target differs from `before`, the goal as it was, with its column
  loaded. `actor` is the user who assigned it. Returns `result`.
  """
  @spec goal_assigned(result, Task.t(), User.t() | nil) :: result when result: term()
  def goal_assigned(
        {:ok, %Task{target_id: target_id} = goal} = result,
        %Task{target_id: previous, column: %{board_id: board_id}},
        %{id: actor_id}
      )
      when not is_nil(target_id) and target_id != previous do
    Kanban.Telemetry.emit([:kanban, :target, :goal_assigned], %{count: 1}, %{
      target_id: target_id,
      goal_id: goal.id,
      board_id: board_id,
      actor_user_id: actor_id
    })

    result
  end

  def goal_assigned(result, _before, _actor), do: result

  @doc """
  Emits `[:kanban, :target, :goal_unassigned]` when `result` is a saved goal
  and `before`, the goal as it was with its column loaded, had a target.
  `target_id` is the target the goal left. `actor` is the user who detached
  it. Returns `result`.
  """
  @spec goal_unassigned(result, Task.t(), User.t() | nil) :: result when result: term()
  def goal_unassigned(
        {:ok, %Task{target_id: nil} = goal} = result,
        %Task{target_id: previous, column: %{board_id: board_id}},
        %{id: actor_id}
      )
      when not is_nil(previous) do
    Kanban.Telemetry.emit([:kanban, :target, :goal_unassigned], %{count: 1}, %{
      target_id: previous,
      goal_id: goal.id,
      board_id: board_id,
      actor_user_id: actor_id
    })

    result
  end

  def goal_unassigned(result, _before, _actor), do: result

  @doc """
  Emits `[:kanban, :target, :status_changed]` when `result` is a target whose
  recorded status watermark differs from `previous`, the watermark it had
  (a status string, or `nil` before the first observation). Returns
  `result`.
  """
  @spec status_changed(result, String.t() | nil) :: result when result: term()
  def status_changed({:ok, %DeliveryTarget{last_notified_status: current}} = result, previous)
      when current == previous,
      do: result

  def status_changed({:ok, %DeliveryTarget{} = target} = result, previous) do
    Kanban.Telemetry.emit([:kanban, :target, :status_changed], %{count: 1}, %{
      target_id: target.id,
      from_status: status_atom(previous),
      to_status: status_atom(target.last_notified_status)
    })

    result
  end

  def status_changed(result, _previous), do: result

  defp status_atom(status) when is_binary(status), do: Map.get(@statuses, status)
  defp status_atom(_status), do: nil
end
