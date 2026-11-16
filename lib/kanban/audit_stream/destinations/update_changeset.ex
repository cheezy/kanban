defmodule Kanban.AuditStream.Destinations.UpdateChangeset do
  @moduledoc """
  The changeset `Kanban.AuditStream.Destinations` saves when an org-admin
  edits a destination (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.4,
  §12.2): which attrs an edit may set, the stale-form check, the secrets that
  must be entered again once unreadable (D17), the excluded actions whose
  order alone changed, the `filter_version` bump (D16) and which halt an edit
  clears.

  It reads and writes nothing in the database: the caller passes the row it
  read under lock and the url lookup it made before its transaction.
  """

  alias Ecto.Changeset
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Reachability

  # The fields an org-admin edits, in the order `changed` lists them.
  @editable_fields [
    :name,
    :url,
    :credential,
    :settings,
    :include_personal_data,
    :excluded_actions
  ]

  # A change to either changes which events, or what content, a batch
  # carries, so it increases filter_version (D16).
  @filter_fields [:excluded_actions, :include_personal_data]

  # The secrets an org-admin types in, which must be entered again when they
  # can no longer be read (D17).
  @entered_secrets [:url, :credential]

  @doc """
  The attrs an edit may set. The kind never changes; enabled changes only
  through pause and resume, which record their own events; a blank secret
  keeps the stored one.
  """
  @spec attrs(map() | keyword()) :: map()
  def attrs(attrs) do
    attrs
    |> Map.new()
    |> drop_keys([:kind, :enabled, :start_from])
    |> Map.reject(&blank_secret?/1)
  end

  @doc """
  The update changeset for `fresh`, the row read under lock, with the
  caller's `lock_version`, so a form loaded before another save is refused
  as stale. `reachability` is what `Reachability.lookup/2` returned.
  """
  @spec build(Destination.t(), integer(), map(), {:ok, term()} | {:error, term()} | nil) ::
          Changeset.t()
  def build(fresh, lock_version, attrs, reachability) do
    %{fresh | lock_version: lock_version}
    |> Destination.changeset(attrs)
    |> Changeset.optimistic_lock(:lock_version)
    |> require_current(fresh)
    |> require_readable(fresh)
    |> drop_reordered_actions(fresh)
    |> Reachability.put_result(reachability)
    |> bump_filter_version(fresh)
    |> clear_halt(fresh)
  end

  @doc """
  Clears `fresh`'s halt when a valid change removes its cause: a new url for
  `:blocked_address`, a filter change for `:rejected_batch`, and no needed
  secret left unreadable for `:credentials_unreadable`. Rotation uses it too.
  """
  @spec clear_halt(Changeset.t(), Destination.t()) :: Changeset.t()
  def clear_halt(%Changeset{valid?: true} = changeset, fresh) do
    if halt_cleared?(fresh.halted_reason, changeset),
      do: Changeset.put_change(changeset, :halted_reason, nil),
      else: changeset
  end

  def clear_halt(changeset, _fresh), do: changeset

  @doc "The editable fields the changeset changes, in the order the updated event lists them."
  @spec changed_fields(Changeset.t()) :: [atom()]
  def changed_fields(%Changeset{changes: changes}),
    do: for(field <- @editable_fields, Map.has_key?(changes, field), do: field)

  defp blank_secret?({key, value}), do: to_string(key) in ~w(url credential) and blank?(value)

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  # A save that changes nothing runs no UPDATE, so the optimistic lock never
  # sees a stale lock_version; it is compared here, so a form loaded before
  # another save is refused whether or not it changes anything.
  defp require_current(%Changeset{data: %{lock_version: lock_version}} = changeset, fresh)
       when lock_version != fresh.lock_version,
       do: Changeset.add_error(changeset, :id, "is stale", stale: true)

  defp require_current(changeset, _fresh), do: changeset

  # An unreadable secret can't be kept: it can't be sent with, so the
  # org-admin must enter it again.
  defp require_readable(changeset, fresh) do
    Enum.reduce(@entered_secrets, changeset, fn field, acc ->
      if Map.fetch!(fresh, field) == :unreadable and not Map.has_key?(acc.changes, field),
        do: Changeset.add_error(acc, field, "can't be blank", validation: :unreadable),
        else: acc
    end)
  end

  # The same actions in another order are no change.
  defp drop_reordered_actions(changeset, fresh) do
    with {:ok, actions} <- Changeset.fetch_change(changeset, :excluded_actions),
         true <- Enum.sort(actions) == Enum.sort(fresh.excluded_actions) do
      Changeset.delete_change(changeset, :excluded_actions)
    else
      _changed -> changeset
    end
  end

  defp bump_filter_version(%Changeset{valid?: true} = changeset, fresh) do
    if Enum.any?(@filter_fields, &Map.has_key?(changeset.changes, &1)),
      do: Changeset.put_change(changeset, :filter_version, fresh.filter_version + 1),
      else: changeset
  end

  defp bump_filter_version(changeset, _fresh), do: changeset

  defp halt_cleared?(:blocked_address, changeset), do: Map.has_key?(changeset.changes, :url)

  # The rejected events may no longer be in the batch: the next run re-cuts
  # it because filter_version changed (D16).
  defp halt_cleared?(:rejected_batch, changeset),
    do: Enum.any?(@filter_fields, &Map.has_key?(changeset.changes, &1))

  defp halt_cleared?(:credentials_unreadable, changeset),
    do: changeset |> Changeset.apply_changes() |> needed_unreadable() == []

  defp halt_cleared?(_reason, _changeset), do: false

  # An unreadable previous signing secret is never needed: rotation drops it.
  defp needed_unreadable(destination),
    do: Destination.unreadable_secrets(destination) -- [:previous_signing_secret]

  defp drop_keys(attrs, keys), do: Map.drop(attrs, keys ++ Enum.map(keys, &Atom.to_string/1))
end
