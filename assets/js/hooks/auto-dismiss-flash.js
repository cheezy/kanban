// Hides an info flash after a short delay. Error flashes do not use this hook
// (see auto_dismiss_hook/1 in core_components.ex), so they stay until dismissed.
const DISMISS_AFTER_MS = 5000

export default {
  mounted() {
    this.timer = setTimeout(() => {
      // Simulate a click to trigger the existing phx-click handler
      // which properly clears the flash and hides the element
      this.el.click();
    }, DISMISS_AFTER_MS);
  },
  destroyed() {
    if (this.timer) {
      clearTimeout(this.timer);
    }
  },
};
