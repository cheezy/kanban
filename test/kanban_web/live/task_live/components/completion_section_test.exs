defmodule KanbanWeb.TaskLive.Components.CompletionSectionTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.LocalTime
  alias KanbanWeb.TaskLive.Components.CompletionSection

  defp task(attrs) do
    Map.merge(
      %{
        completed_at: nil,
        completed_by: nil,
        completed_by_agent: nil,
        completion_summary: nil,
        completion_notes: nil
      },
      attrs
    )
  end

  defp render_section(task) do
    assigns = %{task: task}

    rendered_to_string(~H"""
    <CompletionSection.completion_section task={@task} />
    """)
  end

  describe "completion_section/1 — local time" do
    test "renders completed_at in the viewer's timezone" do
      LocalTime.put_timezone("America/Toronto")

      html = render_section(task(%{completed_at: ~U[2026-11-11 04:56:00Z]}))

      assert html =~ "Completed at"
      assert html =~ "November 10, 2026 at 11:56 PM"
      assert html =~ ~s(datetime="2026-11-11T04:56:00Z")
    end

    test "renders completed_at in the UI language" do
      LocalTime.put_timezone("Asia/Tokyo")

      html =
        Gettext.with_locale(KanbanWeb.Gettext, "ja", fn ->
          render_section(task(%{completed_at: ~U[2026-11-11 04:56:00Z]}))
        end)

      assert html =~ "2026年11月11日 13:56"
    end

    test "renders no timestamp when completed_at is nil" do
      html = render_section(task(%{completion_summary: "Done"}))

      assert html =~ "Done"
      refute html =~ "Completed at"
      refute html =~ "<time"
    end
  end
end
