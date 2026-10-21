defmodule KanbanWeb.OrganizationTwoFactorBanner do
  @moduledoc """
  The banner a member sees while their Organization requires two-factor
  authentication and they have not turned it on, rendered by
  `KanbanWeb.Layouts.app/1` at the top of `<main>`.

  It shows only when `current_scope.two_factor_deadline` is set, which
  `KanbanWeb.UserAuth.OrganizationTwoFactorGate` does during the grace period
  and, on the settings page, after it. Before the deadline it names the
  deadline; after it, it says two-factor must be turned on now. Unlike
  `KanbanWeb.TwoFactorReminder` it cannot be dismissed: it is a requirement,
  not a suggestion.
  """
  use KanbanWeb, :html

  attr :current_scope, :map, default: nil
  attr :id, :string, default: "organization-two-factor-banner"

  def card(%{current_scope: %{two_factor_deadline: %DateTime{} = deadline}} = assigns) do
    assigns =
      assign(assigns,
        deadline: deadline,
        passed?: DateTime.compare(DateTime.utc_now(), deadline) != :lt
      )

    ~H"""
    <div id={"#{@id}-wrap"} class="px-3 pt-3 sm:px-4 lg:px-6">
      <section
        id={@id}
        role="status"
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
          <.icon name="hero-shield-exclamation" class="h-5 w-5" />
        </span>

        <div class="flex-1 min-w-0">
          <h2
            id={"#{@id}-title"}
            class="m-0 font-semibold text-[15px]"
            style="color: var(--ink); letter-spacing: -0.01em;"
          >
            {gettext("Your Organization requires two-factor authentication")}
          </h2>
          <p
            :if={!@passed?}
            id={"#{@id}-deadline"}
            class="mt-1.5 mb-0 text-[13.5px] leading-relaxed"
            style="color: var(--ink-2);"
          >
            {gettext(
              "Turn it on before %{deadline}, or you will be asked to before you can continue.",
              deadline: format_deadline(@deadline)
            )}
          </p>
          <p
            :if={@passed?}
            id={"#{@id}-overdue"}
            class="mt-1.5 mb-0 text-[13.5px] leading-relaxed"
            style="color: var(--ink-2);"
          >
            {gettext("The grace period has ended. Turn it on now to keep using Stride.")}
          </p>
          <div class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-2">
            <.button
              id={"#{@id}-setup"}
              variant="primary"
              navigate={~p"/users/settings?section=two_factor"}
            >
              {gettext("Set up two-factor authentication")}
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

  @doc false
  # UTC, minute precision, in a form every locale reads the same way.
  def format_deadline(%DateTime{} = deadline),
    do: Calendar.strftime(deadline, "%Y-%m-%d %H:%M UTC")
end
