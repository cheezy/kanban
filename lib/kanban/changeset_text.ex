defmodule Kanban.ChangesetText do
  @moduledoc """
  Changeset checks for user-entered text that PostgreSQL cannot store.

  PostgreSQL `text` and `varchar` columns cannot hold a NUL byte, `jsonb`
  refuses a NUL anywhere in a key or value, and none of them accept invalid
  UTF-8. Such a value reaches the database and raises there, so the caller
  gets a 500 or a crashed LiveView instead of a form error.
  `validate_storable/2` turns it into an ordinary changeset error on the field
  instead, with the message "contains characters that are not allowed".

  Only the NUL byte and invalid UTF-8 are refused. Every other character,
  including tabs, newlines and other control characters, is valid text and
  passes. Nothing is stripped or rewritten: a value is either stored as given
  or refused.

  Call it straight after `cast/3`, before any validation that assumes valid
  UTF-8 (a regex with the `u` flag raises on invalid UTF-8), and list every
  user-text field the changeset casts:

      schema
      |> cast(attrs, [:name, :description])
      |> Kanban.ChangesetText.validate_storable([:name, :description])

  It checks strings, lists of strings and maps (keys and values, at any
  depth), so it covers `{:array, :string}` and `:map` fields as well. Embedded
  schemas run it in their own changeset, so the error lands on the embedded
  field. Fields that are nil or not changed are skipped. The error message
  names the field only and never echoes the offending bytes.

  A schema whose API already promised a different message for these bytes can
  keep it with the `:message` option (`Kanban.Tasks.TaskComment` keeps
  "is invalid").

  `validate_visible/2` is the one rule for names and other required text
  that must show something (decided 2026-10-21): a value made only of
  whitespace and characters that render as nothing (`visible?/1`) is refused
  as "can't be blank". It refuses and never strips, so a name that has a
  visible character is stored exactly as typed. `Kanban.Workspaces.Workspace`
  strips the same characters from workspace names instead, because a
  workspace name is compared for uniqueness.
  """

  import Ecto.Changeset

  @message "contains characters that are not allowed"

  # Whitespace, every format character (category Cf: zero-width spaces and
  # joiners, direction marks and overrides, the soft hyphen, tag characters),
  # and the default-ignorable letters and marks that render as nothing: the
  # combining grapheme joiner, the Hangul fillers and the Khmer inherent
  # vowels.
  @not_visible ~r/[\s\p{Cf}\x{034F}\x{115F}\x{1160}\x{17B4}\x{17B5}\x{3164}\x{FFA0}]/u

  @doc """
  Adds "contains characters that are not allowed" to each of `fields` whose
  change holds a NUL byte or invalid UTF-8.

  ## Options

    * `:message` - the error message to add instead of the default
  """
  @spec validate_storable(Ecto.Changeset.t(), [atom()], keyword()) :: Ecto.Changeset.t()
  def validate_storable(%Ecto.Changeset{} = changeset, fields, opts \\ [])
      when is_list(fields) and is_list(opts) do
    message = Keyword.get(opts, :message, @message)

    Enum.reduce(fields, changeset, fn field, acc ->
      validate_change(acc, field, fn ^field, value ->
        if storable?(value), do: [], else: [{field, message}]
      end)
    end)
  end

  @doc """
  Adds "can't be blank" to each of `fields` whose change is text with no
  visible character (`visible?/1`), such as a name typed as zero-width
  spaces.

  Whitespace-only text is left to `validate_required/3`, which already
  reports it, and text that cannot be stored is left to `validate_storable/2`,
  so neither gets a second error. Call it after both.
  """
  @spec validate_visible(Ecto.Changeset.t(), [atom()]) :: Ecto.Changeset.t()
  def validate_visible(%Ecto.Changeset{} = changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      validate_change(acc, field, fn ^field, value ->
        if invisible_only?(value), do: [{field, "can't be blank"}], else: []
      end)
    end)
  end

  defp invisible_only?(value) when is_binary(value),
    do: storable?(value) and String.trim(value) != "" and not visible?(value)

  defp invisible_only?(_value), do: false

  @doc """
  Returns true when `text` has at least one character that shows: anything
  other than whitespace, format characters (zero-width spaces and joiners,
  direction marks, the soft hyphen, tag characters) and the letters and
  marks that render as nothing (U+034F, U+115F, U+1160, U+17B4, U+17B5,
  U+3164, U+FFA0). `text` must be valid UTF-8.

  ## Examples

      iex> Kanban.ChangesetText.visible?("Board")
      true

      iex> Kanban.ChangesetText.visible?("\u200B \u200D")
      false

  """
  @spec visible?(String.t()) :: boolean()
  def visible?(text) when is_binary(text), do: String.replace(text, @not_visible, "") != ""

  @doc """
  Returns true when `value` can be stored: every string in it, including map
  keys and list elements at any depth, is valid UTF-8 without a NUL byte.
  Structs are checked by their fields; other values (numbers, booleans, atoms)
  are always storable.
  """
  @spec storable?(term()) :: boolean()
  def storable?(value) when is_binary(value),
    do: String.valid?(value) and not String.contains?(value, <<0>>)

  def storable?(value) when is_list(value), do: Enum.all?(value, &storable?/1)

  def storable?(%_{} = struct), do: struct |> Map.from_struct() |> Map.values() |> storable?()

  def storable?(value) when is_map(value),
    do: Enum.all?(value, fn {key, val} -> storable?(key) and storable?(val) end)

  def storable?(_value), do: true

  @doc """
  Returns an invalid changeset carrying only the "contains characters that
  are not allowed" error on `field`, for a value that is not part of any
  schema (such as the free-text unclaim reason) and that `storable?/1`
  refused. The value itself is never put in the changeset, so rendering the
  errors cannot echo the offending bytes.

  ## Options

    * `:message` - the error message to add instead of the default
  """
  @spec unstorable_changeset(atom(), keyword()) :: Ecto.Changeset.t()
  def unstorable_changeset(field, opts \\ []) when is_atom(field) and is_list(opts) do
    {%{}, %{field => :string}}
    |> change()
    |> add_error(field, Keyword.get(opts, :message, @message))
  end

  @doc """
  Returns the error message the check adds.
  """
  @spec message() :: String.t()
  def message, do: @message
end
