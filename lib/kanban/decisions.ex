defmodule Kanban.Decisions do
  @moduledoc """
  The decisions waiting on a person: the one builder behind the app's Now
  screen, its badge, the widget and the inbox channel
  (`docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md` §7.4).

  `build/1` gathers five kinds of item, one source each in
  `Kanban.Decisions.Sources`:

  | Kind | Source | Clears when |
  |---|---|---|
  | `:review` | pending reviews on the person's boards, from the `/review` query (`Kanban.Reviews.list_pending_reviews/1`) | the review is decided, or the task leaves Review |
  | `:released` | the person's newest unread `task_unclaimed` notification per task, while the task is open in Ready | the task is claimed or moved out of Ready, archived, or the notification is read |
  | `:claim_expired` | the person's newest `claim_expired` notification per task, sent at or after the current claim's expiry, while the task is still in Doing | the task is claimed again, moved, completed or archived |
  | `:hook_failed` | goals whose last `after_goal` attempt failed: any recorded attempt whose `exit_code` is not `0`, as `Kanban.Tasks.report_after_goal/2` decides | a later attempt succeeds |
  | `:ready_empty` | boards the person can write to with no Ready task, at least one Backlog task, and an agent that worked on the board in the last 24 hours and is idle on every board the person can see | a task reaches Ready, or no agent is idle |

  Two limits follow from what is stored. A `:released` item for an
  earlier release comes back when a later claim ends without a
  `task_unclaimed` notification (`Kanban.Tasks.ClaimRelease`, or a move
  back to Ready), because no claim history is kept to tell the two apart.
  And an agent busy only on boards the person cannot see counts as idle,
  since those boards are never read for this person.

  ## Scope

  Only boards the person can access (`Kanban.Workspaces.Policy`) that are
  unlocked by the plan (`Kanban.Plans.unlocked_board_ids/1`) contribute
  items. Board ids always come from that list, never from a caller.

  ## Items

  Each item is a plain map with every key present:

    * `:id` - a stable string, `"<kind>:task:<id>"`, `"hook_failed:goal:<id>"`
      or `"ready_empty:board:<id>"`
    * `:kind` - one of the five kinds above
    * `:since` - a UTC `DateTime`: when the item started waiting
    * `:task_id` and `:board_id` - the task or goal (`nil` for `:ready_empty`)
      and its board
    * `:summary` - `%{identifier:, title:, priority:, agent:, board: %{id:, name:}}`
      (all but `:board` are `nil` for `:ready_empty`)
    * `:details` - the kind's own fields: `verdicts` and `first_failed_note` for a
      review, `reason` and `notification_id` for a release, `claimed_at` and
      `expired_at` for an expired claim, `exit_code` and `duration_ms` for a
      failed hook (never its output), `idle_agents` and `backlog_count` for an
      empty Ready column
    * `:actions` - the actions the server lets this person take, as atoms
    * `:web_url` - the absolute URL of the item on the web

  Items come back grouped by kind in the order above and, within a kind,
  oldest first. Ranking and the summary counts are not built here.

  ## Cost

  A fixed number of queries whatever the number of tasks: the boards, the
  plan, the pending reviews, the notifications, the failed goals and the
  column counts, plus, only when some board's Ready column is empty, one
  roster query for the person and one per such board.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Decisions.Sources
  alias Kanban.Plans
  alias Kanban.Workspaces.Policy

  @type kind :: :review | :released | :claim_expired | :hook_failed | :ready_empty
  @type item :: %{
          id: String.t(),
          kind: kind(),
          since: DateTime.t() | nil,
          task_id: integer() | nil,
          board_id: integer(),
          summary: map(),
          details: map(),
          actions: [atom()],
          web_url: String.t()
        }

  @sources [
    &Sources.review/1,
    &Sources.released/1,
    &Sources.claim_expired/1,
    &Sources.hook_failed/1,
    &Sources.ready_empty/1
  ]

  @doc """
  Returns every decision item waiting on the scoped person.

  A scope without a user gets `[]`, as does a person with no accessible,
  unlocked board.
  """
  @spec build(Scope.t() | nil) :: [item()]
  def build(%Scope{user: %User{} = user} = scope) do
    case unlocked_boards(user) do
      [] -> []
      boards -> scope |> Sources.context(user, boards) |> collect()
    end
  end

  def build(_scope), do: []

  defp unlocked_boards(user) do
    boards = Policy.list_accessible_boards(user)
    unlocked = boards |> Enum.map(& &1.id) |> Plans.unlocked_board_ids()
    Enum.filter(boards, &MapSet.member?(unlocked, &1.id))
  end

  defp collect(ctx) do
    Enum.flat_map(@sources, fn source ->
      ctx
      |> source.()
      |> Enum.sort_by(&{since_key(&1.since), &1.id})
    end)
  end

  defp since_key(%DateTime{} = since), do: DateTime.to_unix(since, :microsecond)
  defp since_key(_since), do: 0
end
