defmodule Kanban.AuditLog.Redaction do
  @moduledoc """
  Decides which audit metadata pairs `Kanban.AuditLog` drops before an event
  is emitted, logged or stored.

  A key is dropped when its name contains a credential-shaped substring
  (`password`, `token`, `secret`, `authorization`, `key`, `otp`), unless it
  ends in `_id`: those are database identifiers (`token_id` is a row id, not
  the token value). Matching on substrings rather than exact names redacts
  keys such as `:reset_token` or `:otp_secret` that no list anticipated (D159).

  One pair is exempt by name and value: `approval_key` holding a boolean. It
  records whether a review was approved with the device's verified approval
  signature (`docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md` §9.5), and a
  boolean cannot carry a credential. Under any other value — a key's text,
  say — `approval_key` is dropped like every other credential-shaped key.
  """

  @sensitive_substrings ~w(password token secret authorization key otp)
  @id_suffix "_id"
  @boolean_flags ["approval_key"]

  @doc """
  Whether the metadata pair `key` => `value` must be dropped. `key` is an
  atom or a string.
  """
  @spec drop?(atom() | String.t(), term()) :: boolean()
  def drop?(key, value) do
    name = to_string(key)

    if name in @boolean_flags and is_boolean(value) do
      false
    else
      sensitive_name?(name)
    end
  end

  defp sensitive_name?(name) do
    not String.ends_with?(name, @id_suffix) and
      Enum.any?(@sensitive_substrings, &String.contains?(name, &1))
  end
end
