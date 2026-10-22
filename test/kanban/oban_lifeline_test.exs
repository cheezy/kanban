defmodule Kanban.ObanLifelineTest do
  @moduledoc """
  Oban's Lifeline (decided 2026-10-22): a job left in `executing`, such as one
  whose node was killed mid-send, goes back to `available` after an hour, or
  to `discarded` once its attempts are used up.
  """
  # Not async: the Oban instance started here reaches the database from its
  # own processes, so the sandbox runs in shared mode.
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures

  alias Kanban.Notifications.AnnouncementWorker

  defp configured_lifeline,
    do:
      "config/config.exs" |> Config.Reader.read!(env: :prod) |> get_in([:kanban, Oban, :lifeline])

  test "config.exs rescues jobs left executing for an hour" do
    assert configured_lifeline() == [rescue_after: {60, :minutes}]
  end

  test "an orphaned announcement job is run again, or discarded once its attempts are used up" do
    two_hours_ago = DateTime.add(DateTime.utc_now(), -2, :hour)
    orphan = executing_job(attempt: 1, attempted_at: two_hours_ago)
    spent = executing_job(attempt: 3, attempted_at: two_hours_ago)
    running = executing_job(attempt: 1, attempted_at: DateTime.utc_now())

    start_supervised!(
      {Oban,
       name: __MODULE__.Oban,
       repo: Repo,
       queues: false,
       plugins: [],
       stager: false,
       notifier: Oban.Notifiers.Isolated,
       peer: {Oban.Peers.Isolated, leader?: true},
       lifeline: Keyword.put(configured_lifeline(), :interval, 20)}
    )

    assert eventually(fn -> state(orphan) == "available" end)
    assert state(spent) == "discarded"
    assert state(running) == "executing"
  end

  defp executing_job(attrs) do
    %{user_id: user_fixture().id, key: "organizations-launch"}
    |> AnnouncementWorker.new()
    |> Ecto.Changeset.change(
      [state: "executing", attempted_by: ["killed-node"]] ++ Keyword.new(attrs)
    )
    |> Repo.insert!()
  end

  defp state(job), do: Repo.reload!(job).state

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end
end
