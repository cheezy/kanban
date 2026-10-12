defmodule Kanban.Accounts.UserTelemetry do
  @moduledoc """
  Emits the account and user administration telemetry events through
  `Kanban.Telemetry`.

  Every event is emitted only after the change it reports has been saved, so
  a refused, invalid or rolled-back change emits nothing. The functions that
  take a result return it unchanged, so they can sit at the end of a pipe
  without changing what the caller sees. A change that saves nothing new (the
  same name, the same type, disabling a disabled user or enabling an enabled
  one) emits nothing either.

  Metadata carries ids and user types only. Email addresses, names, passwords
  and token values never appear in it, because telemetry handlers may forward
  events to tools outside the app. The session events `logged_out` and
  `sessions_revoked` are emitted by `KanbanWeb.UserAuth` instead.
  """

  alias Ecto.Changeset
  alias Kanban.Accounts.User

  @doc """
  Emits `[:kanban, :user, :name_changed]` when `result` is a saved user and
  the changeset changed the name. Returns `result`.
  """
  @spec name_changed(result, Changeset.t()) :: result when result: term()
  def name_changed({:ok, %User{} = user} = result, %Changeset{changes: %{name: _}}) do
    Kanban.Telemetry.emit([:kanban, :user, :name_changed], %{count: 1}, %{user_id: user.id})
    result
  end

  def name_changed(result, _changeset), do: result

  @doc """
  Emits `[:kanban, :user, :email_changed]` when `result` is a user whose email
  change was confirmed. Returns `result`.
  """
  @spec email_changed(result) :: result when result: term()
  def email_changed({:ok, %User{} = user} = result) do
    Kanban.Telemetry.emit([:kanban, :user, :email_changed], %{count: 1}, %{user_id: user.id})
    result
  end

  def email_changed(result), do: result

  @doc """
  Emits `[:kanban, :user, :email_change_requested]` for `user`. Call it only
  once the email change token has been saved. Returns `:ok`.
  """
  @spec email_change_requested(User.t()) :: :ok
  def email_change_requested(%User{} = user) do
    Kanban.Telemetry.emit([:kanban, :user, :email_change_requested], %{count: 1}, %{
      user_id: user.id
    })
  end

  @doc """
  Emits `[:kanban, :user, :password_changed]` when `result` is the
  `{:ok, {user, expired_tokens}}` of a saved password change. Returns `result`.
  """
  @spec password_changed(result) :: result when result: term()
  def password_changed({:ok, {%User{} = user, _tokens}} = result) do
    Kanban.Telemetry.emit([:kanban, :user, :password_changed], %{count: 1}, %{user_id: user.id})
    result
  end

  def password_changed(result), do: result

  @doc """
  Emits `[:kanban, :user, :password_reset_completed]` when `result` is the
  `{:ok, {user, expired_tokens}}` of a saved password reset. Returns `result`.
  """
  @spec password_reset_completed(result) :: result when result: term()
  def password_reset_completed({:ok, {%User{} = user, _tokens}} = result) do
    Kanban.Telemetry.emit([:kanban, :user, :password_reset_completed], %{count: 1}, %{
      user_id: user.id
    })

    result
  end

  def password_reset_completed(result), do: result

  @doc """
  Emits `[:kanban, :user, :confirmed]` when `result` is a newly confirmed
  user. Returns `result`.
  """
  @spec confirmed(result) :: result when result: term()
  def confirmed({:ok, %User{} = user} = result) do
    Kanban.Telemetry.emit([:kanban, :user, :confirmed], %{count: 1}, %{user_id: user.id})
    result
  end

  def confirmed(result), do: result

  @doc """
  Emits `[:kanban, :user, :type_changed]` when `result` is a saved user whose
  type differs from `from_type`. Returns `result`.
  """
  @spec type_changed(result, atom()) :: result when result: term()
  def type_changed({:ok, %User{type: to_type} = user} = result, from_type)
      when to_type != from_type do
    Kanban.Telemetry.emit([:kanban, :user, :type_changed], %{count: 1}, %{
      user_id: user.id,
      from_type: from_type,
      to_type: to_type
    })

    result
  end

  def type_changed(result, _from_type), do: result

  @doc """
  Emits `[:kanban, :user, :disabled]` when `result` is a saved user and
  `before`, the user as it was, was enabled. `actor` is the administrator.
  Returns `result`.
  """
  @spec disabled(result, User.t(), User.t()) :: result when result: term()
  def disabled({:ok, %User{} = user} = result, %User{disabled_at: nil}, %User{} = actor) do
    Kanban.Telemetry.emit([:kanban, :user, :disabled], %{count: 1}, %{
      user_id: user.id,
      actor_user_id: actor.id
    })

    result
  end

  def disabled(result, _before, _actor), do: result

  @doc """
  Emits `[:kanban, :user, :enabled]` when `result` is a saved user and
  `before`, the user as it was, was disabled. `actor` is the administrator.
  Returns `result`.
  """
  @spec enabled(result, User.t(), User.t()) :: result when result: term()
  def enabled({:ok, %User{} = user} = result, %User{disabled_at: %DateTime{}}, %User{} = actor) do
    Kanban.Telemetry.emit([:kanban, :user, :enabled], %{count: 1}, %{
      user_id: user.id,
      actor_user_id: actor.id
    })

    result
  end

  def enabled(result, _before, _actor), do: result

  @doc """
  Emits `[:kanban, :user, :deleted]` when `result` is a successful deletion of
  `user`. The id is taken from `user`, which was loaded before the deletion.
  `actor` is the administrator. Returns `result`.
  """
  @spec deleted(result, User.t(), User.t()) :: result when result: term()
  def deleted({:ok, _deleted} = result, %User{id: user_id}, %User{} = actor) do
    Kanban.Telemetry.emit([:kanban, :user, :deleted], %{count: 1}, %{
      user_id: user_id,
      actor_user_id: actor.id
    })

    result
  end

  def deleted(result, _user, _actor), do: result
end
