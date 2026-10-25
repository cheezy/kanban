# Marketing Showcase Images

This directory holds the screenshots on the two showcase pages, `/product`
(`lib/kanban_web/controllers/page_html/product.html.heex`) and `/workflows`
(`lib/kanban_web/controllers/page_html/workflows.html.heex`). Every image
comes from demo data, so it can be taken again whenever the UI changes.

`test/kanban_web/controllers/marketing_images_test.exs` reads the `<img>` tags
in each page's `<main>` and fails when an image:

- points at a file that isn't under `priv/static`;
- isn't a PNG in this directory (`/images/marketing/`);
- has no `width` and `height`, or declares a size the PNG doesn't have;
- is in this directory but neither page uses it.

`/product` shows only images from this directory. When you retake one, keep
its file name, declare its new size in the page's `width` and `height`, and
update its row in the checklist below in the same change.

Like everything under `priv/static`, this file is served publicly, so it names
demo data only.

## 1. Load the demo data

Seed the demo data inside the running dev app with Tidewave `project_eval`,
never with `mix` in a shell while the dev server is up:

```elixir
{summary, _binding} = Code.eval_file("priv/repo/resources_demo_seeds.exs")
summary
```

Run it again **right before each capture session**. Each run moves the
timestamps on the **Storefront Search** board up to the present, so Claude
Opus 5.5 shows as working on `/agents` (it shows as stuck once its claim is an
hour old), its last completions show as recent, and the six weeks of history
end today. The summary's `showcase_refresh` says what happened: `:shifted`,
`:current` (nothing to move) or `:missing`.

The seed is described in
[the Resources guide images README](../resources/guides/README.md), section 1.
Besides the guides' boards it creates **Storefront Search**, an AI-optimized
board owned by Maya Chen with:

- about 38 finished tasks over six weeks, some by four agents (Claude Opus
  5.5, Claude Sonnet 5.5, Codex and Claude Haiku 4.5) and some by Priya, Marcus
  and Maya, so the metrics and cycle-time charts show agents and humans side
  by side;
- Claude Opus 5.5 at work on "Suggest spellings when a search finds nothing"
  in Doing, after five tasks it finished in the last day;
- "Rank exact title matches above partial ones" waiting in Review, with a
  written reviewer report, a structured review (3/3 criteria, one minor issue)
  and a diff for each changed file;
- tasks in Backlog and Ready.

Don't rebuild Checkout Revamp: the demo delivery target "Checkout launch" uses
its goal, and targets can't be deleted.

## 2. Sign in

Sign in as `maya.chen@example.test` in a private window, using the password you
set with `RESOURCES_DEMO_PASSWORD`. Never forge a session cookie.

If you can't sign in as Maya, photograph from a browser that is already
signed in, with the seed's `RESOURCES_DEMO_VIEWER` set to that account, and
remove your own name, avatar, other boards and their counts from the page
first, as
[the Resources guide images README](../resources/guides/README.md), section 2,
describes. Pages that add up every board you can see (the `/boards` header,
the review queue's header, targets) must be cropped out or hidden, and
`/agents` and `/metrics` filtered to Storefront Search with their own board
selector. That selector's label still counts every board you can see ("1 of 11
boards"), so hide the selector (`[data-metrics-board-selector]` on `/metrics`)
before capturing.

In the dev database Maya is also a member of the Northwind Studio
Organization. Unless a shot is about Organizations, hide its board (Mobile App
Launch) and the workspace switcher (`#workspace-switcher`) in the page before
capturing.

## 3. Capture

Follow the capture steps and redaction rules in
[the Resources guide images README](../resources/guides/README.md), section 3,
with these differences:

1. **Viewport:** 1440 CSS pixels wide, zoom at 100%, unless the row says
   otherwise.
2. **Theme:** always light. The pages show the same image in the light and the
   dark theme.
3. **Annotations:** none, unless the row asks for one. These images show the
   product, not a step to follow.
4. **Name** the file `[page]-[section].png`, as in the checklist.
5. **Compress** to under 200 KB and **declare the real size** in the page's
   `width` and `height`.
6. **Check** by running
   `mix test test/kanban_web/controllers/marketing_images_test.exs`, then open
   the page in the light and the dark theme.

## 4. Checklist

One row per planned image. Board ids differ between databases, so routes name the demo board:
`Checkout` is Checkout Revamp, `Search` is Storefront Search and `Mobile` is Mobile App Launch.

| File | Page / section | Route | Demo user | UI state | Crop | Theme |
|---|---|---|---|---|---|---|
| `product-hero.png` | `/product`, hero | `/boards/<Search>` | Maya Chen | All five columns with cards, Claude Opus 5.5's card in Doing, page zoomed to 80% | The board header and columns, no sidebar, about 700 px high | Light |
| `product-boards.png` | `/product`, Plan / "All your boards at a glance" | `/boards` | Maya Chen | The demo boards' cards with their stats and the Checkout launch target; Mobile App Launch hidden | The header and the board cards, no sidebar | Light |
| `product-board.png` | `/product`, Plan / "A fixed flow for agents, or columns of your own" | `/boards/<Search>` | Maya Chen | Zoom at 100% | The Ready, Doing and Review columns | Light |
| `product-goal.png` | `/product`, Plan / "Goals that track their own progress" | `/boards/<Checkout>/goals/<Saved payment methods>` | Maya Chen | Hierarchy, progress and the three children | From the header to the children, no sidebar | Light |
| `product-task-detail.png` | `/product`, Build / "Everything an agent needs, in one task" | `/boards/<Checkout>`, "Add a delivery estimate to the order summary" open | Maya Chen | The Field visibility toggles on, as in the guides' `reading-a-tasks-details` rows, and off again after the two Build shots | The modal, from its header to **Key files** | Light |
| `product-task-schema.png` | `/product`, Build / "Tests, security and pitfalls, spelled out" | same task | Maya Chen | Scrolled to **Verification steps** | From **Verification steps** to **Security considerations**, main column only | Light |
| `product-review-queue.png` | `/product`, Review / "Review queue" | `/review` | Maya Chen | Click "Rank exact title matches above partial ones" (the queue opens on the Checkout task); the report and 3/3 · 1 issue showing. Don't click **Approve** | The queue and the review pane, below the page header | Light |
| `product-review-diff.png` | `/product`, Review / "The checks and the diff, file by file" | `/review`, same task | Maya Chen | `lib/storefront/search/ranking.ex` clicked so its diff is open, pane scrolled to the end | The review pane from the acceptance criteria to the changed files | Light |
| `product-agent-activity.png` | `/product`, Operate / "See what every agent is doing" | `/agents`, filtered to Storefront Search | Maya Chen | Claude Opus 5.5 working (seed run just before), the feed on **All** | The header, the roster and the feed, no sidebar | Light |
| `product-my-work.png` | `/product`, Operate / "Everything assigned to you, on one page" | `/my-work` | Maya Chen | Copied from the guide image `your-work-across-boards-step-2.png`: Checkout D1, W1, W2 and Marketing W1 assigned to Maya | The header and the two board cards, no sidebar | Light |
| `product-target.png` | `/product`, Operate / "Plan toward a date across boards" | `/targets/<Checkout launch>` | Maya Chen | Copied from the guide image `planning-with-targets-step-5.png`: the target as it stands. Don't click **Edit target** | From the date and status to the Goals list | Light |
| `product-notifications.png` | `/product`, Operate / "Told when work needs you" | `/notifications` | Maya Chen | Copied from the guide image `staying-informed-with-notifications-step-4.png`: the demo notifications on **All** | The header and the notification list, no sidebar | Light |
| `product-integrations.png` | `/product`, Operate / "Send board events to Slack, Discord or your own service" | `/boards/<Mobile>/integrations` | Maya Chen | Copied from the guide image `connecting-webhooks-slack-and-discord-step-5.png`: the generic `.test` endpoint's **Deliveries** open. No signing secret, no Slack or Discord host, and never **Send test** | The generic endpoint and its recent deliveries | Light |
| `product-metrics.png` | `/product`, Measure / "Know where work waits" | `/metrics`, Storefront Search only in the board selector | Maya Chen | 30-day window, page zoomed to 80% | From the KPI strip to the leaderboard, no sidebar | Light |
| `workflows-ready.png` | `/workflows`, "Getting ready for development" | `/boards/<Search>` | Maya Chen | The Backlog and Ready columns | The two columns | Light |
| `workflows-claim.png` | `/workflows`, "The AI development lifecycle" | `/boards/<Search>` | Maya Chen | The Doing column with Claude Opus 5.5's card | The Doing column | Light |
| `workflows-compliance.png` | `/workflows`, "The AI development lifecycle" (hooks and subagents) | `/boards/<Checkout>/metrics/compliance` | Maya Chen | Step dispatch rates and skip reasons | The two charts | Light |
| `workflows-flagged-for-review.png` | `/workflows`, "Human review and completion" / "Flagged for review" | `/review`, "Rank exact title matches above partial ones" selected | Maya Chen | The acceptance criteria and the diff | The review pane | Light |
| `workflows-cleared-to-ship.png` | `/workflows`, "Human review and completion" / "Cleared to ship" | `/boards/<Search>/metrics/wait-time` | Maya Chen | Review wait time from the approved history | The Review Wait Time section | Light |

Four Operate rows reuse Resources guide screenshots, which were taken from the
same demo data under the guide README's capture and redaction rules. To retake
one, follow that guide row and keep the `/product` file name. The Operate MCP
subsection shows the commands from `KanbanWeb.PageHTML.mcp_snippet/0` instead
of a screenshot, so it has no row.

Each `/product` subsection is a `<div data-showcase-item>` holding its `h3`, and
the image test fails when one shows neither an image nor a code snippet, or when
a theme `h3` sits outside such a `div`. Mark every new subsection the same way.

When you add an image to a page, add or update its row here in the same change.
