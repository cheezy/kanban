defmodule Kanban.Boards.Membership do
  @moduledoc """
  Board membership queries: which users belong to which boards, and how many,
  and which personal-workspace boards are over the free-board member cap.

  These read across every user rather than a single scope, so callers must be
  admin-gated — the same constraint `Kanban.Accounts.AdminManagement` carries.

  Exposed through the `Kanban.Boards` facade via `defdelegate` — call these as
  `Boards.board_counts_by_user/0` and `Boards.over_cap_boards/0` rather than
  reaching into this module directly.
  """

  import Ecto.Query, warn: false

  alias Kanban.Boards.BoardUser
  alias Kanban.Plans
  alias Kanban.Repo

  @type over_cap_board :: %{
          board_id: pos_integer(),
          owner_user_id: pos_integer() | nil,
          member_count: pos_integer()
        }

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

  @doc """
  Returns every personal-workspace board with more members than
  `Kanban.Plans.free_board_member_cap/0`, for the pre-launch grandfathering
  report (D12).

  Members are `board_users` rows, the owner's included — the count the cap in
  `Kanban.Boards.add_user_to_board/4` uses. Org-workspace boards are never
  listed. The answer ignores `:plans_enforced`, because it reports who would be
  over the cap once enforcement is switched on.

  Each entry carries only ids and a count: `:board_id`, `:owner_user_id` (the
  user holding the board's `:owner` row, or `nil` when the board has none) and
  `:member_count`. No board name, user name or email is selected. Built from
  one aggregate query, ordered by board id. Read-only.

  ## Examples

      iex> over_cap_boards()
      [%{board_id: 12, owner_user_id: 4, member_count: 5}]

  """
  @spec over_cap_boards() :: [over_cap_board()]
  def over_cap_boards do
    cap = Plans.free_board_member_cap()

    from(bu in BoardUser,
      join: b in assoc(bu, :board),
      join: w in assoc(b, :workspace),
      where: w.personal,
      group_by: bu.board_id,
      having: count(bu.id) > ^cap,
      order_by: bu.board_id,
      select: %{
        board_id: bu.board_id,
        owner_user_id: filter(min(bu.user_id), bu.access == ^:owner),
        member_count: count(bu.id)
      }
    )
    |> Repo.all()
  end
end
