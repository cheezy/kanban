defmodule Kanban.Tasks.CredentialShapes do
  @moduledoc """
  The one list of **high-signal credential shapes** Stride checks free text
  against.

  Three callers share it, and changing a pattern changes all three:

    * `Kanban.Tasks.CompletionNotesScan` — detects a credential in
      `completion_notes` on `/complete` and raises an audit event (D188).
    * `Kanban.Tasks.Task.MapFieldValidations` — rejects a
      `security_considerations` entry with this shape when a write introduces
      it (W2382).
    * `Kanban.Tasks.SecurityConsiderationsScan` — detects a credential in the
      reviewer's echo of those entries on `/complete` (W2382).

  Each pattern matches a token FORMAT, never the English word for one, so prose
  that merely discusses credentials ("API tokens are never logged", or the
  `[REDACTED — row text embedded a credential]` sentinel) does not match. Short
  example values such as `stride_dev_abc123` fall below the length floors and
  do not match either.

  Two shapes are known to match text that is not a secret, and they are
  accepted rather than loosened: `bearer` followed by a single 20+ character
  word (such as a long hyphenated compound), and an `auth_token:`-style label
  followed by a long unbroken value such as a file path. Both are rare in
  prose, and a pattern loose enough to admit them would also admit real tokens.
  """

  # Ordered roughly by how often they appear in this project's own ecosystem.
  @patterns [
    # Stride API tokens — the credential most likely to reach these fields.
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
    # A `password`/`secret`/`api_key`/`*_token` label followed by `=` or `:` and
    # a long opaque value. What makes this high-signal is the 20+ unbroken
    # credential characters after the separator: prose separates its words with
    # spaces. A colon label before a long unbroken non-secret value (such as a
    # file path) still matches; see the moduledoc's note on that false positive.
    ~r/\b(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token)\s*[=:]\s*["']?[A-Za-z0-9._~+\/=-]{20,}/i
  ]

  @doc """
  True when `value` is a string containing something shaped like a real
  credential. Any non-string is `false`.

      iex> Kanban.Tasks.CredentialShapes.match?("Row 2 embedded a credential; value redacted.")
      false

      iex> Kanban.Tasks.CredentialShapes.match?("saw ghp_abcdefghij0123456789 in the fixture")
      true
  """
  @spec match?(term()) :: boolean()
  def match?(value) when is_binary(value) do
    Enum.any?(@patterns, &Regex.match?(&1, value))
  end

  def match?(_value), do: false
end
