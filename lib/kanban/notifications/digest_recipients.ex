defmodule Kanban.Notifications.DigestRecipients do
  @moduledoc """
  Decides who receives the weekly digest email.

  A recipient is a confirmed, enabled user who belongs to at least one board
  and whose `:weekly_digest` email preference is on — their saved row, else
  the in-code default from `Kanban.Notifications.default_preference/1`.

  `list_digest_recipients/0` feeds the weekly fan-out and returns ids only;
  `get_digest_recipient/1` re-applies the same rules when each per-user job
  runs, so a user who was disabled or opted out after the fan-out is skipped.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Boards.BoardUser
  alias Kanban.Notifications
  alias Kanban.Notifications.Preference
  alias Kanban.Repo

  @doc """
  Returns the ids of every user who should receive the weekly digest, in id
  order.
  """
  @spec list_digest_recipients() :: [pos_integer()]
  def list_digest_recipients do
    base_query()
    |> order_by([user: u], asc: u.id)
    |> select([user: u], u.id)
    |> Repo.all()
  end

  @doc """
  Returns the user when they should still receive the weekly digest, else
  `nil`.
  """
  @spec get_digest_recipient(pos_integer()) :: User.t() | nil
  def get_digest_recipient(user_id) when is_integer(user_id) do
    base_query()
    |> where([user: u], u.id == ^user_id)
    |> Repo.one()
  end

  defp base_query do
    default_email = Notifications.default_preference(:weekly_digest).email

    from(u in User,
      as: :user,
      left_join: p in Preference,
      on: p.user_id == u.id and p.event_type == :weekly_digest,
      where: not is_nil(u.confirmed_at) and is_nil(u.disabled_at),
      where: p.email == true or (is_nil(p.id) and ^default_email),
      where: exists(from(bu in BoardUser, where: bu.user_id == parent_as(:user).id))
    )
  end
end
