const Dropdown = {
  mounted() {
    this.button = this.el.querySelector("[data-dropdown-toggle]")
    this.menu = this.el.querySelector("[data-dropdown-menu]")

    if (this.button && this.menu) {
      this.button.addEventListener("click", (e) => {
        e.stopPropagation()
        this.toggle()
      })

      document.addEventListener("click", (e) => {
        if (!this.el.contains(e.target)) {
          this.close()
        }
      })
    }
  },

  toggle() {
    this.menu.classList.toggle("hidden")
  },

  close() {
    this.menu.classList.add("hidden")
  }
}

export default Dropdown
