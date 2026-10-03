defmodule Kanban.Notifications.Notification do
  @moduledoc """
  An in-app notification for one user.

  `title` and `body` are stored as plain text; templates and emails escape
  them at render time, so pre-rendered HTML must never be stored here.

  `board_id` is nullable only for the account-level event types in
  `board_less_event_types/0` (for example being removed from a board), so
  those stay visible after membership ends. Every other event type must name
  its board. On a board-less row the changeset rejects:

    * a `task_id` (also enforced by the `notifications_task_requires_board`
      check constraint),
    * a board-scoped `url_path` (`/boards/<id>` and anything under it), and
    * `metadata` keys that name a task (any key containing "task" or
      "identifier").

  `title` and `body` are free text the changeset cannot inspect, so callers
  emitting a board-less event must keep task titles and identifiers out of
  them; anything task-specific belongs on a board-scoped row, which
  `Kanban.Notifications` hides once membership ends.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Kanban.Notifications.Preference

  @cast_fields [
    :board_id,
    :task_id,
    :title,
    :body,
    :url_path,
    :actor_name,
    :metadata,
    :dedupe_key
  ]
  @board_less_event_types [:board_access_changed, :weekly_digest, :target_status_changed]

  # App-relative only: one leading slash, never "//" or "/\\", and no
  # whitespace or control characters anywhere (browsers strip tab/newline,
  # which would turn "/\t/evil" into the protocol-relative "//evil").
  @url_path_format ~r{\A/(?![/\\])[^\s\x00-\x1f\x7f]*\z}
  @board_scoped_path ~r{\A/boards/\d+(?:[/?#]|\z)}
  @task_metadata_key ~r/task|identifier/i

  @type t :: %__MODULE__{}

  schema "notifications" do
    belongs_to :user, Kanban.Accounts.User
    belongs_to :board, Kanban.Boards.Board
    belongs_to :task, Kanban.Tasks.Task

    field :event_type, Ecto.Enum, values: Preference.event_types()
    field :title, :string
    field :body, :string
    field :url_path, :string
    field :actor_name, :string
    field :metadata, :map, default: %{}
    field :dedupe_key, :string
    field :read_at, :utc_datetime_usec
    field :emailed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the event types whose notifications may omit `board_id`.
  """
  def board_less_event_types, do: @board_less_event_types

  @doc """
  Builds a changeset for a new notification.

  `user_id` and `event_type` are not cast: the context sets them on the
  struct, so attributes can never redirect a notification to another user.
  """
  def changeset(notification, attrs) do
    notification
    |> cast(attrs, @cast_fields)
    |> put_default_metadata()
    |> validate_required([:user_id, :event_type, :title])
    |> validate_length(:title, max: 255)
    |> validate_length(:url_path, max: 255)
    |> validate_length(:actor_name, max: 255)
    |> validate_length(:dedupe_key, max: 255)
    |> validate_format(:url_path, @url_path_format, message: "must be an app-relative path")
    |> validate_board_presence()
    |> check_constraint(:board_id,
      name: :notifications_task_requires_board,
      message: "is required when a task is referenced"
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:board_id)
    |> foreign_key_constraint(:task_id)
    |> unique_constraint([:user_id, :dedupe_key])
  end

  defp put_default_metadata(changeset) do
    case get_field(changeset, :metadata) do
      nil -> put_change(changeset, :metadata, %{})
      _ -> changeset
    end
  end

  defp validate_board_presence(changeset) do
    board_id = get_field(changeset, :board_id)

    cond do
      not is_nil(board_id) ->
        changeset

      get_field(changeset, :task_id) ->
        add_error(changeset, :board_id, "is required when a task is referenced")

      get_field(changeset, :event_type) in @board_less_event_types ->
        validate_board_less_payload(changeset)

      true ->
        add_error(changeset, :board_id, "is required for this event type")
    end
  end

  # Board-less rows outlive board membership, so they must not point at or
  # describe anything inside a board.
  defp validate_board_less_payload(changeset) do
    changeset
    |> validate_change(:url_path, fn :url_path, path ->
      if Regex.match?(@board_scoped_path, path),
        do: [url_path: "must not point inside a board on a board-less notification"],
        else: []
    end)
    |> validate_change(:metadata, fn :metadata, metadata ->
      if metadata |> Map.keys() |> Enum.any?(&task_metadata_key?/1),
        do: [metadata: "must not carry task data on a board-less notification"],
        else: []
    end)
  end

  defp task_metadata_key?(key), do: key |> to_string() |> String.match?(@task_metadata_key)
end
