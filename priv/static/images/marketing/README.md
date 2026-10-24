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

`/product` still shows seven older mockups from `/images/`. They are listed in
`@legacy_mockups` in that test, which skips the directory and size checks for
them. When a screenshot from this checklist replaces a mockup, do all of
these in the same change:

1. Commit the PNG here and point the page's `<img>` at it, with its real size.
2. Remove the mockup's path from `@legacy_mockups` (the test fails while a
   listed mockup is no longer on a page).
3. Update the image assertions in the `GET /product` test in
   `test/kanban_web/controllers/page_controller_test.exs`.
4. Delete the old PNG from `priv/static/images/`.

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
`Checkout` is Checkout Revamp and `Search` is Storefront Search.

| File | Page / section | Route | Demo user | UI state | Crop | Theme |
|---|---|---|---|---|---|---|
| `product-boards.png` | `/product`, "Organization wide real-time activity" | `/boards` | Maya Chen | The demo boards' cards with their stats; Mobile App Launch hidden | The header and the board cards, no sidebar | Light |
| `product-board.png` | `/product`, "Five-column flow, AI-optimized" | `/boards/<Search>` | Maya Chen | All five columns with cards, Claude Opus 5.5's card in Doing, page zoomed to 80% | Full board width | Light |
| `product-task-detail.png` | `/product`, "Structured schema, not free-text" | `/boards/<Checkout>`, "Add a delivery estimate to the order summary" open | Maya Chen | The Field visibility toggles on, as in the guides' `reading-a-tasks-details` rows, and off again afterwards | The modal | Light |
| `product-goal.png` | `/product`, "Plan at the level you think at" | `/boards/<Checkout>/goals/<Saved payment methods>` | Maya Chen | Hierarchy, progress and the three children | From the header to the children | Light |
| `product-review-queue.png` | `/product`, "Approve at the speed of keystrokes" | `/review` | Maya Chen | Click "Rank exact title matches above partial ones" (the queue opens on the Checkout task); the report, 3/3 · 1 issue and the diff showing. Don't click **Approve** | The queue and the review pane | Light |
| `product-agent-activity.png` | `/product`, "AI ops as a first-class surface" | `/agents`, filtered to Storefront Search | Maya Chen | Claude Opus 5.5 working (seed run just before), the feed on **All** | The roster and the feed | Light |
| `product-metrics.png` | `/product`, "Cycle time, split by agent vs human on all levels" | `/metrics` | Maya Chen | 30-day window, the KPI strip, the cycle-time series and the leaderboard with agents and people | From the KPI strip to the leaderboard, no sidebar | Light |
| `workflows-ready.png` | `/workflows`, "Getting ready for development" | `/boards/<Search>` | Maya Chen | The Backlog and Ready columns | The two columns | Light |
| `workflows-claim.png` | `/workflows`, "The AI development lifecycle" | `/boards/<Search>` | Maya Chen | The Doing column with Claude Opus 5.5's card | The Doing column | Light |
| `workflows-compliance.png` | `/workflows`, "The AI development lifecycle" (hooks and subagents) | `/boards/<Checkout>/metrics/compliance` | Maya Chen | Step dispatch rates and skip reasons | The two charts | Light |
| `workflows-flagged-for-review.png` | `/workflows`, "Human review and completion" / "Flagged for review" | `/review`, "Rank exact title matches above partial ones" selected | Maya Chen | The acceptance criteria and the diff | The review pane | Light |
| `workflows-cleared-to-ship.png` | `/workflows`, "Human review and completion" / "Cleared to ship" | `/boards/<Search>/metrics/wait-time` | Maya Chen | Review wait time from the approved history | The Review Wait Time section | Light |

When you add an image to a page, add or update its row here in the same change.
