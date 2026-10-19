defmodule KanbanWeb.LockedFeature do
  @moduledoc """
  The one component for a paid feature a free board or user cannot use.

  The feature stays visible: a lock icon, its translated label and an
  Available to organizations prompt. The prompt links to `GET /locked/:feature`
  (`KanbanWeb.LockedFeatureController`), which counts the click and redirects
  to the pricing page, so every locked surface feeds the same per-feature
  metric.

  Two variants are recognised:

    * `:inline` — one compact row, for a menu item, a toolbar or a line of
      text.
    * `:panel` — a bordered card, for a whole section. Its optional
      `inner_block` renders a disabled preview of the feature: `inert` and
      `aria-disabled`, so it can be seen but not used.
  """
  use KanbanWeb, :html

  alias Kanban.Plans

  @features Plans.features()

  @doc """
  Renders a locked feature.

  ## Attrs

    * `feature` — one of `Kanban.Plans.features/0`. Required. Any other value
      raises `ArgumentError`.
    * `variant` — `:inline | :panel`. Defaults to `:inline`.
    * `id` — optional DOM id for the wrapper.

  An optional `inner_block` is rendered as a disabled preview in the `:panel`
  variant.
  """
  attr :feature, :atom, required: true, values: @features
  attr :variant, :atom, default: :inline, values: [:inline, :panel]
  attr :id, :string, default: nil
  slot :inner_block

  def locked_feature(assigns) do
    validate_feature!(assigns.feature)

    assigns =
      assigns
      |> assign(:label, label(assigns.feature))
      |> assign(:href, ~p"/locked/#{Atom.to_string(assigns.feature)}")

    render_variant(assigns)
  end

  defp render_variant(%{variant: :inline} = assigns) do
    ~H"""
    <span
      id={@id}
      data-locked-feature={@feature}
      data-variant="inline"
      style={[
        "display: inline-flex; align-items: center; flex-wrap: wrap;",
        "gap: 4px 6px; font-size: 12.5px; line-height: 1.4; color: var(--ink-2);"
      ]}
    >
      <span aria-hidden="true" style="display: inline-flex; color: var(--ink-3);">
        <.icon name="hero-lock-closed" class="w-4 h-4 flex-shrink-0" />
      </span>
      <span style="color: var(--ink); font-weight: 500;">{@label}</span>
      <.prompt href={@href} />
    </span>
    """
  end

  defp render_variant(%{variant: :panel} = assigns) do
    ~H"""
    <section
      id={@id}
      data-locked-feature={@feature}
      data-variant="panel"
      style={[
        "background: var(--surface); border: 1px solid var(--line);",
        "border-radius: 8px; padding: 12px 14px; box-shadow: var(--shadow-sm);"
      ]}
    >
      <div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;">
        <span aria-hidden="true" style="display: inline-flex; color: var(--ink-3);">
          <.icon name="hero-lock-closed" class="w-5 h-5 flex-shrink-0" />
        </span>
        <h3 style="margin: 0; font-size: 13px; font-weight: 600; color: var(--ink);">
          {@label}
        </h3>
      </div>
      <div
        :if={@inner_block != []}
        data-locked-preview
        inert
        aria-disabled="true"
        style={[
          "margin-top: 10px; padding: 10px; border: 1px dashed var(--line);",
          "border-radius: 6px; background: var(--surface-sunken);",
          "pointer-events: none; user-select: none; filter: grayscale(1);"
        ]}
      >
        {render_slot(@inner_block)}
      </div>
      <p style="margin: 10px 0 0; font-size: 12.5px; color: var(--ink-2);">
        <.prompt href={@href} />
      </p>
    </section>
    """
  end

  attr :href, :string, required: true

  defp prompt(assigns) do
    ~H"""
    <.link
      href={@href}
      rel="nofollow"
      data-locked-feature-prompt
      style="color: var(--ink); font-weight: 500; text-decoration: underline; text-underline-offset: 2px;"
    >
      {gettext("Available to organizations")}
    </.link>
    """
  end

  defp validate_feature!(feature) when feature in @features, do: :ok

  defp validate_feature!(feature) do
    raise ArgumentError,
          "unknown locked feature #{inspect(feature)}, expected one of #{inspect(@features)}"
  end

  # One literal gettext call per feature, so extraction picks up every label.
  defp label(:notifications), do: gettext("Notifications")
  defp label(:audit), do: gettext("Audit")
  defp label(:sso), do: gettext("SSO")
  defp label(:workspaces), do: gettext("Workspaces")
  defp label(:bulk_actions), do: gettext("Bulk actions")
  defp label(:integrations), do: gettext("Integrations")
  defp label(:telemetry), do: gettext("Telemetry")
  defp label(:mcp), do: gettext("MCP")
end
