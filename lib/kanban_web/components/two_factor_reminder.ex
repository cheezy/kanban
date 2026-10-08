defmodule KanbanWeb.TwoFactorReminder do
  @moduledoc """
  The two-factor setup reminder card, rendered by `KanbanWeb.Layouts.app/1`
  at the top of `<main>`.

  It shows only when `current_scope.two_factor_reminder` is true, which
  `KanbanWeb.TwoFactorReminderOnMount` sets on the page a user without
  two-factor lands on after a password sign-in. Its dismiss button sends
  `dismiss_two_factor_reminder`, which that hook handles for every page.

  It is a labelled region rather than an alert: a gentle nudge, not an urgent
  announcement.
  """
  use KanbanWeb, :html

  attr :current_scope, :map, default: nil
  attr :id, :string, default: "two-factor-reminder"

  def card(%{current_scope: %{two_factor_reminder: true}} = assigns) do
    ~H"""
    <div id={"#{@id}-wrap"} class="px-3 pt-3 sm:px-4 lg:px-6">
      <section
        id={@id}
        aria-labelledby={"#{@id}-title"}
        class="flex items-start gap-4 p-4 sm:p-5 rounded-xl"
        style={[
          "background: var(--banner-gradient);",
          "border: 1px solid var(--banner-border);",
          "border-left: 4px solid var(--stride-orange);",
          "box-shadow: var(--shadow-lg);"
        ]}
      >
        <span
          aria-hidden="true"
          class="hidden sm:inline-flex items-center justify-center w-10 h-10 rounded-xl shrink-0"
          style="background: var(--surface-2); color: var(--stride-orange);"
        >
          <.icon name="hero-shield-check" class="h-5 w-5" />
        </span>

        <div class="flex-1 min-w-0">
          <h2
            id={"#{@id}-title"}
            class="m-0 font-semibold text-[15px]"
            style="color: var(--ink); letter-spacing: -0.01em;"
          >
            {gettext("Protect your account with two-factor authentication")}
          </h2>
          <p class="mt-1.5 mb-0 text-[13.5px] leading-relaxed" style="color: var(--ink-2);">
            {gettext(
              "Add a code from an authenticator app to your password, so a stolen password alone cannot open your account."
            )}
          </p>
          <div class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-2">
            <.button
              id={"#{@id}-setup"}
              variant="primary"
              navigate={~p"/users/settings?section=two_factor"}
            >
              {gettext("Set up two-factor authentication")}
            </.button>
            <%!-- The card hides at once and focus moves to <main> (which has
                  tabindex="-1"), so it does not fall back to <body> when the
                  card goes; the next Tab reaches the page's first control. --%>
            <.button
              id={"#{@id}-dismiss"}
              type="button"
              phx-click={
                JS.push("dismiss_two_factor_reminder")
                |> JS.set_attribute({"hidden", "hidden"}, to: "##{@id}-wrap")
                |> JS.focus(to: "main")
              }
            >
              {gettext("Not now")}
            </.button>
            <.link
              id={"#{@id}-guide"}
              navigate={~p"/resources/two-factor-authentication"}
              class="text-[13.5px] font-medium underline underline-offset-2"
            >
              {gettext("Read the setup guide")}
            </.link>
          </div>
        </div>
      </section>
    </div>
    """
  end

  def card(assigns), do: ~H""
end
