defmodule KanbanWeb.IntegrationsHTML do
  @moduledoc """
  Templates and components for `KanbanWeb.IntegrationsController`. See the
  `integrations_html` directory.
  """
  use KanbanWeb, :html

  embed_templates "integrations_html/*"

  @doc """
  The "Preview" badge for a runtime whose plugin is still in preview. Renders
  nothing otherwise.
  """
  attr :preview, :boolean, required: true

  def preview_badge(%{preview: true} = assigns) do
    ~H"""
    <span
      class="inline-block rounded-full px-2 py-0.5 text-xs font-semibold"
      style="border: 1px solid var(--stride-orange); color: var(--stride-orange-ink);"
      data-preview-badge
    >
      {gettext("Preview")}
    </span>
    """
  end

  def preview_badge(assigns), do: ~H""

  @doc """
  The label for where a runtime's plugin is listed.
  """
  @spec listing_label(KanbanWeb.Integrations.Runtime.listing_kind()) :: String.t()
  def listing_label(:marketplace), do: gettext("Marketplace")
  def listing_label(:extension_index), do: gettext("Extension index")
  def listing_label(:repository), do: gettext("Repository")

  @doc """
  A URL without its scheme, for link text.
  """
  @spec display_url(String.t()) :: String.t()
  def display_url(url), do: String.replace_prefix(url, "https://", "")
end
