defmodule KanbanWeb.API.Me.DecisionJSON do
  @moduledoc """
  JSON rendering for `GET /api/me/decisions` (W2758,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.4), from what
  `Kanban.Decisions.build_with_summary/2` returns. `item/1` also renders each
  entry of `GET /api/me/reviews` (`KanbanWeb.API.Me.ReviewJSON.index/1`).

  The keys are a contract with every supported app version: add fields, never
  remove or rename one (design §7.2). An app ignores a `kind` or an action it
  does not know. `priv/openapi/stride-api.json` documents the same keys, and
  `test/kanban_web/controllers/api/open_api_contract_test.exs` checks they
  agree. Every key is always present; a value that is unknown is `null`.
  Atoms are rendered as strings.
  """

  # A review's size, as `Kanban.Reviews.MobileGuard.size/1` counts it plus
  # `large_change`: the same keys as the review screen's `size`.
  @size_keys [:files, :files_unknown, :changed_lines, :truncated, :large_change]

  @doc "The decisions waiting on the person and the summary, under `data`."
  def index(%{decisions: %{items: items, summary: summary}}) do
    %{data: %{items: Enum.map(items, &item/1), summary: summary(summary)}}
  end

  @doc "The Now screen's counts: waiting, held up and agents working."
  def summary(summary) do
    %{
      waiting: summary.waiting,
      held_up: summary.held_up,
      agents_working: summary.agents_working
    }
  end

  @doc "One decision item, with its kind's own details."
  def item(item) do
    %{
      id: item.id,
      kind: atom_string(item.kind),
      since: item.since,
      task_id: item.task_id,
      board_id: item.board_id,
      summary: task_summary(item.summary),
      details: details(item.kind, item.details),
      actions: Enum.map(item.actions, &atom_string/1),
      web_url: item.web_url,
      holds_up: item.holds_up,
      held_identifiers: item.held_identifiers
    }
  end

  defp task_summary(summary) do
    %{
      identifier: summary.identifier,
      title: summary.title,
      priority: atom_string(summary.priority),
      agent: summary.agent,
      board: %{id: summary.board.id, name: summary.board.name}
    }
  end

  defp details(:review, details) do
    %{
      verdicts: Enum.map(details.verdicts, &verdict/1),
      first_failed_note: details.first_failed_note,
      size: Map.take(details.size, @size_keys)
    }
  end

  defp details(:released, details),
    do: %{reason: details.reason, notification_id: details.notification_id}

  defp details(:claim_expired, details),
    do: %{claimed_at: details.claimed_at, expired_at: details.expired_at}

  defp details(:hook_failed, details),
    do: %{exit_code: details.exit_code, duration_ms: details.duration_ms}

  defp details(:ready_empty, details),
    do: %{idle_agents: details.idle_agents, backlog_count: details.backlog_count}

  defp verdict(verdict), do: %{section: atom_string(verdict.section), status: verdict.status}

  defp atom_string(nil), do: nil
  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
end
