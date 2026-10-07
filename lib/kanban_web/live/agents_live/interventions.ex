defmodule KanbanWeb.AgentsLive.Interventions do
  @moduledoc """
  The goal-level intervention logic behind `KanbanWeb.AgentsLive`'s at-risk
  explainer — Reassign, Reprioritize and the time-boxed Undo — extracted from
  the LiveView to keep it under the module-size guideline.

  Resolves a client-supplied goal id against the stalled goals on screen,
  builds the dialog state from the context preview, commits the write through
  the `Kanban.Tasks` context ops (which re-authorize via `can_intervene?/2`),
  sets the success/failure flash, arms the Undo snapshot and its bounded clear
  timer, and reverts exactly the snapshotted set on Undo. Moved unchanged.

  The `handle_event/3` and `handle_info/2` clauses stay on the LiveView (only
  it can receive them) and call into this module; the dialog markup lives in
  `KanbanWeb.AgentsLive.Components.InterventionDialogs`. After a successful
  write the page is refreshed through
  `KanbanWeb.AgentsLive.DataLoader.load_agents_data/1`.
  """

  use Gettext, backend: KanbanWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Kanban.Tasks
  alias KanbanWeb.AgentsLive.DataLoader

  # How long the Undo affordance for a reassign/reprioritize stays live before it
  # is cleared. Read at runtime (not a compile-time attr) so tests can shorten the
  # window; a bounded window keeps a stale prior-state snapshot from being
  # replayed indefinitely.
  @default_undo_window_ms 8_000

  @doc false
  def commit_reassign(socket, goal, assigned_to_id) do
    scope = socket.assigns.current_scope

    case Tasks.reassign_goal_unstarted(scope, goal, assigned_to_id) do
      {:ok, result} -> {:noreply, reassign_succeeded(socket, goal, result)}
      {:error, reason} -> {:noreply, reassign_failed(socket, reason)}
    end
  end

  # The pre-write goal + preview children still carry each task's original owner,
  # so they seed the per-task undo snapshot (matched by id against the moved set).
  defp reassign_succeeded(socket, goal, %{moved: moved, skipped: skipped}) do
    restorations =
      intervention_restorations([goal | socket.assigns.reassign.children], moved, :assigned_to_id)

    socket
    |> assign(:reassign, nil)
    |> put_flash(:info, reassign_flash(moved, skipped))
    |> arm_undo(:reassign, goal, restorations)
    |> DataLoader.load_agents_data()
  end

  defp reassign_failed(socket, :unauthorized) do
    socket
    |> assign(:reassign, nil)
    |> put_flash(:error, gettext("You are not allowed to reassign this goal."))
  end

  defp reassign_failed(socket, :assignee_not_on_board) do
    put_flash(socket, :error, gettext("That user is not a member of this board."))
  end

  defp reassign_failed(socket, _changeset) do
    put_flash(socket, :error, gettext("Could not reassign the goal. Please try again."))
  end

  # Resolve a client-supplied goal id against the stalled goals actually on
  # screen, so a forged payload can only ever name a goal the page already
  # shows (authorization is still re-checked by can_intervene?/2 afterward).
  @doc false
  def find_stalled_goal(socket, goal_id) do
    case Integer.parse(goal_id) do
      {id, ""} ->
        socket.assigns.delivery_rollup.targets
        |> Enum.flat_map(& &1.stalled_details)
        |> Enum.map(& &1.goal)
        |> Enum.find(&(&1.id == id))

      _ ->
        nil
    end
  end

  @doc false
  def build_reassign_state(%{goal: goal, children: children, members: members}) do
    %{goal: goal, children: children, member_options: member_options(members)}
  end

  defp member_options(members) do
    Enum.map(members, fn %{user: user} -> {user_label(user), user.id} end)
  end

  defp user_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_label(%{email: email}), do: email

  @doc false
  def parse_assignee_id(""), do: :none

  def parse_assignee_id(raw_id) do
    case Integer.parse(raw_id) do
      {id, ""} -> id
      _ -> :none
    end
  end

  defp reassign_flash(moved, []) do
    ngettext("Reassigned %{count} task.", "Reassigned %{count} tasks.", length(moved))
  end

  defp reassign_flash(moved, skipped) do
    ids = Enum.map_join(skipped, ", ", & &1.identifier)

    moved_msg = ngettext("Reassigned %{count} task.", "Reassigned %{count} tasks.", length(moved))

    skipped_msg =
      ngettext(
        "Skipped %{count} task already claimed: %{ids}.",
        "Skipped %{count} tasks already claimed: %{ids}.",
        length(skipped),
        ids: ids
      )

    moved_msg <> " " <> skipped_msg
  end

  @doc false
  def commit_reprioritize(socket, goal, priority) do
    scope = socket.assigns.current_scope

    case Tasks.reprioritize_goal_unstarted(scope, goal, priority) do
      {:ok, result} -> {:noreply, reprioritize_succeeded(socket, goal, result)}
      {:error, reason} -> {:noreply, reprioritize_failed(socket, reason)}
    end
  end

  # The pre-write goal + preview children still carry each task's original
  # priority, so they seed the per-task undo snapshot (matched by id to the moved
  # set).
  defp reprioritize_succeeded(socket, goal, %{moved: moved, skipped: skipped}) do
    restorations =
      intervention_restorations([goal | socket.assigns.reprioritize.children], moved, :priority)

    socket
    |> assign(:reprioritize, nil)
    |> put_flash(:info, reprioritize_flash(moved, skipped))
    |> arm_undo(:reprioritize, goal, restorations)
    |> DataLoader.load_agents_data()
  end

  defp reprioritize_failed(socket, :unauthorized) do
    socket
    |> assign(:reprioritize, nil)
    |> put_flash(:error, gettext("You are not allowed to reprioritize this goal."))
  end

  defp reprioritize_failed(socket, :invalid_priority) do
    put_flash(socket, :error, gettext("That is not a valid priority."))
  end

  defp reprioritize_failed(socket, _changeset) do
    put_flash(socket, :error, gettext("Could not reprioritize the goal. Please try again."))
  end

  @doc false
  def build_reprioritize_state(%{goal: goal, children: children}) do
    %{goal: goal, children: children}
  end

  # The priority selector is constrained to these four values; the context op
  # re-validates the submitted string, so no atom is ever built from user input.
  @doc false
  def parse_priority(""), do: :none
  def parse_priority(priority), do: priority

  defp reprioritize_flash(moved, []) do
    ngettext("Reprioritized %{count} task.", "Reprioritized %{count} tasks.", length(moved))
  end

  defp reprioritize_flash(moved, skipped) do
    ids = Enum.map_join(skipped, ", ", & &1.identifier)

    moved_msg =
      ngettext("Reprioritized %{count} task.", "Reprioritized %{count} tasks.", length(moved))

    skipped_msg =
      ngettext(
        "Skipped %{count} task already claimed: %{ids}.",
        "Skipped %{count} tasks already claimed: %{ids}.",
        length(skipped),
        ids: ids
      )

    moved_msg <> " " <> skipped_msg
  end

  # Builds the per-task undo snapshot from the pre-write goal + preview children
  # (which still carry each task's ORIGINAL value) matched by id against the set
  # the op actually moved, so the undo restores each task to *its own* prior
  # `field` value — not one flattened goal-level value.
  defp intervention_restorations(prior_tasks, moved, field) do
    prior_by_id = Map.new(prior_tasks, &{&1.id, Map.fetch!(&1, field)})

    Enum.map(moved, fn task ->
      %{id: task.id, identifier: task.identifier, prior: Map.get(prior_by_id, task.id)}
    end)
  end

  # Snapshots the per-task restorations (id + identifier + that task's own prior
  # value) and schedules the bounded-window clear. A fresh token per arming lets
  # the timed clear ignore snapshots superseded by a later intervention.
  defp arm_undo(socket, op, goal, restorations) do
    token = make_ref()
    Process.send_after(self(), {:clear_undo, token}, undo_window_ms())

    assign(socket, :undo, %{op: op, goal_id: goal.id, restorations: restorations, token: token})
  end

  # Reverts exactly the snapshotted moved set to each task's own prior value via
  # the set-scoped undo context op (never the goal's broader current not-started
  # set, so a task that did not move is untouched). The op re-checks
  # can_intervene?/2 and board scope and re-reads under a row lock, so a
  # now-unauthorized user or a since-claimed task is refused/skipped rather than
  # force-reverted. Anything from the moved set the op could not restore (claimed
  # since — moved out of the not-started columns, so the op never sees it) is
  # surfaced, not silently dropped.
  @doc false
  def commit_undo(socket, %{op: op, goal_id: goal_id, restorations: restorations}) do
    scope = socket.assigns.current_scope
    # Re-read the goal fresh: the snapshot's struct holds the pre-intervention
    # field value, so building the revert changeset from it would be an empty
    # (no-op) change. The fresh row carries the intervention's new value, so
    # setting it back to its prior is a real update.
    goal = Tasks.get_task!(goal_id)

    case undo_op(op, scope, goal, restorations) do
      {:ok, result} -> undo_succeeded(socket, result, restorations)
      {:error, reason} -> undo_failed(socket, reason)
    end
  end

  # `restored` is what the undo op actually re-read and reverted; any task from
  # the moved snapshot missing from it was claimed since and is surfaced.
  defp undo_succeeded(socket, %{moved: restored}, restorations) do
    restored_ids = MapSet.new(restored, & &1.id)
    unrestorable = Enum.reject(restorations, &MapSet.member?(restored_ids, &1.id))

    socket
    |> assign(:undo, nil)
    |> put_flash(:info, undo_flash(restored, unrestorable))
    |> DataLoader.load_agents_data()
  end

  defp undo_failed(socket, reason) do
    socket
    |> assign(:undo, nil)
    |> put_flash(:error, undo_error_flash(reason))
  end

  defp undo_op(:reassign, scope, goal, restorations),
    do: Tasks.undo_reassignment(scope, goal, restorations)

  defp undo_op(:reprioritize, scope, goal, restorations),
    do: Tasks.undo_reprioritization(scope, goal, restorations)

  defp undo_flash(restored, []) do
    ngettext(
      "Undone: restored %{count} task.",
      "Undone: restored %{count} tasks.",
      length(restored)
    )
  end

  defp undo_flash(restored, unrestorable) do
    ids = Enum.map_join(unrestorable, ", ", & &1.identifier)

    restored_msg =
      ngettext(
        "Undone: restored %{count} task.",
        "Undone: restored %{count} tasks.",
        length(restored)
      )

    unrestorable_msg =
      ngettext(
        "Could not restore %{count} task claimed since: %{ids}.",
        "Could not restore %{count} tasks claimed since: %{ids}.",
        length(unrestorable),
        ids: ids
      )

    restored_msg <> " " <> unrestorable_msg
  end

  defp undo_error_flash(:unauthorized),
    do: gettext("You are no longer allowed to undo this change.")

  defp undo_error_flash(_reason), do: gettext("Could not undo the change. Please try again.")

  defp undo_window_ms, do: Application.get_env(:kanban, :undo_window_ms, @default_undo_window_ms)
end
