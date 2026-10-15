defmodule Kanban.Tasks.SecurityConsiderationsScan do
  @moduledoc """
  Detective control over the security-consideration strings a reviewer echoes
  into `reviewer_result` on `/complete` (W2382).

  Security-review agents copy each `security_considerations` entry verbatim
  into `reviewer_result.security_considerations.considerations[]`, and Stride
  persists that result and renders it on the Review queue. Since W2382 a task
  write refuses a credential-shaped consideration (see
  `Kanban.Tasks.Task.MapFieldValidations`), but a task written before that
  check existed can still carry one, and an agent can paste a secret into its
  own `evidence` or `note`. This scan covers both.

  It matches the shared high-signal patterns in `Kanban.Tasks.CredentialShapes`
  against every string in each considerations entry (`consideration`,
  `evidence`, `note`) and the section's own `note`/`notes`. On a hit it emits
  `:security_considerations_credential_suspected` once per completion.

  Like `Kanban.Tasks.CompletionNotesScan`, it **detects; it never blocks or
  rewrites**: the completion proceeds and the result is stored verbatim, and
  the event carries only the task id and agent name — never the matched text.
  It runs before the completion is validated, as the completion-notes scan
  does, so it can fire for a completion that is later rejected for another
  reason.

  `scan_stored/0` is the matching report over the stored field (W2384): it
  finds every task — archived tasks and goals included — whose stored
  `security_considerations` still carries a credential-shaped entry written
  before W2382, so an operator can clean the data once. It is read-only and
  reports identifiers and 1-based positions, never the matched text.
  `Kanban.Release.scan_credential_considerations/0` runs it from a release.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.AuditLog
  alias Kanban.Repo
  alias Kanban.Tasks.CredentialShapes
  alias Kanban.Tasks.Task

  @entry_keys [:consideration, :evidence, :note]
  @section_keys [:note, :notes]
  @scan_batch_size 500

  @typedoc """
  One task whose stored `security_considerations` carries at least one
  credential-shaped entry. `positions` are 1-based and ascending; the matched
  text is deliberately absent.
  """
  @type stored_hit :: %{
          identifier: String.t() | nil,
          task_id: pos_integer(),
          positions: [pos_integer(), ...]
        }

  @doc """
  True when any security-consideration string in `reviewer_result` is shaped
  like a real credential. Accepts string- or atom-keyed maps; any other shape
  is `false`.

      iex> Kanban.Tasks.SecurityConsiderationsScan.credential_shaped?(%{
      ...>   "security_considerations" => %{
      ...>     "considerations" => [%{"consideration" => "API tokens are never logged"}]
      ...>   }
      ...> })
      false
  """
  @spec credential_shaped?(term()) :: boolean()
  def credential_shaped?(reviewer_result) do
    reviewer_result
    |> consideration_strings()
    |> Enum.any?(&CredentialShapes.match?/1)
  end

  @doc """
  Emits a security audit event when `reviewer_result` carries a
  credential-shaped consideration string. Always returns `:ok`.
  """
  @spec audit(term(), integer() | nil, String.t() | nil) :: :ok
  def audit(reviewer_result, task_id, agent_name) do
    if credential_shaped?(reviewer_result) do
      AuditLog.event(:security_considerations_credential_suspected,
        task_id: task_id,
        agent_name: agent_name
      )
    end

    :ok
  end

  @doc """
  Reports every stored task whose `security_considerations` carries an entry
  shaped like a real credential, per `Kanban.Tasks.CredentialShapes`.

  Returns one `t:stored_hit/0` per matching task, ordered by task id, and `[]`
  when nothing matches. Archived tasks and goals are included; tasks whose
  field is `nil` or empty are skipped. The report carries the identifier, the
  task id and the 1-based positions of the matching entries — never the
  entries themselves. It writes nothing, emits no event and never logs a
  matched value.

  Tasks are read in keyset batches of #{@scan_batch_size} (only the id,
  identifier and considerations columns), so the whole table is never loaded
  at once. `opts` is a test seam only: `:batch_size`.
  """
  @spec scan_stored(keyword()) :: [stored_hit()]
  def scan_stored(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @scan_batch_size)

    0
    |> Stream.unfold(&next_stored_batch(&1, batch_size))
    |> Stream.concat()
    |> Stream.flat_map(&stored_hits/1)
    |> Enum.to_list()
  end

  defp next_stored_batch(nil, _batch_size), do: nil

  defp next_stored_batch(after_id, batch_size) do
    case after_id |> stored_batch_query(batch_size) |> Repo.all() do
      [] -> nil
      batch when length(batch) < batch_size -> {batch, nil}
      batch -> {batch, batch |> List.last() |> elem(0)}
    end
  end

  # cardinality(NULL) is NULL, so this skips nil and empty fields alike.
  defp stored_batch_query(after_id, batch_size) do
    from t in Task,
      where: t.id > ^after_id,
      where: fragment("cardinality(?) > 0", t.security_considerations),
      order_by: [asc: t.id],
      limit: ^batch_size,
      select: {t.id, t.identifier, t.security_considerations}
  end

  defp stored_hits({task_id, identifier, considerations}) do
    case matching_positions(considerations) do
      [] -> []
      positions -> [%{identifier: identifier, task_id: task_id, positions: positions}]
    end
  end

  defp matching_positions(considerations) do
    for {value, position} <- Enum.with_index(considerations, 1),
        CredentialShapes.match?(value),
        do: position
  end

  defp consideration_strings(%{} = reviewer_result) do
    case fetch(reviewer_result, :security_considerations) do
      %{} = section -> section_strings(section) ++ entry_strings(fetch(section, :considerations))
      _other -> []
    end
  end

  defp consideration_strings(_other), do: []

  defp section_strings(section), do: Enum.map(@section_keys, &fetch(section, &1))

  defp entry_strings(entries) when is_list(entries) do
    Enum.flat_map(entries, fn
      %{} = entry -> Enum.map(@entry_keys, &fetch(entry, &1))
      _other -> []
    end)
  end

  defp entry_strings(_other), do: []

  defp fetch(map, key), do: Map.get(map, Atom.to_string(key), Map.get(map, key))
end
