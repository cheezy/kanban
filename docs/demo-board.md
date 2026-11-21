# Demo Board

`/demo` is a public, read-only sample board. Agents claim tasks, run their
hooks and move cards from Ready to Done, a goal moves with its tasks, and
when the script ends the replay starts again. Anyone can open it without an
account, and the home page links it from the band under the hero.

Nothing on the page is real. There is no board, no user and no task behind
it, and the page never reads or writes the database.

## How it is built

| Piece | Where | What it does |
|---|---|---|
| The data and the script | [`demo_board.ex`](../lib/kanban_web/demo_board.ex) (`KanbanWeb.DemoBoard`) | The sample cards and goal, the board before the first move, the ordered list of moves, where the goal goes and how far along it is, and the functions that translate card titles, column names and feed sentences |
| The page | [`demo_board_live.ex`](../lib/kanban_web/live/demo_board_live.ex) (`KanbanWeb.DemoBoardLive`) | Holds one replay per visitor, advances it on a timer, and renders the goals strip, the columns and the activity feed |
| The home page link | [`marketing_demo_band.ex`](../lib/kanban_web/components/marketing_demo_band.ex) (`KanbanWeb.MarketingDemoBand`) | The "See agents work a board" band on `/` |
| The route | [`router.ex`](../lib/kanban_web/router.ex) | `live "/demo"` in the `:public` live session, whose root layout is the marketing layout, so it works signed in or out |

The cards, column headers and goals strip are the board's own components,
`KanbanWeb.TaskCard`, `KanbanWeb.GoalCard`, `KanbanWeb.ColumnHeader` and
`KanbanWeb.GoalsStrip`, so the demo looks like a real board. Three
attributes exist for it:

- `TaskCard`'s `read_only` shows a plain cursor instead of the grab cursor a
  draggable card has.
- `GoalCard`'s `read_only` does the same for a goal card. `TaskCard` passes
  its own `read_only` on when the card is a goal.
- `ColumnHeader`'s `status` takes the column as an atom, such as `:doing`, and
  picks the status dot colour from it. A real board picks the colour from the
  column's name, which does not work once the name is translated.

## The layout

`/demo` is a page for visitors, so it looks like the home page and `/issue`,
not like the app. It renders in the marketing layout, which gives it the
marketing header and footer, and never in the app shell, so it has no
SideNav or app header, even for a signed-in visitor.

The page looks the same to everyone. Its one call to action is "Start now",
which goes to `/users/register`; it never offers a signed-in visitor a link
to their boards. The marketing header already does that.

The board sits in a `.stride-screen` element inside the page's `<main>`, as
it does on a real board, so the ink and surface tokens and the board's own
components resolve the same way in light and dark mode. The LiveView tests
check that `/demo` renders no app shell and no SideNav, signed in or out.

## The goal

One card, `G10`, is a goal with five children: four work tasks and the
defect `D106`. Two of them start in Done, so the goal and its strip open
partly complete, and the script finishes the other three.

The goal is placed by the rule a real board uses: it sits in the leftmost
column that holds one of its children, and in Done once they all are. No
move in the script names the goal. After every move, `apply_step/2` works
out the goal's column, and moves the goal to the head of that column if it
changed, so the goal changes column in the same move as the child that
drives it. It goes to Doing when its last Ready child is claimed, to Review
when its last child in Doing is sent there, and to Done with its last
child.

The goal card shows its children's progress, such as `2/5`, and each child
card carries the goal's chip. A column header counts only the work tasks and
defects in it, through `task_count/2`, as a real board does, so the goal card
is not counted. The card is marked promoted, so it renders no
"Promote children to Ready" button.

The goals strip above the columns gets each goal's `:flow`, the number of
its children in each column, from `goals/1` on every move, so the strip
fills as cards move and empties back to its starting state when the replay
starts again. The page passes the strip no board, so a goal pill is plain
text, never a link to a board the visitor cannot open.

## The replay

Each visitor's LiveView process holds its own replay: the index of the next
move, the board, and the last four moves for the activity feed. Two tabs
replay independently, and a reconnect starts again from the first move.

A `Process.send_after/3` timer sends the next tick. It is armed only on the
connected mount, so the first, static render shows the board before any move.
Every tick carries a fresh token, and a tick whose token is not the current one
is ignored, so a replaced timer can never advance the replay twice. The timer
belongs to the LiveView process and stops when the visitor leaves.

The interval is `config :kanban, :demo_board_tick_ms`, 3,000 milliseconds by
default. [`config/test.exs`](../config/test.exs) sets it to `0`, which arms no
timer: the tests send each tick themselves, so they never wait on a clock.

## Changing the script

The script is the `@script` list in `KanbanWeb.DemoBoard`. Each move is a map:

| Key | Meaning |
|---|---|
| `card` | The card's identifier, one of the keys of `@cards` |
| `agent` | `:claude`, `:cursor` or `:codex`, the keys of `@agents` |
| `event` | `:claim`, `:submit`, `:finish` or `:hook_failed`, which picks the feed sentence |
| `to` | The column the card ends in. A move whose column is the one the card is already in leaves it where it is, which is how a failing hook keeps a card in Doing |
| `hook` | The `.stride.md` hook the move runs, shown in the feed as written |
| `result` | `:passed` or `:failed` |

To add a card, add it to `@cards`, place it in a column of `@initial_board`,
and add a `card_title/1` clause with its title in `gettext`. A card is a
work task unless its `@cards` entry sets `type`, as `D106`'s does. To make it a
goal's child, add it to that goal's `children` in `@goals`. A goal must
start in the column `goal_column/2` picks for it, which
`test/kanban_web/demo_board_test.exs` checks. Every card must
start on the board exactly once; `test/kanban_web/demo_board_test.exs` checks
that every move names a known card, agent and column and that no move ever
duplicates or loses a card.

## Translations

The data holds no display text, only atoms and identifiers, so the page
follows the visitor's locale. Card titles, column names, feed sentences and
result labels are `gettext` calls in `KanbanWeb.DemoBoard`. Agent names are
product names and hook names are `.stride.md` section names, so neither is
translated.

Column names and result labels use their own contexts, `demo column` and
`hook result`, through `pgettext`. A shared msgid such as "Ready" is
translated for other pages, and one locale gave "Backlog" and "Ready" the
same word. A shared "passed" read as an exam grade next to a hook name. The
demo tests check that every locale gives the five columns five distinct
names.

After changing any of that text, run `mix gettext.extract --merge` and
translate the new entries in all seven locales, leaving none fuzzy. A feed
sentence's `%{agent}` and `%{card}` placeholders must appear in every
translation.

## Why it can change nothing

The page is read-only by construction:

- It renders no form, no drag hook and no click binding. The goal card is
  marked promoted, so its promote button is not rendered, and the goals strip
  has no board to link to.
- Its only `handle_event/3` clause ignores every event, so a crafted event, a
  move, a delete or a form submit, never reaches a board context function.
  Its `handle_params/3` ignores a live patch too, so a crafted patch to
  `/demo` leaves the replay as it is rather than crashing the view.
- It never calls `Kanban.Repo` or a context module. The LiveView tests check
  that its source names none of them, and that crafted events leave the task
  and board counts unchanged.
- It renders no token, email or real name. The card author is a made-up first
  name.

## Search

`/demo` is public and indexed. It has a translated `page_title` and
`meta_description`, it is listed in `SeoXML.public_paths/0` for the sitemap,
and it is in the noindex test's public list. See
[Search and Social Tags](seo.md).
