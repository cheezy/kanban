defmodule KanbanWeb.AuthComponentsTest do
  use KanbanWeb.ConnCase

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.AuthComponents

  describe "auth_form/1" do
    test "renders the title and inner block markup" do
      assigns = %{title: "Forgot your password?"}

      html =
        rendered_to_string(~H"""
        <AuthComponents.auth_form title={@title}>
          <form id="my-form"><input name="email" /></form>
        </AuthComponents.auth_form>
        """)

      assert html =~ "Forgot your password?"
      assert html =~ ~s(id="my-form")
      assert html =~ ~s(name="email")
    end

    test "renders the subtitle when provided" do
      assigns = %{
        title: "Forgot your password?",
        subtitle: "We'll send you an email with instructions to reset your password."
      }

      html =
        rendered_to_string(~H"""
        <AuthComponents.auth_form title={@title} subtitle={@subtitle}>
          <span>body</span>
        </AuthComponents.auth_form>
        """)

      assert html =~ "send you an email with instructions"
    end

    test "omits the subtitle paragraph when no subtitle is provided" do
      assigns = %{title: "Reset password"}

      html =
        rendered_to_string(~H"""
        <AuthComponents.auth_form title={@title}>
          <span>body</span>
        </AuthComponents.auth_form>
        """)

      refute html =~ "opacity-70 mt-2"
    end

    test "always renders the Back to log in link to the log-in route" do
      assigns = %{title: "Reset password"}

      html =
        rendered_to_string(~H"""
        <AuthComponents.auth_form title={@title}>
          <span>body</span>
        </AuthComponents.auth_form>
        """)

      assert html =~ ~s(href="/users/log-in")
      assert html =~ "Back to log in"
    end
  end
end
