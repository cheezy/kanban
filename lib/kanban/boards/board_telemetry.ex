defmodule Kanban.Boards.BoardTelemetry do
  @moduledoc """
  Emits the board and board membership telemetry events through
  `Kanban.Telemetry`.

  Every event is emitted only after the change it reports has been saved, so
  a refused, invalid or rolled-back change emits nothing. The functions that
  take a result return it unchanged, so they can sit at the end of a pipe
  without changing what the caller sees.

  Metadata carries ids, access levels and field names only. A board's name,
  description or field values never appear in it, because telemetry handlers
  may forward events to tools outside the app.
  """

  alias Ecto.Changeset
  alias Kanban.ApiTokens
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser

  @doc """
  Emits `[:kanban, :board, :updated]` when `result` is a saved board and the
  changeset changed at least one field. `fields` lists the changed field
  names, never their values. Returns `result`.
  """
  @spec updated(result, Changeset.t(), map()) :: result when result: term()
  def updated({:ok, %Board{} = board} = result, %Changeset{} = changeset, actor) do
    case changed_fields(changeset) do
      [] ->
        result

      fields ->
        Kanban.Telemetry.emit([:kanban, :board, :updated], %{count: 1}, %{
          board_id: board.id,
          actor_user_id: actor.id,
          fields: fields
        })

        result
    end
  end

  def updated(result, _changeset, _actor), do: result

  @doc """
  Emits `[:kanban, :board, :deleted]` when `result` is a deleted board.
  Returns `result`.
  """
  @spec deleted(result, map()) :: result when result: term()
  def deleted({:ok, %Board{} = board} = result, actor) do
    Kanban.Telemetry.emit([:kanban, :board, :deleted], %{count: 1}, %{
      board_id: board.id,
      actor_user_id: actor.id
    })

    result
  end

  def deleted(result, _actor), do: result

  @doc """
  Emits `[:kanban, :board, :field_visibility_changed]` when `result` is a
  saved board and at least one field was shown or hidden. `fields` lists the
  toggled field names. Returns `result`.
  """
  @spec field_visibility_changed(result, Changeset.t(), map()) :: result when result: term()
  def field_visibility_changed(
        {:ok, %Board{} = board} = result,
        %Changeset{} = changeset,
        actor
      ) do
    case toggled_fields(changeset) do
      [] ->
        result

      fields ->
        Kanban.Telemetry.emit([:kanban, :board, :field_visibility_changed], %{count: 1}, %{
          board_id: board.id,
          actor_user_id: actor.id,
          fields: fields
        })

        result
    end
  end

  def field_visibility_changed(result, _changeset, _actor), do: result

  @doc """
  Emits the membership events for a committed membership change.

  `change` is `:added`, `:removed`, `{:access_changed, from_access}` or
  `:unchanged` (the same access level saved again). `revoked` is the number of
  API tokens the change revoked. A removal, and any save that leaves the member
  at `:read_only`, also reports the token revocation through
  `Kanban.ApiTokens.report_bulk_revocation/5`. Returns `:ok`.
  """
  @spec membership_changed(BoardUser.t(), term(), non_neg_integer(), map()) :: :ok
  def membership_changed(%BoardUser{} = board_user, :added, _revoked, actor) do
    Kanban.Telemetry.emit([:kanban, :board, :member_added], %{count: 1}, %{
      board_id: board_user.board_id,
      user_id: board_user.user_id,
      access: board_user.access,
      actor_user_id: actor.id
    })
  end

  def membership_changed(%BoardUser{} = board_user, :removed, revoked, actor) do
    Kanban.Telemetry.emit([:kanban, :board, :member_removed], %{count: 1}, %{
      board_id: board_user.board_id,
      user_id: board_user.user_id,
      access: board_user.access,
      actor_user_id: actor.id
    })

    ApiTokens.report_bulk_revocation(
      board_user.board_id,
      board_user.user_id,
      revoked,
      actor.id,
      :member_removed
    )
  end

  def membership_changed(%BoardUser{} = board_user, {:access_changed, from}, revoked, actor) do
    Kanban.Telemetry.emit([:kanban, :board, :member_access_changed], %{count: 1}, %{
      board_id: board_user.board_id,
      user_id: board_user.user_id,
      from_access: from,
      to_access: board_user.access,
      actor_user_id: actor.id
    })

    maybe_report_revocation(board_user, revoked, actor)
  end

  def membership_changed(%BoardUser{} = board_user, :unchanged, revoked, actor),
    do: maybe_report_revocation(board_user, revoked, actor)

  def membership_changed(_board_user, _change, _revoked, _actor), do: :ok

  # Only a save that leaves the member at :read_only runs the revoke step.
  defp maybe_report_revocation(%BoardUser{access: :read_only} = board_user, revoked, actor) do
    ApiTokens.report_bulk_revocation(
      board_user.board_id,
      board_user.user_id,
      revoked,
      actor.id,
      :read_only_access
    )
  end

  defp maybe_report_revocation(_board_user, _revoked, _actor), do: :ok

  defp changed_fields(%Changeset{changes: changes}) do
    changes
    |> Map.keys()
    |> Enum.sort()
  end

  defp toggled_fields(%Changeset{data: data, changes: changes}) do
    old = Map.get(data, :field_visibility) || %{}
    new = Map.get(changes, :field_visibility, old) || %{}

    old
    |> Map.keys()
    |> Enum.concat(Map.keys(new))
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(old, &1) != Map.get(new, &1)))
    |> Enum.sort()
  end
end
