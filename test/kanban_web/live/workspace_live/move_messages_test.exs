defmodule KanbanWeb.WorkspaceLive.MoveMessagesTest do
  use ExUnit.Case, async: true

  alias Kanban.Accounts.User
  alias KanbanWeb.WorkspaceLive.MoveMessages

  test "names the non-members, by name or else by email" do
    users = [
      %User{name: "Olive Outsider", email: "olive@x.test"},
      %User{name: "", email: "e@x.test"}
    ]

    assert MoveMessages.refusal({:non_members, users}) ==
             "That board can't be moved here: Olive Outsider, e@x.test aren't members of this Organization. Remove them from the board, or invite them to this workspace, then move it."
  end

  test "names the board's attachment size, what is left and the shortfall in the attachment UI's units" do
    sizes = %{board_bytes: 3 * 1024 * 1024, available_bytes: 1024 * 1024, shortfall_bytes: 2048}

    assert MoveMessages.refusal({:quota_exceeded, sizes}) ==
             "That board can't be moved here: its attachments take 3 MB, but this Organization has 1 MB of attachment storage left, so it is 2 KB short. Delete attachments from the board or from this Organization's other boards, then move it."
  end

  test "is translated, sizes included" do
    sizes = %{board_bytes: 45, available_bytes: 0, shortfall_bytes: 2048}

    message =
      Gettext.with_locale(KanbanWeb.Gettext, "fr", fn ->
        MoveMessages.refusal({:quota_exceeded, sizes})
      end)

    assert message =~ "Ce tableau ne peut pas être déplacé ici : ses pièces jointes occupent 45 o"
    assert message =~ "que 0 o d’espace"
    assert message =~ "soit 2 Ko de moins"
  end

  test "gives the generic refusal for any other reason" do
    for reason <- [:not_found, :not_owner, :not_in_personal_workspace, :something_else] do
      assert MoveMessages.refusal(reason) ==
               "That board can't be moved here. Choose a board you own in your personal boards."
    end
  end
end
