defmodule Kanban.Decisions.HoldsUp do
  @moduledoc """
  Finds the tasks a decision holds up
  (`docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md` §7.4).

  A task is held up by a root identifier when it depends on that identifier
  directly, or through a chain of other tasks, following each task's
  `dependencies` (the same identifiers `Kanban.Tasks.Dependencies` reads).

    * Only unfinished, unarchived tasks count: a task whose `status` is
      `:completed`, or whose `archived_at` is set, is left out, and a chain
      stops there, since a finished task no longer waits on anything.
    * The chain is followed to a depth of 5: a task five links away is
      held up, a task six links away is not.
    * At most 50 held tasks are returned for a root, the shallowest first,
      then by task id, which is creation order.
    * A root never holds itself up, and a dependency cycle ends at the depth
      limit rather than looping.

  Identifiers are unique only within a board, so every level of the chain is
  matched on the root's board alone and a task on another board that happens
  to share an identifier is never counted.

  ## Scope

  This module does no access check of its own. The caller,
  `Kanban.Decisions`, passes only boards the person can see, so a count never
  reveals the size of work on a board hidden from them.

  ## Board totals

  Alongside each root's capped list, the result carries every distinct task
  held up on each board by any of its roots, without the per-root cap, so a
  total across several roots is never cut short by one root reaching it.

  ## Cost

  One recursive query per board that has at least one root, and none at all
  when no board has a root.
  """

  alias Kanban.Repo

  @max_depth 5
  @cap 50

  # $1 board id, $2 root identifiers, $3 maximum depth, $4 cap per root.
  #
  # `live` holds the board's unfinished, unarchived tasks. `held` walks the
  # dependents of each root: UNION drops repeated rows and the depth bound ends
  # every path, so a cycle terminates. `ranked` keeps each task once per root,
  # at its shallowest depth. The rows with a NULL root carry the board's
  # distinct held tasks across every root, uncapped.
  @held_sql """
  WITH RECURSIVE live AS (
    SELECT t.id, t.identifier, t.dependencies
    FROM tasks t
    JOIN columns c ON c.id = t.column_id
    WHERE c.board_id = $1
      AND t.archived_at IS NULL
      AND t.status <> 'completed'
  ),
  held(root, id, identifier, depth) AS (
    SELECT r.root, l.id, l.identifier, 1
    FROM unnest($2::varchar[]) AS r(root)
    JOIN live l ON r.root = ANY(l.dependencies)
    WHERE l.identifier <> r.root
    UNION
    SELECT h.root, l.id, l.identifier, h.depth + 1
    FROM held h
    JOIN live l ON h.identifier = ANY(l.dependencies)
    WHERE h.depth < $3
      AND l.identifier <> h.root
  ),
  ranked AS (
    SELECT root, identifier,
           row_number() OVER (PARTITION BY root ORDER BY MIN(depth), id) AS row_n
    FROM held
    GROUP BY root, id, identifier
  )
  SELECT root, identifier, row_n
  FROM ranked
  WHERE row_n <= $4
  UNION ALL
  SELECT DISTINCT NULL::varchar, identifier, 0::bigint
  FROM held
  ORDER BY 1, 3, 2
  """

  @doc "The most held tasks counted for one root."
  @spec cap() :: pos_integer()
  def cap, do: @cap

  @doc "How many links of a dependency chain are followed."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc """
  Returns the tasks the given roots hold up.

  Takes a map of board id to the root identifiers on that board, and returns:

    * `:roots` - keyed by `{board_id, root_identifier}`, the identifiers each
      root holds up, the shallowest first, then by task id, at most `cap/0`
      of them. A root that holds nothing up is left out.
    * `:boards` - keyed by board id, every distinct identifier held up by any
      root on that board, with no per-root cap. A board whose roots hold
      nothing up is left out.
  """
  @spec held(%{optional(integer()) => [String.t()]}) :: %{
          roots: %{optional({integer(), String.t()}) => [String.t()]},
          boards: %{optional(integer()) => [String.t()]}
        }
  def held(roots_by_board) when is_map(roots_by_board) do
    roots_by_board
    |> Enum.reject(fn {_board_id, roots} -> roots == [] end)
    |> Enum.reduce(%{roots: %{}, boards: %{}}, fn {board_id, roots}, acc ->
      {by_root, all} = board_held(board_id, Enum.uniq(roots))

      %{
        roots: Map.merge(acc.roots, by_root),
        boards: put_board(acc.boards, board_id, all)
      }
    end)
  end

  defp board_held(board_id, roots) do
    %{rows: rows} = Repo.query!(@held_sql, [board_id, roots, @max_depth, @cap])
    {all, by_root} = Enum.split_with(rows, &board_total_row?/1)

    {Enum.group_by(by_root, &root_key(board_id, &1), &held_identifier/1),
     Enum.map(all, &held_identifier/1)}
  end

  defp board_total_row?([root | _rest]), do: is_nil(root)

  defp root_key(board_id, [root | _rest]), do: {board_id, root}

  defp held_identifier([_root, identifier, _row_n]), do: identifier

  defp put_board(boards, _board_id, []), do: boards
  defp put_board(boards, board_id, all), do: Map.put(boards, board_id, all)
end
