defmodule Kanban.Agents.Idle do
  @moduledoc """
  The one definition of an idle agent on a board, shared by the decision
  list's `:ready_empty` item (`Kanban.Decisions.Sources`) and the app's board
  list (`GET /api/me/boards`, W2759): an agent that worked on the board in the
  last 24 hours and is idle now.

  An agent is idle now when it holds no unarchived task in Doing or Review on
  any board the person can see, not only on this one (`Kanban.Agents.Roster`
  status `:idle`). An archived task left in Doing or Review is no current
  work, so it does not keep an agent from being idle; it still counts as the
  agent's last activity on its board. Boards the person cannot see are never
  read, so work there does not count.
  """

  alias Kanban.Agents
  alias Kanban.Agents.Agent

  @recent_seconds 24 * 60 * 60

  @doc "How long ago an agent may have last worked on a board and still count: 24 hours."
  def recent_seconds, do: @recent_seconds

  @doc """
  The `{name, owner_key}` of every agent idle now across the boards `scope`
  can see. One roster query.
  """
  @spec idle_keys(Kanban.Accounts.Scope.t()) :: MapSet.t()
  def idle_keys(scope) do
    [scope: scope]
    |> Agents.list_agents()
    |> idle_keys_from()
  end

  @doc """
  The agents of `agents` (one board's roster) that were active at or after
  `cutoff` and whose key is in `idle_keys`.
  """
  @spec recent_idle([Agent.t()], MapSet.t(), NaiveDateTime.t()) :: [Agent.t()]
  def recent_idle(agents, idle_keys, cutoff) do
    Enum.filter(
      agents,
      &(recent?(&1.last_active_at, cutoff) and MapSet.member?(idle_keys, key(&1)))
    )
  end

  @doc "The naive UTC cutoff 24 hours before `now`."
  @spec cutoff(DateTime.t()) :: NaiveDateTime.t()
  def cutoff(%DateTime{} = now),
    do: now |> DateTime.to_naive() |> NaiveDateTime.add(-@recent_seconds)

  @doc """
  The number of recently active, idle-now agents on each of `board_ids`, as
  `%{board_id => count}`, with every board present. Reads the person's tasks
  once and splits them by board, so it costs one query whatever the number of
  boards, and none for an empty list.
  """
  @spec count_by_board(Kanban.Accounts.Scope.t(), [integer()], DateTime.t()) ::
          %{integer() => non_neg_integer()}
  def count_by_board(_scope, [], _now), do: %{}

  def count_by_board(scope, board_ids, %DateTime{} = now) do
    tasks = Agents.fetch_tasks(scope: scope)
    idle = tasks |> Agents.list_agents_from() |> idle_keys_from()
    cutoff = cutoff(now)
    by_board = Enum.group_by(tasks, & &1.board_id)

    Map.new(board_ids, fn board_id ->
      count =
        by_board
        |> Map.get(board_id, [])
        |> Agents.list_agents_from()
        |> recent_idle(idle, cutoff)
        |> length()

      {board_id, count}
    end)
  end

  defp idle_keys_from(agents) do
    agents
    |> Enum.filter(&(&1.status == :idle))
    |> MapSet.new(&key/1)
  end

  defp key(agent), do: {agent.name, agent.owner_key}

  defp recent?(%NaiveDateTime{} = at, cutoff), do: NaiveDateTime.compare(at, cutoff) != :lt
  defp recent?(_at, _cutoff), do: false
end
