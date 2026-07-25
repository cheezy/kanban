defmodule KanbanWeb.TaskLive.Components.BehaviourTestMatrixSection do
  @moduledoc """
  Renders a task's behaviour/test matrix on the read view: one line per row,
  pairing the behaviour with the test that covers it (or the reason it is
  waived). Caller is responsible for the outer visibility/presence guard.
  """
  use KanbanWeb, :html

  alias KanbanWeb.BehaviourTestLabels

  attr :rows, :list, required: true

  def behaviour_test_matrix_section(assigns) do
    ~H"""
    <ul style="display: flex; flex-direction: column; gap: 6px; margin: 0; padding: 0; list-style: none;">
      <li
        :for={row <- @rows}
        style="display: flex; flex-direction: column; gap: 2px; padding: 3px 0; min-width: 0;"
      >
        <span style="display: flex; flex-wrap: wrap; align-items: baseline; gap: 6px; min-width: 0;">
          <span style="font-size: 10px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; color: var(--ink-3);">
            {BehaviourTestLabels.category_label(row.category)}
          </span>
          <span style="font-size: 12.5px; color: var(--ink); overflow-wrap: anywhere; min-width: 0;">
            {row.behaviour}
          </span>
        </span>
        <span style="display: flex; flex-wrap: wrap; align-items: baseline; gap: 6px; padding-left: 0; min-width: 0;">
          <span
            :if={row.test_name}
            style="font-size: 11.5px; color: var(--ink-2); font-family: var(--font-mono); overflow-wrap: anywhere; min-width: 0;"
          >
            {row.test_name}
          </span>
          <span :if={row.na_reason} style="font-size: 11px; color: var(--ink-3);">
            {row.na_reason}
          </span>
          <span :if={row.type} style="font-size: 11px; color: var(--ink-3);">
            {row.type}
          </span>
          <span :if={row.status} style="font-size: 11px; color: var(--ink-3);">
            {BehaviourTestLabels.status_label(row.status)}
          </span>
        </span>
      </li>
    </ul>
    """
  end
end
