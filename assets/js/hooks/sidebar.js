// Drives the mobile slide-in behaviour of the app_chrome sidebar.
// At >=md the sidebar is rendered inline by Tailwind's `md:static md:translate-x-0`,
// so this hook only manages the mobile drawer state (open/closed, escape, click-outside,
// nav-link auto-close, aria-expanded, focus return, Tab focus trap, resize close).
const FOCUSABLE_SELECTOR =
  "a[href], button:not([disabled]), input:not([disabled]), [tabindex]:not([tabindex='-1'])"
const MD_BREAKPOINT_PX = 768

const Sidebar = {
  mounted() {
    this.sidebar = document.getElementById("app-sidebar")
    this.toggle = document.querySelector("[data-sidebar-toggle]")
    this.backdrop = document.querySelector("[data-sidebar-backdrop]")

    if (!this.sidebar || !this.toggle) return

    this._onToggleClick = () => this.toggleDrawer()
    this._onBackdropClick = () => this.closeDrawer()
    this._onKeyDown = (e) => {
      if (!this.isOpen()) return
      if (e.key === "Escape") {
        this.closeDrawer()
      } else if (e.key === "Tab") {
        this.trapFocus(e)
      }
    }
    this._onNavClick = () => this.closeDrawer()
    this._onResize = () => {
      if (window.innerWidth >= MD_BREAKPOINT_PX && this.isOpen()) {
        this.closeDrawer({skipFocus: true})
      }
    }

    this.toggle.addEventListener("click", this._onToggleClick)
    this.backdrop?.addEventListener("click", this._onBackdropClick)
    document.addEventListener("keydown", this._onKeyDown)
    window.addEventListener("resize", this._onResize)
    this.sidebar.querySelectorAll("a, button").forEach((el) => {
      el.addEventListener("click", this._onNavClick)
    })
  },

  destroyed() {
    this.toggle?.removeEventListener("click", this._onToggleClick)
    this.backdrop?.removeEventListener("click", this._onBackdropClick)
    document.removeEventListener("keydown", this._onKeyDown)
    window.removeEventListener("resize", this._onResize)
    this.sidebar?.querySelectorAll("a, button").forEach((el) => {
      el.removeEventListener("click", this._onNavClick)
    })
  },

  trapFocus(e) {
    const focusables = Array.from(this.sidebar.querySelectorAll(FOCUSABLE_SELECTOR))
      .filter((el) => !el.hasAttribute("disabled") && el.offsetParent !== null)
    if (focusables.length === 0) return
    const first = focusables[0]
    const last = focusables[focusables.length - 1]
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault()
      last.focus()
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault()
      first.focus()
    }
  },

  isOpen() {
    return this.sidebar.classList.contains("translate-x-0")
  },

  openDrawer() {
    this.sidebar.classList.remove("-translate-x-full")
    this.sidebar.classList.add("translate-x-0")
    this.toggle.setAttribute("aria-expanded", "true")
    this.backdrop?.classList.remove("hidden")
    const firstFocusable = this.sidebar.querySelector("a, button")
    if (firstFocusable) firstFocusable.focus()
  },

  closeDrawer({skipFocus = false} = {}) {
    this.sidebar.classList.remove("translate-x-0")
    this.sidebar.classList.add("-translate-x-full")
    this.toggle.setAttribute("aria-expanded", "false")
    this.backdrop?.classList.add("hidden")
    if (!skipFocus) this.toggle?.focus()
  },

  toggleDrawer() {
    if (this.isOpen()) this.closeDrawer()
    else this.openDrawer()
  }
}

export default Sidebar
