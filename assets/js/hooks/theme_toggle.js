// Mirrors the theme choice onto the System / Light / Dark buttons of
// Layouts.theme_toggle as aria-pressed, so assistive tech can tell which one is
// active. The choice lives in this browser's localStorage, so the server cannot
// render it; the <head> bootstrap in the three root layouts paints it as
// data-theme-choice on <html>. Its phx:set-theme and storage listeners were
// added first, so by the time ours run the attribute is already up to date.

const CHOICES = ["system", "light", "dark"]

// Anything the bootstrap does not store (absent, or a stale unknown value)
// paints as system, so it reads as system here too.
export function currentChoice(choice) {
  return CHOICES.includes(choice) ? choice : "system"
}

export function syncPressed(buttons, choice) {
  const current = currentChoice(choice)
  buttons.forEach((button) => {
    button.setAttribute("aria-pressed", button.dataset.phxTheme === current ? "true" : "false")
  })
}

const ThemeToggle = {
  mounted() {
    this.sync = () =>
      syncPressed(
        this.el.querySelectorAll("[data-phx-theme]"),
        document.documentElement.dataset.themeChoice
      )

    window.addEventListener("phx:set-theme", this.sync)
    window.addEventListener("storage", this.sync)
    this.sync()
  },

  updated() {
    this.sync()
  },

  destroyed() {
    window.removeEventListener("phx:set-theme", this.sync)
    window.removeEventListener("storage", this.sync)
  }
}

export default ThemeToggle
