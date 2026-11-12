defmodule Kanban.AuditStream.AttemptPruneWorkerTest do
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditStream
  alias Kanban.AuditStream.Attempt
  alias Kanban.AuditStream.AttemptPruneWorker
  alias Kanban.AuditStream.Gap
  alias Kanban.Repo

  @now ~U[2026-11-12 12:00:00.000000Z]

  defp destination, do: organization_fixture() |> destination_fixture(:https)

  # `count` attempts for `destination`, one a minute, the newest at `newest`.
  defp attempts!(destination, count, newest \\ @now) do
    rows =
      for n <- 0..(count - 1)//1 do
        %{
          destination_id: destination.id,
          batch_id: Ecto.UUID.generate(),
          started_at: DateTime.add(newest, -n * 60, :second),
          outcome: :delivered
        }
      end

    {^count, _} = Repo.insert_all(Attempt, rows)
    :ok
  end

  defp started(destination) do
    from(a in Attempt,
      where: a.destination_id == ^destination.id,
      order_by: [desc: a.started_at],
      select: a.started_at
    )
    |> Repo.all()
  end

  describe "prune_attempts/1" do
    test "keeps newest 200 and drops older than 7 days" do
      over = destination()
      attempts!(over, 201)

      exactly = destination()
      attempts!(exactly, 200)

      week = destination()
      seven_days_ago = DateTime.add(@now, -7 * 86_400, :second)
      attempts!(week, 1, seven_days_ago)
      attempts!(week, 1, DateTime.add(seven_days_ago, -1, :microsecond))
      attempts!(week, 1)

      assert AuditStream.prune_attempts(@now) == 2

      kept = started(over)
      assert length(kept) == 200
      assert hd(kept) == @now
      assert List.last(kept) == DateTime.add(@now, -199 * 60, :second)

      assert length(started(exactly)) == 200

      # An attempt exactly 7 days old is kept; one a microsecond older is not.
      assert started(week) == [@now, seven_days_ago]

      # Running it again removes nothing.
      assert AuditStream.prune_attempts(@now) == 0
    end

    test "gaps survive pruning" do
      destination = destination()
      attempts!(destination, 1, DateTime.add(@now, -30 * 86_400, :second))
      old = DateTime.add(@now, -30 * 86_400, :second)

      gap =
        %Gap{}
        |> Gap.changeset(%{
          destination_id: destination.id,
          reason: :retention,
          events: 3,
          first_occurred_at: old,
          last_occurred_at: old,
          opened_at: old,
          last_extended_at: old
        })
        |> Repo.insert!()

      assert AuditStream.prune_attempts(@now) == 1
      assert started(destination) == []
      assert Repo.get(Gap, gap.id)
    end

    test "an Organization with no attempts prunes nothing" do
      assert AuditStream.prune_attempts(@now) == 0
    end
  end

  describe "perform/1" do
    test "prunes as of now" do
      destination = destination()
      attempts!(destination, 1, DateTime.add(DateTime.utc_now(), -8 * 86_400, :second))
      attempts!(destination, 1, DateTime.utc_now())

      assert :ok = perform_job(AttemptPruneWorker, %{})
      assert length(started(destination)) == 1
    end
  end
end
