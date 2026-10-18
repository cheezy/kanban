// Hides an info flash after a short delay. Error flashes do not use this hook
// (see auto_dismiss_hook/1 in core_components.ex), so they stay until dismissed.
//
// A new message can replace the one on screen without remounting this element,
// because the flash keeps its id. The timer therefore restarts when the text
// changes (updated/0), and when the server pushes "flash:shown" for this kind:
// a LiveView that shows the same text twice in a row sends nothing else the
// client could notice.
export const DISMISS_AFTER_MS = 5000

export default {
  mounted() {
    this.lastText = this.el.innerText
    this.restartTimer()

    this.handleEvent("flash:shown", ({kind}) => {
      if (this.el.id === `flash-${kind}`) this.restartTimer()
    })
  },
  updated() {
    if (this.el.innerText !== this.lastText) {
      this.lastText = this.el.innerText
      this.restartTimer()
    }
  },
  destroyed() {
    clearTimeout(this.timer)
  },
  restartTimer() {
    clearTimeout(this.timer)
    // Simulate a click to trigger the existing phx-click handler, which
    // clears the flash on the server and hides the element.
    this.timer = setTimeout(() => this.el.click(), DISMISS_AFTER_MS)
  }
}
