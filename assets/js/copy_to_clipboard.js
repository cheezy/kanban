// Copies an element's text to the clipboard and says whether it worked:
// JS.dispatch("stride:copy", to: "#value", detail: %{copied: "ok-id", failed: "fail-id"}).
// Used by the one-time webhook signing secret, so the secret never sits in an
// attribute. "Copied" shows only after the browser accepts the text; when the
// clipboard is missing (a plain-http address) or refuses (the page is not
// focused, permission denied) the failure message shows instead, because that
// box is the user's only chance to take the secret.
//
// `setVisible(el, visible)` shows or hides a status element. app.js passes
// LiveView's JS commands, so the change survives a re-render.

export function copyText(nav, text) {
  if (!nav || !nav.clipboard || typeof nav.clipboard.writeText !== "function") {
    return Promise.resolve(false)
  }

  try {
    return nav.clipboard.writeText(text).then(() => true, () => false)
  } catch (_error) {
    return Promise.resolve(false)
  }
}

export function showOutcome(doc, detail, copied, setVisible) {
  if (!detail || typeof detail !== "object") return
  const shown = copied ? detail.copied : detail.failed
  const hidden = copied ? detail.failed : detail.copied
  const hide = typeof hidden === "string" ? doc.getElementById(hidden) : null
  const show = typeof shown === "string" ? doc.getElementById(shown) : null
  if (hide) setVisible(hide, false)
  if (show) setVisible(show, true)
}

export function install(win, doc, setVisible) {
  win.addEventListener("stride:copy", (event) => {
    const text = event.target.textContent.trim()
    return copyText(win.navigator, text).then((copied) =>
      showOutcome(doc, event.detail, copied, setVisible)
    )
  })
}
