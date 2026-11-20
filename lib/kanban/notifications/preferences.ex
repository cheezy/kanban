defmodule Kanban.Notifications.Preferences do
  @moduledoc """
  Per-user delivery preferences: the event types, their in-code defaults,
  and reading and writing a user's saved choices.

  A `notification_preferences` row exists only once a user changes a
  setting; `default_preference/1` supplies the rest, so existing users need
  no backfill. `Kanban.Notifications.Delivery` uses `normalize_event_type/1`
  and `default_preference/1` when it resolves an event's recipients.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Notifications.NotificationTelemetry
  alias Kanban.Notifications.Preference
  alias Kanban.Notifications.PushSettings
  alias Kanban.Plans
  alias Kanban.Repo

  @email_off_by_default [:goal_completed, :comment_added]

  @type event_type :: atom()

  @doc """
  Returns every notification event type, including the reserved
  `:comment_added` and `:mentioned` types.
  """
  @spec event_types() :: [event_type()]
  def event_types, do: Preference.event_types()

  @doc """
  Returns `{:ok, type}` for a known event type given as an atom or a string,
  else `:error`. Never creates an atom.
  """
  @spec normalize_event_type(term()) :: {:ok, event_type()} | :error
  def normalize_event_type(type) when is_atom(type) do
    if type in Preference.event_types(), do: {:ok, type}, else: :error
  end

  def normalize_event_type(type) when is_binary(type) do
    case Enum.find(Preference.event_types(), &(Atom.to_string(&1) == type)) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  def normalize_event_type(_), do: :error

  @doc """
  Returns the in-code default preference for an event type, as an unsaved
  `%Preference{}` with no user.

  Accepts the atom or string form. Raises `ArgumentError` for an unknown
  event type — this is a programmer-facing API.
  """
  @spec default_preference(event_type() | String.t()) :: Preference.t()
  def default_preference(event_type) do
    case normalize_event_type(event_type) do
      {:ok, type} ->
        %Preference{
          event_type: type,
          in_app: true,
          email: type not in @email_off_by_default,
          push: PushSettings.default_push?(type)
        }

      :error ->
        raise ArgumentError, "unknown notification event type: #{inspect(event_type)}"
    end
  end

  @doc """
  Returns the scoped user's preference for every event type, in
  `event_types/0` order. Types without a saved row use
  `default_preference/1`.
  """
  @spec get_preferences(Scope.t()) :: [Preference.t()]
  def get_preferences(%Scope{user: %User{id: user_id}}) do
    saved =
      Preference
      |> where([p], p.user_id == ^user_id)
      |> Repo.all()
      |> Map.new(&{&1.event_type, &1})

    Enum.map(event_types(), fn type ->
      Map.get_lazy(saved, type, fn -> %{default_preference(type) | user_id: user_id} end)
    end)
  end

  @doc """
  Creates or updates the scoped user's preference for one event type.

  `attrs` may set `:in_app` and/or `:email`; an omitted flag keeps its
  current (or default) value. Returns `{:error, :invalid_event_type}` for an
  unknown event type.

  While paid plans are enforced, a user without paid access is refused with
  `{:error, {:plan_required, :notifications}}` (`Kanban.Plans.check_user/3`),
  so a crafted event cannot change a locked setting. `unsubscribe/2` skips
  this check: turning email off is never a paid action.
  """
  @spec update_preference(Scope.t(), event_type() | String.t(), map()) ::
          {:ok, Preference.t()}
          | {:error, :invalid_event_type | {:plan_required, :notifications} | Ecto.Changeset.t()}
  def update_preference(%Scope{} = scope, event_type, attrs) do
    with :ok <- Plans.check_user(scope, :notifications, surface: :context) do
      write_preference(scope, event_type, attrs)
    end
  end

  @doc """
  Turns email off for one user and one event type, leaving in-app delivery
  as it was. Used by the signed unsubscribe links, which carry a verified
  user id and event type rather than a session.

  Idempotent. Returns `{:error, :not_found}` when the user no longer exists
  and `{:error, :invalid_event_type}` for an unknown event type.
  """
  @spec unsubscribe(pos_integer(), event_type() | String.t()) ::
          :ok | {:error, :not_found | :invalid_event_type | Ecto.Changeset.t()}
  def unsubscribe(user_id, event_type) when is_integer(user_id) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :not_found}

      user ->
        user
        |> Scope.for_user()
        |> write_preference(event_type, %{email: false})
        |> NotificationTelemetry.unsubscribed()
        |> ok_or_error()
    end
  end

  defp write_preference(%Scope{user: %User{id: user_id}}, event_type, attrs) do
    case normalize_event_type(event_type) do
      {:ok, type} ->
        current = current_preference(user_id, type)

        %Preference{
          user_id: user_id,
          event_type: type,
          in_app: current.in_app,
          email: current.email,
          push: current.push
        }
        |> Preference.changeset(attrs)
        |> Repo.insert(
          on_conflict: {:replace, [:in_app, :email, :updated_at]},
          conflict_target: [:user_id, :event_type],
          returning: true
        )
        |> NotificationTelemetry.preference_updated(current)

      :error ->
        {:error, :invalid_event_type}
    end
  end

  defp current_preference(user_id, type) do
    Repo.get_by(Preference, user_id: user_id, event_type: type) || default_preference(type)
  end

  defp ok_or_error({:ok, _preference}), do: :ok
  defp ok_or_error({:error, _reason} = error), do: error
end
