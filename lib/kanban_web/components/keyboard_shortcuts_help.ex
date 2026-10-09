defmodule KanbanWeb.KeyboardShortcutsHelp do
  @moduledoc """
  The board's keyboard shortcut help overlay (W2236).

  `KanbanWeb.BoardLive.Show` renders it while `:show_shortcuts_help` is true.
  The `KeyboardShortcuts` JS hook (`assets/js/hooks/keyboard_shortcuts.js`)
  opens it by pushing `"toggle_shortcuts_help"` when `?` is pressed; Escape,
  a click outside the panel and the close button all push
  `"close_shortcuts_help"`. Because the open state is a server assign, the
  overlay is testable without a browser.

  Opening it remembers the element that had focus (`JS.push_focus/0`) and
  removing it returns focus there (`JS.pop_focus/0`), so a keyboard user is not
  dropped back at the top of the page when the overlay closes.

  It renders only the static, translated rows from `shortcuts/0` — no user
  content ever reaches it.
  """
  use KanbanWeb, :html

  @doc """
  The board shortcuts as `{key, description}` pairs, in display order. Both
  halves are translated: the key caps too, since some locales name them
  differently (French keyboards label Escape "Échap").
  """
  def shortcuts do
    [
      {"/", gettext("Focus the search box")},
      {"?", gettext("Show or hide this list of shortcuts")},
      {gettext("Esc"), gettext("Close this list, or clear the selected tasks")}
    ]
  end

  @doc """
  Renders the overlay as an accessible modal dialog.

  ## Attrs

    * `id` — the overlay's DOM id. The JS hook looks the overlay up by the
      default, so only tests should change it.
  """
  attr :id, :string, default: "keyboard-shortcuts-help"

  def keyboard_shortcuts_help(assigns) do
    assigns = assign(assigns, :shortcuts, shortcuts())

    ~H"""
    <div id={@id} class="relative z-50" phx-remove={JS.pop_focus()}>
      <div class="bg-base-200/90 fixed inset-0" aria-hidden="true" />
      <div class="fixed inset-0 flex items-center justify-center p-4">
        <.focus_wrap
          id={"#{@id}-panel"}
          role="dialog"
          aria-modal="true"
          aria-labelledby={"#{@id}-title"}
          phx-mounted={JS.push_focus() |> JS.focus_first(to: "##{@id}-panel")}
          phx-window-keydown="close_shortcuts_help"
          phx-key="escape"
          phx-click-away="close_shortcuts_help"
          class="relative w-full max-w-md rounded-2xl bg-base-100 text-base-content p-6 shadow-lg ring-1 ring-base-300/40 dark:ring-base-content/15"
        >
          <div style="display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 16px;">
            <h2
              id={"#{@id}-title"}
              style="font-size: 15px; font-weight: 600; color: var(--ink); margin: 0;"
            >
              {gettext("Keyboard shortcuts")}
            </h2>
            <button
              id={"#{@id}-close"}
              type="button"
              phx-click="close_shortcuts_help"
              aria-label={gettext("Close keyboard shortcuts")}
              class="min-h-[44px] min-w-[44px] md:min-h-0 md:min-w-0 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
              style="display: inline-flex; align-items: center; justify-content: center; padding: 4px; border-radius: 5px; background: transparent; border: none; color: var(--ink-2); cursor: pointer;"
            >
              <.icon name="hero-x-mark" class="h-5 w-5" />
            </button>
          </div>
          <dl style="display: flex; flex-direction: column; gap: 10px; margin: 0;">
            <div
              :for={{key, description} <- @shortcuts}
              data-shortcut-row
              style="display: flex; align-items: center; gap: 12px;"
            >
              <dt style="min-width: 48px;"><kbd class="kbd">{key}</kbd></dt>
              <dd style="margin: 0; font-size: 13px; color: var(--ink-2);">{description}</dd>
            </div>
          </dl>
        </.focus_wrap>
      </div>
    </div>
    """
  end
end
