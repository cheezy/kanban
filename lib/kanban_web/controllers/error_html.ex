defmodule KanbanWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.

  Also defines a shared `error_page/1` function component used by the
  404 and 500 templates so the shared chrome (head, layout, Go-Home
  button) lives in one place. Each template passes its title, heading,
  message, and icon slot.
  """
  use KanbanWeb, :html

  embed_templates "error_html/*"

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
      </head>
      <body class="h-full bg-base-100">
        <div class="min-h-screen flex items-center justify-center px-4 py-12">
          <div class="max-w-md w-full text-center">
            {render_slot(@icon)}
            <h1 class="text-6xl font-bold text-base-content mb-4">{@status_code}</h1>
            <h2 class="text-2xl font-bold text-base-content mb-4">{@heading}</h2>
            <p class="text-base-content opacity-70 mb-8 leading-relaxed">{@message}</p>
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
