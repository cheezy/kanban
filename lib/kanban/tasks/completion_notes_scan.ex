defmodule Kanban.Tasks.CompletionNotesScan do
  @moduledoc """
  Detective control over `completion_notes`, the agent-authored free-text
  findings channel persisted by D188.

  `completion_notes` is written by an agent and rendered to a human on the
  Review queue. The contract in `docs/matrix-row-refusal-contract.md` requires
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
  token formats and key blocks, not the English words for them — and the caller
  emits a security audit event on a hit. The completion still succeeds and the
  narrative is preserved verbatim; an operator gets a signal that a real secret
  may have landed in a durable, human-rendered field.
  """

  alias Kanban.AuditLog

  # High-signal credential shapes only. Each pattern matches a token FORMAT, so
  # prose that merely discusses credentials does not trip it. Ordered roughly by
  # how often they appear in this project's own ecosystem.
  @patterns [
    # Stride API tokens — the credential most likely to reach this field.
    ~r/stride_(dev|prod|live)_[A-Za-z0-9+\/=_-]{16,}/,
    # `Authorization: Bearer <token>` with an actual token after it.
    ~r/bearer\s+[A-Za-z0-9._~+\/=-]{20,}/i,
    # PEM private key blocks. The trailing `[A-Z ]*` matters: PGP writes
    # `-----BEGIN PGP PRIVATE KEY BLOCK-----`, which a `KEY-----`-anchored
    # pattern would miss.
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY[A-Z ]*-----/,
    # Bare JWTs — three base64url segments. Very common in fixtures and
    # debugger output, and only caught above when prefixed with `Bearer `.
    ~r/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/,
    # Credentials in a URL userinfo segment (postgres://user:pw@host,
    # https://user:token@github.com/...).
    ~r/:\/\/[^\/\s:@]+:[^\/\s:@]{12,}@/,
    # GitHub personal access / app tokens.
    ~r/gh[pousr]_[A-Za-z0-9]{16,}/,
    # OpenAI-style secret keys.
    ~r/\bsk-[A-Za-z0-9]{20,}/,
    # AWS access key ids.
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    # Slack tokens.
    ~r/\bxox[abprs]-[A-Za-z0-9-]{10,}/,
    # A `key=`/`password=`/`secret=`/`token=` assignment with a long opaque
    # value. The assignment form is what makes this high-signal: prose uses a
    # space or a colon, not `=` followed by 20+ unbroken credential characters.
    ~r/\b(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token)\s*[=:]\s*["']?[A-Za-z0-9._~+\/=-]{20,}/i
  ]

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
  def credential_shaped?(notes) when is_binary(notes) do
    Enum.any?(@patterns, &Regex.match?(&1, notes))
  end

  def credential_shaped?(_), do: false

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
