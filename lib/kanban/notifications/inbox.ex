defmodule Kanban.Notifications.Inbox do
  @moduledoc """
  Reading and marking the scoped user's notifications: the inbox page, the
  unread count, and mark read.

  Every function goes through `Kanban.Notifications.Visibility.query/1`, so
  it only ever touches the scoped user's visible in-app rows. Each mark
  broadcasts `{:notifications_read, unread_count}` on the user's topic
  (`Kanban.Notifications.Broadcaster`).
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Notifications.Broadcaster
  alias Kanban.Notifications.Notification
  alias Kanban.Notifications.NotificationTelemetry
  alias Kanban.Notifications.Visibility
  alias Kanban.Repo

  @default_limit 50
  @max_limit 100

  @doc """
  Lists the scoped user's visible notifications, newest first.

  ## Options

    * `:unread_only` - only unread notifications (default `false`)
    * `:limit` - page size, clamped to 1..#{@max_limit} (default #{@default_limit})
    * `:before` - a `%Notification{}` cursor; returns rows older than it
  """
  @spec list_notifications(Scope.t(), keyword()) :: [Notification.t()]
  def list_notifications(%Scope{user: %User{}} = scope, opts \\ []) do
    scope
    |> Visibility.query()
    |> maybe_unread_only(Keyword.get(opts, :unread_only, false))
    |> maybe_before(Keyword.get(opts, :before))
    |> order_by([n], desc: n.inserted_at, desc: n.id)
    |> limit(^clamp_limit(Keyword.get(opts, :limit, @default_limit)))
    |> Repo.all()
  end

  @doc """
  Counts the scoped user's visible unread notifications.
  """
  @spec unread_count(Scope.t()) :: non_neg_integer()
  def unread_count(%Scope{user: %User{}} = scope) do
    scope
    |> Visibility.query()
    |> where([n], is_nil(n.read_at))
    |> select([n], count(n.id))
    |> Repo.one()
  end

  @doc """
  Marks one of the scoped user's notifications read and broadcasts the new
  unread count.

  Returns `{:error, :not_found}` for an id that does not exist, belongs to
  another user, or is hidden because the user left its board. Marking an
  already-read notification is a no-op that still succeeds.
  """
  @spec mark_read(Scope.t(), integer() | String.t()) ::
          {:ok, Notification.t()} | {:error, :not_found}
  def mark_read(%Scope{user: %User{}} = scope, id) do
    with {:ok, id} <- cast_id(id),
         %Notification{} = notification <- get_visible(scope, id),
         {:ok, notification} <- stamp_read(notification) do
      Broadcaster.broadcast(scope.user.id, {:notifications_read, unread_count(scope)})
      {:ok, notification}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Marks every visible unread notification of the scoped user read and
  broadcasts the new unread count. Returns `{:ok, updated_count}`.

  Notifications hidden because the user left their board are left untouched,
  so this touches exactly the rows `unread_count/1` counts.
  """
  @spec mark_all_read(Scope.t()) :: {:ok, non_neg_integer()}
  def mark_all_read(%Scope{user: %User{id: user_id}} = scope) do
    now = DateTime.utc_now()

    {count, _} =
      scope
      |> Visibility.query()
      |> where([n], is_nil(n.read_at))
      |> Repo.update_all(set: [read_at: now, updated_at: now])

    Broadcaster.broadcast(user_id, {:notifications_read, unread_count(scope)})
    NotificationTelemetry.all_read({:ok, count}, user_id)
  end

  defp get_visible(scope, id) do
    scope
    |> Visibility.query()
    |> where([n], n.id == ^id)
    |> Repo.one()
  end

  defp maybe_unread_only(query, true), do: where(query, [n], is_nil(n.read_at))
  defp maybe_unread_only(query, _), do: query

  defp maybe_before(query, %Notification{inserted_at: inserted_at, id: id}) do
    where(
      query,
      [n],
      n.inserted_at < ^inserted_at or (n.inserted_at == ^inserted_at and n.id < ^id)
    )
  end

  defp maybe_before(query, _), do: query

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)
  defp clamp_limit(_), do: @default_limit

  defp stamp_read(%Notification{read_at: nil} = notification) do
    notification
    |> Ecto.Changeset.change(read_at: DateTime.utc_now())
    |> Repo.update()
    |> NotificationTelemetry.read()
  end

  defp stamp_read(%Notification{} = notification), do: {:ok, notification}

  defp cast_id(id) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} when is_integer(id) -> {:ok, id}
      _ -> :error
    end
  end
end
