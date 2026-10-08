defmodule KanbanWeb.UserLive.SettingsComponents do
  @moduledoc """
  The account settings shell shared by `KanbanWeb.UserLive.Settings` (Profile,
  Password and Two-factor) and `KanbanWeb.UserLive.NotificationPreferences`: the page
  header, the section menu and the card each section renders in.

  The two pages live in different `live_session`s (the settings page is
  sudo-gated, notification preferences are not), so they cannot be one
  LiveView. On the settings page Profile, Password and Two-factor are tabs that
  swap in place (`tabs`); on any other page they are links back to the settings
  page.
  Notifications is always a link, marked as the current page when active.
  """
  use KanbanWeb, :html

  attr :active, :atom,
    required: true,
    values: [:profile, :password, :two_factor, :notifications]

  attr :tabs, :boolean,
    default: false,
    doc: "render the account sections as in-page tabs (the settings page itself)"

  slot :inner_block, required: true

  def settings_shell(assigns) do
    ~H"""
    <div data-settings-panel class="stride-screen px-4 pb-6 pt-5 md:px-7 md:pb-7">
      <header style="display: flex; align-items: flex-start; gap: 16px; padding-bottom: 14px;">
        <div style="flex: 1; min-width: 0;">
          <h1 style="margin: 0; font-size: 24px; font-weight: 600; letter-spacing: -0.025em; color: var(--ink);">
            {gettext("Settings")}
          </h1>
          <p style="margin: 6px 0 0; font-size: 13px; color: var(--ink-2); max-width: 720px; text-wrap: pretty; line-height: 1.55;">
            {gettext(
              "Manage your profile, password and notifications. Changes apply to your account immediately."
            )}
          </p>
        </div>
      </header>

      <div class="flex flex-col md:flex-row gap-4 md:gap-7 flex-1 min-h-0">
        <nav
          aria-label={gettext("Settings sections")}
          class="flex flex-row flex-wrap md:flex-nowrap md:flex-col gap-1 md:w-[184px] md:flex-shrink-0 md:pt-1"
        >
          <%!-- Below md the account sections share a row and Notifications takes its own:
                four items in one phone-width row would squeeze every label. --%>
          <div
            role={@tabs && "tablist"}
            aria-orientation={@tabs && "vertical"}
            aria-label={@tabs && gettext("Settings sections")}
            class="flex flex-row md:flex-col gap-1 basis-full md:basis-auto md:flex-initial"
          >
            <%= for {section, label, hint} <- account_sections() do %>
              <.section_tab
                :if={@tabs}
                section={section}
                active={@active == section}
                label={label}
                hint={hint}
              />
              <.section_link
                :if={!@tabs}
                id={"settings-#{section}-link"}
                navigate={account_section_path(section)}
                active={@active == section}
                label={label}
                hint={hint}
                class="flex-1 md:flex-initial"
              />
            <% end %>
          </div>
          <.section_link
            id="settings-notifications-link"
            navigate={~p"/users/notifications"}
            active={@active == :notifications}
            label={gettext("Notifications")}
            hint={gettext("in-app · email")}
            class="basis-full md:basis-auto md:flex-initial"
          />
        </nav>

        <%!-- A size container, so sections can lay out by their own width (@md: etc.)
              rather than the viewport's: beside the menu it is much narrower. --%>
        <div class="@container flex-1 min-w-0 flex flex-col gap-[18px]">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Returns the path an account section's menu link points at: the settings
  page, opened on that section.
  """
  @spec account_section_path(:profile | :password | :two_factor) :: String.t()
  def account_section_path(:profile), do: ~p"/users/settings"
  def account_section_path(:password), do: ~p"/users/settings?section=password"
  def account_section_path(:two_factor), do: ~p"/users/settings?section=two_factor"

  defp account_sections do
    [
      {:profile, gettext("Profile"), gettext("name · email")},
      {:password, gettext("Password"), gettext("change credentials")},
      {:two_factor, gettext("Two-factor"), gettext("authenticator app")}
    ]
  end

  attr :section, :atom, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil
  attr :active, :boolean, default: false

  defp section_tab(assigns) do
    ~H"""
    <button
      type="button"
      role="tab"
      aria-selected={if @active, do: "true", else: "false"}
      aria-controls={"section-#{@section}"}
      phx-click="select_section"
      phx-value-section={Atom.to_string(@section)}
      class="flex-1 md:flex-initial"
      style={[item_style(@active), "border: 0; text-align: left; font: inherit; cursor: pointer;"]}
    >
      <.item_text label={@label} hint={@hint} active={@active} />
    </button>
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil
  attr :active, :boolean, default: false
  attr :class, :string, default: nil

  # Links get the 44px phone tap height the settings panel's CSS gives its
  # buttons (app.css, [data-settings-panel] button).
  defp section_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      aria-current={@active && "page"}
      class={["min-h-11 md:min-h-0", @class]}
      style={[item_style(@active), "text-decoration: none;"]}
    >
      <.item_text label={@label} hint={@hint} active={@active} />
    </.link>
    """
  end

  attr :label, :string, required: true
  attr :hint, :string, default: nil
  attr :active, :boolean, default: false

  defp item_text(assigns) do
    ~H"""
    <span style={[
      "font-size: 12.5px;",
      if(@active,
        do: "font-weight: 600; color: var(--ink);",
        else: "font-weight: 500; color: var(--ink-2);"
      )
    ]}>
      {@label}
    </span>
    <span
      :if={@hint}
      style="font-size: 10.5px; font-family: var(--font-mono); color: var(--ink-3); letter-spacing: -0.01em;"
    >
      {@hint}
    </span>
    """
  end

  defp item_style(active) do
    [
      "display: flex; flex-direction: column; gap: 1px; padding: 7px 10px; border-radius: 5px; min-width: 0;",
      if(active,
        do: "background: var(--surface); box-shadow: inset 0 0 0 1px var(--line);",
        else: "background: transparent;"
      )
    ]
  end

  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :hint, :string, default: nil
  attr :level, :integer, default: 2, values: [2, 3], doc: "heading level of the title"
  attr :compact, :boolean, default: false, doc: "tighter body padding for row lists"
  slot :inner_block, required: true

  def settings_card(assigns) do
    ~H"""
    <section
      id={@id}
      style="background: var(--surface); border: 1px solid var(--line); border-radius: 10px; overflow: hidden;"
    >
      <header style="padding: 14px 18px 12px; border-bottom: 1px solid var(--line); display: flex; align-items: flex-start; gap: 12px; background: var(--surface);">
        <div style="flex: 1; min-width: 0;">
          <.dynamic_tag
            tag_name={"h#{@level}"}
            style="margin: 0; font-size: 15px; font-weight: 600; letter-spacing: -0.015em; color: var(--ink);"
          >
            {@title}
          </.dynamic_tag>
          <p
            :if={@hint}
            style="margin: 4px 0 0; font-size: 12px; color: var(--ink-3); line-height: 1.5; text-wrap: pretty;"
          >
            {@hint}
          </p>
        </div>
      </header>
      <div style={if @compact, do: "padding: 4px 18px 8px;", else: "padding: 18px;"}>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end
end
