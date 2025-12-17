// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/kanban"
import AutoDismissFlash from "./hooks/auto-dismiss-flash"
import SortableHook from "./hooks/sortable"
import ColumnSortableHook from "./hooks/column_sortable"
import DelayedModalClickAway from "./hooks/delayed_modal_click_away"
import Dropdown from "./hooks/dropdown"
import PasswordToggle from "./hooks/password_toggle"
import topbar from "../vendor/topbar"

const MyHooks = {
  AutoDismissFlash,
  Sortable: SortableHook,
  ColumnSortable: ColumnSortableHook,
  DelayedModalClickAway,
  Dropdown,
  PasswordToggle,
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...MyHooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Handle remote task moves (from other clients)
window.addEventListener("phx:task_moved_remotely", (e) => {
  const {task_id, new_column_id, new_position} = e.detail
  console.log(`Task ${task_id} moved remotely to column ${new_column_id} at position ${new_position}`)

  // Find the task element
  const taskElement = document.querySelector(`[data-id="${task_id}"]`)
  if (!taskElement) {
    console.log(`Task element ${task_id} not found, will reload`)
    window.location.reload()
    return
  }

  // Find the target column's sortable container
  const targetColumn = document.querySelector(`[data-column-id="${new_column_id}"][phx-hook="Sortable"]`)
  if (!targetColumn) {
    console.log(`Target column ${new_column_id} not found, will reload`)
    window.location.reload()
    return
  }

  // Remove from current location
  taskElement.remove()

  // Insert at new position
  const children = Array.from(targetColumn.children).filter(child => !child.classList.contains('empty-state'))
  if (new_position >= children.length) {
    targetColumn.appendChild(taskElement)
  } else {
    targetColumn.insertBefore(taskElement, children[new_position])
  }

  console.log(`Task ${task_id} moved successfully to column ${new_column_id}`)
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

