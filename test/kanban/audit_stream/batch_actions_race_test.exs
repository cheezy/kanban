defmodule Kanban.AuditStream.BatchActionsRaceTest do
  @moduledoc """
  **Retry now** and **Skip this batch** with real, committing connections:
  an org-admin who loses the role after the pre-check has passed and the
  lease is taken, but before the locked re-check, is refused, and the halt,
  the cursor and the lease are left as they were
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.4, §10.4). The sandboxed
  suite shares one connection, so a row lock never blocks there and only
  the pre-check can be tested.

  ## Running

  Tagged `:audit_stream_race`, which `test/test_helper.exs` excludes. It
  commits Organizations and users, so it runs only in the throwaway race
  database:

      dropdb --if-exists kanban_test_race
      MIX_TEST_PARTITION=_race MIX_ENV=test mix test --only audit_stream_race test/kanban/audit_stream/batch_actions_race_test.exs
      dropdb kanban_test_race
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.AuditStreamFixtures
  import Kanban.OrganizationsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Kanban.Accounts.Scope
  alias Kanban.AuditStream
  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  @moduletag :audit_stream_race
  @moduletag timeout: 120_000

  @await_ms 30_000

  setup_all do
    database = Repo.config()[:database]

    unless String.ends_with?(database, "_race") do
      raise """
      #{inspect(__MODULE__)} commits rows it never deletes, so it runs only in \
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
      organization_fixture(%{name: "audit-batch-race #{System.unique_integer([:positive])}"})

    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)
    destination = destination_fixture(organization, :https)

    from(c in Cursor, where: c.destination_id == ^destination.id)
    |> Repo.update_all(
      set: [
        pending_batch_id: Ecto.UUID.generate(),
        pending_first_txid: 5,
        pending_first_id: 1,
        pending_last_txid: 6,
        pending_last_id: 2,
        pending_attempts: 3,
        pending_filter_version: 1
      ]
    )

    from(d in Destination, where: d.id == ^destination.id)
    |> Repo.update_all(set: [state: :failing, halted_reason: :rejected_batch])

    %{organization: organization, admin: admin, destination: destination}
  end

  # Holds the Organization row, which the locked re-check takes first, until
  # told to remove the admin; then commits the removal and the lock goes. Each
  # task checks out its own connection, so the lock really blocks.
  defp hold_organization(ctx) do
    test = self()

    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      Repo.transaction(fn ->
        from(o in Organization, where: o.id == ^ctx.organization.id, lock: "FOR UPDATE")
        |> Repo.one!()

        send(test, :holding)

        receive do
          :remove -> :ok
        after
          @await_ms -> raise "never told to remove the admin"
        end

        from(m in OrganizationMember, where: m.user_id == ^ctx.admin.id) |> Repo.delete_all()
      end)
    end)
  end

  defp leased?(destination), do: Repo.get!(Cursor, destination.id).lease_token != nil

  defp await_lease(destination, deadline \\ @await_ms) do
    cond do
      leased?(destination) ->
        :ok

      deadline <= 0 ->
        flunk("the action never took the lease")

      true ->
        Process.sleep(10)
        await_lease(destination, deadline - 10)
    end
  end

  for action <- [:skip_batch, :retry_now] do
    test "#{action} is refused for an org-admin removed after the pre-check", ctx do
      holder = hold_organization(ctx)
      assert_receive :holding, @await_ms

      scope = Scope.for_user(ctx.admin)

      press =
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)
          apply(AuditStream, unquote(action), [scope, ctx.destination])
        end)

      # The lease is taken only after the pre-check passed, so the action is
      # now past it and waiting on the Organization row.
      await_lease(ctx.destination)
      send(holder.pid, :remove)

      assert {:ok, _removed} = Task.await(holder, @await_ms)
      assert {:error, :unauthorized} = Task.await(press, @await_ms)

      assert Repo.get!(Destination, ctx.destination.id).halted_reason == :rejected_batch
      cursor = Repo.get!(Cursor, ctx.destination.id)
      assert cursor.pending_attempts == 3
      assert cursor.lease_token == nil
    end
  end
end
