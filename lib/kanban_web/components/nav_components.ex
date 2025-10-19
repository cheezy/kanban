defmodule KanbanWeb.NavComponents do
  use Phoenix.Component
  use KanbanWeb, :verified_routes

  import Phoenix.Controller, only: [get_csrf_token: 0]

  attr :brand_text, :string, required: true

  def logo(assigns) do
    ~H"""
    <div class="flex items-center">
      <.link href={~p"/"} class="flex items-center gap-3 group">
        <div class="flex items-center justify-center w-10 h-10 bg-gradient-to-br from-blue-600 to-blue-700 rounded-lg shadow-md group-hover:shadow-lg transition-shadow">
          <svg class="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"
            />
          </svg>
        </div>
        <span class="text-xl font-bold text-gray-900 hidden sm:block">
          {@brand_text}
        </span>
      </.link>
    </div>
    """
  end

  attr :email, :string, required: true

  def user_badge(assigns) do
    ~H"""
    <span class="hidden md:block text-sm font-medium text-gray-700 px-3 py-2 bg-gray-100 rounded-lg">
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
      class="text-sm font-medium text-gray-700 hover:text-blue-600 px-3 py-2 rounded-lg hover:bg-blue-50 transition-colors"
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
      class="text-sm font-medium text-white bg-gradient-to-r from-blue-600 to-blue-700 hover:from-blue-700 hover:to-blue-800 px-4 py-2 rounded-lg shadow-sm hover:shadow-md transition-all"
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

  def language_switcher(assigns) do
    ~H"""
    <div class="relative flex items-center gap-2 border-l border-gray-300 pl-4">
      <%= if @current_locale == "en" do %>
        <form action={~p"/locale/fr"} method="post">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <button
            type="submit"
            class="flex items-center gap-1 text-sm font-medium text-gray-600 hover:text-blue-600 px-2 py-1 rounded transition-colors"
            title="Français"
          >
            <.french_flag />
            <span class="hidden sm:inline">FR</span>
          </button>
        </form>
      <% else %>
        <form action={~p"/locale/en"} method="post">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <button
            type="submit"
            class="flex items-center gap-1 text-sm font-medium text-gray-600 hover:text-blue-600 px-2 py-1 rounded transition-colors"
            title="English"
          >
            <.uk_flag />
            <span class="hidden sm:inline">EN</span>
          </button>
        </form>
      <% end %>
    </div>
    """
  end

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
end
