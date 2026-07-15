defmodule Kanban.Boards.Membership do
  @moduledoc """
  Board membership queries: which users belong to which boards, and how many.

  These read across every user rather than a single scope, so callers must be
  admin-gated — the same constraint `Kanban.Accounts.AdminManagement` carries.

  Exposed through the `Kanban.Boards` facade via `defdelegate` — call these as
  `Boards.board_counts_by_user/0` rather than reaching into this module directly.
  """

  import Ecto.Query, warn: false

  alias Kanban.Boards.BoardUser
  alias Kanban.Repo

  @doc """
  Returns a map of `%{user_id => board_count}` for every user who belongs to at
  least one board.

  Built for listing many users at once: it answers the whole page in one query,
  so callers must not fall back to a per-user count. Users with no boards are
  absent from the map rather than present with `0` — look them up with a
  default, e.g. `Map.get(counts, user.id, 0)`.

  ## Examples

      iex> board_counts_by_user()
      %{1 => 3, 2 => 1}

  """
  def board_counts_by_user do
    BoardUser
    |> group_by([bu], bu.user_id)
    |> select([bu], {bu.user_id, count(bu.id)})
    |> Repo.all()
    |> Map.new()
  end
end
