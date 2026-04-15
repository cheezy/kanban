defmodule Kanban.Tasks.Identifiers do
  @moduledoc """
  Identifier generation for tasks.

  Generates sequential identifiers with type-based prefixes:
  - W (work tasks): W1, W2, W3, ...
  - D (defects): D1, D2, D3, ...
  - G (goals): G1, G2, G3, ...

  Identifiers are scoped per board and based on the maximum existing
  identifier number for the given prefix. All generation functions acquire
  a board-scoped advisory lock and MUST be called within a transaction.
  """

  import Ecto.Query, warn: false

  alias Kanban.Repo
  alias Kanban.Tasks.Task

  # Offset to avoid collisions with column-based advisory locks used by Positioning
  @lock_namespace 1_000_000

  @doc """
  Generates the next sequential identifier for a task type within a board.

  Acquires a board-scoped advisory lock to prevent concurrent generation
  of duplicate identifiers. MUST be called within a `Repo.transaction`.
  """
  def generate_identifier(board_id, task_type) do
    task_type = normalize_task_type(task_type)
    prefix = get_task_type_prefix(task_type)

    acquire_lock(board_id)

    max_number = get_max_identifier_number(board_id, prefix)
    "#{prefix}#{max_number + 1}"
  end

  @doc """
  Pre-generates identifiers for a batch of tasks.

  Acquires a board-scoped advisory lock, then reads initial max values from
  the database for each type and assigns sequential identifiers in memory.
  MUST be called within a `Repo.transaction`.
  """
  def pregenerate_task_identifiers(board_id, child_tasks_attrs) do
    acquire_lock(board_id)

    initial_counters = %{
      work: get_max_identifier_number(board_id, "W"),
      defect: get_max_identifier_number(board_id, "D"),
      goal: get_max_identifier_number(board_id, "G")
    }

    {identifiers, _final_counters} =
      Enum.map_reduce(child_tasks_attrs, initial_counters, fn attrs, counters ->
        task_type = Map.get(attrs, :type, Map.get(attrs, "type", :work))
        task_type = normalize_task_type(task_type)
        prefix = get_task_type_prefix(task_type)

        current_count = Map.get(counters, task_type)
        new_count = current_count + 1
        identifier = "#{prefix}#{new_count}"

        updated_counters = Map.put(counters, task_type, new_count)

        {identifier, updated_counters}
      end)

    identifiers
  end

  defp acquire_lock(board_id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [board_id + @lock_namespace])
  end

  defp normalize_task_type(task_type) when is_atom(task_type), do: task_type
  defp normalize_task_type("work"), do: :work
  defp normalize_task_type("defect"), do: :defect
  defp normalize_task_type("goal"), do: :goal
  defp normalize_task_type(_invalid), do: :work

  defp get_task_type_prefix(:work), do: "W"
  defp get_task_type_prefix(:defect), do: "D"
  defp get_task_type_prefix(:goal), do: "G"

  defp get_max_identifier_number(board_id, prefix) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], c.board_id == ^board_id and like(t.identifier, ^"#{prefix}%"))
    |> select([t], t.identifier)
    |> Repo.all()
    |> Enum.map(&extract_identifier_number(&1, prefix))
    |> get_max_number()
  end

  defp extract_identifier_number(identifier, prefix) do
    identifier
    |> String.replace(prefix, "")
    |> String.replace(~r/[^0-9].*$/, "")
    |> parse_number()
  end

  defp parse_number(""), do: 0
  defp parse_number(num_str), do: String.to_integer(num_str)

  defp get_max_number([]), do: 0
  defp get_max_number(numbers), do: Enum.max(numbers)
end
