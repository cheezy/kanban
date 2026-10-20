defmodule Kanban.Workspaces.Export.Importer.TaskChecks do
  @moduledoc """
  Checks an archive's task rows as a whole, before
  `Kanban.Workspaces.Export.Importer.Tasks` inserts any of them. The task
  changeset sees one row at a time, so it cannot see these:

    * every identifier is a letter prefix and a number (`W12`, `G3`), so no
      control or bidirectional-override character reaches the board, the
      import report or a terminal;
    * no two tasks on one board share an identifier, since dependencies and
      the API resolve a task by its identifier within its board;
    * no task is its own parent, and parent links never form a cycle;
    * a parent, or the task an archived duplicate points to, is on the same
      board as the task, so a goal page never lists another board's task.

  Only rows whose column is in the archive are checked for the last three,
  because only those are imported. A link to a task that is not imported is
  left to the importer, which skips and reports it.

  Each check returns `:ok` or `{:error, ref, reason}`, where `ref` names the
  row by its identifier, or by its 1-based place in the tasks file when the
  identifier itself is refused (so the refused bytes are never echoed).
  """

  @identifier ~r/\A[A-Z]{1,4}[0-9]{1,10}\z/

  @type failure :: {:error, String.t(), atom()}

  @doc """
  Runs every check on `rows` (the archive's task rows). `boards_by_column`
  maps each imported source column id to its source board id.
  """
  @spec check([map()], %{term() => term()}) :: :ok | failure()
  def check(rows, boards_by_column) when is_list(rows) and is_map(boards_by_column) do
    imported = Enum.filter(rows, &Map.has_key?(boards_by_column, &1["column_id"]))

    with :ok <- check_identifiers(rows),
         :ok <- check_unique_identifiers(imported, boards_by_column),
         :ok <- check_links(imported, boards_by_column) do
      check_parent_cycles(imported)
    end
  end

  @doc "True when `identifier` is a letter prefix followed by a number."
  @spec valid_identifier?(term()) :: boolean()
  def valid_identifier?(identifier) when is_binary(identifier),
    do: Regex.match?(@identifier, identifier)

  def valid_identifier?(_identifier), do: false

  @doc "Refuses a missing or malformed identifier on any row."
  @spec check_identifiers([map()]) :: :ok | failure()
  def check_identifiers(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.find_value(:ok, fn {row, index} ->
      if not valid_identifier?(row["identifier"]),
        do: {:error, "row #{index}", :invalid_identifier}
    end)
  end

  @doc "Refuses two rows on one board with the same identifier."
  @spec check_unique_identifiers([map()], map()) :: :ok | failure()
  def check_unique_identifiers(rows, boards_by_column) do
    rows
    |> Enum.reduce_while(MapSet.new(), fn row, seen ->
      key = {board_of(row, boards_by_column), row["identifier"]}

      if MapSet.member?(seen, key),
        do: {:halt, {:error, row["identifier"], :duplicate_identifier}},
        else: {:cont, MapSet.put(seen, key)}
    end)
    |> case do
      {:error, _ref, _reason} = error -> error
      _seen -> :ok
    end
  end

  @doc """
  Refuses a task that is its own parent, and a parent or duplicate link to an
  imported task on another board.
  """
  @spec check_links([map()], map()) :: :ok | failure()
  def check_links(rows, boards_by_column) do
    by_id = Map.new(rows, &{&1["id"], &1})

    Enum.find_value(rows, :ok, fn row ->
      link_error(row, "parent_id", by_id, boards_by_column) ||
        duplicate_link_error(row, by_id, boards_by_column)
    end)
  end

  defp duplicate_link_error(%{"archive_reason" => "duplicate"} = row, by_id, boards_by_column),
    do: link_error(row, "duplicate_of_id", by_id, boards_by_column)

  defp duplicate_link_error(_row, _by_id, _boards_by_column), do: nil

  defp link_error(row, field, by_id, boards_by_column) do
    target_id = row[field]
    target = target_id && Map.get(by_id, target_id)

    cond do
      is_nil(target_id) ->
        nil

      field == "parent_id" and target_id == row["id"] ->
        {:error, row["identifier"], :parent_is_itself}

      is_nil(target) ->
        nil

      board_of(target, boards_by_column) != board_of(row, boards_by_column) ->
        {:error, row["identifier"], cross_board_reason(field)}

      true ->
        nil
    end
  end

  defp cross_board_reason("parent_id"), do: :parent_on_another_board
  defp cross_board_reason("duplicate_of_id"), do: :duplicate_on_another_board

  @doc """
  Refuses parent links that loop back on themselves. Each row is walked once,
  so a long chain cannot make the check quadratic.
  """
  @spec check_parent_cycles([map()]) :: :ok | failure()
  def check_parent_cycles(rows) do
    parents = Map.new(rows, &{&1["id"], &1["parent_id"]})

    case find_cycle(parents) do
      nil -> :ok
      id -> {:error, Enum.find_value(rows, &(&1["id"] == id && &1["identifier"])), :parent_cycle}
    end
  end

  # The id of a row on a parent cycle, or nil.
  defp find_cycle(parents) do
    parents
    |> Map.keys()
    |> Enum.reduce_while(MapSet.new(), fn id, done ->
      case walk(id, parents, done, MapSet.new(), []) do
        {:ok, done} -> {:cont, done}
        {:cycle, at} -> {:halt, {:cycle, at}}
      end
    end)
    |> case do
      {:cycle, at} -> at
      _done -> nil
    end
  end

  # Follows parent links from `id` until it leaves the imported rows, meets a
  # row already cleared, or comes back to a row on this path.
  defp walk(id, parents, done, on_path, path) do
    cond do
      is_nil(id) or not Map.has_key?(parents, id) or MapSet.member?(done, id) ->
        {:ok, MapSet.union(done, MapSet.new(path))}

      MapSet.member?(on_path, id) ->
        {:cycle, id}

      true ->
        walk(Map.fetch!(parents, id), parents, done, MapSet.put(on_path, id), [id | path])
    end
  end

  defp board_of(row, boards_by_column), do: Map.get(boards_by_column, row["column_id"])
end
