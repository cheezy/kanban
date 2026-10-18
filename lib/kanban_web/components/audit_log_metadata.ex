defmodule KanbanWeb.AuditLogMetadata do
  @moduledoc """
  The Details cell of the audit-log tables, shared by the site-admin viewer
  (`KanbanWeb.Admin.AuditLogLive.Index`) and the Organization viewer
  (`KanbanWeb.OrgLive.AuditLog`).

  From the `sm` breakpoint up it shows the event's metadata as pretty-printed
  JSON, one key per line. Below it, where pretty JSON made each row several
  times taller than the screen could spare, it shows the same metadata as
  compact JSON clamped to two lines inside a native `<details>`; tapping it
  opens the pretty version. Both are rendered as escaped text, never raw HTML.
  """
  use KanbanWeb, :html

  @doc """
  Renders an event's metadata. Empty or missing metadata renders nothing.
  """
  attr :metadata, :map, default: nil

  def audit_metadata(assigns) do
    assigns =
      assign(assigns,
        pretty: encode(assigns.metadata, pretty: true),
        compact: encode(assigns.metadata, [])
      )

    ~H"""
    <pre
      :if={@pretty != ""}
      data-audit-metadata="pretty"
      class="hidden sm:block min-w-48 max-w-xl whitespace-pre-wrap break-all font-mono text-xs text-base-content"
    >{@pretty}</pre>
    <details
      :if={@pretty != ""}
      data-audit-metadata="compact"
      class="sm:hidden w-48 font-mono text-xs text-base-content"
    >
      <summary class="cursor-pointer line-clamp-2 break-all">{@compact}</summary>
      <pre class="mt-1 whitespace-pre-wrap break-all">{@pretty}</pre>
    </details>
    """
  end

  defp encode(metadata, _opts) when metadata == %{} or is_nil(metadata), do: ""
  defp encode(metadata, opts), do: Jason.encode!(metadata, opts)
end
