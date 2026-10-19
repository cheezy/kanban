defmodule Mix.Tasks.Kanban.OverCapBoards do
  @shortdoc "Reports personal-workspace boards over the free member cap"

  @moduledoc """
  Lists every personal-workspace board with more members than
  `Kanban.Plans.free_board_member_cap/0`, through
  `Kanban.Boards.over_cap_boards/0`, so the team knows which boards are
  grandfathered before plan enforcement launches (D12, W2402).

  Prints a summary line and one line per board with its board id, owner user
  id and member count, or a message that no board is over the cap. It prints
  no board name, user name or email; look an owner up in `/admin/users` by id.

  ## Usage

      mix kanban.over_cap_boards

  It takes no arguments and refuses any it is given. It starts only the
  database connection (`Ecto.Migrator.with_repo/2`), not the application, so
  Oban and the other workers never run while it reports. Read-only: it never
  changes a board or a membership. In a production release, where Mix is not
  available, run `Kanban.Release.report_over_cap_boards/0` with
  `bin/kanban eval` instead.
  """
  use Mix.Task

  alias Kanban.Boards
  alias Kanban.Plans
  alias Kanban.Repo

  @impl Mix.Task
  def run([]) do
    Mix.Task.run("app.config")
    {:ok, boards, _apps} = Ecto.Migrator.with_repo(Repo, fn _repo -> Boards.over_cap_boards() end)
    report(boards)
  end

  def run(args) do
    Mix.raise(
      "mix kanban.over_cap_boards takes no arguments, got: #{Enum.join(args, " ")}. " <>
        "See mix help kanban.over_cap_boards."
    )
  end

  defp report([]) do
    Mix.shell().info(
      "No personal-workspace boards are over the free member cap of #{Plans.free_board_member_cap()}."
    )

    :ok
  end

  defp report(boards) do
    Mix.shell().info(
      "#{length(boards)} personal-workspace board(s) over the free member cap of #{Plans.free_board_member_cap()}:"
    )

    Enum.each(boards, fn board ->
      Mix.shell().info(
        "  board #{board.board_id} — owner user #{owner(board.owner_user_id)}, #{board.member_count} members"
      )
    end)

    :ok
  end

  defp owner(nil), do: "none"
  defp owner(user_id), do: user_id
end
