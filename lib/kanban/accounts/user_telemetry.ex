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

  Account deletion is the one exception to "a refused change records
  nothing": `deleted/3` also records a `Kanban.AuditLog` event, `:user_deleted`
  on success and `:user_delete_refused` on a refusal, because a refused
  deletion is exactly what the site audit log exists to show. The telemetry
  event itself is still emitted only on success.
  """

  alias Ecto.Changeset
  alias Kanban.Accounts.User
  alias Kanban.AuditLog

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
  Reports the outcome of deleting `user`. `actor` is whoever asked for the
  deletion. The id is taken from `user`, which was loaded before the deletion.
  Returns `result`.

  On a successful deletion it emits `[:kanban, :user, :deleted]` and records
  the `:user_deleted` audit event. On a refusal, `{:error, reason}` with an
  atom `reason`, it records the `:user_delete_refused` audit event carrying
  that reason and emits no telemetry. Both audit events name `actor` as
  `user_id` and the target account as `member_user_id`; they carry ids only.
  Any other result, such as a changeset error from a database fault, records
  nothing.

  Call it after the deletion's transaction has returned, so a rollback cannot
  erase the audit row of a refusal.
  """
  @spec deleted(result, User.t(), User.t()) :: result when result: term()
  def deleted({:ok, _deleted} = result, %User{id: user_id}, %User{} = actor) do
    Kanban.Telemetry.emit([:kanban, :user, :deleted], %{count: 1}, %{
      user_id: user_id,
      actor_user_id: actor.id
    })

    AuditLog.event(:user_deleted, user_id: actor.id, member_user_id: user_id)

    result
  end

  def deleted({:error, reason} = result, %User{id: user_id}, %User{} = actor)
      when is_atom(reason) do
    AuditLog.event(:user_delete_refused,
      user_id: actor.id,
      member_user_id: user_id,
      reason: reason
    )

    result
  end

  def deleted(result, _user, _actor), do: result
end
