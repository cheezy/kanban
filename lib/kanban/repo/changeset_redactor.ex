defmodule Kanban.Repo.ChangesetRedactor do
  @moduledoc """
  Keeps the plaintext of encrypted fields out of `Ecto.InvalidChangesetError`
  messages.

  `Ecto.InvalidChangesetError.message/1` (ecto 3.14) prints a changeset's
  "Applied changes" and "Params" with `inspect/2` on plain maps, so
  `redact: true` does not reach them: an invalid changeset for a schema with
  an encrypted field put the decrypted secret in the message, and from there
  into logs, error trackers and test output, in every environment.

  `Kanban.Repo` therefore rescues the error its bang functions (`insert!/2`,
  `update!/2`, `insert_or_update!/2`, `delete!/2`) raise and re-raises it, with
  the same stacktrace, through `redact_error/1`. The exception is still an
  `Ecto.InvalidChangesetError` with the same action and errors; only the
  sensitive values in its changeset are replaced by `"**redacted**"`, the
  marker `Ecto.Changeset` itself uses.

  ## What is redacted

  A field is sensitive when its Ecto type encrypts — found by behaviour, not
  by name: a custom type over `:binary` or `:string` (parameterized, or inside
  an array or map, included) whose dump changes a string, which
  covers `Kanban.Encryption.EncryptedBinary`, `TolerantEncryptedBinary` and
  `Kanban.Integrations.EncryptedString` and any new type like them — or when
  the schema declares it `redact: true`. So a new encrypted field is covered
  with no list to maintain. Its value is replaced in the changeset's `changes`
  and in its `params` (string or atom keys), in nested association and embed
  changesets and params too. A `nil` value stays `nil`, and a changeset with
  no sensitive field is returned unchanged, so its message is Ecto's own.

  ## What it does not cover

  Only this one exception is rewritten. `Ecto.ConstraintError` prints the
  action, the violated and declared constraint names and a hint, never a
  value, and `Ecto.StaleEntryError` inspects the struct, whose derived
  `Inspect` hides `redact: true` fields, so neither needs it. No code in this
  app reaches any gap below:

    * `Ecto.Changeset.apply_action!/2` raises the same error without going
      through the Repo; use `apply_action/2` for a changeset with an
      encrypted field.
    * `Ecto.NoResultsError` and `Ecto.MultipleResultsError` (from `one!/2`,
      `get_by!/3` and the like) print the query with its pinned values; never
      pin an encrypted field's plaintext in a bang query.
    * `Ecto.Query.CastError` and `Ecto.ChangeError` print a value an encrypted
      type refused to cast or dump. Only a non-binary value (a list or a
      charlist, say) is refused, so pass a secret as a binary.
  """

  alias Ecto.Changeset

  @mark "**redacted**"
  @type_probe "D434-encrypting-type-probe"

  @doc """
  The error with every sensitive value in its changeset replaced by
  `"**redacted**"`. Any other exception is returned unchanged.
  """
  @spec redact_error(Exception.t()) :: Exception.t()
  def redact_error(%Ecto.InvalidChangesetError{changeset: changeset} = error),
    do: %{error | changeset: redact(changeset)}

  def redact_error(exception), do: exception

  @doc """
  The changeset with the value of every sensitive field replaced by
  `"**redacted**"` in its `changes` and `params`, recursively through nested
  changesets. Anything that is not a changeset is returned unchanged.

  ## Examples

      iex> types = %{secret: Kanban.Encryption.EncryptedBinary}
      iex> changeset = Ecto.Changeset.change({%{}, types}, secret: "s3cret")
      iex> Kanban.Repo.ChangesetRedactor.redact(changeset).changes
      %{secret: "**redacted**"}

      iex> types = %{secret: Kanban.Encryption.EncryptedBinary}
      iex> changeset = Ecto.Changeset.change({%{secret: "old"}, types}, secret: nil)
      iex> Kanban.Repo.ChangesetRedactor.redact(changeset).changes
      %{secret: nil}

  """
  @spec redact(term()) :: term()
  def redact(%Changeset{types: types} = changeset) when is_map(types) do
    sensitive = sensitive_fields(changeset.data, types)

    %{
      changeset
      | changes: redact_changes(changeset.changes, sensitive),
        params: redact_params(changeset.params, types, sensitive)
    }
  end

  def redact(other), do: other

  @doc """
  The fields of a changeset's data and types that must never be printed: those
  whose type encrypts, plus those the schema declares `redact: true`.
  """
  @spec sensitive_fields(term(), map()) :: MapSet.t(atom())
  def sensitive_fields(data, types) when is_map(types) do
    types
    |> Enum.filter(fn {_field, type} -> encrypting_type?(type) end)
    |> Enum.map(fn {field, _type} -> field end)
    |> Enum.concat(redact_fields(data))
    |> MapSet.new()
  end

  @doc """
  Whether an Ecto type writes something other than the value it is given: a
  custom type over `:binary` or `:string` whose dump changes a string, such as
  a cipher. Parameterized types are probed the same way, and `{:array, type}`,
  `{:map, type}` and `{:in, type}` by their element type. A type whose probe
  raises counts as encrypting, so a failure redacts rather than prints.
  """
  @spec encrypting_type?(term()) :: boolean()
  def encrypting_type?({container, inner}) when container in [:array, :map, :in],
    do: encrypting_type?(inner)

  def encrypting_type?({relation, _meta}) when relation in [:assoc, :embed], do: false

  def encrypting_type?(type) do
    not Ecto.Type.base?(type) and Ecto.Type.type(type) in [:binary, :string] and
      match?({:ok, dumped} when dumped != @type_probe, Ecto.Type.dump(type, @type_probe))
  rescue
    _exception -> true
  end

  defp redact_fields(%schema{}) do
    if function_exported?(schema, :__schema__, 1), do: schema.__schema__(:redact_fields), else: []
  end

  defp redact_fields(_data), do: []

  defp redact_changes(changes, sensitive) do
    Map.new(changes, fn {field, value} -> {field, redact_change(field, value, sensitive)} end)
  end

  defp redact_change(_field, %Changeset{} = nested, _sensitive), do: redact(nested)

  defp redact_change(_field, [%Changeset{} | _] = nested, _sensitive),
    do: Enum.map(nested, &redact/1)

  defp redact_change(field, value, sensitive), do: mark(value, field in sensitive)

  defp redact_params(params, types, sensitive) when is_map(params) do
    fields = Map.new(types, fn {field, _type} -> {to_string(field), field} end)

    Map.new(params, fn {key, value} ->
      field = Map.get(fields, to_string(key))
      {key, redact_param(value, field, types, sensitive)}
    end)
  end

  defp redact_params(params, _types, _sensitive), do: params

  defp redact_param(value, nil, _types, _sensitive), do: value

  defp redact_param(value, field, types, sensitive) do
    case Map.get(types, field) do
      {relation, %{related: related, cardinality: cardinality}}
      when relation in [:assoc, :embed] ->
        redact_nested_params(value, related, cardinality)

      _type ->
        mark(value, field in sensitive)
    end
  end

  # An association's or embed's params. For a :many relation they are a list
  # of maps or a map of any keys to maps (Ecto accepts any key, not only an
  # index); for a :one relation they are one map.
  defp redact_nested_params(params, related, :many) when is_list(params),
    do: Enum.map(params, &redact_related_params(&1, related))

  defp redact_nested_params(params, related, :many) when is_map(params) and not is_struct(params),
    do: Map.new(params, fn {key, value} -> {key, redact_related_params(value, related)} end)

  defp redact_nested_params(params, related, _cardinality),
    do: redact_related_params(params, related)

  defp redact_related_params(params, related) when is_map(params) and not is_struct(params) do
    types = related.__changeset__()
    redact_params(params, types, sensitive_fields(struct(related), types))
  end

  defp redact_related_params(params, _related), do: params

  defp mark(nil, _sensitive?), do: nil
  defp mark(_value, true), do: @mark
  defp mark(value, false), do: value
end
