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
  """

  alias Kanban.AuditLog
  alias Kanban.Tasks.CredentialShapes

  @entry_keys [:consideration, :evidence, :note]
  @section_keys [:note, :notes]

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
