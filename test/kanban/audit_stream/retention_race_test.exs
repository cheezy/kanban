defmodule Kanban.AuditStream.RetentionRaceTest do
  @moduledoc """
  The audit stream gap steps around a retention purge
  (`Kanban.AuditStream.Retention`) against a dispatch running at the same
  time, with every row committed: a purge that fails after its delete has
  committed still records the gap, and leaves no lease behind to stop the
  next dispatch (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.6).

  ## Running

  Tagged `:audit_stream_race`, which `test/test_helper.exs` excludes. The
  rows these tests commit stay behind, so they run only in the throwaway race
  database:

      dropdb --if-exists kanban_test_race
      MIX_TEST_PARTITION=_race MIX_ENV=test mix test --only audit_stream_race test/kanban/audit_stream/retention_race_test.exs
      dropdb kanban_test_race
  """
  use ExUnit.Case, async: false

  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.AuditLog
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.DispatchWorker
  alias Kanban.AuditStream.Gap
  alias Kanban.AuditStream.Retention
  alias Kanban.Repo
  alias Kanban.Webhooks.Transport

  @moduletag :audit_stream_race
  @moduletag timeout: 120_000

  @await_ms 30_000
  @day 24 * 60 * 60

  setup_all do
    database = Repo.config()[:database]

    unless String.ends_with?(database, "_race") do
      raise """
      #{inspect(__MODULE__)} commits rows that stay behind, so it runs only in \
      the throwaway kanban_test_race database, not #{database}:

          dropdb --if-exists kanban_test_race
          MIX_TEST_PARTITION=_race MIX_ENV=test mix test --only audit_stream_race #{Path.relative_to_cwd(__ENV__.file)}
          dropdb kanban_test_race
      """
    end

    :ok
  end

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    organization =
      organization_fixture(%{name: "audit-retention-race #{System.unique_integer([:positive])}"})

    %{organization: organization, destination: destination_fixture(organization, :https)}
  end

  defp event!(organization, txid, inserted_at) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO audit_events (action, organization_id, metadata, inserted_at, txid)
        VALUES ('organization_updated', $1, '{}', $2, $3) RETURNING id
        """,
        [organization.id, inserted_at, txid]
      )

    id
  end

  defp days_ago(days), do: NaiveDateTime.add(NaiveDateTime.utc_now(), -days * @day, :second)

  defp cutoff, do: DateTime.add(DateTime.utc_now(), -120 * @day, :second)

  defp run(destination),
    do: DispatchWorker.perform(%Oban.Job{args: %{"destination_id" => destination.id}})

  defp cursor(destination), do: Repo.get!(Cursor, destination.id)

  defp gaps(destination),
    do: from(g in Gap, where: g.destination_id == ^destination.id) |> Repo.all()

  # A purge that deletes, tells the test, and throws once the test says so,
  # with the delete already committed.
  defp start_failing_purge(organization, cutoff) do
    test = self()

    task =
      Task.async(fn ->
        catch_throw(
          Retention.purge(
            organization.id,
            cutoff,
            fn _keep_alive ->
              {:ok, removed} = AuditLog.purge_organization_before(organization.id, cutoff, 1_000)
              send(test, {:deleted, self(), removed})

              receive do
                :fail -> throw(:purge_failed)
              after
                @await_ms -> throw(:timed_out)
              end
            end,
            lease_wait_ms: 0
          )
        )
      end)

    assert_receive {:deleted, purger, 1}, @await_ms
    {task, purger}
  end

  test "a failing purge racing a dispatch leaves no stuck lease and no lost gap", ctx do
    event!(ctx.organization, 1, days_ago(200))
    event!(ctx.organization, 2, days_ago(1))
    test = self()

    Req.Test.stub(Transport, fn conn ->
      send(test, :posting)
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    {task, purger} = start_failing_purge(ctx.organization, cutoff())

    # While the purge holds the lease, a dispatch sends nothing and comes back
    # later.
    assert {:snooze, _seconds} = run(ctx.destination)
    refute_received :posting

    send(purger, :fail)
    assert Task.await(task, @await_ms) == :purge_failed

    assert [%Gap{reason: :retention, events: 1}] = gaps(ctx.destination)
    assert cursor(ctx.destination).lease_token == nil

    # With the lease released, the next dispatch sends at once.
    assert :ok = run(ctx.destination)
    assert_received :posting
    assert cursor(ctx.destination).lease_token == nil
  end
end
