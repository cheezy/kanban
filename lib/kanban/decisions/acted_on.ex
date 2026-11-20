defmodule Kanban.Decisions.ActedOn do
  @moduledoc """
  Counts a person's first action on a decision, the measure the native apps
  are judged by (`docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md` §16, §23):
  how long a decision waited before someone acted on it.

  When a person first approves, asks for changes, moves, promotes or replies
  on a decision, on the web or in the app, this emits
  `[:kanban, :decision, :acted_on]` with `count: 1` and `wait_seconds`, the
  whole seconds from the decision's `:since` to the action, never below 0.
  Its metadata is the decision's `kind`, the `action`, `via` (`:web`, `:ios`
  or `:android`), `task_id` (left out for `:ready_empty`, which has no task)
  and `board_id`.

  ## Which action counts

  | Action | Counts for |
  |---|---|
  | `:approve`, `:request_changes` | a `:review` |
  | `:move` | a `:released` or `:claim_expired` task, when the move takes it off the decision list |
  | `:promote` | a `:ready_empty` board, when a move into Ready fills it |
  | `:reply` | a `:released` task or a `:hook_failed` goal |

  A decision is the one `Kanban.Decisions` would list for that person at the
  moment of the action, built by the same sources
  (`Kanban.Decisions.Sources`), so a task that is no decision for them emits
  nothing. Moving a task in Review or a failed goal is not one of a
  decision's actions, so it is not counted; neither is a reorder within a
  column, or any other move that leaves the decision in place.

  ## First action only

  Each counted action records the decision's id and `:since` in
  `decision_actions` (`Kanban.Decisions.DecisionAction`), with
  `on_conflict: :nothing` on their unique index, and emits only when its row
  went in. A later action on the same decision, by anyone, finds the row and
  emits nothing, and of two first actions at once exactly one emits. A
  decision that comes back starts waiting at a new `:since` and counts again.

  ## Only people

  Only a person's action passes a `via`: the web's LiveViews and the app's
  `/api/me` controllers call `track/3`, and the review path passes the
  `via` its audit row records (`reviewed/3`). Agents act through other
  paths, which never reach this module, so an agent's action, or a decision
  an agent resolves first, is never counted.

  ## Timing

  The decision is read before the action and recorded after it commits, so
  a rolled-back action records and emits nothing. For moves and replies the
  read is not under the action's locks: if an agent resolves the decision in
  the instant between the read and the person's write, the person's action
  still counts, once. A review is read under the task's row lock.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Decisions.DecisionAction
  alias Kanban.Decisions.Sources
  alias Kanban.Plans
  alias Kanban.Repo
  alias Kanban.Reviews
  alias Kanban.Tasks.Task
  alias Kanban.Telemetry.AfterCommit

  @event [:kanban, :decision, :acted_on]
  @vias [:web, :ios, :android]

  @typedoc "Where the person acted."
  @type via :: :web | :ios | :android

  @typedoc """
  What the person is about to do:

    * `[action: :reply, via: via, task_id: id]` for a comment on a task
    * `[action: :move, via: via, board_id: id, task_ids: ids, into_ready: boolean]`
      for a move of tasks on a board, a promotion to Ready included
  """
  @type act :: keyword()

  @typedoc "One decision, cut down to what the event and its row need."
  @type decision :: %{
          id: String.t(),
          kind: atom(),
          since: DateTime.t() | nil,
          task_id: integer() | nil,
          board_id: integer(),
          action: atom()
        }

  @doc """
  Runs `fun`, the person's action, and counts it as the first action on each
  decision it resolves, as the moduledoc describes. Returns `fun`'s result
  unchanged.

  Nothing is read or counted when `scope` has no user, when the person has
  no access to the board, or when the plan locks the board. The decisions
  are read before `fun` runs; when `fun` returns anything but `{:ok, _}`,
  nothing is read again and nothing is counted. Raises `ArgumentError` for a `via` that is
  not `:web`, `:ios` or `:android`.
  """
  @spec track(Scope.t() | nil, act(), (-> result)) :: result when result: term()
  def track(scope, act, fun) when is_list(act) and is_function(fun, 0) do
    via = validate_via!(Keyword.get(act, :via))

    case pending(scope, act) do
      [] -> fun.()
      before -> run_tracked(scope, act, via, before, fun)
    end
  end

  defp run_tracked(scope, act, via, before, fun) do
    result = fun.()

    if match?({:ok, _}, result) do
      resolved = resolved(scope, act, before)
      AfterCommit.defer(fn -> finish(resolved, via) end)
    end

    result
  end

  @doc """
  Counts an approval or a request for changes of `task`, the pending review
  `Kanban.Reviews.ReviewCommit` has just read under its row lock, with its
  column preloaded. The count waits for the review's commit through
  `Kanban.Telemetry.AfterCommit`, so a review that rolls back counts
  nothing. A board the plan locks counts nothing. Returns `:ok`.
  """
  @spec reviewed(Task.t(), :approved | :changes_requested, via()) :: :ok
  def reviewed(%Task{column: %{board_id: board_id}} = task, status, via) do
    validate_via!(via)

    if Plans.board_unlocked?(board_id) do
      decision = %{
        id: "review:task:#{task.id}",
        kind: :review,
        since: usec(Reviews.waiting_since(task)),
        task_id: task.id,
        board_id: board_id,
        action: review_action(status)
      }

      AfterCommit.defer(fn -> finish([decision], via) end)
    end

    :ok
  end

  defp review_action(:approved), do: :approve
  defp review_action(:changes_requested), do: :request_changes

  @doc false
  # Records each decision and emits for those whose row went in. Public for
  # its tests; only this module calls it.
  @spec finish([decision()], via(), DateTime.t()) :: :ok
  def finish(decisions, via, now \\ DateTime.utc_now()) do
    decisions = countable(decisions)
    won = record(decisions, usec(now))

    decisions
    |> Enum.filter(&MapSet.member?(won, key(&1)))
    |> Enum.each(&emit(&1, via, now))
  end

  defp countable(decisions),
    do: decisions |> Enum.reject(&is_nil(&1.since)) |> Enum.uniq_by(& &1.id)

  defp record([], _now), do: MapSet.new()

  defp record(decisions, now) do
    rows =
      for d <- decisions do
        %{
          decision_key: d.id,
          since: d.since,
          board_id: d.board_id,
          task_id: d.task_id,
          inserted_at: now
        }
      end

    {_count, inserted} =
      Repo.insert_all(DecisionAction, rows,
        on_conflict: :nothing,
        conflict_target: [:decision_key, :since],
        returning: [:decision_key, :since]
      )

    MapSet.new(inserted, &{&1.decision_key, &1.since})
  end

  defp emit(decision, via, now) do
    metadata =
      %{kind: decision.kind, action: decision.action, via: via, board_id: decision.board_id}
      |> put_task_id(decision.task_id)

    Kanban.Telemetry.emit(
      @event,
      %{count: 1, wait_seconds: wait_seconds(decision.since, now)},
      metadata
    )
  end

  defp put_task_id(metadata, nil), do: metadata
  defp put_task_id(metadata, task_id), do: Map.put(metadata, :task_id, task_id)

  @doc false
  # The whole seconds from `since` to `now`, never below 0. Public for its
  # tests.
  @spec wait_seconds(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def wait_seconds(%DateTime{} = since, %DateTime{} = now),
    do: max(DateTime.diff(now, since, :second), 0)

  # -- reading the decisions an action touches --------------------------------

  # A reply resolves nothing, so every decision it touches is counted, once,
  # by its row. A move counts the decisions it took off the list.
  defp resolved(scope, act, before) do
    case Keyword.fetch!(act, :action) do
      :reply ->
        before

      :move ->
        still = scope |> pending(act) |> MapSet.new(&key/1)
        Enum.reject(before, &MapSet.member?(still, key(&1)))
    end
  end

  defp key(decision), do: {decision.id, decision.since}

  defp pending(%Scope{user: %{} = user} = scope, act) do
    case decision_board(act, user) do
      {:ok, board} -> scope |> Sources.context(user, [board]) |> read_pending(act)
      :error -> []
    end
  end

  defp pending(_scope, _act), do: []

  # The board the action is on, when the person is a member of it and the
  # plan unlocks it: the boards `Kanban.Decisions` reads.
  defp decision_board(act, user) do
    with {:ok, board_id} <- board_id(act),
         {:ok, %{user_access: access} = board} when not is_nil(access) <-
           Boards.get_board(board_id, user),
         true <- Plans.board_unlocked?(board) do
      {:ok, board}
    else
      _not_a_decision -> :error
    end
  end

  defp read_pending(ctx, act) do
    task_ids = act |> task_ids() |> MapSet.new()

    act
    |> sources()
    |> Enum.flat_map(fn {source, action} -> ctx |> source.() |> tag(action) end)
    |> Enum.filter(&acted_on_item?(&1, task_ids))
  end

  # A board-level decision (`:ready_empty`) is the board's; a task's is
  # touched only when the action is on that task.
  defp acted_on_item?(%{task_id: nil}, _task_ids), do: true
  defp acted_on_item?(%{task_id: task_id}, task_ids), do: MapSet.member?(task_ids, task_id)

  defp sources(act),
    do: sources(Keyword.fetch!(act, :action), Keyword.get(act, :into_ready, false))

  defp sources(:reply, _into_ready),
    do: [{&Sources.released/1, :reply}, {&Sources.hook_failed/1, :reply}]

  defp sources(:move, false),
    do: [{&Sources.released/1, :move}, {&Sources.claim_expired/1, :move}]

  defp sources(:move, true), do: sources(:move, false) ++ [{&Sources.ready_empty/1, :promote}]

  defp tag(items, action) do
    Enum.map(items, fn item ->
      %{
        id: item.id,
        kind: item.kind,
        since: usec(item.since),
        task_id: item.task_id,
        board_id: item.board_id,
        action: action
      }
    end)
  end

  defp task_ids(act) do
    case Keyword.fetch!(act, :action) do
      :reply -> [Keyword.fetch!(act, :task_id)]
      :move -> Keyword.get(act, :task_ids, [])
    end
  end

  defp board_id(act) do
    case Keyword.fetch!(act, :action) do
      :reply -> task_board_id(Keyword.fetch!(act, :task_id))
      :move -> {:ok, Keyword.fetch!(act, :board_id)}
    end
  end

  defp task_board_id(task_id) when is_integer(task_id) do
    query =
      from(t in Task, join: c in assoc(t, :column), where: t.id == ^task_id, select: c.board_id)

    case Repo.one(query) do
      nil -> :error
      board_id -> {:ok, board_id}
    end
  end

  defp task_board_id(_task_id), do: :error

  defp validate_via!(via) when via in @vias, do: via

  defp validate_via!(via),
    do: raise(ArgumentError, "unknown decision via: #{inspect(via)}")

  defp usec(%DateTime{microsecond: {us, _precision}} = at), do: %{at | microsecond: {us, 6}}
  defp usec(_at), do: nil
end
