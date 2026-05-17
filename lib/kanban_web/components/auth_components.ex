defmodule KanbanWeb.AuthComponents do
  @moduledoc """
  Function components for user-authentication LiveViews (login, registration,
  forgot password, reset password, settings). Provides the shared card-with-icon
  framing so each LiveView only declares its own form fields and submit handler.
  """

  use Phoenix.Component
  use Gettext, backend: KanbanWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: KanbanWeb.Endpoint,
    router: KanbanWeb.Router,
    statics: KanbanWeb.static_paths()

  import KanbanWeb.CoreComponents

  attr :title, :string, required: true

  attr :icon_gradient, :string,
    default: "from-orange-500 to-orange-600",
    doc:
      "Tailwind gradient utility classes (without the bg-gradient-* direction) controlling the icon wrapper background. Defaults to the Stride brand orange."

  attr :icon_path, :string,
    default:
      "M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z",
    doc: "SVG path `d` attribute drawn inside the icon wrapper."

  slot :subtitle, doc: "Optional subtitle markup rendered below the title."

  slot :footer,
    doc:
      "Optional footer markup overriding the default 'Back to log in' link rendered below the form."

  slot :inner_block, required: true

  def auth_form(assigns) do
    ~H"""
    <div class="mx-auto max-w-md space-y-6 py-8">
      <div class="bg-base-100 rounded-2xl shadow-xl p-8 border border-base-300">
        <div class="text-center mb-8">
          <div class={[
            "inline-flex items-center justify-center w-16 h-16 bg-gradient-to-br rounded-xl shadow-lg mb-4",
            @icon_gradient
          ]}>
            <svg class="w-8 h-8 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d={@icon_path}
              />
            </svg>
          </div>
          <.header>
            <p class="text-2xl font-bold text-base-content">{@title}</p>
            <:subtitle :if={@subtitle != []}>
              <p class="text-base-content opacity-70 mt-2">{render_slot(@subtitle)}</p>
            </:subtitle>
          </.header>
        </div>

        {render_slot(@inner_block)}

        <div class="mt-6 text-center text-sm">
          <%= if @footer != [] do %>
            {render_slot(@footer)}
          <% else %>
            <.link
              href={~p"/users/log-in"}
              class="font-medium text-primary hover:underline"
            >
              {gettext("Back to log in")}
            </.link>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  @doc """
  Renders a settings-style card with a heading and content block.

  Uses the same theme-aware card chrome as `auth_form/1` so account-management
  pages share the visual language of the auth surfaces, but without the
  centered icon, subtitle, or default "Back to log in" footer (none of which
  belong on a sub-section card).
  """
  def settings_card(assigns) do
    ~H"""
    <section class="bg-base-100 rounded-2xl shadow-xl p-8 border border-base-300">
      <h2 class="text-xl font-semibold text-base-content mb-6">{@title}</h2>
      {render_slot(@inner_block)}
    </section>
    """
  end
end
