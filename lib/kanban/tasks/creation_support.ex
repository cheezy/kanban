defmodule Kanban.Tasks.CreationSupport do
  @moduledoc """
  Helpers shared by the single-task path (`Kanban.Tasks.Creation`) and the
  goal path (`Kanban.Tasks.GoalCreation`).

  Creation attrs arrive with either string keys (from params) or atom keys
  (from code), so every helper that adds a key writes it in the style the
  attrs already use.
  """

  alias Kanban.Tasks.Task

  @doc """
  The struct a new task in `column` is built from. A task created straight
  into Review starts waiting for review now, so an edit does not reset its age
  (`Kanban.Reviews.waiting_since/1`, D348).
  """
  def new_task(%{id: id, name: "Review"}),
    do: %Task{column_id: id, review_requested_at: DateTime.utc_now(:second)}

  def new_task(column), do: %Task{column_id: column.id}

  @doc """
  Puts `position` into `attrs`, matching their key style.

  ## Examples

      iex> put_position(%{"title" => "T"}, 3)
      %{"title" => "T", "position" => 3}

      iex> put_position(%{title: "T"}, 3)
      %{title: "T", position: 3}

  """
  def put_position(attrs, position), do: put_matching(attrs, "position", :position, position)

  @doc """
  Whether `attrs` name an assignee themselves (including an explicit `nil`),
  in which case no assignee is inherited from a parent goal.

  ## Examples

      iex> assigned_to_id_explicit?(%{"assigned_to_id" => nil})
      true

      iex> assigned_to_id_explicit?(%{title: "T"})
      false

  """
  def assigned_to_id_explicit?(attrs) do
    Map.has_key?(attrs, :assigned_to_id) or Map.has_key?(attrs, "assigned_to_id")
  end

  @doc """
  Puts `assigned_id` into `attrs` as the assignee, matching their key style.

  ## Examples

      iex> put_assigned_to_id(%{"title" => "T"}, 7)
      %{"title" => "T", "assigned_to_id" => 7}

  """
  def put_assigned_to_id(attrs, assigned_id),
    do: put_matching(attrs, "assigned_to_id", :assigned_to_id, assigned_id)

  @doc """
  Calls the `:before_broadcast` function in `opts` with `args`, if there is
  one. The create paths run it after the rows are written and before
  `:task_created` is broadcast.

  ## Examples

      iex> run_before_broadcast([], [:task])
      :ok

      iex> run_before_broadcast([before_broadcast: fn task -> {:ran, task} end], [:task])
      {:ran, :task}

  """
  def run_before_broadcast(opts, args) do
    case Keyword.get(opts, :before_broadcast) do
      nil -> :ok
      fun -> apply(fun, args)
    end
  end

  defp put_matching(attrs, string_key, atom_key, value) do
    if attrs |> Map.keys() |> Enum.any?(&is_binary/1),
      do: Map.put(attrs, string_key, value),
      else: Map.put(attrs, atom_key, value)
  end
end
