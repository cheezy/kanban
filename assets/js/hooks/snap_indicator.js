// Drives the mobile column-indicator strip on the board page (W635).
// IntersectionObserver watches each column inside the snap-scroll container
// and adds an `active` class to the corresponding dot when that column is
// most visible. Hook is mounted on the indicator strip element itself; the
// strip is `md:hidden` so it only shows on mobile, but the observer runs
// regardless (it's harmless at md+).
const SnapIndicator = {
  mounted() {
    this.container = document.getElementById(this.el.dataset.targetId)
    if (!this.container) return

    this._update = () => this.updateActive()
    this._observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          const id = entry.target.dataset.columnId
          if (!id) return
          this.visibilityByColumn = this.visibilityByColumn || {}
          this.visibilityByColumn[id] = entry.intersectionRatio
        })
        this._update()
      },
      {root: this.container, threshold: [0, 0.5, 1]}
    )

    Array.from(this.container.children)
      .filter((child) => child.dataset.columnId)
      .forEach((col) => this._observer.observe(col))
  },

  updated() {
    // Re-observe any newly streamed columns after a LiveView update.
    if (!this._observer || !this.container) return
    Array.from(this.container.children)
      .filter((child) => child.dataset.columnId)
      .forEach((col) => this._observer.observe(col))
  },

  destroyed() {
    if (this._observer) this._observer.disconnect()
  },

  updateActive() {
    if (!this.visibilityByColumn) return
    const [activeId] = Object.entries(this.visibilityByColumn)
      .sort(([, a], [, b]) => b - a)[0] || []
    if (!activeId) return
    this.el.querySelectorAll("[data-indicator-dot]").forEach((dot) => {
      if (dot.dataset.indicatorDot === activeId) {
        dot.classList.add("opacity-100")
        dot.classList.remove("opacity-30")
      } else {
        dot.classList.add("opacity-30")
        dot.classList.remove("opacity-100")
      }
    })
  }
}

export default SnapIndicator
