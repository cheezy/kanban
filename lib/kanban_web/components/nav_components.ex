defmodule KanbanWeb.NavComponents do
  use Phoenix.Component
  use KanbanWeb, :verified_routes

  import Phoenix.Controller, only: [get_csrf_token: 0]

  attr :brand_text, :string, required: true

  def logo(assigns) do
    ~H"""
    <div class="flex items-center">
      <.link href={~p"/"} class="flex items-center gap-3 group">
        <div class="flex items-center justify-center w-10 h-10 rounded-lg group-hover:scale-110 transition-transform">
          <img src={~p"/images/logos/abstract-s-motion.svg"} alt="Stride Logo" class="w-10 h-10" />
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
      class="text-base font-medium text-base-content opacity-80 hover:text-blue-600 hover:opacity-100 px-3 py-2 rounded-lg hover:bg-blue-50 dark:hover:bg-blue-900/20 transition-colors"
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
      class="text-sm font-medium text-white bg-gradient-to-r from-orange-500 to-orange-600 hover:from-orange-600 hover:to-orange-700 px-4 py-2 rounded-lg shadow-sm hover:shadow-md transition-all"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :current_locale, :string, required: true

  @supported_locales [
    %{code: "en", name: "English", flag: :uk_flag},
    %{code: "fr", name: "Français", flag: :french_flag},
    %{code: "es", name: "Español", flag: :spanish_flag},
    %{code: "pt", name: "Português", flag: :portuguese_flag},
    %{code: "de", name: "Deutsch", flag: :german_flag},
    %{code: "ja", name: "日本語", flag: :japanese_flag},
    %{code: "zh", name: "中文", flag: :chinese_flag}
  ]

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
        class="flex items-center gap-1 text-sm font-medium text-base-content opacity-80 hover:text-blue-600 hover:opacity-100 px-2 py-1 rounded transition-colors"
      >
        <.locale_flag locale={@current_locale} />
        <span class="hidden sm:inline">{String.upcase(@current_locale)}</span>
        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
        </svg>
      </button>
      <div
        data-dropdown-menu
        class="hidden absolute top-full right-0 mt-1 bg-base-100 border border-base-300 rounded-lg shadow-lg py-1 min-w-[140px] z-50"
      >
        <%= for locale <- @locales do %>
          <form action={~p"/locale/#{locale.code}"} method="post">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <button
              type="submit"
              class={"flex items-center gap-2 w-full px-3 py-2 text-sm text-left hover:bg-base-200 transition-colors #{if @current_locale == locale.code, do: "bg-blue-50 dark:bg-blue-900/20 text-blue-600", else: "text-base-content opacity-80"}"}
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

  defp locale_flag(%{locale: "en"} = assigns), do: uk_flag(assigns)
  defp locale_flag(%{locale: "fr"} = assigns), do: french_flag(assigns)
  defp locale_flag(%{locale: "es"} = assigns), do: spanish_flag(assigns)
  defp locale_flag(%{locale: "pt"} = assigns), do: portuguese_flag(assigns)
  defp locale_flag(%{locale: "de"} = assigns), do: german_flag(assigns)
  defp locale_flag(%{locale: "ja"} = assigns), do: japanese_flag(assigns)
  defp locale_flag(%{locale: "zh"} = assigns), do: chinese_flag(assigns)
  defp locale_flag(assigns), do: ~H""

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
