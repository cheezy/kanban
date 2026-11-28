# iOS App Shell

This document is for contributors who work on the native iOS and iPadOS app in
`mobile/ios`. It describes the shell the app shows once a device is signed in:
the four tabs, the corner buttons, the Now badge and how the shell chooses
between a tab bar and a sidebar. How the device gets signed in is in
[iOS Sign-in](ios-sign-in.md).

## Which screen fills the window

`RootScreen` decides, from the update state and the sign-in phase, and
`RootView` shows what it picks:

| Screen | When |
|---|---|
| Update required | The server answered 426, whatever else holds. |
| Sign in | Signed out, signing in, or signed in to a plan without the app (the locked panel). |
| The background alone | The Keychain or `/api/me` has not answered yet. |
| The shell | Signed in, and the plan includes the app or the server could not say. |

Whenever the screen stops being the shell, `AppRouter.follow(_:)` clears what
the shell held: the selected tab, every tab's stack, any open sheet, the
person's name and the badge. A sign-out from any tab therefore leaves nothing of
the person on screen, and an answer that set out before the sign-out is dropped.

## The tabs

The shell has four tabs: **Now**, **Review**, **Boards** and **Agents**. In a
compact width, as on a phone or an iPad in a narrow split view, they sit in a
tab bar. In a regular width they are the rows of a `NavigationSplitView`
sidebar. Each tab has its own `NavigationStack`, whose path `AppRouter` keeps
per tab:

- Switching tabs keeps each tab's stack.
- Selecting the tab already selected takes it back to its first screen.
- `push(_:on:)` adds a screen to a tab without leaving the selected one.
- `show(_:on:)` opens a tab on one screen, as a deep link will.

A Now card's **Open backlog** button opens the Boards tab on
`.board(id, column: .backlog)`, a board scrolled to one column. `BoardColumn`
names the columns a route can open; it holds only Backlog so far.

The Now tab shows the decisions waiting on the person, and the Review tab
shows the review queue: `ReviewQueueView`, which renders `AppRouter.reviews`, a
`ReviewQueueModel`. It lists `GET /api/me/reviews` in the server's order, one
row per pending review with its identifier, age, title, what it holds up, its
verdicts and its file count. A large change is labelled **Large change**, or
**Too large to approve on a phone** when the server offers no Approve for it on
this device. The queue is cached under `.reviewQueue`, so it reads offline with
the offline banner, and it is fetched again on each `me:inbox` update, so a
review decided elsewhere leaves it. The shell observes both models while it is
shown, `refresh()` loads both, and `follow(_:)` forgets both. The Boards and
Agents screens are still to be built, so those tabs show only their titles.

## The review screen

A queue row pushes `.review(taskID)`, and `AppShell` shows `ReviewView` for it
with a `ReviewModel` from `AppRouter.reviewModel(for:)`. The model reads
`GET /api/me/reviews/:task_id`, and `ReviewContent` turns the answer into the
sections of the design's section 6.4, in the order its `sections` gives: the
header (identifier, priority, status, the identifiers it holds up, title, agent,
time spent and goal), What the agent says it did, the four verdict tiles
(acceptance criteria with how many were met, such as "4/4", testing strategy,
patterns and security considerations) with "N of 4 passed" and the failed
tiles' notes, Tests and checks (pitfalls, project checks, the security review's
findings by severity, red only for a critical or important one, and exploratory
testing, or **See notes on the web** when no structured block was stored), and
the changed files, flagged first. A section with nothing to show is left out.
`ReviewContent` also picks each row's words and colour, so the views only
render them: the pitfalls pill says the verdict (Passed, Failed or Not
assessed), and VoiceOver reads a file row as its name in its folder with its
lines added and removed in words, never a bare path. The bottom
bar holds **Request changes** and **Approve**, or **Approve on tablet or web**
for a change too large for the device. They stay disabled until the next goal
wires them (`ReviewModel.canDecide`), so neither looks live while it does
nothing. At the
accessibility text sizes the bar is not pinned: its buttons follow the files,
stacked, and the verdict tiles, the check rows and the file rows stack their
parts, so no word breaks in the middle. The summary and
notes are shown as plain text, and `completion_notes` is never read.

The model keeps each review in the cache under `.review(taskID:)`, which holds
the last 20 opened, and shows the cached copy with the offline banner while
offline; the buttons wait for a connection. A 404 means the review no longer
waits on the person, and the screen says so. A decision the server refuses with
a 409 reaches `ReviewModel.show(_:)`: **Already decided** names who decided and
what, and how long ago, and **Resubmitted** asks the person to reload, which fetches the new
version. A file with a stored diff pushes `.reviewFile(ReviewFileTarget)`,
which carries the task, the file's index, the list's `files_version` and the
review's files, flagged first, so the diff screen can page through them.

## The diff screen

`DiffView` shows one file of a review, read only, through `DiffModel`. Its title
is the file's name; the header under it holds the Flagged pill, the lines added
and removed, the language and the file's place in the list ("1 of 6"), then the
full path. The body is the unified diff with its line numbers, a + or − marker,
the server's highlighting and wrapped lines; the app highlights nothing itself,
and a language with no lexer is plain text. Each reviewer's note sits under the
line it names, and a note on the whole file, or on a line the diff lacks, sits
above the diff. VoiceOver reads each line as "Added, line 2", "Removed, line 2"
or "Line 1", with its text as the value. A capped diff says so, and a binary
file says it has no diff to show.

**Back to verdicts** returns to the review, and **Next file** and a swipe move
through the files that have a stored diff, wrapping at either end; with one such
file, Next file is disabled. At the accessibility text sizes the two buttons
follow the diff, stacked, as the review's do. The model keeps each file in the
cache under `.reviewFile(taskID:index:filesVersion:)`, which is stored only while
its review is cached, and shows the cached copy with the offline banner while
offline. A 409 means the files changed: the model reloads the review, stores
it, finds the same path in the new list and asks again, and a path the new list
lacks, a second 409 or a 404 shows that the file is gone. The diff text is shown
as plain text, never run or linked.

## The corner buttons and the badge

**New task** and the person's avatar, which opens **Settings**, sit in the top
corner of Now on a phone and above the sidebar's tabs on an iPad, where every
tab can reach them. They are a row in the screen, above the large title, rather
than navigation bar items, because bar items do not grow with the text size.
Each tab's first screen hides the navigation bar; the screens pushed after it
show theirs, with the back button (`TabRoot(tab:isPushed:)`, until each route's
own screen is built). On an iPad the first screen shows its empty bar only while the
sidebar is hidden, because the button that brings the sidebar back is then in
that bar. Each corner button is a 44-point target. The two buttons each open a sheet with a **Close** button and the
sheet's title until its own screen is built; both are in the sheet's content
for the same reason, and because the audit fails the contrast of a glass bar
button. The avatar shows the person's initials from `GET /api/me`, and VoiceOver
reads it as Settings.

The Now tab's badge is `summary.waiting` from `GET /api/me/decisions`: every
item waiting on the person, counted before the list's cap of 100. A count of
zero hides the badge. On a phone it is the tab bar's badge; in the sidebar the
row draws the count as a pill of ink on surface, which reads the same on the
selected row and the other rows, in light and dark, because a list badge fails
the contrast audit on the selected row. VoiceOver reads the count as the tab's
value, as it reads a badge.

Each sidebar row is a plain button that draws its own selection, as the design
does: `stride-orange-ink` text on a `stride-orange-soft` background, with the
selected trait for VoiceOver. The list's own selection sometimes fills the row
with the tint and draws white text on it, which in dark, where the tint is
light, falls far below 4.5:1. The shell asks for both again each time the app
becomes active, and a failed answer leaves what it already shows.

## Seeing and testing it

Start a debug build with `-StrideStubSignIn allow` and press **Sign in**: the
shell then reads the fixtures in `mobile/shared/fixtures/`, so Now shows a badge
of 4, Review lists three reviews, one of them too large to approve on a phone,
and the avatar reads "Alex Example". `ReviewQueueModelTests` covers the queue's
order, sizes, states, cache and live updates, and `ReviewModelTests` the review
screen's sections, file order, offline copy and 409 states. `ReviewUITests`
opens a review from the queue, audits it in light and dark and opens its flagged
file. `DiffModelTests` covers the diff screen's notes, header, highlighting,
paging, cache, 409 and 404, and `DiffUITests` reads its lines with VoiceOver,
audits it in light and dark and in German at the largest text, and pages with
Next file and a swipe. `AppRouterTests` covers the screen
choice, the stacks and the badge, and `ShellUITests` opens every tab in light
and dark, the two sheets and the German tab names at the largest text size,
auditing each for accessibility, and hides the iPad's sidebar and brings it
back.
