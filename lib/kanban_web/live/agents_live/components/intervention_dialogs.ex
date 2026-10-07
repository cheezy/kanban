defmodule KanbanWeb.AgentsLive.Components.InterventionDialogs do
  @moduledoc """
  The goal-level intervention markup on `KanbanWeb.AgentsLive`: the Reassign
  and Reprioritize confirmation dialogs, the shared `intervention_dialog/1`
  scaffold they both render through, and the time-boxed Undo affordance.

  Split out of `KanbanWeb.AgentsLive` to keep it under the module-size
  guideline in `AGENTS.md`. Purely presentational: each component reads the
  dialog/undo state map the LiveView holds (`@reassign`, `@reprioritize`,
  `@undo`) and renders, pushing its events (`confirm_reassign`,
  `cancel_reprioritize`, `undo_intervention`, ...) to the LiveView, which keeps
  the `handle_event/3` clauses. The write logic those events trigger lives in
  `KanbanWeb.AgentsLive.Interventions`. Moved unchanged; no DB access.
  """
  use KanbanWeb, :html

  attr :undo, :map, default: nil

  # The time-boxed Undo affordance shown after a successful reassign/reprioritize.
  # Rendered only while the snapshot is live (cleared on undo or when the window
  # elapses); clicking it reverts the moved set via commit_undo/2.
  def undo_affordance(assigns) do
    ~H"""
    <div
      :if={@undo}
      data-undo-affordance
      class="fixed bottom-4 left-1/2 -translate-x-1/2 z-50 flex items-center gap-3 rounded-lg border border-base-300 bg-base-100 px-4 py-2 shadow-lg"
    >
      <span class="text-sm text-base-content">{undo_prompt(@undo.op)}</span>
      <.button type="button" phx-click="undo_intervention" data-undo-trigger variant="primary">
        {gettext("Undo")}
      </.button>
    </div>
    """
  end

  defp undo_prompt(:reassign), do: gettext("Goal reassigned.")
  defp undo_prompt(:reprioritize), do: gettext("Goal reprioritized.")

  attr :reassign, :map, default: nil

  # The confirmation dialog for the goal-level Reassign action: a board-member
  # owner selector in the shared intervention_dialog/1 scaffold; confirming routes
  # through the reassign_goal_unstarted context op.
  def reassign_dialog(assigns) do
    ~H"""
    <.intervention_dialog
      :if={@reassign}
      id="reassign-goal-modal"
      form_id="reassign-form"
      goal={@reassign.goal}
      children={@reassign.children}
      title={gettext("Reassign %{goal}", goal: @reassign.goal.identifier)}
      summary={
        ngettext(
          "This will move 1 task to the new owner:",
          "This will move %{count} tasks to the new owner:",
          length(@reassign.children) + 1
        )
      }
      cancel_event="cancel_reassign"
      submit_event="confirm_reassign"
      submit_label={gettext("Reassign")}
    >
      <.input
        type="select"
        id="reassign-assigned-to"
        name="assigned_to_id"
        value=""
        label={gettext("New owner")}
        options={@reassign.member_options}
        prompt={gettext("Choose a new owner")}
      />
    </.intervention_dialog>
    """
  end

  attr :reprioritize, :map, default: nil

  # The confirmation dialog for the goal-level Reprioritize action: a selector
  # constrained to the four allowed priorities in the shared intervention_dialog/1
  # scaffold; confirming routes through the reprioritize_goal_unstarted context op.
  def reprioritize_dialog(assigns) do
    ~H"""
    <.intervention_dialog
      :if={@reprioritize}
      id="reprioritize-goal-modal"
      form_id="reprioritize-form"
      goal={@reprioritize.goal}
      children={@reprioritize.children}
      title={gettext("Reprioritize %{goal}", goal: @reprioritize.goal.identifier)}
      summary={
        ngettext(
          "This will change the priority of 1 task:",
          "This will change the priority of %{count} tasks:",
          length(@reprioritize.children) + 1
        )
      }
      cancel_event="cancel_reprioritize"
      submit_event="confirm_reprioritize"
      submit_label={gettext("Reprioritize")}
    >
      <.input
        type="select"
        id="reprioritize-priority"
        name="priority"
        value=""
        label={gettext("New priority")}
        options={priority_options()}
        prompt={gettext("Choose a new priority")}
      />
    </.intervention_dialog>
    """
  end

  defp priority_options do
    [
      {gettext("Low"), "low"},
      {gettext("Medium"), "medium"},
      {gettext("High"), "high"},
      {gettext("Critical"), "critical"}
    ]
  end

  attr :id, :string, required: true
  attr :form_id, :string, required: true
  attr :goal, :map, required: true
  attr :children, :list, required: true
  attr :title, :string, required: true
  attr :summary, :string, required: true
  attr :cancel_event, :string, required: true
  attr :submit_event, :string, required: true
  attr :submit_label, :string, required: true
  slot :inner_block, required: true

  # Shared confirmation-dialog scaffold for the goal-level interventions
  # (Reassign, Reprioritize). Renders the DelayedModal shell, the title, the
  # affected goal + not-started children list, and a form whose selector is the
  # caller-supplied inner block; the caller wires the submit/cancel events to its
  # own context op. Keeps the two interventions' shared markup in one place per
  # the "reuse the scaffold" contract, so only the selector and copy differ.
  def intervention_dialog(assigns) do
    ~H"""
    <KanbanWeb.DelayedModal.delayed_modal
      id={@id}
      show
      on_cancel={JS.push(@cancel_event)}
      max_width="max-w-lg"
    >
      <div class="flex flex-col gap-4">
        <h2 class="text-lg font-semibold text-base-content">{@title}</h2>

        <p class="text-sm text-base-content opacity-70">{@summary}</p>

        <ul class="flex flex-col gap-1 text-sm text-base-content" data-intervention-affected>
          <li data-intervention-goal={@goal.id}>
            <span class="font-mono">{@goal.identifier}</span>
            <span class="opacity-70">— {@goal.title}</span>
          </li>
          <li :for={child <- @children} data-intervention-child={child.id}>
            <span class="font-mono">{child.identifier}</span>
            <span class="opacity-70">— {child.title}</span>
          </li>
        </ul>

        <form id={@form_id} phx-submit={@submit_event} class="flex flex-col gap-4">
          {render_slot(@inner_block)}

          <div class="flex justify-end gap-2">
            <.button type="button" phx-click={@cancel_event}>
              {gettext("Cancel")}
            </.button>
            <.button type="submit" variant="primary">
              {@submit_label}
            </.button>
          </div>
        </form>
      </div>
    </KanbanWeb.DelayedModal.delayed_modal>
    """
  end
end
