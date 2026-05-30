defmodule KanbanWeb.DelayedModal do
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}

  attr :max_width, :string,
    default: "max-w-3xl",
    doc: "Tailwind max-w-* class controlling the modal's maximum width."

  attr :padding, :string,
    default: "p-14",
    doc: "Tailwind padding class applied to the inner container."

  attr :mobile_fullscreen, :boolean,
    default: false,
    doc:
      "When true, the modal renders full-screen below the md breakpoint (no rounding, no outer padding, min-h-screen) and reverts to the centered max_width layout at md+."

  slot :inner_block, required: true

  def delayed_modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="relative z-50 hidden"
      phx-hook="DelayedModalClickAway"
    >
      <div
        id={"#{@id}-bg"}
        class="bg-base-200/90 fixed inset-0 transition-opacity"
        aria-hidden="true"
      />
      <div
        class="fixed inset-0 overflow-y-auto"
        aria-labelledby={"#{@id}-title"}
        aria-describedby={"#{@id}-description"}
        role="dialog"
        aria-modal="true"
        tabindex="0"
      >
        <div class="flex min-h-full items-center justify-center">
          <div class={[
            "w-full",
            if(@mobile_fullscreen, do: md_max_width(@max_width), else: @max_width),
            if(@mobile_fullscreen,
              do: "p-0 md:p-6 lg:py-8",
              else: "p-4 sm:p-6 lg:py-8"
            )
          ]}>
            <div
              id={"#{@id}-container"}
              data-modal-container
              phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
              phx-key="escape"
              class={
                [
                  # D48: ring-base-300 resolves to the sunken token (darker than the
                  # base-100 modal fill) so the modal edge vanished in dark. Add a
                  # visible raised edge in dark via base-content; light unchanged.
                  "shadow-base-300/20 ring-base-300/40 dark:ring-base-content/15 relative hidden bg-base-100 shadow-lg ring-1 transition",
                  if(@mobile_fullscreen,
                    do: "rounded-none md:rounded-2xl min-h-screen md:min-h-0",
                    else: "rounded-2xl"
                  ),
                  @padding
                ]
              }
            >
              <div class="absolute top-6 right-5">
                <button
                  phx-click={JS.exec("data-cancel", to: "##{@id}")}
                  type="button"
                  class="-m-3 flex-none p-3 text-base-content opacity-20 hover:opacity-40"
                  aria-label="close"
                >
                  <span class={["hero-x-mark-solid", "size-5"]} />
                </button>
              </div>
              <div id={"#{@id}-content"}>
                {render_slot(@inner_block)}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp show(js, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  defp hide(js, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  defp show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-bg",
      transition: {"transition-all ease-out duration-300", "opacity-0", "opacity-100"}
    )
    |> show("##{id}-container")
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.focus_first(to: "##{id}-content")
  end

  defp hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-bg",
      transition: {"transition-all ease-in duration-200", "opacity-100", "opacity-0"}
    )
    |> hide("##{id}-container")
    |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"})
    |> JS.remove_class("overflow-hidden", to: "body")
    |> JS.pop_focus()
  end

  # Maps a `max-w-*` class to its `md:`-prefixed variant as literal strings so
  # Tailwind v4's `source(none)` static scanner picks them up. Add a new clause
  # when a new max_width value is introduced at a call site.
  defp md_max_width("max-w-sm"), do: "md:max-w-sm"
  defp md_max_width("max-w-md"), do: "md:max-w-md"
  defp md_max_width("max-w-lg"), do: "md:max-w-lg"
  defp md_max_width("max-w-xl"), do: "md:max-w-xl"
  defp md_max_width("max-w-2xl"), do: "md:max-w-2xl"
  defp md_max_width("max-w-3xl"), do: "md:max-w-3xl"
  defp md_max_width("max-w-4xl"), do: "md:max-w-4xl"
  defp md_max_width("max-w-5xl"), do: "md:max-w-5xl"
  defp md_max_width("max-w-6xl"), do: "md:max-w-6xl"
  defp md_max_width("max-w-7xl"), do: "md:max-w-7xl"
  defp md_max_width(other), do: other
end
