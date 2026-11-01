defmodule Kanban.Attachments.Policy do
  @moduledoc """
  Who may upload, read and delete task attachments.

  The single permission source for `Kanban.Attachments`, so the board UI, the
  REST API and MCP cannot drift apart:

    * **upload** — the board owner and `:modify` members. A comment-level
      upload additionally needs the viewer to be the comment's author
      (`:upload_to_comment`); the caller checks that the comment is on the
      same task.
    * **read** (list and download) — every board member, `:read_only`
      included.
    * **delete** — the uploader, while still a member, or the board owner.

  Access is read live through `Kanban.Boards.get_user_access/2`, once per
  call through `resolve/2`, so a user removed from the board loses these
  rights at once. An Organization admin whose access derives as `:owner`
  counts as the owner. `scope` is anything shaped `%{user: %{id: id}}`; `nil`
  or any other value has no access. `board_id` must be the board found
  through the task's column, never one a client supplied.

  `member?/1` separates the two refusals `Kanban.Attachments` returns: a
  non-member gets `{:error, :not_found}`, so attachment ids reveal nothing,
  and a member without the right gets `{:error, :unauthorized}`.
  """

  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Boards
  alias Kanban.Tasks.TaskComment

  @typedoc "The caller's access to one board, resolved once by `resolve/2`."
  @type viewer :: %{
          user_id: integer() | nil,
          access: :owner | :modify | :read_only | nil
        }

  @doc """
  Resolves the scope's access to `board_id` with a single lookup. A `nil`
  scope, a scope without a user, or a non-member resolves to `access: nil`.
  """
  @spec resolve(term(), term()) :: viewer()
  def resolve(scope, board_id), do: %{user_id: user_id(scope), access: access(scope, board_id)}

  @doc "`true` when the viewer is a member of the board at any access level."
  @spec member?(viewer()) :: boolean()
  def member?(%{access: access}), do: not is_nil(access)

  @doc """
  `true` when the viewer may `:upload` (owner or modify) or `:read` (any
  member).
  """
  @spec allowed?(viewer(), :upload | :read) :: boolean()
  def allowed?(%{access: access}, :upload), do: access in [:owner, :modify]
  def allowed?(viewer, :read), do: member?(viewer)

  @doc """
  `true` when the viewer may `:delete` the attachment (uploader or owner) or
  `:upload_to_comment` the comment (upload right and the comment's author).
  """
  @spec allowed?(viewer(), :delete | :upload_to_comment, struct()) :: boolean()
  def allowed?(%{access: nil}, _action, _subject), do: false
  def allowed?(%{access: :owner}, :delete, %TaskAttachment{}), do: true

  def allowed?(viewer, :delete, %TaskAttachment{uploaded_by_id: uploader_id}),
    do: same_user?(viewer, uploader_id)

  def allowed?(viewer, :upload_to_comment, %TaskComment{author_user_id: author_id}),
    do: allowed?(viewer, :upload) and same_user?(viewer, author_id)

  @doc "`true` when the scope's user may upload to `board_id`."
  @spec can_upload?(term(), integer()) :: boolean()
  def can_upload?(scope, board_id), do: scope |> resolve(board_id) |> allowed?(:upload)

  @doc "`true` when the scope's user may list and download on `board_id`."
  @spec can_read?(term(), integer()) :: boolean()
  def can_read?(scope, board_id), do: scope |> resolve(board_id) |> allowed?(:read)

  @doc "`true` when the scope's user may delete `attachment` on `board_id`."
  @spec can_delete?(term(), integer(), TaskAttachment.t()) :: boolean()
  def can_delete?(scope, board_id, %TaskAttachment{} = attachment),
    do: scope |> resolve(board_id) |> allowed?(:delete, attachment)

  defp access(%{user: %{id: user_id}}, board_id)
       when is_integer(user_id) and is_integer(board_id),
       do: Boards.get_user_access(board_id, user_id)

  defp access(_scope, _board_id), do: nil

  defp user_id(%{user: %{id: user_id}}) when is_integer(user_id), do: user_id
  defp user_id(_scope), do: nil

  defp same_user?(%{user_id: user_id}, user_id) when is_integer(user_id), do: true
  defp same_user?(_viewer, _other_id), do: false
end
