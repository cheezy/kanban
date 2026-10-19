defmodule KanbanWeb.LockedFeatureTest do
  @moduledoc """
  Contract tests for `KanbanWeb.LockedFeature.locked_feature/1`, the one
  component for a paid feature that a free board or user cannot use.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Kanban.Plans
  alias KanbanWeb.LockedFeature

  @labels %{
    notifications: "Notifications",
    audit: "Audit",
    sso: "SSO",
    workspaces: "Workspaces",
    bulk_actions: "Bulk actions",
    integrations: "Integrations",
    telemetry: "Telemetry",
    mcp: "MCP"
  }

  defp render_locked(feature, variant) do
    assigns = %{feature: feature, variant: variant}

    rendered_to_string(~H"""
    <LockedFeature.locked_feature feature={@feature} variant={@variant} />
    """)
  end

  describe "locked_feature/1 for every feature" do
    test "has a label for each of Kanban.Plans.features/0" do
      assert @labels |> Map.keys() |> Enum.sort() == Enum.sort(Plans.features())
    end

    for variant <- [:inline, :panel] do
      test "renders the lock, the label and the prompt for each feature (#{variant})" do
        for feature <- Plans.features() do
          html = render_locked(feature, unquote(variant))

          assert html =~ "hero-lock-closed"
          assert html =~ ~s(data-locked-feature="#{feature}")
          assert html =~ ~s(data-variant="#{unquote(variant)}")
          assert html =~ Map.fetch!(@labels, feature)
          assert html =~ "Available to organizations"
          assert html =~ ~s(href="/locked/#{feature}")
        end
      end
    end
  end

  describe "locked_feature/1 prompt link" do
    test "links to /locked/:feature with rel nofollow" do
      link =
        render_locked(:bulk_actions, :inline)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("a[data-locked-feature-prompt]")

      assert Enum.count(link) == 1
      assert LazyHTML.attribute(link, "href") == ["/locked/bulk_actions"]
      assert LazyHTML.attribute(link, "rel") == ["nofollow"]
      assert LazyHTML.text(link) =~ "Available to organizations"
    end

    test "hides the lock icon from assistive technology" do
      doc = :sso |> render_locked(:panel) |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query(".hero-lock-closed") |> Enum.count() == 1

      assert doc
             |> LazyHTML.query("span[aria-hidden=true] > .hero-lock-closed")
             |> Enum.count() == 1
    end
  end

  describe "locked_feature/1 variants" do
    test "defaults to the inline variant" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <LockedFeature.locked_feature feature={:audit} />
        """)

      assert html =~ ~s(data-variant="inline")
    end

    test "the panel renders its inner_block as an inert, aria-disabled preview" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <LockedFeature.locked_feature feature={:workspaces} variant={:panel} id="locked-ws">
          <button type="button">Create workspace</button>
        </LockedFeature.locked_feature>
        """)

      doc = LazyHTML.from_fragment(html)
      preview = LazyHTML.query(doc, "[data-locked-preview]")

      assert doc |> LazyHTML.query("section#locked-ws") |> Enum.count() == 1
      assert Enum.count(preview) == 1
      assert doc |> LazyHTML.query("[data-locked-preview][inert]") |> Enum.count() == 1
      assert LazyHTML.attribute(preview, "aria-disabled") == ["true"]
      assert LazyHTML.text(preview) =~ "Create workspace"
    end

    test "the panel without an inner_block renders no preview" do
      refute render_locked(:telemetry, :panel) =~ "data-locked-preview"
    end

    test "uses ink tokens rather than opacity for its text" do
      for variant <- [:inline, :panel] do
        html = render_locked(:integrations, variant)

        assert html =~ "var(--ink)"
        assert html =~ "var(--ink-2)"
        refute html =~ "opacity"
      end
    end
  end

  describe "locked_feature/1 with an unknown feature" do
    test "raises ArgumentError" do
      for feature <- [:billing, nil, "audit"] do
        assert_raise ArgumentError, ~r/unknown locked feature/, fn ->
          render_locked(feature, :inline)
        end
      end
    end
  end

  describe "locked_feature/1 translations" do
    test "renders the label and prompt in the current locale" do
      Gettext.with_locale(KanbanWeb.Gettext, "fr", fn ->
        html = render_locked(:bulk_actions, :inline)

        refute html =~ "Available to organizations"
        refute html =~ "Bulk actions"
      end)
    end

    for {locale, label, prompt} <- [
          {"de", "Massenaktionen", "Für Organisationen verfügbar"},
          {"ja", "一括操作", "組織で利用可能"}
        ] do
      test "renders the long #{locale} label and prompt in rows that wrap" do
        Gettext.with_locale(KanbanWeb.Gettext, unquote(locale), fn ->
          inline = render_locked(:bulk_actions, :inline)
          panel = render_locked(:bulk_actions, :panel)

          for html <- [inline, panel] do
            assert html =~ unquote(label)
            assert html =~ unquote(prompt)
          end

          inline_row =
            inline |> LazyHTML.from_fragment() |> LazyHTML.query("[data-variant=inline]")

          panel_header = panel |> LazyHTML.from_fragment() |> LazyHTML.query("section > div")

          assert [inline_style] = LazyHTML.attribute(inline_row, "style")
          assert inline_style =~ "flex-wrap: wrap"
          assert Enum.any?(LazyHTML.attribute(panel_header, "style"), &(&1 =~ "flex-wrap: wrap"))
        end)
      end
    end
  end
end
