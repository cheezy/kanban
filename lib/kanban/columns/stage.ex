defmodule Kanban.Columns.Stage do
  @moduledoc """
  Which stage of work a board column stands for: `:not_started`,
  `:in_progress` or `:done`.

  A task's status follows the column it is moved into, and goal interventions
  only touch children that have not started, so both need to know a column's
  stage. AI-optimized boards use five fixed column names, which decide it
  directly. Custom boards can name columns anything, and every unknown name
  used to count as in progress, so a custom board's "To Do" column marked each
  task dropped into it as started.

  The rule, applied to one board's columns:

    1. A known name decides, ignoring case and surrounding spaces: Backlog and
       Ready are `:not_started`, Doing and Review are `:in_progress`, Done is
       `:done`.
    2. Any other name is `:not_started` when it sits before (has a lower
       position than) the board's first Doing or Review column, and
       `:in_progress` otherwise. "To Do | Doing | Done" and
       "Backlog | Refinement | Doing" both read the way they look.
    3. On a board with no Doing or Review column, only the board's first
       column is `:not_started`; other unknown names are `:in_progress`.
  """

  import Ecto.Query

  alias Kanban.Columns.Column
  alias Kanban.Repo

  @type stage :: :not_started | :in_progress | :done

  @known_stages %{
    "backlog" => :not_started,
    "ready" => :not_started,
    "doing" => :in_progress,
    "review" => :in_progress,
    "done" => :done
  }

  @doc """
  The stage a column name decides on its own, or `nil` for a custom name.
  """
  @spec known_stage(term()) :: stage() | nil
  def known_stage(name) when is_binary(name),
    do: Map.get(@known_stages, name |> String.trim() |> String.downcase())

  def known_stage(_name), do: nil

  @doc """
  Classifies one board's columns, returning `%{column_id => stage}`. Each
  column needs `:id`, `:name` and `:position`.
  """
  @spec classify([map()]) :: %{optional(term()) => stage()}
  def classify(columns) do
    sorted = Enum.sort_by(columns, & &1.position)
    first_in_progress = Enum.find(sorted, &(known_stage(&1.name) == :in_progress))
    first_id = first_column_id(sorted)

    Map.new(sorted, fn column ->
      {column.id, known_stage(column.name) || custom_stage(column, first_in_progress, first_id)}
    end)
  end

  defp first_column_id([%{id: id} | _]), do: id
  defp first_column_id([]), do: nil

  defp custom_stage(%{position: position}, %{position: anchor}, _first_id),
    do: if(position < anchor, do: :not_started, else: :in_progress)

  defp custom_stage(%{id: id}, nil, id), do: :not_started
  defp custom_stage(_column, nil, _first_id), do: :in_progress

  @doc """
  The stage of `column`, reading its board's other columns only when its own
  name does not decide it.
  """
  @spec for_column(Column.t()) :: stage()
  def for_column(%Column{} = column) do
    case known_stage(column.name) do
      nil -> column.board_id |> board_columns() |> classify() |> Map.get(column.id, :in_progress)
      stage -> stage
    end
  end

  @doc """
  The ids of the board's `:not_started` columns.
  """
  @spec not_started_column_ids(term()) :: [term()]
  def not_started_column_ids(board_id) do
    for {id, :not_started} <- board_id |> board_columns() |> classify(), do: id
  end

  defp board_columns(board_id) do
    from(c in Column,
      where: c.board_id == ^board_id,
      select: %{id: c.id, name: c.name, position: c.position}
    )
    |> Repo.all()
  end
end
