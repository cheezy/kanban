defmodule Kanban.AuditStream.Retention.Leases do
  @moduledoc """
  The leases `Kanban.AuditStream.Retention` holds on an Organization's
  destinations while the purge counts and deletes
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.6), so no run sends
  meanwhile. Each is a `Kanban.AuditStream.Lease`, taken, renewed and
  released as a list of `{destination_id, token}` pairs.
  """

  alias Kanban.AuditStream.Lease

  @typedoc "The leases taken: one `{destination_id, token}` pair per destination."
  @type leases :: [{integer(), Ecto.UUID.t()}]

  @doc """
  Takes the lease of each destination in `ids`, in order, polling every
  `poll_ms` while one is held until `deadline` (monotonic milliseconds). A
  destination deleted meanwhile is skipped. When a lease can't be taken in
  time, the leases already taken are released and `:held` is returned. When
  taking one raises, throws or exits, the leases already taken are released
  and the failure is re-raised with its own kind and stacktrace.
  """
  @spec take_all([integer()], integer(), non_neg_integer()) :: {:ok, leases()} | :held
  def take_all(ids, deadline, poll_ms) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, leases} ->
      case take_or_release(id, leases, deadline, poll_ms) do
        {:ok, token} ->
          {:cont, {:ok, [{id, token} | leases]}}

        :gone ->
          {:cont, {:ok, leases}}

        :held ->
          release_all(leases)
          {:halt, :held}
      end
    end)
  end

  @doc "Renews every lease in `leases`."
  @spec extend_all(leases()) :: :ok
  def extend_all(leases), do: Enum.each(leases, fn {id, token} -> Lease.extend(id, token) end)

  @doc """
  Releases every lease in `leases`. Each release is attempted even when an
  earlier one fails, so one failure never keeps the rest held until they
  expire; the first failure is then re-raised with its own kind and
  stacktrace.
  """
  @spec release_all(leases()) :: :ok
  def release_all(leases) do
    case Enum.flat_map(leases, &release/1) do
      [] -> :ok
      [{kind, reason, stacktrace} | _] -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp release({id, token}) do
    Lease.release(id, token)
    []
  catch
    kind, reason -> [{kind, reason, __STACKTRACE__}]
  end

  # The failure to take a lease is the one re-raised: a lease whose release
  # fails as well expires on its own (`Kanban.AuditStream.Lease.ttl/0`).
  defp take_or_release(id, leases, deadline, poll_ms) do
    take(id, deadline, poll_ms)
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      release_quietly(leases)
      :erlang.raise(kind, reason, stacktrace)
  end

  defp release_quietly(leases) do
    release_all(leases)
  catch
    _kind, _reason -> :ok
  end

  defp take(id, deadline, poll_ms) do
    case Lease.take(id) do
      {:ok, token} -> {:ok, token}
      :held -> wait(id, deadline, poll_ms)
    end
  end

  # No cursor means the destination was deleted after it was listed.
  defp wait(id, deadline, poll_ms) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      is_nil(Lease.seconds_left(id)) ->
        :gone

      remaining <= 0 ->
        :held

      true ->
        poll_ms |> min(remaining) |> Process.sleep()
        take(id, deadline, poll_ms)
    end
  end
end
