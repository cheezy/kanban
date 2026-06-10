defmodule KanbanWeb.FormHelpersTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.FormHelpers

  describe "field_errors/1" do
    test "renders a translated span per error" do
      assigns = %{errors: [{"can't be blank", []}, {"is too short", []}]}

      html =
        rendered_to_string(~H"""
        <FormHelpers.field_errors errors={@errors} />
        """)

      assert html =~ "can&#39;t be blank"
      assert html =~ "is too short"
      assert html =~ ~s|style="font-size: 11.5px; color: var(--st-blocked);"|
    end

    test "interpolates error bindings via translate_error" do
      assigns = %{errors: [{"should be at least %{count} character(s)", [count: 12]}]}

      html =
        rendered_to_string(~H"""
        <FormHelpers.field_errors errors={@errors} />
        """)

      assert html =~ "should be at least 12 character(s)"
    end

    test "renders nothing for an empty error list" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <FormHelpers.field_errors errors={[]} />
        """)

      refute html =~ "<span"
    end

    test "defaults to no errors when the attr is omitted" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <FormHelpers.field_errors />
        """)

      refute html =~ "<span"
    end
  end
end
