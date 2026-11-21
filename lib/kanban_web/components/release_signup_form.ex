defmodule KanbanWeb.ReleaseSignupForm do
  @moduledoc """
  The release announcement signup form on `/changelog` (W2905).

  It posts to `POST /releases/subscribe` through the `:browser` pipeline, so
  the form carries the CSRF token. The email field is always empty: the page
  never renders an address, not even a signed-in visitor's own.

  `consent_text/0` is the consent wording shown above the button.
  `KanbanWeb.SubscriberController` stores that same string with the
  signup, in the visitor's locale, so the stored consent is exactly what was
  shown.
  """
  use KanbanWeb, :html

  @doc "The translated consent wording shown on the form and stored with each signup."
  @spec consent_text() :: String.t()
  def consent_text do
    gettext(
      "I agree to receive an email from Stride when a new version is released. I can unsubscribe at any time with the link in every email."
    )
  end

  @doc "Renders the signup form."
  def release_signup_form(assigns) do
    assigns = assign(assigns, form: to_form(%{}, as: :subscriber), consent: consent_text())

    ~H"""
    <aside
      id="release-signup"
      data-release-signup
      class="flex flex-col gap-2 rounded-lg p-5 mb-4"
      style="background: var(--surface); border: 1px solid var(--line);"
    >
      <h2 class="m-0 text-[15px] font-semibold" style="color: var(--ink);">
        {gettext("Get release announcements")}
      </h2>
      <p class="m-0 text-[13px] leading-relaxed" style="color: var(--ink-2);">
        {gettext(
          "Leave your email address and we will send you a short note when a new version of Stride is released. We will first email you a link to confirm."
        )}
      </p>
      <.form
        for={@form}
        id="release-signup-form"
        action={~p"/releases/subscribe"}
        method="post"
        class="flex flex-col gap-2 mt-1"
      >
        <.input
          field={@form[:email]}
          type="email"
          label={gettext("Email address")}
          required
          autocomplete="email"
          maxlength="160"
        />
        <p class="m-0 text-[12.5px] leading-relaxed" style="color: var(--ink-2);">
          {@consent}
        </p>
        <div>
          <.button type="submit" variant="primary">
            {gettext("Subscribe")}
          </.button>
        </div>
      </.form>
    </aside>
    """
  end
end
