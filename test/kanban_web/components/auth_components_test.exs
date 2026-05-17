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

    test "renders the subtitle slot when provided" do
      assigns = %{title: "Forgot your password?"}

      html =
        rendered_to_string(~H"""
        <AuthComponents.auth_form title={@title}>
          <:subtitle>
            We'll send you an email with instructions to reset your password.
          </:subtitle>
          <span>body</span>
        </AuthComponents.auth_form>
        """)

      assert html =~ "send you an email with instructions"
    end

    test "renders rich subtitle markup (links, conditional text) inside the subtitle slot" do
      assigns = %{title: "Welcome Back"}

      html =
        rendered_to_string(~H"""
        <AuthComponents.auth_form title={@title}>
          <:subtitle>
            Don't have an account? <a href="/users/register" class="signup-link">Sign up</a> for free.
          </:subtitle>
          <span>body</span>
        </AuthComponents.auth_form>
        """)

      assert html =~ "Don't have an account?"
      assert html =~ ~s(href="/users/register")
      assert html =~ "signup-link"
      assert html =~ "Sign up"
    end

    test "omits the subtitle paragraph when no subtitle slot is provided" do
      assigns = %{title: "Reset password"}

      html =
        rendered_to_string(~H"""
        <AuthComponents.auth_form title={@title}>
          <span>body</span>
        </AuthComponents.auth_form>
        """)

      refute html =~ "opacity-70 mt-2"
    end

    test "renders the default Stride-orange gradient icon when no icon attrs are supplied" do
      assigns = %{title: "Reset password"}

      html =
        rendered_to_string(~H"""
        <AuthComponents.auth_form title={@title}>
          <span>body</span>
        </AuthComponents.auth_form>
        """)

      assert html =~ "from-orange-500"
      assert html =~ "to-orange-600"
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
      refute html =~ "from-orange-500"
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

    test "renders the default Back to log in link when no footer slot is provided" do
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

    test "renders the supplied footer slot instead of the default Back to log in link" do
      assigns = %{title: "Welcome Back"}

      html =
        rendered_to_string(~H"""
        <AuthComponents.auth_form title={@title}>
          <:footer>
            <a href="/users/forgot-password" class="forgot-link">Forgot your password?</a>
          </:footer>
          <span>body</span>
        </AuthComponents.auth_form>
        """)

      assert html =~ ~s(href="/users/forgot-password")
      assert html =~ "forgot-link"
      assert html =~ "Forgot your password?"
      refute html =~ "Back to log in"
    end
  end

  describe "settings_card/1" do
    test "renders the title heading and inner block content" do
      assigns = %{title: "Profile Information"}

      html =
        rendered_to_string(~H"""
        <AuthComponents.settings_card title={@title}>
          <form id="profile_form"><input name="email" /></form>
        </AuthComponents.settings_card>
        """)

      assert html =~ "Profile Information"
      assert html =~ ~s(id="profile_form")
      assert html =~ ~s(name="email")
    end

    test "uses the same card chrome classes as auth_form" do
      assigns = %{title: "Change Password"}

      html =
        rendered_to_string(~H"""
        <AuthComponents.settings_card title={@title}>
          <span>body</span>
        </AuthComponents.settings_card>
        """)

      assert html =~ "bg-base-100"
      assert html =~ "rounded-2xl"
      assert html =~ "shadow-xl"
      assert html =~ "border-base-300"
    end

    test "does not render the auth_form footer or default Back to log in link" do
      assigns = %{title: "Profile Information"}

      html =
        rendered_to_string(~H"""
        <AuthComponents.settings_card title={@title}>
          <span>body</span>
        </AuthComponents.settings_card>
        """)

      refute html =~ "Back to log in"
    end
  end
end
