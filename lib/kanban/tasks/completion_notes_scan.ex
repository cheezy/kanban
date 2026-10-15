defmodule Kanban.Tasks.CompletionNotesScan do
  @moduledoc """
  Detective control over `completion_notes`, the agent-authored free-text
  findings channel persisted by D188.

  `completion_notes` is written by an agent and rendered to a human in two
  places: the Review queue, which is membership-scoped through
  `Kanban.Queries.BoardScope.apply_board_scope/2`, and the board task detail
  view (W1963), which is not. The detail view loads through
  `Kanban.Boards.get_board/2`, which admits a non-member whenever the board is
  `read_only` — so on a read_only board this field reaches every authenticated
  user of the application, not only board members.

  That wider reach is deliberate (D209): `read_only` boards are a
  share-outward feature and the completion narrative is part of what is
  shared. It is recorded here because this module is what a reader checks when
  asking "who can see a credential that leaked into this field?", and the
  honest answer is no longer "the Review queue".

  **This scan does not narrow that audience.** It is detective only: it runs
  at completion time, before the write, but it never blocks and never redacts
  — it records that the value looked credential-bearing and lets the
  completion proceed, so the value is persisted and rendered either way. That
  is a deliberate choice rather than a timing constraint; see "Why this
  detects rather than blocks or mutates" below. A wider audience is therefore a wider
  blast radius for a contract violation, and the mitigations remain what they
  were — the agent-side redaction rule, plus an operator acting on
  `:completion_notes_credential_suspected`.

  The contract in `docs/matrix-row-refusal-contract.md` requires
  the agent to redact any credential before writing — but until D188 that rule
  was purely advisory prompt text living in five external plugin repositories
  on independent release cycles, while the value itself was discarded. Now that
  the value is durable and re-served by the API, the rule needs a server-side
  counterpart.

  ## Why this detects rather than blocks or mutates

  A legitimate refusal narrative is *about* credentials — it says things like
  "the row embedded a credential" or names an `api_key` field. Rejecting or
  scrubbing on those words would break the exact workflow the field exists to
  serve, and a lossy rewrite would destroy the finding a human needs to read.

  So this module matches only **high-signal credential shapes** — concrete
  token formats and key blocks, not the English words for them, kept in
  `Kanban.Tasks.CredentialShapes` and shared with the `security_considerations`
  checks — and the caller emits a security audit event on a hit. The
  completion still succeeds and the
  narrative is preserved verbatim; an operator gets a signal that a real secret
  may have landed in a durable, human-rendered field.
  """

  alias Kanban.AuditLog
  alias Kanban.Tasks.CredentialShapes

  @doc """
  True when `notes` contains something shaped like a real credential.

  Matches token formats, not the English words for them, so a refusal narrative
  that merely *describes* a credential does not match.

      iex> Kanban.Tasks.CompletionNotesScan.credential_shaped?("Row 2 embedded a credential; value redacted.")
      false

      iex> Kanban.Tasks.CompletionNotesScan.credential_shaped?("saw ghp_abcdefghij0123456789 in the fixture")
      true
  """
  @spec credential_shaped?(String.t() | nil) :: boolean()
  defdelegate credential_shaped?(notes), to: CredentialShapes, as: :match?

  @doc """
  Emits a security audit event when `notes` looks credential-bearing.

  Returns `:ok` either way — this never blocks a completion. The event carries
  only the task id and the agent name; **the matched text is deliberately never
  logged**, since logging it would copy the suspected secret into a second
  durable store and defeat the purpose.
  """
  @spec audit(String.t() | nil, integer() | nil, String.t() | nil) :: :ok
  def audit(notes, task_id, agent_name) do
    if credential_shaped?(notes) do
      AuditLog.event(:completion_notes_credential_suspected,
        task_id: task_id,
        agent_name: agent_name
      )
    end

    :ok
  end
end
