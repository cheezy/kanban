defmodule KanbanWeb.LocalTimeComponentTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import KanbanWeb.LocalTimeComponent

  alias KanbanWeb.LocalTime

  @dt ~U[2026-11-10 23:56:00Z]

  defp render_local_time(value, opts \\ []) do
    assigns = %{value: value, style: Keyword.get(opts, :style, :datetime)}

    rendered_to_string(~H"""
    <.local_time value={@value} style={@style} class="text-xs" />
    """)
  end

  test "uses the process timezone" do
    LocalTime.put_timezone("America/Toronto")

    html = Gettext.with_locale(KanbanWeb.Gettext, "en", fn -> render_local_time(@dt) end)

    assert html =~ ">November 10, 2026 at 6:56 PM</time>"
    assert html =~ ~s(title="November 10, 2026 at 6:56 PM EST")
  end

  test "keeps an ISO 8601 UTC datetime attribute" do
    LocalTime.put_timezone("Asia/Tokyo")

    html = Gettext.with_locale(KanbanWeb.Gettext, "ja", fn -> render_local_time(@dt) end)

    assert html =~ ~s(datetime="2026-11-10T23:56:00Z")
    assert html =~ ">2026年11月11日 08:56</time>"
    assert html =~ ~s(title="2026年11月11日 08:56 JST")

    tokyo = DateTime.shift_zone!(@dt, "Asia/Tokyo")
    assert render_local_time(tokyo) =~ ~s(datetime="2026-11-10T23:56:00Z")
  end

  test "renders a Date with an ISO date attribute and no zone in the title" do
    html =
      Gettext.with_locale(KanbanWeb.Gettext, "en", fn ->
        render_local_time(~D[2026-11-10], style: :date)
      end)

    assert html =~ ~s(datetime="2026-11-10")
    assert html =~ ~s(title="November 10, 2026")
    assert html =~ ">November 10, 2026</time>"
  end

  test "renders the requested style and passes global attributes through" do
    LocalTime.put_timezone("America/Toronto")

    html =
      Gettext.with_locale(KanbanWeb.Gettext, "en", fn ->
        render_local_time(@dt, style: :short_date)
      end)

    assert html =~ ~s(class="text-xs")
    assert html =~ ">Nov 10, 2026</time>"
  end

  test "renders the compact :short_datetime style" do
    LocalTime.put_timezone("America/Toronto")

    html =
      Gettext.with_locale(KanbanWeb.Gettext, "en", fn ->
        render_local_time(@dt, style: :short_datetime)
      end)

    assert html =~ ">Nov 10, 6:56 PM</time>"
    assert html =~ ~s(datetime="2026-11-10T23:56:00Z")
  end

  test "renders nothing for nil" do
    refute render_local_time(nil) =~ "<time"
  end

  test "defaults to the :datetime style" do
    assigns = %{value: @dt}

    html =
      Gettext.with_locale(KanbanWeb.Gettext, "en", fn ->
        rendered_to_string(~H"""
        <.local_time value={@value} />
        """)
      end)

    assert html =~ ">November 10, 2026 at 11:56 PM</time>"
  end

  test "escapes attribute values" do
    assigns = %{value: @dt, note: "<b>x</b>"}

    html =
      rendered_to_string(~H"""
      <.local_time value={@value} data-note={@note} />
      """)

    refute html =~ "<b>"
    assert html =~ "&lt;b&gt;x&lt;/b&gt;"
  end
end
