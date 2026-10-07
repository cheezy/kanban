defmodule Kanban.Tasks.CommentPolicy do
  @moduledoc """
  Who may create, edit and delete task comments.

  The single permission source shared by the board UI, the REST API and the
  MCP `stride_add_comment` tool, so those surfaces cannot drift apart:

    * **comment** — any member of the board (`:owner`, `:modify` or
      `:read_only`). Commenting is discussion, not task mutation, so read-only
      members are included; non-members are refused.
    * **edit** — only the comment's author, and only while they are still a
      board member. A legacy comment with no author cannot be edited.
    * **delete** — the comment's author (while still a member) or the board
      owner.

  Every predicate reads the caller's access live through
  `Kanban.Boards.get_user_access/2`, so a user removed from the board loses
  these rights at once. `scope` is anything shaped `%{user: %{id: id}}` (a
  `Kanban.Accounts.Scope` or an equivalent map); `nil` or any other value has
  no access. `board_id` must be the board the comment's task lives on, derived
  server-side by the caller — never a board id supplied by a client.
  """

  alias Kanban.Boards
  alias Kanban.Tasks.TaskComment

  @typedoc """
  The caller's access to one board, resolved once by `resolve/2` so that many
  comments can be checked with `allowed?/2` and `allowed?/3` without a query
  per comment.
  """
  @type viewer :: %{
          user_id: integer() | nil,
          access: :owner | :modify | :read_only | nil
        }

  @doc """
  Resolves the scope's access to `board_id` with a single lookup.

  A `nil` scope, a scope without a user, or a non-member resolves to a viewer
  with `access: nil`, which every `allowed?` check refuses.
  """
  @spec resolve(term(), integer()) :: viewer()
  def resolve(scope, board_id), do: %{user_id: user_id(scope), access: access(scope, board_id)}

  @doc """
  `true` when the resolved viewer may comment on the board (any membership).
  """
  @spec allowed?(viewer(), :comment) :: boolean()
  def allowed?(%{access: access}, :comment), do: not is_nil(access)

  @doc """
  `true` when the resolved viewer may `:edit` or `:delete` `comment`.

  Edit is author-only; delete is the author or the board owner. Both require
  the viewer to still be a board member, and a comment with no author is never
  "authored" by anyone.
  """
  @spec allowed?(viewer(), :edit | :delete, struct()) :: boolean()
  def allowed?(%{access: nil}, _action, _comment), do: false

  def allowed?(viewer, :edit, %TaskComment{author_user_id: author_id}),
    do: author?(viewer, author_id)

  def allowed?(%{access: :owner}, :delete, %TaskComment{}), do: true

  def allowed?(viewer, :delete, %TaskComment{author_user_id: author_id}),
    do: author?(viewer, author_id)

  @doc """
  `true` when the scope's user is a member of `board_id` at any access level.
  """
  @spec can_comment?(term(), integer()) :: boolean()
  def can_comment?(scope, board_id), do: scope |> resolve(board_id) |> allowed?(:comment)

  @doc """
  `true` only when the scope's user authored `comment` and is still a member
  of `board_id`. Always `false` for a comment with no author.
  """
  @spec can_edit?(term(), integer(), struct()) :: boolean()
  def can_edit?(scope, board_id, %TaskComment{} = comment) do
    scope |> resolve(board_id) |> allowed?(:edit, comment)
  end

  @doc """
  `true` when the scope's user owns `board_id`, or authored `comment` and is
  still a member of `board_id`.
  """
  @spec can_delete?(term(), integer(), struct()) :: boolean()
  def can_delete?(scope, board_id, %TaskComment{} = comment) do
    scope |> resolve(board_id) |> allowed?(:delete, comment)
  end

  defp access(%{user: %{id: user_id}}, board_id)
       when is_integer(user_id) and is_integer(board_id),
       do: Boards.get_user_access(board_id, user_id)

  defp access(_scope, _board_id), do: nil

  defp user_id(%{user: %{id: user_id}}) when is_integer(user_id), do: user_id
  defp user_id(_scope), do: nil

  defp author?(%{user_id: user_id}, user_id) when is_integer(user_id), do: true
  defp author?(_viewer, _author_id), do: false
end
