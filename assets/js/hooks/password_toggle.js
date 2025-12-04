const PasswordToggle = {
  mounted() {
    this.input = this.el.querySelector("input[type='password']")
    this.button = this.el.querySelector("[data-toggle-password]")
    this.eyeOpen = this.el.querySelector(".eye-open")
    this.eyeClosed = this.el.querySelector(".eye-closed")

    if (this.button && this.input && this.eyeOpen && this.eyeClosed) {
      this.button.addEventListener("mousedown", (e) => {
        e.preventDefault()
      })

      this.button.addEventListener("click", (e) => {
        e.preventDefault()
        e.stopPropagation()
        this.toggle()
      })
    }
  },

  toggle() {
    if (this.input.type === "password") {
      this.input.type = "text"
      this.eyeOpen.classList.add("hidden")
      this.eyeClosed.classList.remove("hidden")
    } else {
      this.input.type = "password"
      this.eyeOpen.classList.remove("hidden")
      this.eyeClosed.classList.add("hidden")
    }
  }
}

export default PasswordToggle
