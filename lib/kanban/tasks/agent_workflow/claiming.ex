defmodule Kanban.Tasks.AgentWorkflow.Claiming do
  @moduledoc """
  The claim lifecycle of the agent workflow: claiming a task (the next
  available one, or a specific one by identifier) and releasing a claim.

  Not a public entry point. `Kanban.Tasks.AgentWorkflow` owns the public API,
  its defaults and its documentation, and delegates `claim_next_task/5` and
  `unclaim_task/3` here with every argument; callers outside the agent
  workflow call the facade, never this module.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.ChangesetText
  alias Kanban.Hooks
  alias Kanban.Notifications.Events
  alias Kanban.Repo
  alias Kanban.Tasks.AgentQueries
  alias Kanban.Tasks.AgentWorkflow.Support
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.Goals
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Queries
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskTelemetry

  require Logger

  @doc false
  def claim_next_task(agent_capabilities, user, board_id, task_identifier, agent_name) do
    if Support.board_write_access?(board_id, user) do
      do_claim_next_task(agent_capabilities, user, board_id, task_identifier, agent_name)
    else
      {:error, :not_authorized}
    end
  end

  defp do_claim_next_task(agent_capabilities, user, board_id, task_identifier, agent_name) do
    task =
      if task_identifier do
        AgentQueries.get_specific_task_for_claim(
          task_identifier,
          agent_capabilities,
          board_id,
          user.id
        )
      else
        AgentQueries.get_next_task(agent_capabilities, board_id, user.id)
      end

    case task do
      nil ->
        if task_identifier do
          claim_failure_for_specific_task(task_identifier, board_id, user.id)
        else
          {:error, :no_tasks_available}
        end

      task ->
        perform_claim(task, user, board_id, agent_name)
    end
  end

  # When a specific identifier is requested but the assignment-aware query
  # returns nil, distinguish "this task is assigned to a different user" from
  # "this task does not exist / is not eligible for any agent". The unfiltered
  # lookup tells us if the row exists and who owns it.
  #
  # Capabilities are intentionally passed as `[]` here so this disambiguation
  # step never hides an assignment conflict behind a capability filter — we
  # are answering "is this row assigned to someone else?", not "is the caller
  # capable of claiming it?".
  defp claim_failure_for_specific_task(task_identifier, board_id, user_id) do
    case AgentQueries.get_specific_task_for_claim(task_identifier, [], board_id) do
      %{assigned_to_id: assigned_id} when not is_nil(assigned_id) and assigned_id != user_id ->
        {:error, :assigned_to_other_user}

      _ ->
        {:error, :no_tasks_available}
    end
  end

  defp perform_claim(task, user, board_id, agent_name) do
    board = Repo.get!(Kanban.Boards.Board, board_id)
    doing_column = Support.get_column_by_name(board_id, "Doing")
    now = DateTime.utc_now()
    expires_at = now |> DateTime.add(60 * 60, :second)

    task
    |> run_claim_transaction(user, doing_column, now, expires_at)
    |> handle_claim_result(task, board, board_id, doing_column, agent_name)
    |> TaskTelemetry.claimed(user.id, board_id)
  end

  defp run_claim_transaction(task, user, doing_column, now, expires_at) do
    Repo.transaction(fn ->
      next_position = Positioning.get_next_position_locked(doing_column)

      # The atomic update_query carries the assignment predicate so that a
      # concurrent claim attempt by a different user cannot race past an
      # Elixir-level guard while the row is still :open. It also requires the
      # task to still be in the column it was found in, so a card a person
      # drags out of Ready while the claim runs stays where they put it. If 0
      # rows update, disambiguate the failure by inspecting the row inside the
      # same transaction.
      update_query =
        from(t in Task,
          where: t.id == ^task.id and t.column_id == ^task.column_id,
          where: t.status == :open or (t.status == :in_progress and t.claim_expires_at < ^now),
          where: is_nil(t.assigned_to_id) or t.assigned_to_id == ^user.id
        )

      case Repo.update_all(
             update_query,
             set: [
               status: :in_progress,
               claimed_at: now,
               claim_expires_at: expires_at,
               assigned_to_id: user.id,
               column_id: doing_column.id,
               position: next_position,
               updated_at: now
             ]
           ) do
        {1, _} ->
          :claimed

        {0, _} ->
          Repo.rollback(claim_zero_row_reason(task.id, user.id))
      end
    end)
  end

  defp handle_claim_result({:ok, :claimed}, task, board, board_id, _doing_column, agent_name) do
    updated_task = Queries.get_task_for_view!(task.id)

    Goals.update_parent_goal_position_locked(updated_task)

    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{board_id}",
      {:task_updated, updated_task}
    )

    # The board-topic broadcast above only reaches board LiveViews. The agents
    # surface subscribes to the board-scoped "agents:#{board_id}" topic, so
    # notify it directly — mirroring the completion path — otherwise a claim
    # never reaches the agent activity feed live and only appears after some
    # later event triggers a refresh (or a manual reload).
    Broadcaster.broadcast_agent_event(updated_task, :task_claimed, board_id)
    Broadcaster.emit_webhook(updated_task, :task_claimed, board_id)

    {:ok, hook_info} = Hooks.get_hook_info(updated_task, board, "before_doing", agent_name)
    {:ok, updated_task, hook_info}
  end

  defp handle_claim_result({:error, :no_tasks_available}, _task, _board, _board_id, _col, _agent),
    do: {:error, :no_tasks_available}

  defp handle_claim_result(
         {:error, :assigned_to_other_user},
         _task,
         _board,
         _board_id,
         _col,
         _agent
       ),
       do: {:error, :assigned_to_other_user}

  # After the atomic update_all returns 0 rows, inspect the live row to decide
  # whether the failure was caused by a competing claim/state change
  # (:no_tasks_available) or by a non-matching assignment
  # (:assigned_to_other_user).
  defp claim_zero_row_reason(task_id, user_id) do
    case Repo.get(Task, task_id) do
      %Task{assigned_to_id: assigned_id}
      when not is_nil(assigned_id) and assigned_id != user_id ->
        :assigned_to_other_user

      _ ->
        :no_tasks_available
    end
  end

  @doc false
  def unclaim_task(task, user, reason) do
    task = Repo.preload(task, [:column, :assigned_to])

    case unclaim_refusal(task, user, reason) do
      nil ->
        ready_column = Support.get_column_by_name(task.column.board_id, "Ready")
        result = perform_unclaim_transaction(task, ready_column)
        handle_unclaim_result(result, task, user, reason)

      refusal ->
        refusal
    end
  end

  defp unclaim_refusal(task, user, reason) do
    cond do
      task.status != :in_progress ->
        {:error, :not_claimed}

      task.assigned_to_id != user.id ->
        {:error, :not_authorized}

      # D109: live board-write re-check (W1430 in-depth), matching claim/complete.
      # An assignee who lost :owner/:modify access (and whose token escaped
      # revocation) can no longer unclaim.
      not Support.board_write_access?(task.column.board_id, user) ->
        {:error, :not_authorized}

      not ChangesetText.storable?(reason) ->
        {:error, ChangesetText.unstorable_changeset(:reason)}

      true ->
        nil
    end
  end

  defp perform_unclaim_transaction(task, ready_column) do
    Repo.transaction(fn ->
      next_position = Positioning.get_next_position_locked(ready_column)

      changeset =
        task
        |> Ecto.Changeset.change(%{
          status: :open,
          claimed_at: nil,
          claim_expires_at: nil,
          assigned_to_id: nil,
          column_id: ready_column.id,
          position: next_position
        })

      case Repo.update(changeset) do
        {:ok, updated_task} -> updated_task
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp handle_unclaim_result({:ok, updated_task}, task, user, reason) do
    updated_task = Repo.preload(updated_task, [:column, :assigned_to, :created_by])

    if reason do
      Logger.info("Task #{task.id} unclaimed by user #{user.id}. Reason: #{reason}")
    end

    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{task.column.board_id}",
      {:task_updated, updated_task}
    )

    Events.task_unclaimed(task, user, reason)
    Broadcaster.emit_webhook(updated_task, :task_unclaimed, task.column.board_id)
    TaskTelemetry.unclaimed(task, user.id, task.column.board_id, reason_given?(reason))
    {:ok, updated_task}
  end

  defp handle_unclaim_result({:error, changeset}, _task, _user, _reason) do
    {:error, changeset}
  end

  # Only whether a reason was given reaches telemetry, never the reason.
  defp reason_given?(reason) when is_binary(reason), do: String.trim(reason) != ""
  defp reason_given?(_reason), do: false
end
