# Marketing Showcase Images

This directory holds the screenshots on the two showcase pages, `/product`
(`lib/kanban_web/controllers/page_html/product.html.heex`) and `/workflows`
(`lib/kanban_web/controllers/page_html/workflows.html.heex`). Every screenshot
comes from demo data, so it can be taken again whenever the UI changes.

It also holds the "LEVEL: BOSS" Stride sticker on `/HitMe`
(`lib/kanban_web/controllers/page_html/hit_me.html.heex`), the page the printed
handout points to. The sticker is supplied artwork, not a screenshot: it is the
handout's sticker with a transparent background outside its white border, so
it sits on the page's navy card without a grey box. Replace it only with a new
export of the same artwork, keep the file name, and declare its size in the
page's `width` and `height`.

`test/kanban_web/controllers/marketing_images_test.exs` reads the `<img>` tags
in each page's `<main>` and fails when an image:

- points at a file that isn't under `priv/static`;
- isn't a PNG in this directory (`/images/marketing/`);
- has no `width` and `height`, or declares a size the PNG doesn't have;
- is in this directory but no page uses it.

On `/product` it also fails when a subsection shows neither an image nor a code
snippet (see the end of this file).

Both pages show only images from this directory. When you retake one, keep
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
| `product-board-metrics.png` | `/product`, Measure / "Flow metrics for every board" | `/boards/<Search>/metrics` | Maya Chen | **Last 30 Days**, **All Agents**, weekends included | From the **Metrics Dashboard** title to the five summary cards, no sidebar | Light |
| `product-metrics.png` | `/product`, Measure / "Trends across all your boards" | `/metrics`, Storefront Search only in the board selector | Maya Chen | 30-day window, page zoomed to 80%, board selector and workspace switcher hidden | From the KPI strip to the leaderboard, no sidebar | Light |
| `product-compliance.png` | `/product`, Measure / "See how agents follow your workflow" | `/boards/<Search>/metrics/compliance` | Maya Chen | As it stands; the page has no filters | From the **Compliance Metrics** title to the end of **Step Dispatch Rates**, no sidebar | Light |
| `product-workspaces.png` | `/product`, Govern / "A workspace for each team" | `/workspace/settings`, Product Team selected | Maya Chen | Copied from the guide image `working-in-a-workspace-step-3.png`: the **Members** tab with Marcus (Guest) and Priya (Member) | The workspace header, the tab list and the members | Light |
| `product-free-boards.png` | `/product`, Govern / "Free boards and paid boards" | `/boards/<Checkout>/members` | Maya Chen | Copied from the guide image `free-and-paid-boards-step-3.png`: plans switched on for that capture and off again; "4 of 3 people" on a board that was over the limit before it started | The **Add user by email** card | Light |
| `product-org-console.png` | `/product`, Govern / "One console for org-admins" | `/org` | Maya Chen (org-admin of Northwind Studio) | Copied from the guide image `administering-your-organization-step-2.png`: the **Details** tab | The header with its four buttons and the **Details** card | Light |
| `product-audit-log.png` | `/product`, Govern / "An audit log of security events" | `/org/audit` | Maya Chen | Copied from the guide image `reading-the-organization-audit-log-step-5.png`: demo events only, actors outside the Organization shown as such | The event table | Light |
| `product-security-policy.png` | `/product`, Govern / "Require two-factor for every member" | `/org/security` | Maya Chen | Copied from the guide image `organization-security-policy-step-2.png`: the requirement ticked, 7-day grace period | The **Two-factor authentication** card | Light |
| `product-sso.png` | `/product`, Govern / "Single sign-on with your identity provider" | `/org/sso` | Maya Chen | Copied from the guide image `setting-up-single-sign-on-step-2.png`: `northwind.example` typed in **Email domain**, no TXT record shown | The **Verified domains** card | Light |
| `product-scim.png` | `/product`, Govern / "Provision people with SCIM" | `/org/scim` | Maya Chen | Cropped from the guide image `provisioning-users-with-scim-step-2.png` so the SCIM base URL is left out; no token shown | The **Create a SCIM token** card only | Light |
| `workflows-requirements.png` | `/workflows`, "Requirements" | `/boards/<Checkout>/goals/<Saved payment methods>` | Maya Chen | The goal with its three children (Ready, Doing, Done), page zoomed to 110% | From the goal's title to the end of the hierarchy and the side panel, no topbar or sidebar | Light |
| `workflows-ready.png` | `/workflows`, "Getting ready for development" | `/boards/<Search>` | Maya Chen | Page zoomed to 150% | The Backlog and Ready columns | Light |
| `workflows-needs-review.png` | `/workflows`, "Getting ready for development" / "Decide what needs review" | `/boards/<Search>/tasks/<Search inside product descriptions>/edit` | Maya Chen | **Needs Review** ticked in the page, page zoomed to 150%. Never press **Save Task**; leave the form without saving | The **Needs Review** and **Human Task** boxes | Light |
| `workflows-claim.png` | `/workflows`, "The AI development lifecycle" / Claim | `/boards/<Search>` | Maya Chen | Claude Opus 5.5's task in Doing (seed run just before), page zoomed to 150% | The Doing column | Light |
| `workflows-explore.png` | `/workflows`, "The AI development lifecycle" / Explore | `/boards/<Checkout>`, "Add a delivery estimate to the order summary" open | Maya Chen | Page zoomed to 150%, scrolled to **Explorer result** | The **Explorer result** section, main column only | Light |
| `workflows-implement.png` | `/workflows`, "The AI development lifecycle" / Implement | same task | Maya Chen | `lib/storefront/shipping/estimate.ex` clicked so its diff is open, page zoomed to 150% | The **Changed files** section, main column only | Light |
| `workflows-review-report.png` | `/workflows`, "The AI development lifecycle" / Review | `/boards/<Search>`, "Rank exact title matches above partial ones" open | Maya Chen | Page zoomed to 150%, scrolled to **Review report** | The **Review report** section, main column only | Light |
| `workflows-review-matrix.png` | `/workflows`, "The AI development lifecycle" / Review | `/boards/<Checkout>`, "Add a delivery estimate to the order summary" open | Maya Chen | The **Behaviour/Test Matrix** Field visibility toggle on for this capture and off again after it, page zoomed to 150% | The matrix, main column only | Light |
| `workflows-validate.png` | `/workflows`, "The AI development lifecycle" / Validate | same task | Maya Chen | Page zoomed to 150%, scrolled to **Workflow steps** | The **Workflow steps** section, main column only | Light |
| `workflows-flagged-for-review.png` | `/workflows`, "Human review and completion" / "Flagged for review" | `/review` | Maya Chen | "Rank exact title matches above partial ones" clicked, then `lib/storefront/search/ranking.ex`; the review pane scrolled to its end. Don't click **Approve** or **Request changes** | The queue and the review pane, below the page header (its subtitle counts every board you can see) | Light |
| `workflows-cleared-to-ship.png` | `/workflows`, "Human review and completion" / "Cleared to ship" | `/boards/<Search>` | Maya Chen | Board scrolled sideways, page zoomed to 150% | The Review column and the top of the Done column | Light |
| `hitme-sticker.png` | `/HitMe`, hero | None: supplied artwork | None | The handout's "LEVEL: BOSS" sticker, 504x504, transparent outside its white border | Whole sticker; the page tilts and clips it | Both |

Four Operate rows and the seven Govern rows reuse Resources guide
screenshots, which were taken from the same demo data under the guide README's
capture and redaction rules. To retake one, follow that guide row and keep the
`/product` file name. The Govern screens need an org-admin of the demo
Organization, so sign in as Maya Chen; never appoint your own account. Leave
SCIM tokens, SSO client secrets, redirect and base URLs and DNS verification
values out of the frame. The Operate MCP
subsection shows the commands from `KanbanWeb.PageHTML.mcp_snippet/0` instead
of a screenshot, so it has no row.

Each `/product` subsection is a `<div data-showcase-item>` holding its `h3`, and
the image test fails when one shows neither an image nor a code snippet, or when
a theme `h3` sits outside such a `div`. Mark every new subsection the same way.

When you add an image to a page, add or update its row here in the same change.
