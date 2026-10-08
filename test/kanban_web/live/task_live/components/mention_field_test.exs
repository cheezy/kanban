defmodule KanbanWeb.TaskLive.Components.MentionFieldTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Kanban.Tasks.TaskComment
  alias KanbanWeb.TaskLive.Components.MentionField

  defp field do
    form =
      %TaskComment{}
      |> TaskComment.changeset(%{})
      |> Phoenix.Component.to_form(id: "thread-composer")

    form[:content]
  end

  test "listbox_id/1 is the textarea id plus -mentions" do
    assert MentionField.listbox_id(field()) == "thread-composer_content-mentions"
  end

  test "renders the hooked textarea pointing at its listbox" do
    html =
      render_component(&MentionField.mention_textarea/1,
        field: field(),
        label: "Add a comment",
        placeholder: "Write here"
      )

    assert html =~ ~s(id="thread-composer_content")
    assert html =~ ~s(phx-hook="MentionAutocomplete")
    assert html =~ ~s(aria-autocomplete="list")
    assert html =~ ~s(aria-controls="thread-composer_content-mentions")
    assert html =~ ~s(data-mention-listbox="thread-composer_content-mentions")
    assert html =~ ~s(autocomplete="off")
    assert html =~ ~s(maxlength="#{TaskComment.content_max_length()}")
    assert html =~ "Add a comment"
    assert html =~ ~s(placeholder="Write here")
  end

  test "renders a hidden, patch-ignored listbox with translated texts" do
    html = render_component(&MentionField.mention_textarea/1, field: field())

    assert html =~ ~r/<ul[^>]*id="thread-composer_content-mentions"[^>]*>/
    assert html =~ ~s(role="listbox")
    assert html =~ ~s(phx-update="ignore")
    assert html =~ ~s(aria-label="Board members")
    assert html =~ ~s(data-empty-text="No matching members")
    assert html =~ ~r/<ul[^>]*\shidden[\s>]/
    # No inline script: the behaviour lives in assets/js/hooks.
    refute html =~ "<script"
  end
end
