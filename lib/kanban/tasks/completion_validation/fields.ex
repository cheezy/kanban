defmodule Kanban.Tasks.CompletionValidation.Fields do
  @moduledoc """
  Leaf-level field checks shared across the `Kanban.Tasks.CompletionValidation`
  family.

  These are the primitives every validator in the family reaches for rather
  than re-implementing: decoding a value against an allow-list of atoms, and
  checking an optional `note` (and its legacy plural `notes`) string on a
  section verdict. They live here, not on the parent, for two reasons.

  First, they are used from more than one sibling — `check_enum/6` from the
  parent's issue/criterion/consideration checks and from
  `Kanban.Tasks.CompletionValidation.BehaviourTestMatrix`; `check_section_notes/3`
  from the parent's generic section verdict and from the same matrix module.
  Copying them would let the copies drift and produce inconsistent rejection
  messages for the same class of mistake.

  Second, they take an allow-list as a *parameter*. Exposing that from the
  parent — the input-validation boundary for an authenticated endpoint —
  would advertise "bring your own allow-list"; keeping it on an internal
  sibling keeps the invitation narrow.

  ## Atom safety

  `decode_enum_field/2` resolves strings with `String.to_existing_atom/1`
  inside a rescue, so an attacker-supplied string can never mint an atom: an
  unknown string raises `ArgumentError` and is reported as `:invalid`. That
  only holds while every allow-list stays a **compile-time atom literal**
  somewhere in the family. Deriving an enum from runtime strings would
  reintroduce the atom-exhaustion risk this guards against.
  """

  @section_status_enum [:passed, :failed, :not_assessed]

  @doc false
  # Validates that `map[key]` is present and decodes to a member of `allowed`.
  # Mirrors the binary-or-atom acceptance pattern used by `check_reason/2`.
  # `prefix` is the entry locator (e.g., `"issues[0]"`) used in messages.
  def check_enum(errors, map, key, allowed, field, prefix) do
    case decode_enum_field(Map.get(map, key), allowed) do
      :ok -> errors
      :missing -> [{field, "#{prefix} is missing #{key}"} | errors]
      :invalid -> [{field, "#{prefix} #{key} #{enum_message(allowed)}"} | errors]
    end
  end

  defp decode_enum_field(nil, _allowed), do: :missing

  defp decode_enum_field(value, allowed) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in allowed, do: :ok, else: :invalid
  rescue
    ArgumentError -> :invalid
  end

  defp decode_enum_field(value, allowed) when is_atom(value) do
    if value in allowed, do: :ok, else: :invalid
  end

  defp decode_enum_field(_value, _allowed), do: :invalid

  defp enum_message(allowed),
    do: "must be one of: " <> Enum.map_join(allowed, ", ", &Atom.to_string/1)

  @doc false
  def check_section_status(errors, map, field, prefix),
    do: check_enum(errors, map, "status", @section_status_enum, field, prefix)

  # Two keys, and only one of them is live. The reviewer contract specifies
  # `note`, SINGULAR, and that is the only key the review queue renders; the
  # plural `notes` is checked purely so a legacy payload carrying it is not
  # newly rejected. Both are type-checked on every status — a non-string note
  # otherwise validates clean and then vanishes at render time, which reports
  # nothing to the caller.
  #
  # The SUBSTANCE rule for a `failed` verdict's `note` is not here: it lives in
  # `Kanban.Tasks.CompletionValidation.ReviewContract`, because it must reject
  # unconditionally rather than warn under the grace flag (D231).
  @doc false
  def check_section_notes(errors, verdict, key) do
    errors
    |> check_note_type(verdict, key, "notes", :notes)
    |> check_note_type(verdict, key, "note", :note)
  end

  # (D231) `note` is type-checked on EVERY status, not only `failed`. The
  # substance rule in ReviewContract binds failed verdicts alone, so without
  # this a `passed` verdict carrying `note: 42` validated clean and then
  # vanished at render time — `ReviewReportHelpers.note_from_section/1` guards
  # on `is_binary`, so the reviewer's rationale silently disappeared from the
  # review queue with nothing reported to the caller. A type error is not a
  # substance judgement, so checking it everywhere does not widen D222's scope.
  defp check_note_type(errors, verdict, key, note_key, field) do
    case Map.get(verdict, note_key) do
      nil -> errors
      note when is_binary(note) -> errors
      _ -> [{field, "#{key}.#{note_key} must be a string"} | errors]
    end
  end
end
