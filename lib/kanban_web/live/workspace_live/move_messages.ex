defmodule KanbanWeb.WorkspaceLive.MoveMessages do
  @moduledoc """
  The flash messages for a refused board move in
  `KanbanWeb.WorkspaceLive.Settings`, kept out of the LiveView to hold it
  under the size limit. `refusal/1` takes the reason
  `Kanban.Workspaces.move_board_to_workspace/3` returned.
  """

  use Gettext, backend: KanbanWeb.Gettext

  alias Kanban.Accounts.User
  alias KanbanWeb.TaskLive.AttachmentUploads

  @doc """
  The message for a refused move, in the current locale:

    * `{:non_members, users}` names the users outside the Organization;
    * `{:quota_exceeded, sizes}` names the board's attachment bytes, what the
      Organization has left and the shortfall, in the attachment UI's units;
    * anything else gets the generic refusal.
  """
  @spec refusal(term()) :: String.t()
  def refusal({:non_members, users}) do
    gettext(
      "That board can't be moved here: %{names} aren't members of this Organization. Remove them from the board, or invite them to this workspace, then move it.",
      names: Enum.map_join(users, ", ", &name_or_email/1)
    )
  end

  def refusal(
        {:quota_exceeded,
         %{board_bytes: board, available_bytes: available, shortfall_bytes: shortfall}}
      ) do
    gettext(
      "That board can't be moved here: its attachments take %{board}, but this Organization has %{available} of attachment storage left, so it is %{shortfall} short. Delete attachments from the board or from this Organization's other boards, then move it.",
      board: AttachmentUploads.format_size(board),
      available: AttachmentUploads.format_size(available),
      shortfall: AttachmentUploads.format_size(shortfall)
    )
  end

  def refusal(_reason),
    do: gettext("That board can't be moved here. Choose a board you own in your personal boards.")

  defp name_or_email(%User{name: name}) when is_binary(name) and name != "", do: name
  defp name_or_email(%User{email: email}), do: email
end
