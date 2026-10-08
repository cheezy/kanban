defmodule KanbanWeb.TaskLive.Components.CommentRowTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Kanban.Tasks.TaskComment
  alias KanbanWeb.TaskLive.Components.CommentRow

  defp entry(comment, flags \\ %{}) do
    Map.merge(%{comment: comment, can_edit: false, can_delete: false}, flags)
  end

  defp comment(attrs) do
    struct(
      %TaskComment{
        id: 1,
        content: "Hello",
        author: nil,
        author_agent_name: nil,
        edited_at: nil,
        inserted_at: ~N[2024-01-15 10:30:00]
      },
      attrs
    )
  end

  defp render_row(entry, attrs \\ []) do
    render_component(&CommentRow.comment_row/1, [entry: entry] ++ attrs)
  end

  describe "comment_row/1" do
    test "renders \"Unknown\" for a comment with no author" do
      html = render_row(entry(comment(%{author: nil})))

      assert html =~ "Unknown"
      assert html =~ "Hello"
    end

    test "renders the author's name, falling back to email when the name is blank" do
      named = render_row(entry(comment(%{author: %{id: 7, name: "Ada", email: "ada@x.test"}})))
      blank = render_row(entry(comment(%{author: %{id: 7, name: "", email: "ada@x.test"}})))

      assert named =~ "Ada"
      refute named =~ "ada@x.test"
      assert blank =~ "ada@x.test"
    end

    test "renders the agent name and the via-user label for an agent comment" do
      html =
        render_row(
          entry(
            comment(%{
              author_agent_name: "Claude Opus 5.5",
              author: %{id: 7, name: "Ada", email: "ada@x.test"}
            })
          )
        )

      assert html =~ "Claude Opus 5.5"
      assert html =~ "via Ada"
    end

    test "renders the edited marker only when edited_at is present" do
      plain = render_row(entry(comment(%{})))
      edited = render_row(entry(comment(%{edited_at: ~U[2024-01-16 09:00:00Z]})))

      refute plain =~ "data-comment-edited"
      assert edited =~ "data-comment-edited"
      assert edited =~ "edited"
    end

    test "renders a relative time from the naive inserted_at" do
      inserted_at = NaiveDateTime.add(NaiveDateTime.utc_now(), -3 * 3600)
      html = render_row(entry(comment(%{inserted_at: inserted_at})))

      assert html =~ "3h ago"
      assert html =~ ~s(datetime=")
    end

    test "shows edit and delete controls only when allowed" do
      none = render_row(entry(comment(%{})))
      delete_only = render_row(entry(comment(%{}), %{can_delete: true}))
      both = render_row(entry(comment(%{}), %{can_edit: true, can_delete: true}))

      refute none =~ "edit_comment"
      refute none =~ "delete_comment"
      refute delete_only =~ "edit_comment"
      assert delete_only =~ "delete_comment"
      assert both =~ "edit_comment"
      assert both =~ "delete_comment"
    end

    test "escapes comment content and keeps a very long word wrappable" do
      long_word = String.duplicate("a", 2_000)
      html = render_row(entry(comment(%{content: "<script>alert(1)</script> " <> long_word})))

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
      assert html =~ long_word
      assert html =~ ~r/data-comment-body[^>]*overflow-wrap: anywhere/
    end

    test "gives each row the id comment_dom_id/2 names" do
      html = render_row(entry(comment(%{id: 42})), dom_prefix: "comment-thread-view-7")

      assert CommentRow.comment_dom_id("comment-thread-view-7", %{id: 42}) ==
               "comment-thread-view-7-comment-42"

      assert html =~ ~s(id="comment-thread-view-7-comment-42")
    end

    # The body is white-space: pre-wrap, so any template whitespace inside the
    # tag would render as a blank line and an indent above the text.
    test "renders the body with no surrounding whitespace" do
      html = render_row(entry(comment(%{content: "Hello"})))

      assert html =~ ~r/data-comment-body[^>]*>Hello<\/p>/
    end

    test "keeps a multi-line body's own line breaks and nothing more" do
      html = render_row(entry(comment(%{content: "line one\nline two"})))

      assert html =~ ~r/data-comment-body[^>]*>line one\nline two<\/p>/
    end

    test "renders a resolved mention as a chip with the member's current name" do
      html =
        render_row(
          entry(comment(%{content: "hi @[Old Name](user:7)!"}), %{mentions: %{7 => "Ada"}})
        )

      assert html =~ ~r/data-mention-chip[^>]*data-user-id="7"/
      assert html =~ "@Ada"
      refute html =~ "Old Name"
      refute html =~ "(user:7)"
    end

    test "emits the mention segments with no whitespace between them" do
      html =
        render_row(entry(comment(%{content: "hi @[A](user:7)!"}), %{mentions: %{7 => "Ada"}}))

      assert html =~ ~r/data-comment-body[^>]*>hi <span data-mention-chip/
      assert html =~ ~r/@Ada<\/span>!<\/p>/
    end

    test "renders an unresolved token, or a row with no mentions map, as plain text" do
      unresolved =
        render_row(entry(comment(%{content: "@[Bo](user:8)"}), %{mentions: %{7 => "Ada"}}))

      legacy = render_row(entry(comment(%{content: "@[Bo](user:8)"})))

      for html <- [unresolved, legacy] do
        refute html =~ "data-mention-chip"
        assert html =~ ~r/data-comment-body[^>]*>@\[Bo\]\(user:8\)<\/p>/
      end
    end

    test "escapes markup in mention names and around mention tokens" do
      content = "<script>x</script>@[<img src=x onerror=alert(1)>](user:7) @[<b>](user:9)"

      html =
        render_row(entry(comment(%{content: content}), %{mentions: %{7 => "<i>Ada</i>"}}))

      refute html =~ "<script>"
      refute html =~ "<img src=x"
      refute html =~ "<i>Ada</i>"
      refute html =~ "<b>"
      assert html =~ "&lt;script&gt;x&lt;/script&gt;"
      assert html =~ "@&lt;i&gt;Ada&lt;/i&gt;"
      assert html =~ "@[&lt;b&gt;](user:9)"
    end

    test "styles the chip with theme tokens only" do
      html =
        render_row(entry(comment(%{content: "@[A](user:7)"}), %{mentions: %{7 => "Ada"}}))

      assert html =~ "background: var(--st-ready-soft)"
      assert html =~ "border: 1px solid var(--line)"
      assert html =~ "color: var(--ink)"
    end
  end

  describe "comment_row/1 edit form" do
    test "renders the edit textarea with the mention autocomplete hook" do
      comment = comment(%{id: 5, content: "Draft"})
      form = comment |> TaskComment.changeset(%{}) |> Phoenix.Component.to_form(id: "t-edit-5")

      html =
        render_row(entry(comment, %{can_edit: true}),
          editing: true,
          edit_form: form,
          dom_prefix: "t"
        )

      assert html =~ ~s(phx-hook="MentionAutocomplete")
      assert html =~ ~s(id="t-edit-5_content-mentions")
      refute html =~ "data-comment-body"
    end
  end
end
