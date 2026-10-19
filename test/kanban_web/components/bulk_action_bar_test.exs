defmodule KanbanWeb.BulkActionBarTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KanbanWeb.BulkActionBar

  describe "bulk_action_bar/1" do
    test "renders the controls when not locked" do
      html = render_component(&BulkActionBar.bulk_action_bar/1, count: 2)

      assert html =~ ~s(id="bulk-action-bar")
      assert html =~ "2 selected"
      refute html =~ "bulk-action-bar-locked"
    end

    test "renders only the locked Bulk actions prompt when locked" do
      html = render_component(&BulkActionBar.bulk_action_bar/1, count: 0, locked: true)

      assert html =~ ~s(id="bulk-action-bar-locked")
      assert html =~ ~s(data-locked-feature="bulk_actions")
      assert html =~ ~s(href="/locked/bulk_actions")
      assert html =~ "Bulk actions"
      assert html =~ "Available to organizations"
      refute html =~ ~s(id="bulk-action-bar")
      refute html =~ "bulk-move-form"
    end

    test "translates the locked prompt" do
      Gettext.with_locale(KanbanWeb.Gettext, "fr", fn ->
        html = render_component(&BulkActionBar.bulk_action_bar/1, count: 0, locked: true)

        assert html =~ "Actions groupées"
      end)
    end
  end
end
