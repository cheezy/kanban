defmodule Kanban.Decisions do
  @moduledoc """
  The decisions waiting on a person: the one builder behind the app's Now
  screen, its badge, the widget and the inbox channel
  (`docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md` §7.4).

  `build/2` gathers five kinds of item, one source each in
  `Kanban.Decisions.Sources`:

  | Kind | Source | Clears when |
  |---|---|---|
  | `:review` | pending reviews on the person's boards, from the `/review` query (`Kanban.Reviews.list_pending_reviews/1`) | the review is decided, or the task leaves Review |
  | `:released` | the person's newest unread `task_unclaimed` notification per task, while the task is open in Ready and has not been claimed since (`Kanban.Tasks.TaskClaim`) | the task is claimed (and stays cleared however that claim ends), moved out of Ready, archived, or the notification is read |
  | `:claim_expired` | the person's newest `claim_expired` notification per task, sent at or after the current claim's expiry, while the task is still in Doing | the task is claimed again, moved, completed or archived |
  | `:hook_failed` | goals whose last `after_goal` attempt failed: any recorded attempt whose `exit_code` is not `0`, as `Kanban.Tasks.report_after_goal/2` decides | a later attempt succeeds |
  | `:ready_empty` | boards the person can write to with no Ready task, at least one Backlog task, and an agent that worked on the board in the last 24 hours and is idle on every board the person can see | a task reaches Ready, or no agent is idle |

  One limit follows from what the person may see, and is kept on purpose:
  an agent busy only on boards the person cannot see counts as idle, since
  those boards are never read for this person: reading them would tell the
  person about work on boards they have no access to.

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
    * `:actions` - the actions the server lets this person take, as atoms,
      on the device asking: with `device_class: :phone`, a review whose change
      `Kanban.Reviews.MobileGuard` finds too large for a phone has no
      `:approve`, as the review detail's `approvable_here` says; a tablet and
      the web (`nil`, the default) keep it
    * `:web_url` - the absolute URL of the item on the web: for a task, its
      edit page when the person can write to the board, else the board, which
      a read-only member can open
    * `:holds_up` - how many tasks the item holds up (`nil` for `:ready_empty`,
      which carries its idle agents in `:details` instead)
    * `:held_identifiers` - the identifiers of up to 5 of those tasks, the
      nearest first (`[]` for `:ready_empty`)

  ## Holds up

  An item holds up the unfinished, unarchived tasks on its board that depend
  on its task or goal, directly or through a chain, followed to a depth of 5
  and counted to at most 50 (`Kanban.Decisions.HoldsUp`). A goal whose
  `after_goal` failed is itself held up, so a `:hook_failed` item counts its
  goal first, then the goal's dependents. Two items can hold up the same
  task, and each counts it.

  ## Order

  Items come back by `:holds_up`, highest first, then by `:since`, oldest
  first, then by `:id`. Every `:ready_empty` item comes after every other
  item, because it invites a choice rather than unblocking a task. At most
  100 items come back; the cap is applied after ordering.

  ## Summary

  `build_with_summary/1` returns the items with a summary:

    * `:waiting` - every item waiting on the person, `:ready_empty` included,
      counted before the 100-item cap
    * `:held_up` - the distinct tasks held up across every item, also counted
      before the cap and without the per-item cap of 50, so a task two items
      hold up counts once and an item holding up more than 50 counts them all
      (still to a depth of 5)
    * `:agents_working` - agents holding a task in Doing on a board the person
      can access (`Kanban.Agents.fleet_health/1`), dormant agents left out.
      Like the `:ready_empty` idle check, this reads every board the person
      can access, including boards outside the plan.

  ## Options

    * `:source` - `:api` (the default), `:channel` or `:push`; see Telemetry
    * `:device_class` - `:phone`, `:tablet` or `nil` (the web, the default),
      the class of the device the items are for; see `:actions` above. Any
      other value raises `ArgumentError`.

  ## Telemetry

  Every build emits `[:kanban, :decisions, :built]`
  (`Kanban.Telemetry.Catalog.DecisionEvents`) with `count`, the items waiting
  before the 100-item cap, and `duration`, in native time units, and the
  `:source` option as its only metadata: `:api` (the default), `:channel` or
  `:push` (`Kanban.Push.PushWorker`).
  Any other source raises `ArgumentError`, because it is a metric tag.

  A person's first action on a decision, on the web or in the app, emits
  `[:kanban, :decision, :acted_on]` through `acted_on/3`
  (`Kanban.Decisions.ActedOn`, which has the rules).

  ## Cost

  A fixed number of queries whatever the number of tasks: the boards, the
  plan, the pending reviews, the notifications, the failed goals and the
  column counts, plus, only when some board's Ready column is empty, one
  roster query for the person and one per such board. Holds-up adds one
  recursive query per board with at least one task or goal item, and
  `build_with_summary/1` adds one roster query when anything is waiting.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Agents
  alias Kanban.Decisions.ActedOn
  alias Kanban.Decisions.HoldsUp
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
          web_url: String.t(),
          holds_up: non_neg_integer() | nil,
          held_identifiers: [String.t()]
        }
  @type summary :: %{
          waiting: non_neg_integer(),
          held_up: non_neg_integer(),
          agents_working: non_neg_integer()
        }

  @type option ::
          {:source, :api | :channel | :push}
          | {:device_class, Kanban.Reviews.MobileGuard.device_class()}

  @max_items 100
  @shown_held 5
  @telemetry_sources [:api, :channel, :push]
  @device_classes [nil, :phone, :tablet]

  @sources [
    &Sources.review/1,
    &Sources.released/1,
    &Sources.claim_expired/1,
    &Sources.hook_failed/1,
    &Sources.ready_empty/1
  ]

  @doc """
  Returns the decision items waiting on the scoped person, ordered and
  capped at 100 (see "Order" above).

  A scope without a user gets `[]`, as does a person with no accessible,
  unlocked board.
  """
  @spec build(Scope.t() | nil, [option()]) :: [item()]
  def build(scope, opts \\ []), do: timed(scope, opts, fn ranked, _held_up -> capped(ranked) end)

  @doc """
  Returns the same items as `build/1` with the summary counts
  (see "Summary" above).

  A scope without a user, or a person with nothing waiting, gets no items and
  a summary of zeros, without reading the agent roster.
  """
  @spec build_with_summary(Scope.t() | nil, [option()]) :: %{
          items: [item()],
          summary: summary()
        }
  def build_with_summary(scope, opts \\ []) do
    timed(scope, opts, fn ranked, held_up ->
      %{items: capped(ranked), summary: summary(scope, ranked, held_up)}
    end)
  end

  @doc """
  Returns only the `:review` items, in the same order as `build/1`: the
  app's review queue.

  The review items are taken before the 100-item cap, so a review never
  drops off the queue because other kinds filled the cap; the queue itself
  is capped at 100.
  """
  @spec review_queue(Scope.t() | nil, [option()]) :: [item()]
  def review_queue(scope, opts \\ []) do
    timed(scope, opts, fn ranked, _held_up ->
      ranked |> Enum.filter(&(&1.kind == :review)) |> capped()
    end)
  end

  # Builds the ranked items once, hands them to `fun` and emits
  # [:kanban, :decisions, :built] with the number of items waiting (before
  # the cap) and how long the whole build took, the summary included.
  defp timed(scope, opts, fun) do
    source = source!(opts)
    device_class = device_class!(opts)
    started = System.monotonic_time()
    {ranked, held_up} = ranked(scope, device_class)
    result = fun.(ranked, held_up)

    Kanban.Telemetry.emit(
      [:kanban, :decisions, :built],
      %{count: length(ranked), duration: System.monotonic_time() - started},
      %{source: source}
    )

    result
  end

  defp source!(opts) do
    case Keyword.get(opts, :source, :api) do
      source when source in @telemetry_sources ->
        source

      other ->
        raise ArgumentError,
              "unknown decisions source #{inspect(other)}, expected one of #{inspect(@telemetry_sources)}"
    end
  end

  defp device_class!(opts) do
    case Keyword.get(opts, :device_class) do
      device_class when device_class in @device_classes ->
        device_class

      other ->
        raise ArgumentError,
              "unknown device class #{inspect(other)}, expected one of #{inspect(@device_classes)}"
    end
  end

  # Every item, ordered but not capped, and the number of distinct tasks they
  # hold up, so the summary can count past both caps.
  defp ranked(%Scope{user: %User{} = user} = scope, device_class) do
    case unlocked_boards(user) do
      [] -> {[], 0}
      boards -> scope |> Sources.context(user, boards, device_class) |> collect() |> rank()
    end
  end

  defp ranked(_scope, _device_class), do: {[], 0}

  defp capped(ranked), do: Enum.take(ranked, @max_items)

  defp unlocked_boards(user) do
    boards = Policy.list_accessible_boards(user)
    unlocked = boards |> Enum.map(& &1.id) |> Plans.unlocked_board_ids()
    Enum.filter(boards, &MapSet.member?(unlocked, &1.id))
  end

  defp collect(ctx) do
    items = Enum.flat_map(@sources, & &1.(ctx))
    {items, ctx}
  end

  defp rank({items, ctx}) do
    %{roots: held, boards: board_held} = items |> roots_by_board(ctx) |> HoldsUp.held()

    ranked =
      items
      |> Enum.map(&with_holds_up(&1, all_held(&1, held)))
      |> Enum.sort_by(&sort_key/1)

    {ranked, held_up_count(items, board_held)}
  end

  # Every distinct task held up on the person's boards, uncapped, plus each
  # failed goal, which holds itself up.
  defp held_up_count(items, board_held) do
    goals =
      for %{kind: :hook_failed} = item <- items, do: {item.board_id, item.summary.identifier}

    board_held
    |> Enum.flat_map(fn {board_id, identifiers} -> Enum.map(identifiers, &{board_id, &1}) end)
    |> Enum.concat(goals)
    |> MapSet.new()
    |> MapSet.size()
  end

  # Board ids come from the person's own boards, never only from the items,
  # so a count can never reach a board hidden from them.
  defp roots_by_board(items, ctx) do
    items
    |> Enum.reject(&(&1.kind == :ready_empty or is_nil(&1.summary.identifier)))
    |> Enum.group_by(& &1.board_id, & &1.summary.identifier)
    |> Map.take(Map.keys(ctx.boards))
  end

  defp all_held(%{kind: :ready_empty}, _held), do: nil

  defp all_held(%{kind: :hook_failed} = item, held),
    do: Enum.take([item.summary.identifier | dependents(item, held)], HoldsUp.cap())

  defp all_held(item, held), do: dependents(item, held)

  defp dependents(item, held), do: Map.get(held, {item.board_id, item.summary.identifier}, [])

  defp with_holds_up(item, nil), do: Map.merge(item, %{holds_up: nil, held_identifiers: []})

  defp with_holds_up(item, all) do
    Map.merge(item, %{holds_up: length(all), held_identifiers: Enum.take(all, @shown_held)})
  end

  @doc """
  Runs `fun`, a person's move or reply on the web or in the app, and counts
  it as the first action on each decision it resolves
  (`Kanban.Decisions.ActedOn.track/3`). Returns `fun`'s result unchanged.
  """
  @spec acted_on(Scope.t() | nil, ActedOn.act(), (-> result)) :: result when result: term()
  defdelegate acted_on(scope, act, fun), to: ActedOn, as: :track

  # Ties on the time fall back to the item id with its trailing number read as
  # a number, so "review:task:999999" sorts before "review:task:1000000" as
  # the web queue's integer ids do.
  @doc false
  def sort_key(item) do
    {ready_empty_rank(item.kind), -(item.holds_up || 0), since_key(item.since), id_key(item.id)}
  end

  defp id_key(id) do
    {prefix, [last]} = id |> String.split(":") |> Enum.split(-1)

    case Integer.parse(last) do
      {number, ""} -> {prefix, number, ""}
      _not_a_number -> {prefix, 0, last}
    end
  end

  defp ready_empty_rank(:ready_empty), do: 1
  defp ready_empty_rank(_kind), do: 0

  defp since_key(%DateTime{} = since), do: DateTime.to_unix(since, :microsecond)
  defp since_key(_since), do: 0

  # agents_working does not depend on anything waiting: an empty inbox still
  # counts the agents at work, so only a scope with no person skips the read.
  defp summary(%Scope{user: %User{}} = scope, ranked, held_up) do
    %{
      waiting: length(ranked),
      held_up: held_up,
      agents_working: Agents.fleet_health(scope: scope).working
    }
  end

  defp summary(_scope, _ranked, _held_up), do: %{waiting: 0, held_up: 0, agents_working: 0}
end
