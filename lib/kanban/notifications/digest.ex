defmodule Kanban.Notifications.Digest do
  @moduledoc """
  Builds the content of one user's weekly digest.

  Everything is read through the user's own access: boards come from
  `Kanban.Boards.list_boards_with_metrics/2` and pending reviews from
  `Kanban.Reviews.list_pending_reviews/1` with the user's scope, so a digest
  never mentions a board the user is not a member of.

  The window is the last full ISO week before `now`: Monday 00:00 to the
  following Monday 00:00 UTC. The cron sends on Mondays, so consecutive
  digests tile with no gap or overlap whatever hour they run. "Done" counts
  work tasks and defects whose `completed_at` falls in the window, except
  those still in a Review column; completed goals are counted separately.
  Archived tasks still count, since they were finished that week. Pending
  reviews are a snapshot at `now`, each aged from
  `Kanban.Reviews.waiting_since/1` as on the /review page.

  `build/2` returns `:empty` when the user has no boards, or nothing was
  done and nothing is waiting for review, so quiet weeks send no email.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Boards
  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Reviews
  alias Kanban.Tasks.Task

  @window_days 7
  @max_boards 10
  @max_reviews 5
  @review_column "Review"

  @type board_row :: %{
          id: pos_integer(),
          name: String.t(),
          open: non_neg_integer(),
          doing: non_neg_integer(),
          review: non_neg_integer(),
          done_this_week: non_neg_integer(),
          goals_completed: non_neg_integer()
        }

  @type review_row :: %{
          identifier: String.t() | nil,
          title: String.t(),
          board_id: pos_integer(),
          board_name: String.t(),
          age_hours: non_neg_integer()
        }

  @type t :: %{
          window_start: Date.t(),
          window_end: Date.t(),
          boards: [board_row()],
          more_boards: non_neg_integer(),
          tasks_done: non_neg_integer(),
          goals_completed: non_neg_integer(),
          reviews: %{
            count: non_neg_integer(),
            oldest_age_hours: non_neg_integer() | nil,
            oldest: [review_row()]
          }
        }

  @doc """
  Builds the digest for `user`, or returns `:empty` when there is nothing
  to send.

  ## Options

    * `:now` — the digest covers the full ISO week before this moment
      (defaults to the current time).
  """
  @spec build(User.t(), keyword()) :: :empty | t()
  def build(%User{} = user, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case Boards.list_boards_with_metrics(user, now: now) do
      [] -> :empty
      boards -> boards |> summarize(user, now) |> empty_if_quiet()
    end
  end

  @doc """
  Returns the ISO 8601 week of `datetime` as `"YYYY-Www"`, using the ISO
  week-numbering year (so 2027-01-01 is `"2026-W53"`).
  """
  @spec iso_week(DateTime.t()) :: String.t()
  def iso_week(%DateTime{} = datetime) do
    {year, week} =
      datetime
      |> DateTime.to_date()
      |> Date.to_erl()
      |> :calendar.iso_week_number()

    "#{year}-W#{week |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  @doc """
  Reads the `"now"` job argument (ISO 8601) the digest workers carry,
  falling back to the current time when it is missing or invalid.
  Truncated to the second.
  """
  @spec parse_now(map()) :: DateTime.t()
  def parse_now(%{"now" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _error -> utc_now()
    end
  end

  def parse_now(_args), do: utc_now()

  defp utc_now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp summarize(boards, user, now) do
    {from, to} = window(now)

    boards
    |> board_rows(from, to)
    |> board_summary()
    |> Map.merge(%{
      window_start: from,
      window_end: Date.add(to, -1),
      reviews: pending_reviews(user, now)
    })
  end

  # [from, to): the full ISO week before the one `now` falls in.
  defp window(now) do
    to = now |> DateTime.to_date() |> Date.beginning_of_week()
    {Date.add(to, -@window_days), to}
  end

  defp board_rows(boards, from, to) do
    completed = completed_by_board(boards, from, to)

    boards
    |> Enum.map(&board_row(&1, completed))
    |> Enum.sort_by(&board_sort_key/1)
  end

  defp board_summary(rows) do
    %{
      boards: Enum.take(rows, @max_boards),
      more_boards: max(length(rows) - @max_boards, 0),
      tasks_done: sum_of(rows, :done_this_week),
      goals_completed: sum_of(rows, :goals_completed)
    }
  end

  defp sum_of(rows, key), do: rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum()

  defp empty_if_quiet(%{tasks_done: 0, goals_completed: 0, reviews: %{count: 0}}), do: :empty
  defp empty_if_quiet(digest), do: digest

  # Returns %{{board_id, :tasks | :goals} => count} for [from, to) in UTC.
  # The board ids come from the user-scoped board list.
  defp completed_by_board(boards, from_date, to_date) do
    boards
    |> Enum.map(& &1.id)
    |> completed_query(midnight(from_date), midnight(to_date))
    |> Repo.all()
    |> Enum.reduce(%{}, &count_completed/2)
  end

  defp completed_query(board_ids, from, to) do
    Task
    |> join(:inner, [t], c in Column, on: c.id == t.column_id)
    |> where([t, c], c.board_id in ^board_ids and c.name != @review_column)
    |> where([t], t.completed_at >= ^from and t.completed_at < ^to)
    |> group_by([t, c], [c.board_id, t.type])
    |> select([t, c], {c.board_id, t.type, count(t.id)})
  end

  defp midnight(date), do: DateTime.new!(date, ~T[00:00:00])

  defp count_completed({board_id, type, count}, acc) do
    Map.update(acc, {board_id, completed_kind(type)}, count, &(&1 + count))
  end

  defp completed_kind(:goal), do: :goals
  defp completed_kind(_type), do: :tasks

  defp board_row(board, completed) do
    %{
      id: board.id,
      name: board.name,
      open: board.metrics.open,
      doing: board.metrics.doing,
      review: board.metrics.review,
      done_this_week: Map.get(completed, {board.id, :tasks}, 0),
      goals_completed: Map.get(completed, {board.id, :goals}, 0)
    }
  end

  # Busiest boards first: most done this week, then most work in flight.
  defp board_sort_key(row) do
    {-row.done_this_week, -(row.open + row.doing + row.review), String.downcase(row.name), row.id}
  end

  defp pending_reviews(user, now) do
    tasks = Reviews.list_pending_reviews(scope: Scope.for_user(user))
    oldest = tasks |> Enum.take(@max_reviews) |> Enum.map(&review_row(&1, now))

    %{count: length(tasks), oldest_age_hours: oldest_age(oldest), oldest: oldest}
  end

  defp review_row(task, now) do
    %{
      identifier: task.identifier,
      title: task.title,
      board_id: task.column.board.id,
      board_name: task.column.board.name,
      age_hours: task |> Reviews.waiting_since() |> hours_since(now)
    }
  end

  defp hours_since(since, now), do: now |> DateTime.diff(since, :hour) |> max(0)

  defp oldest_age([first | _rest]), do: first.age_hours
  defp oldest_age([]), do: nil
end
