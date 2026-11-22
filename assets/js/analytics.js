// Umami analytics events (W2897). docs/analytics.md lists every event.
//
// The tracker tag (KanbanWeb.Analytics) renders only on pages that opted in
// and only when Umami is configured, and an ad blocker can stop it loading,
// so every call checks that window.umami exists and does nothing otherwise.
// Nothing here sends an email, a token, an account id or board data: event
// names and properties are fixed strings or a runtime slug that must match
// the slug pattern.
//
// Page views and the data-umami-event clicks (github-clicked,
// get-started-clicked) are sent by the tracker itself; this file adds:
//   - install-command-copied {runtime}: a copy inside [data-install-command]
//   - signup: once, from the AnalyticsSignup hook on confirmation-pending
//   - strideAnalyticsBeforeSend: the tracker's data-before-send hook, which
//     drops the query string and fragment from the page URL and the referrer

const RUNTIME_SLUG = /^[a-z0-9-]{1,40}$/

// Calls umami.track when the tracker loaded. Returns whether it was sent.
export function umamiTrack(win, name, data) {
  // Everything that touches the tracker sits inside the try, the reads of
  // window.umami and umami.track included: a tracker or blocker can define
  // either as a getter that throws, and an analytics failure must never break
  // the click, copy or sign-up that triggered it.
  //
  // The guard and the catch overlap on purpose. The guard handles a missing
  // tracker (Umami unset or blocked, the common case) by returning false
  // without raising an exception; the catch handles a read or a track call
  // that throws. For a missing tracker the catch alone would also return
  // false, so no test in analytics.test.mjs can see whether the guard is
  // there (W2918). Keep it anyway: it spares every page without a tracker a
  // thrown and caught TypeError.
  try {
    const umami = win && win.umami
    if (!umami || typeof umami.track !== "function") return false

    if (data === undefined) {
      umami.track(name)
    } else {
      umami.track(name, data)
    }
    return true
  } catch (_error) {
    return false
  }
}

// "https://host/path?x=1#y" -> "https://host/path". Non-strings pass through.
export function stripQuery(url) {
  if (typeof url !== "string") return url
  return url.split("#")[0].split("?")[0]
}

// data-before-send="strideAnalyticsBeforeSend": returns the payload with the
// query string and fragment removed from url and referrer, so neither the
// email on /users/confirmation-pending nor a token in a referring URL can
// reach Umami even if the tracker keeps a referrer's query string.
export function beforeSend(_type, payload) {
  if (!payload || typeof payload !== "object") return payload

  const cleaned = {...payload}
  if ("url" in cleaned) cleaned.url = stripQuery(cleaned.url)
  if ("referrer" in cleaned) cleaned.referrer = stripQuery(cleaned.referrer)
  return cleaned
}

function elementOf(node) {
  if (!node) return null
  return node.nodeType === 1 ? node : node.parentElement || null
}

// The [data-install-command] element the current selection is in, if any.
export function installCommandFor(win, event) {
  const fromTarget = elementOf(event && event.target)
  const fromTargetMatch = fromTarget && fromTarget.closest && fromTarget.closest("[data-install-command]")
  if (fromTargetMatch) return fromTargetMatch

  const selection = win.getSelection ? win.getSelection() : null
  if (!selection) return null

  for (const node of [selection.anchorNode, selection.focusNode]) {
    const el = elementOf(node)
    const match = el && el.closest && el.closest("[data-install-command]")
    if (match) return match
  }

  return null
}

// Sends install-command-copied with the runtime slug when the visitor copies
// text from an install command.
export function onCopy(win, event) {
  const command = installCommandFor(win, event)
  if (!command) return false

  const runtime = command.getAttribute("data-runtime")
  if (typeof runtime !== "string" || !RUNTIME_SLUG.test(runtime)) return false

  return umamiTrack(win, "install-command-copied", {runtime})
}

// The AnalyticsSignup hook. The element is rendered only right after a
// successful registration; `state` keeps a remount on the same page load
// (a LiveView reconnect) from sending a second event.
export function signupHook(win, state = {sent: false}) {
  return {
    mounted() {
      if (state.sent) return
      state.sent = umamiTrack(win, "signup")
    }
  }
}

export function install(win, doc) {
  win.strideAnalyticsBeforeSend = beforeSend
  doc.addEventListener("copy", (event) => onCopy(win, event))
}
