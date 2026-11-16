defmodule KanbanWeb.OrganizationTwoFactorBannerTest do
  @moduledoc """
  Contract tests for `KanbanWeb.OrganizationTwoFactorBanner.card/1`: the
  deadline renders in the viewer's timezone and language.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.LocalTime
  alias KanbanWeb.OrganizationTwoFactorBanner

  defp render_banner(deadline) do
    assigns = %{current_scope: %{two_factor_deadline: deadline}}

    rendered_to_string(~H"""
    <OrganizationTwoFactorBanner.card current_scope={@current_scope} />
    """)
  end

  test "names the deadline in the viewer's zone with its abbreviation" do
    LocalTime.put_timezone("America/Toronto")

    html =
      Gettext.with_locale(KanbanWeb.Gettext, "en", fn ->
        render_banner(~U[2099-01-15 04:56:00Z])
      end)

    assert html =~ "organization-two-factor-banner-deadline"
    assert html =~ "January 14, 2099 at 11:56 PM EST"
    refute html =~ "UTC"
  end

  test "names the deadline in the current language" do
    LocalTime.put_timezone("America/Toronto")

    html =
      Gettext.with_locale(KanbanWeb.Gettext, "de", fn ->
        render_banner(~U[2099-01-15 04:56:00Z])
      end)

    assert html =~ "14. Januar 2099, 23:56 EST"
  end

  test "says the grace period has ended once the deadline has passed" do
    html =
      Gettext.with_locale(KanbanWeb.Gettext, "en", fn ->
        render_banner(~U[2020-01-01 00:00:00Z])
      end)

    assert html =~ "organization-two-factor-banner-overdue"
    refute html =~ "organization-two-factor-banner-deadline"
  end

  test "renders nothing without a deadline" do
    assigns = %{}

    assert rendered_to_string(~H"""
           <OrganizationTwoFactorBanner.card current_scope={nil} />
           """) == ""
  end
end
