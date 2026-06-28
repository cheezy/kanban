defmodule KanbanWeb.NavComponents do
  use Phoenix.Component
  use KanbanWeb, :verified_routes
  use Gettext, backend: KanbanWeb.Gettext

  import Phoenix.Controller, only: [get_csrf_token: 0]
  import KanbanWeb.CoreComponents, only: [icon: 1]

  attr :brand_text, :string, required: true

  def logo(assigns) do
    ~H"""
    <div class="flex items-center">
      <.link href={~p"/"} class="flex items-center gap-3 group">
        <div class="flex items-center justify-center w-10 h-10 rounded-lg group-hover:scale-110 transition-transform">
          <img
            src={~p"/images/logos/abstract-s-motion.svg"}
            alt={gettext("Stride Logo")}
            class="w-10 h-10"
          />
        </div>
        <span class="text-xl font-bold text-base-content hidden sm:block">
          {@brand_text}
        </span>
      </.link>
    </div>
    """
  end

  attr :email, :string, required: true

  def user_badge(assigns) do
    ~H"""
    <span class="hidden md:block text-sm font-medium text-base-content opacity-80 px-3 py-2 bg-base-200 rounded-lg">
      {@email}
    </span>
    """
  end

  attr :href, :string, required: true
  slot :inner_block, required: true

  def nav_link(assigns) do
    ~H"""
    <.link
      href={@href}
      class="text-base font-medium text-base-content opacity-80 hover:text-[var(--stride-orange)] hover:opacity-100 px-3 py-2 rounded-lg transition-colors"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :href, :string, required: true
  attr :method, :string, default: "get"
  slot :inner_block, required: true

  def nav_btn_primary(assigns) do
    ~H"""
    <.link
      href={@href}
      method={@method}
      class="btn btn-primary text-sm font-medium px-4 py-2 rounded-lg transition-all"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :href, :string, required: true
  slot :inner_block, required: true

  def nav_btn_secondary(assigns) do
    ~H"""
    <.link
      href={@href}
      class="text-sm font-medium text-primary-content hover:opacity-90 px-4 py-2 rounded-lg shadow-sm hover:shadow-md transition-all"
      style="background: var(--stride-orange);"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :current_scope, :map,
    default: nil,
    doc: "The `@current_scope` assign — `nil` when no user is signed in."

  @doc """
  Renders the collapsed mobile navigation menu for the public/root top nav.

  Below the `md` breakpoint the full set of top-nav links does not fit on a
  phone-width row, so they are collapsed behind a hamburger toggle. Uses a
  native `<details>`/`<summary>` disclosure (no JS hook required, so it works on
  dead controller pages too) — mirroring the `marketing_nav` mobile menu. The
  toggle is `md:hidden`; at `md` and up the desktop links render instead and
  this is hidden. Links match the desktop nav and switch on auth state.
  """
  def mobile_menu(assigns) do
    ~H"""
    <details class="md:hidden relative group">
      <summary
        class="list-none [&::-webkit-details-marker]:hidden [&::marker]:hidden inline-flex items-center justify-center w-11 h-11 rounded-lg cursor-pointer text-base-content opacity-80 hover:text-[var(--stride-orange)] hover:opacity-100 transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
        aria-label={gettext("Toggle menu")}
        aria-controls="root-mobile-menu"
        aria-expanded="false"
      >
        <.icon name="hero-bars-3" class="w-6 h-6 group-open:hidden" />
        <.icon name="hero-x-mark" class="w-6 h-6 hidden group-open:block" />
      </summary>
      <div
        id="root-mobile-menu"
        class="absolute right-0 top-full mt-2 w-56 bg-base-100 border border-base-300 rounded-xl shadow-lg py-2 z-50"
      >
        <%= if @current_scope do %>
          <span class="block px-4 py-2 text-sm font-medium text-base-content opacity-80 truncate">
            {@current_scope.user.email}
          </span>
          <hr class="my-1 border-base-300" />
          <%= if @current_scope.user.type == :admin do %>
            <.mobile_menu_link href={~p"/admin/dashboard"}>
              {gettext("Dashboard")}
            </.mobile_menu_link>
            <.mobile_menu_link href={~p"/admin/errors"}>
              {gettext("Error Tracker")}
            </.mobile_menu_link>
          <% end %>
          <.mobile_menu_link href={~p"/boards"}>{gettext("My Boards")}</.mobile_menu_link>
          <.mobile_menu_link href={~p"/users/settings"}>{gettext("Settings")}</.mobile_menu_link>
          <.mobile_menu_link href={~p"/resources"}>{gettext("Resources")}</.mobile_menu_link>
          <.mobile_menu_link href={~p"/about"}>{gettext("About")}</.mobile_menu_link>
          <hr class="my-1 border-base-300" />
          <.mobile_menu_link href={~p"/users/log-out"} method="delete">
            {gettext("Log out")}
          </.mobile_menu_link>
        <% else %>
          <.mobile_menu_link href={~p"/resources"}>{gettext("Resources")}</.mobile_menu_link>
          <.mobile_menu_link href={~p"/about"}>{gettext("About")}</.mobile_menu_link>
          <.mobile_menu_link href={~p"/users/log-in"}>{gettext("Log in")}</.mobile_menu_link>
          <.mobile_menu_link href={~p"/users/register"}>
            {gettext("Get Started")}
          </.mobile_menu_link>
        <% end %>
      </div>
    </details>
    """
  end

  attr :href, :string, required: true
  attr :method, :string, default: "get"
  slot :inner_block, required: true

  defp mobile_menu_link(assigns) do
    ~H"""
    <.link
      href={@href}
      method={@method}
      class="flex items-center min-h-11 px-4 text-sm font-medium text-base-content opacity-80 hover:text-[var(--stride-orange)] hover:opacity-100 hover:bg-base-200 transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[-2px]"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @supported_locales [
    %{code: "en", name: "English", flag: :uk_flag},
    %{code: "fr", name: "Français", flag: :french_flag},
    %{code: "es", name: "Español", flag: :spanish_flag},
    %{code: "pt", name: "Português", flag: :portuguese_flag},
    %{code: "de", name: "Deutsch", flag: :german_flag},
    %{code: "ja", name: "日本語", flag: :japanese_flag},
    %{code: "zh", name: "中文", flag: :chinese_flag}
  ]

  @doc """
  Returns the list of supported locales (code + name + flag-atom). Exposed
  publicly so sibling component modules (e.g. `MarketingComponents`) can
  render their own locale switchers without duplicating this list.
  """
  def supported_locales, do: @supported_locales

  attr :current_locale, :string, required: true

  def language_switcher(assigns) do
    assigns = assign(assigns, :locales, @supported_locales)

    ~H"""
    <div
      class="relative flex items-center border-l border-base-300 pl-4"
      id="language-switcher"
      phx-hook="Dropdown"
    >
      <button
        type="button"
        data-dropdown-toggle
        class="flex items-center gap-1 text-sm font-medium text-base-content opacity-80 hover:text-[var(--stride-orange)] hover:opacity-100 px-2 py-1 rounded transition-colors"
      >
        <.locale_flag locale={@current_locale} />
        <span class="hidden sm:inline">{String.upcase(@current_locale)}</span>
        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
        </svg>
      </button>
      <div
        data-dropdown-menu
        class="hidden absolute top-full right-0 mt-1 bg-base-100 border border-base-300 dark:border-base-content/15 rounded-lg shadow-lg py-1 min-w-[140px] z-50"
      >
        <%= for locale <- @locales do %>
          <form
            id={"nav-locale-form-#{locale.code}"}
            action={~p"/locale/#{locale.code}"}
            method="post"
          >
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <button
              type="submit"
              class={"flex items-center gap-2 w-full px-3 py-2 text-sm text-left hover:bg-base-200 transition-colors #{if @current_locale == locale.code, do: "bg-base-200 text-base-content", else: "text-base-content opacity-80"}"}
            >
              <.locale_flag locale={locale.code} />
              <span>{locale.name}</span>
              <%= if @current_locale == locale.code do %>
                <svg class="w-4 h-4 ml-auto" fill="currentColor" viewBox="0 0 20 20">
                  <path
                    fill-rule="evenodd"
                    d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z"
                    clip-rule="evenodd"
                  />
                </svg>
              <% end %>
            </button>
          </form>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders a small SVG flag for the given locale code. Public so sibling
  component modules can reuse the flag SVG bank.
  """
  attr :locale, :string, required: true

  def locale_flag(%{locale: "en"} = assigns), do: uk_flag(assigns)
  def locale_flag(%{locale: "fr"} = assigns), do: french_flag(assigns)
  def locale_flag(%{locale: "es"} = assigns), do: spanish_flag(assigns)
  def locale_flag(%{locale: "pt"} = assigns), do: portuguese_flag(assigns)
  def locale_flag(%{locale: "de"} = assigns), do: german_flag(assigns)
  def locale_flag(%{locale: "ja"} = assigns), do: japanese_flag(assigns)
  def locale_flag(%{locale: "zh"} = assigns), do: chinese_flag(assigns)
  def locale_flag(assigns), do: ~H""

  defp french_flag(assigns) do
    ~H"""
    <svg class="w-5 h-5" viewBox="0 0 640 480" fill="currentColor">
      <path fill="#002654" d="M0 0h213.3v480H0z" />
      <path fill="#FFF" d="M213.3 0h213.4v480H213.3z" />
      <path fill="#CE1126" d="M426.7 0H640v480H426.7z" />
    </svg>
    """
  end

  defp uk_flag(assigns) do
    ~H"""
    <svg class="w-5 h-5" viewBox="0 0 640 480" fill="currentColor">
      <path fill="#012169" d="M0 0h640v480H0z" />
      <path
        fill="#FFF"
        d="m75 0 244 181L562 0h78v62L400 241l240 178v61h-80L320 301 81 480H0v-60l239-178L0 64V0z"
      />
      <path
        fill="#C8102E"
        d="m424 281 216 159v40L369 281zm-184 20 6 35L54 480H0zM640 0v3L391 191l2-44L590 0zM0 0l239 176h-60L0 42z"
      />
      <path fill="#FFF" d="M241 0v480h160V0zM0 160v160h640V160z" />
      <path fill="#C8102E" d="M0 193v96h640v-96zM273 0v480h96V0z" />
    </svg>
    """
  end

  defp spanish_flag(assigns) do
    ~H"""
    <svg class="w-5 h-5" viewBox="0 0 640 480" fill="currentColor">
      <path fill="#AA151B" d="M0 0h640v480H0z" />
      <path fill="#F1BF00" d="M0 120h640v240H0z" />
    </svg>
    """
  end

  defp portuguese_flag(assigns) do
    ~H"""
    <svg class="w-5 h-5" viewBox="0 0 640 480" fill="currentColor">
      <path fill="#060" d="M0 0h640v480H0z" />
      <path fill="#D80027" d="M256 0h384v480H256z" />
    </svg>
    """
  end

  defp german_flag(assigns) do
    ~H"""
    <svg class="w-5 h-5" viewBox="0 0 640 480" fill="currentColor">
      <path fill="#000" d="M0 0h640v160H0z" />
      <path fill="#D00" d="M0 160h640v160H0z" />
      <path fill="#FFCE00" d="M0 320h640v160H0z" />
    </svg>
    """
  end

  defp japanese_flag(assigns) do
    ~H"""
    <svg class="w-5 h-5" viewBox="0 0 640 480" fill="currentColor">
      <path fill="#FFF" d="M0 0h640v480H0z" />
      <circle fill="#BC002D" cx="320" cy="240" r="144" />
    </svg>
    """
  end

  defp chinese_flag(assigns) do
    ~H"""
    <svg class="w-5 h-5" viewBox="0 0 640 480" fill="currentColor">
      <path fill="#DE2910" d="M0 0h640v480H0z" />
      <g fill="#FFDE00">
        <path
          d="M-119.5 18.5l5.4 16.6L-97.4 26l-10.7 13.6 17.6-3.5-17.6-3.4L-97.4 46l-16.7-9.1 5.4 16.6z"
          transform="scale(3.9385) translate(194.4 78.8)"
        />
        <path
          d="M0-20l1.5 4.6L6 -20l-3.8 3-1.5-4.6-1.5 4.6L-5-20l4.5 4.6z"
          transform="scale(3.9385) translate(261.6 51.2)"
        />
        <path
          d="M0-20l1.5 4.6L6 -20l-3.8 3-1.5-4.6-1.5 4.6L-5-20l4.5 4.6z"
          transform="scale(3.9385) translate(272 67.2)"
        />
        <path
          d="M0-20l1.5 4.6L6 -20l-3.8 3-1.5-4.6-1.5 4.6L-5-20l4.5 4.6z"
          transform="scale(3.9385) translate(267.2 86.4)"
        />
        <path
          d="M0-20l1.5 4.6L6 -20l-3.8 3-1.5-4.6-1.5 4.6L-5-20l4.5 4.6z"
          transform="scale(3.9385) translate(253.6 99.2)"
        />
      </g>
    </svg>
    """
  end
end
