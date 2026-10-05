defmodule KanbanWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.

  Also defines a shared `error_page/1` function component used by the
  404 and 500 templates so the shared chrome (head, layout, Go-Home
  button) lives in one place. Each template passes its title, heading,
  message, and icon slot.

  Only 404 and 500 have templates. Every other status that
  `Phoenix.Endpoint.RenderErrors` renders as HTML goes through the `render/2`
  fallback below (D353), so a 400 from a malformed query string or a 406 from
  a browser route asked for an unsupported `Accept` returns its real status
  with a translated page instead of crashing into a 500.
  """
  use KanbanWeb, :html

  embed_templates "error_html/*"

  @doc """
  Renders an error page for any status without its own template (D353).

  `template` is `"<status>.html"`, as built by `Phoenix.Endpoint.RenderErrors`.
  The page shows that status code with translated wording for 400, 406, 413
  and 415 and generic translated wording for any other status. Nothing from
  the request or the exception is shown.
  """
  def render(template, assigns) do
    status_code = template |> String.split(".", parts: 2) |> hd()
    {heading, message} = fallback_copy(status_code)

    assigns
    |> Map.new()
    |> Map.merge(%{status_code: status_code, heading: heading, message: message})
    |> fallback_page()
  end

  defp fallback_copy("400") do
    {gettext("Bad Request"),
     gettext("The request couldn't be understood. Check the address and try again.")}
  end

  defp fallback_copy("406") do
    {gettext("Not Acceptable"),
     gettext("This page can't be shown in the format that was requested.")}
  end

  defp fallback_copy("413") do
    {gettext("Request Too Large"), gettext("The request was too large to process.")}
  end

  defp fallback_copy("415") do
    {gettext("Unsupported Media Type"),
     gettext("The request was sent in a format that isn't supported.")}
  end

  defp fallback_copy(_status_code) do
    {gettext("Something Went Wrong"),
     gettext("We couldn't complete your request. Please go back and try again.")}
  end

  defp fallback_page(assigns) do
    ~H"""
    <.error_page
      page_title={@heading}
      status_code={@status_code}
      heading={@heading}
      message={@message}
    >
      <:icon>
        <div
          class="stride-screen"
          style="display: inline-flex; align-items: center; justify-content: center; width: 72px; height: 72px; border-radius: 16px; background: linear-gradient(135deg, var(--stride-orange-soft) 0%, var(--stride-violet-soft) 100%); color: var(--stride-orange-ink); box-shadow: inset 0 0 0 1px var(--line); margin-bottom: 24px;"
        >
          <.icon name="hero-exclamation-circle" class="size-9" />
        </div>
      </:icon>
    </.error_page>
    """
  end

  attr :page_title, :string, required: true
  attr :status_code, :string, required: true
  attr :heading, :string, required: true
  attr :message, :string, required: true
  slot :icon, required: true

  def error_page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@page_title} · Stride</title>
        <link rel="stylesheet" href="/assets/css/app.css" />
        <%!-- Error pages are standalone documents (no app layout), so they need
             their own inline theme bootstrap. It shares the app layout's
             resolve-to-explicit core (see root.html.heex and
             docs/dark-mode-contract.md "Theme activation mechanism"): read the
             stored preference, resolve "system"/unset against
             prefers-color-scheme, and set a CONCRETE data-theme on <html>. This
             is required because the page mixes daisyUI base-* tokens (which honor
             prefersdark) with Stride var(--*) tokens (which only flip on an
             explicit [data-theme="dark"]); a removed data-theme would leave the
             Stride accents light against a dark daisyUI surface. Error pages omit
             the toggle machinery (no data-theme-choice, no phx:set-theme /
             matchMedia listeners) since they are one-shot and carry no theme
             switcher. --%>
        <script nonce={assigns[:csp_nonce]}>
          (() => {
            const stored = localStorage.getItem("phx:theme");
            const systemDark =
              window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
            const theme =
              stored === "dark" || stored === "light" ? stored : systemDark ? "dark" : "light";
            document.documentElement.setAttribute("data-theme", theme);
          })();
        </script>
      </head>
      <body class="h-full bg-base-100">
        <div class="min-h-screen flex items-center justify-center px-4 py-12">
          <div class="max-w-md w-full text-center">
            {render_slot(@icon)}
            <h1 class="text-6xl font-bold text-base-content mb-4">{@status_code}</h1>
            <h2 class="text-2xl font-bold text-base-content mb-4">{@heading}</h2>
            <p class="text-base-content opacity-70 mb-8 leading-relaxed">{@message}</p>
            <%!-- Intentionally inverted: --ink (the primary text token) is used
                  as the button FILL, with --color-base-100 as the label, for a
                  high-contrast "Go Home" button that reads in both themes. --%>
            <a
              href="/"
              class="stride-screen"
              style="display: inline-flex; align-items: center; gap: 8px; height: 40px; padding: 0 18px; border-radius: 6px; background: var(--ink); color: var(--color-base-100); font-size: 13.5px; font-weight: 500; letter-spacing: -0.005em; text-decoration: none; box-shadow: 0 1px 0 rgba(0, 0, 0, 0.1) inset, 0 1px 3px rgba(0, 0, 0, 0.2);"
            >
              <svg class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6"
                />
              </svg>
              {gettext("Go Home")}
            </a>
          </div>
        </div>
      </body>
    </html>
    """
  end
end
