// @mention autocomplete for the comment textareas
// (KanbanWeb.TaskLive.Components.MentionField).
//
// Typing "@" at the start of the text or after whitespace, followed by a few
// characters, asks the comment thread component for matching board members
// (its "mention_search" event) and lists them in the textarea's listbox.
// ArrowUp/ArrowDown move the selection, Enter or Tab insert the canonical
// @[Name](user:ID) token, Escape closes the list without inserting.
//
// Members are fetched on demand, debounced, and a reply for anything but the
// latest request is ignored. Names are only ever set with textContent.

const DEBOUNCE_MS = 150
const MAX_RESULTS = 8
const MAX_QUERY_LENGTH = 50

// The query is everything between the trigger "@" and the caret. A trigger
// counts only at the start of the text or after whitespace, so the "@" of an
// email address typed mid-word never opens the list.
export function findTrigger(value, caret) {
  const before = value.slice(0, caret)
  const at = before.lastIndexOf("@")
  if (at === -1) return null
  if (at > 0 && !/\s/.test(before[at - 1])) return null

  const query = before.slice(at + 1)
  if (query.length > MAX_QUERY_LENGTH) return null
  if (/[\n@]/.test(query)) return null
  // A leading "[" or a "](" means the caret is inside or just after an
  // inserted token; a leading or doubled space means the user has moved on.
  if (/^[\s[]/.test(query) || query.includes("](") || /\s\s/.test(query)) return null

  return {start: at, query}
}

// Keeps only well-formed {id, label} members from a server reply.
export function sanitizeMembers(reply) {
  const members = reply && Array.isArray(reply.members) ? reply.members : []

  return members
    .filter(m => m && Number.isInteger(m.id) && m.id > 0 && typeof m.label === "string" && m.label !== "")
    .slice(0, MAX_RESULTS)
}

export function mentionToken(member) {
  return `@[${member.label}](user:${member.id}) `
}

// Opens the list above the field only when there is no room for it below the
// field but there is above it — e.g. a textarea scrolled near the bottom of
// the viewport. Inputs are pixel measurements.
export function placeAbove(fieldTop, fieldBottom, listHeight, viewportHeight) {
  return viewportHeight - fieldBottom < listHeight && fieldTop > listHeight
}

// Placement is a class rather than a data attribute: LiveView strips data-*
// attributes the server did not render from a phx-update="ignore" container
// on every patch, but leaves its other attributes alone.
const ABOVE_CLASS = "mention-listbox--above"

const MentionAutocomplete = {
  mounted() {
    this.listbox = document.getElementById(this.el.dataset.mentionListbox)
    if (!this.listbox) return

    this.seq = 0
    this.timer = null
    this.members = []
    this.activeIndex = -1

    this.onInput = () => this.check()
    this.onKeyup = e => {
      if (["ArrowLeft", "ArrowRight", "Home", "End"].includes(e.key)) this.check()
    }
    this.onClick = () => this.check()
    this.onKeydown = e => this.keydown(e)
    this.onBlur = () => this.close()
    // Keep focus (and the caret) in the textarea while choosing with the mouse.
    this.onListMousedown = e => e.preventDefault()
    this.onListClick = e => {
      const option = e.target.closest("[role='option']")
      if (option) this.select(Number(option.dataset.index))
    }
    this.onListMousemove = e => {
      const option = e.target.closest("[role='option']")
      if (option) this.setActive(Number(option.dataset.index))
    }

    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("keyup", this.onKeyup)
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("keydown", this.onKeydown)
    this.el.addEventListener("blur", this.onBlur)
    this.listbox.addEventListener("mousedown", this.onListMousedown)
    this.listbox.addEventListener("click", this.onListClick)
    this.listbox.addEventListener("mousemove", this.onListMousemove)
  },

  // A LiveView patch drops textarea attributes the server did not render.
  updated() {
    if (this.isOpen()) this.syncActiveDescendant()
  },

  destroyed() {
    if (!this.listbox) return

    clearTimeout(this.timer)
    this.seq++
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("keyup", this.onKeyup)
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("keydown", this.onKeydown)
    this.el.removeEventListener("blur", this.onBlur)
    this.listbox.removeEventListener("mousedown", this.onListMousedown)
    this.listbox.removeEventListener("click", this.onListClick)
    this.listbox.removeEventListener("mousemove", this.onListMousemove)
  },

  currentTrigger() {
    const {selectionStart, selectionEnd, value} = this.el
    if (selectionStart !== selectionEnd) return null
    return findTrigger(value, selectionStart)
  },

  check() {
    const trigger = this.currentTrigger()
    if (!trigger) return this.close()

    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.search(trigger.query), DEBOUNCE_MS)
  },

  search(query) {
    const seq = ++this.seq

    this.pushEventTo(this.el, "mention_search", {query}, reply => {
      // A newer request, or a close, superseded this one.
      if (seq !== this.seq) return
      this.render(sanitizeMembers(reply), query)
    })
  },

  render(members, query) {
    this.members = members

    if (members.length === 0 && /\s/.test(query)) return this.close()

    const options = members.map((member, index) => {
      const li = document.createElement("li")
      li.id = `${this.listbox.id}-opt-${member.id}`
      li.setAttribute("role", "option")
      li.setAttribute("aria-selected", "false")
      li.className = "mention-option"
      li.dataset.index = String(index)
      li.textContent = member.label
      return li
    })

    if (options.length === 0) {
      const empty = document.createElement("li")
      empty.className = "mention-empty"
      empty.setAttribute("aria-disabled", "true")
      empty.textContent = this.listbox.dataset.emptyText || ""
      options.push(empty)
    }

    this.listbox.replaceChildren(...options)
    this.listbox.hidden = false
    this.place()
    this.setActive(members.length > 0 ? 0 : -1)
  },

  place() {
    this.listbox.classList.remove(ABOVE_CLASS)
    const field = this.el.getBoundingClientRect()
    const above = placeAbove(field.top, field.bottom, this.listbox.offsetHeight, window.innerHeight)
    this.listbox.classList.toggle(ABOVE_CLASS, above)
  },

  setActive(index) {
    this.activeIndex = index

    this.listbox.querySelectorAll("[role='option']").forEach(option => {
      const active = Number(option.dataset.index) === index
      option.setAttribute("aria-selected", active ? "true" : "false")
      if (active) option.scrollIntoView({block: "nearest"})
    })

    this.syncActiveDescendant()
  },

  syncActiveDescendant() {
    const member = this.members[this.activeIndex]
    if (member) {
      this.el.setAttribute("aria-activedescendant", `${this.listbox.id}-opt-${member.id}`)
    } else {
      this.el.removeAttribute("aria-activedescendant")
    }
  },

  isOpen() {
    return this.listbox && !this.listbox.hidden
  },

  keydown(e) {
    if (!this.isOpen() || e.isComposing) return

    const count = this.members.length

    switch (e.key) {
      case "ArrowDown":
        if (count === 0) return
        e.preventDefault()
        this.setActive((this.activeIndex + 1) % count)
        break
      case "ArrowUp":
        if (count === 0) return
        e.preventDefault()
        this.setActive((this.activeIndex - 1 + count) % count)
        break
      case "Enter":
      case "Tab":
        if (this.activeIndex < 0) return this.close()
        e.preventDefault()
        this.select(this.activeIndex)
        break
      case "Escape":
        // Stop the task modal's Escape handler from closing the modal too.
        e.preventDefault()
        e.stopPropagation()
        this.close()
        break
    }
  },

  select(index) {
    const member = this.members[index]
    const trigger = this.currentTrigger()
    if (!member || !trigger) return this.close()

    const text = mentionToken(member)
    const caret = this.el.selectionStart
    const maxLength = this.el.maxLength
    const newLength = this.el.value.length - (caret - trigger.start) + text.length

    if (maxLength > 0 && newLength > maxLength) return this.close()

    this.el.setRangeText(text, trigger.start, caret, "end")
    this.close()
    this.el.dispatchEvent(new Event("input", {bubbles: true}))
  },

  close() {
    clearTimeout(this.timer)
    this.seq++
    this.members = []
    this.activeIndex = -1
    if (!this.listbox) return

    this.listbox.hidden = true
    this.listbox.replaceChildren()
    this.listbox.classList.remove(ABOVE_CLASS)
    this.el.removeAttribute("aria-activedescendant")
  },
}

export default MentionAutocomplete
