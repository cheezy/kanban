defmodule KanbanWeb.AuditLogMetadataTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KanbanWeb.AuditLogMetadata

  defp render_metadata(metadata),
    do: render_component(&AuditLogMetadata.audit_metadata/1, metadata: metadata)

  test "renders pretty JSON for wide screens and clamped compact JSON for phones" do
    metadata = %{"user_id" => 15, "format" => "csv"}
    html = render_metadata(metadata)
    escape = &(&1 |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string())
    pretty = metadata |> Jason.encode!(pretty: true) |> escape.()
    compact = metadata |> Jason.encode!() |> escape.()

    assert html =~ ~r/<pre data-audit-metadata="pretty" class="hidden sm:block[^"]*">/
    assert html =~ ~r/<details data-audit-metadata="compact" class="sm:hidden[^"]*">/
    assert html =~ ~s(<summary class="cursor-pointer line-clamp-2 break-all">#{compact}</summary>)
    # The pretty JSON appears twice: the wide-screen <pre> and the opened <details>.
    assert length(String.split(html, pretty)) == 3
  end

  test "renders nothing for empty or missing metadata" do
    assert render_metadata(%{}) |> String.trim() == ""
    assert render_metadata(nil) |> String.trim() == ""
  end

  test "escapes markup in metadata in both versions" do
    html = render_metadata(%{"name" => "<script>alert(1)</script>"})

    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
  end
end
