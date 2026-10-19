defmodule Kanban.Plans.LockedFeatureClick do
  @moduledoc """
  When one user's click on one locked feature's prompt was last counted.

  `Kanban.Plans.LockedFeatureClicks` is the only writer. There is one row per
  user and feature, which the unique index on `[:user_id, :feature]`
  enforces, and nothing here is cast from request params.
  """
  use Ecto.Schema

  alias Kanban.Accounts.User

  @type t :: %__MODULE__{}

  schema "locked_feature_clicks" do
    field :feature, Ecto.Enum, values: Kanban.Plans.features()
    field :counted_at, :utc_datetime_usec

    belongs_to :user, User
  end
end
