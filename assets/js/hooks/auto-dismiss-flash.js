export default {
  mounted() {
    this.timer = setTimeout(() => {
      // Simulate a click to trigger the existing phx-click handler
      // which properly clears the flash and hides the element
      this.el.click();
    }, 3000); // Wait 5 seconds before auto-dismissing
  },
  destroyed() {
    if (this.timer) {
      clearTimeout(this.timer);
    }
  },
};