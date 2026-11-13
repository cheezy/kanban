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
  time, the leases already taken are released and `:held` is returned.
  """
  @spec take_all([integer()], integer(), non_neg_integer()) :: {:ok, leases()} | :held
  def take_all(ids, deadline, poll_ms) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, leases} ->
      case take(id, deadline, poll_ms) do
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

  @doc "Releases every lease in `leases`."
  @spec release_all(leases()) :: :ok
  def release_all(leases), do: Enum.each(leases, fn {id, token} -> Lease.release(id, token) end)

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
