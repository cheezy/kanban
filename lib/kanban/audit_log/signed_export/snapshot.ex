defmodule Kanban.AuditLog.SignedExport.Snapshot do
  @moduledoc """
  The one database snapshot a signed audit export reads its events from.

  `read/1` runs the read inside one `REPEATABLE READ, READ ONLY` transaction,
  the way `Kanban.Workspaces.Export.Writer` reads a workspace. Every batch of
  `Kanban.AuditLog.Export.batches/2` then sees the same committed state, so
  the file is one point in time rather than whatever each batch happened to
  find.

  The transaction covers the read only. `Kanban.AuditLog.SignedExport` signs,
  zips and hands the archive to the caller's function after it has ended, so
  a slow download never holds a snapshot or a pool connection.

  ## The boundary

  `read/1` returns the boundary with the read's result: the UTC time, in
  microseconds, taken just after the isolation level is set and before the
  first read, which is the statement that takes the snapshot. The manifest
  records it as `snapshot_at`. Every event committed before it is visible to
  the read. An event committed after it is not, whatever its `inserted_at`,
  except one that commits in the instant between the stamp and that first
  read.

  ## Bounds

  A snapshot holds back VACUUM for as long as it lasts, for every tenant, so
  the transaction has a timeout: #{div(:timer.minutes(1), 1000)} seconds. A
  signed build of 50,000 rows, the default cap, measured 0.9 to 3.3 seconds
  on development machines (W2698, D424), so the bound is far above a normal
  build and still short. The time spent waiting for a pool connection after
  the slot is granted counts toward it, as do the file writes inside the
  read. A build that runs past it fails and nothing is left: one still in a
  statement loses its connection, and one past its last statement throws
  `{:signed_export, :timeout}`. The export rate limit (10 an hour per
  org-admin, shared by signed and unsigned exports) bounds how often one
  org-admin can start one, and `Kanban.AuditLog.SignedExport.Slots` bounds
  how many run at once on each application server, across every tenant, so
  a burst cannot take every pool connection. A read waits for its slot
  before the transaction starts, holding no connection, and one that waits
  too long throws `{:signed_export, :busy}`, which fails the build.

  ## The switch

  The test sandbox runs every transaction nested inside its own, where the
  level can no longer be set, so
  `config :kanban, #{inspect(__MODULE__)}, snapshot_isolation: false` turns
  the isolation request off. The read then still runs in one transaction and
  still returns a boundary. A `timeout:` in milliseconds under the same key
  replaces the 60 seconds, so a test can cross the bound quickly. The switch has its own key, apart from
  `Kanban.AuditLog.SignedExport`'s `tmp_root`, so a test that replaces that
  config does not turn isolation back on.
  """

  alias Kanban.AuditLog.SignedExport.Slots
  alias Kanban.Repo

  @timeout :timer.minutes(1)

  @doc """
  Runs `fun` inside the export's snapshot, in a slot of `slots`, and returns
  `{boundary, result}`, `boundary` being the ISO 8601 UTC time described in
  the moduledoc. Throws `{:signed_export, :busy}` without running `fun` when
  no slot came free in time, and `{:signed_export, :timeout}` when the
  timeout fires after `fun` has issued its last statement.

  Whatever `fun` raises, throws or exits with rolls the transaction back and
  is re-raised, thrown or exited here. Must not be called inside another
  transaction: the isolation level can only be set at a transaction's start.
  """
  @spec read((-> result), GenServer.server()) :: {String.t(), result} when result: var
  def read(fun, slots \\ Slots) when is_function(fun, 0) do
    case Slots.with_slot(slots, fn -> transaction(fun) end) do
      {:ok, read} -> read
      {:error, :busy} -> throw({:signed_export, :busy})
    end
  end

  # The read never rolls itself back, so a rollback here is the timeout
  # firing after the read's last statement returned: DBConnection then
  # rolls back and returns {:error, :rollback} instead of raising.
  defp transaction(fun) do
    case Repo.transaction(fn -> isolated(fun) end, timeout: timeout()) do
      {:ok, read} -> read
      {:error, :rollback} -> throw({:signed_export, :timeout})
    end
  end

  defp timeout, do: Keyword.get(settings(), :timeout, @timeout)

  defp settings, do: Application.get_env(:kanban, __MODULE__, [])

  defp isolated(fun) do
    isolate()
    boundary = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    {boundary, fun.()}
  end

  defp isolate do
    if Keyword.get(settings(), :snapshot_isolation, true) do
      Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
    end

    :ok
  end
end
