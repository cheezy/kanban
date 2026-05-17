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

    test "renders the default blue gradient icon when no icon attrs are supplied" do
      assigns = %{title: "Reset password"}

      html =
        rendered_to_string(~H"""
        <AuthComponents.auth_form title={@title}>
          <span>body</span>
        </AuthComponents.auth_form>
        """)

      assert html =~ "from-blue-600"
      assert html =~ "to-blue-700"
      assert html =~ "bg-gradient-to-br"

      assert html =~
               ~s(d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z")
    end

    test "renders the supplied icon_gradient classes" do
      assigns = %{
        title: "Create account",
        icon_gradient: "from-violet-500 to-purple-600"
      }

      html =
        rendered_to_string(~H"""
        <AuthComponents.auth_form title={@title} icon_gradient={@icon_gradient}>
          <span>body</span>
        </AuthComponents.auth_form>
        """)

      assert html =~ "from-violet-500"
      assert html =~ "to-purple-600"
      refute html =~ "from-blue-600"
    end

    test "renders the supplied icon_path inside the SVG element" do
      custom_path = "M12 4v16m8-8H4"

      assigns = %{title: "Create account", icon_path: custom_path}

      html =
        rendered_to_string(~H"""
        <AuthComponents.auth_form title={@title} icon_path={@icon_path}>
          <span>body</span>
        </AuthComponents.auth_form>
        """)

      assert html =~ ~s(d="#{custom_path}")
      refute html =~ "M15 7a2 2 0 012 2m4 0a6"
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
