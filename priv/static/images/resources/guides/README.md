# Resources Guide Images

This directory holds the screenshots shown in the step-by-step guides on the
Resources page (`/resources/:id`). The guides themselves live in
`lib/kanban_web/live/resources_live/how_tos/`, and each step points at an image
with `image:` (plus `image_width` and `image_height`) or with an `images:` list
of `%{url:, alt:, width:, height:}` maps.

`test/kanban_web/live/resources_live/guide_images_test.exs` fails, naming the
guide and step, when a step points at a file that isn't here, at something that
isn't a PNG in this directory, or declares a size the PNG doesn't have.

## 1. Load the demo data

Take every screenshot from demo data, never from a real board. Seed it inside
the running dev app with Tidewave `project_eval`, not with `mix run` in a
shell while the dev server is up:

```elixir
{summary, _binding} = Code.eval_file("priv/repo/resources_demo_seeds.exs")
summary
```

Return only the summary: the binding holds every top-level value the script
built, so printing it puts more than you need into the transcript.

The seed (`priv/repo/resources_demo_seeds.exs`) refuses to run against
anything but the dev database (and the test database, so its own test can run
it), creates no Organization, and is safe to run
again: it finds or creates the users and memberships, and leaves a demo board
that already exists untouched. To rebuild a board, delete it in the UI and run
the seed again.

It creates:

- **Users**, all `@example.test`: Maya Chen (owner of both boards), Priya
  Raman and Marcus Bell (members), and Jordan Alvarez, who is on no board, for
  the "search for users" shots.
- **Checkout Revamp**, an AI-optimized board:
  - tasks in every column, with labels (Payments, iOS, Android,
    Accessibility, Performance);
  - the goal "Saved payment methods" with three children, created days before
    any of them was claimed;
  - "Move the order summary above the fold" waiting in Review, with a comment
    from Priya that mentions Maya, and a full agent completion: acceptance
    criteria, completion notes, a passing structured review and a diff for
    each of its three changed files, so the Review queue has something to
    show;
  - "Show saved cards in the payment sheet" in Doing, depending on the
    finished "Store card tokens with the payment provider";
  - an API token record named "Checkout agent";
  - four weeks of completed work by several agents, so every metrics page
    has data, with the workflow steps each agent reported, so the Compliance
    page has dispatch rates, skip reasons and per-agent numbers.
- **Marketing Site Launch**, a custom board with To Do, In Progress (WIP limit
  3, and full), In Review and Published.

Two optional environment variables, set in the VM before the eval (for
example `System.put_env("RESOURCES_DEMO_VIEWER", "you@example.com")`):

- `RESOURCES_DEMO_PASSWORD` gives the demo users a password you choose (12 to
  72 characters), so you can sign in as Maya. Without it the password is
  random and never printed. Setting it on a later run replaces the old one.
- `RESOURCES_DEMO_VIEWER` adds an existing dev user to both demo boards with
  modify access.

## 2. Sign in to photograph

The best option is to sign in as `maya.chen@example.test` in a private window,
using the password you set. Then every name, avatar and board on screen is demo
data.

If you use `RESOURCES_DEMO_VIEWER` to photograph from a browser that is
already signed in, your own name, avatar and other boards are on screen too.
Crop them out: the sidebar footer, the member avatars in the board header, the
workspace switcher, and `/boards`. For shots of those, sign in as Maya.

Once a viewer is on the demo boards, they stay there, so they show up even
when you're signed in as Maya: in the **Manage members** list, as an avatar on
the board cards and the board header, and in the **Assigned To** options.
Remove them from the page before you capture (delete their member row and
avatar in the browser's dev tools or with a `browser.eval` script). Change only
the page, never the data.

Never forge a session cookie to sign in as someone else.

Organization and workspace screens (`/org`, `/org/audit`, `/org/security`,
`/org/sso`, `/org/scim`, `/workspace/settings`) can't use the
seed, because Organizations can't be deleted and the seed won't create one.
Use an existing dev Organization that the person who owns the dev data names,
and check that every name and email on screen is a test account.

The organizations guides were captured in such an Organization, renamed for
the shots: **Northwind Studio**, with Maya as org-admin, and its workspace
**Product Team**, with Priya as a Member and Marcus as a Guest. Its paid
board **Mobile App Launch** has Priya (can edit) and Marcus (read only).
Once Maya belongs to an Organization, the workspace switcher shows at the top
of her sidebar and any of its other boards show on `/boards`. When you
recapture an older shot, hide the switcher (`#workspace-switcher`) and those
boards in the page.

Locked states (**Available to organizations** and the free-board limit) show
only while plans are enforced. Switch them on in the running VM with
`Application.put_env(:kanban, :plans_enforced, true)`, capture, then switch
them off again with `false` and check `Application.get_env(:kanban, :plans_enforced)`.
Revoke any invitation you sent for a shot, and never click
**Accept invitation** with a demo account you mean to keep out of the
Organization.

## 3. Capture

1. **Viewport:** a browser window 1280 to 1440 CSS pixels wide, zoom at 100%.
   Use a 375px-wide window only for a step about the phone layout.
2. **Theme:** light, unless the step is about the theme.
3. **State:** set the screen up exactly as the checklist row says. Open the
   menu, fill the form with demo values, select the task. Wait for animations
   to finish.
4. **Annotate, if the step needs it:** a 3px orange (`#F97316`) ring around
   the control and an orange arrow pointing at it. Draw them as a temporary
   absolutely-positioned SVG overlay in the page before capturing. Remove the
   overlay afterwards and never commit it. Use at most one or two
   annotations per image.
5. **Capture:**
   - With Tidewave, run `await browser.screenshot()` to look at the page and
     `await browser.saveScreenshot()` to write a PNG under
     `tmp/tidewave/screenshots/`.
   - If a capture call hangs or fails, don't wait on it. Take the shot by
     hand with Cmd+Shift+4 on macOS (or the Snipping Tool) instead.
   - Fill and click with `browser.fill` and `browser.click`. Setting an
     input's value in a script and submitting the form doesn't reach the
     LiveView.
   - Wait about a second after any change to the page before you capture.
     A capture taken straight away can still show the old page.
   - A screen taller than the window (the task form) can be captured whole
     by zooming the page out, for example
     `document.documentElement.style.zoom = "0.8"`. Don't go below 0.8, or
     the text is too small to read.
6. **Crop** to the part of the UI the step talks about, plus enough around it
   to find it. On macOS, `sips -c <height> <width> --cropOffset <y> <x> in.png --out out.png`
   crops without other tools. Use an offset of at least 1: `sips` treats
   `--cropOffset 0 0` as no offset and crops from the middle.
7. **Compress** to under 200 KB (ImageOptim, TinyPNG or `pngquant`).
8. **Name** the file `[guide-id]-step-[n].png`, kebab-case. Use
   `-step-[n]-[m].png` when one step has several images. Older files keep their
   existing names.
9. **Declare the real size.** Read it with `sips -g pixelWidth -g pixelHeight file.png`
   or `file file.png`. Set `image_width`/`image_height` (or `width`/`height` in
   an `images:` entry) to exactly that. The page reserves this space before
   the image loads, so a wrong size makes the page jump.
10. **Check** by running
    `mix test test/kanban_web/live/resources_live/guide_images_test.exs`, then
    open the guide at `/resources/<guide-id>` in light and dark themes.

### Redaction rules

- Show only demo users and demo boards, never a real person's name, email or
  avatar.
- Never show a real API token, password, 2FA QR code, recovery code or
  secret. For a screen that shows a freshly generated token:
  1. generate a throwaway token on a demo board;
  2. replace its text with an obviously fake value such as
     `stride_dev_XXXXXXXXXXXXXXXXXXXXXXXX` in the page before capturing;
  3. revoke the token afterwards.
- Editor screenshots of local files (`.stride.md`, `.stride_auth.md`) use
  placeholder values only.
- Check the whole image, including notification badges, the browser address
  bar and any tooltips, before committing it.

## 4. Checklist

One row per image the guides use today. Board ids differ between databases,
so routes say which demo board to open. `Checkout` is Checkout Revamp and
`Marketing` is Marketing Site Launch.

| File | Guide / step | Route | UI state | Viewport / crop |
|---|---|---|---|---|
| `board-creation-step-1.png` | creating-your-first-board / 1 Access Your Boards Dashboard | `/boards` (as Maya) | Top of the sidebar with **Boards** active | Crop the top of the sidebar |
| `board-creation-step-2.png` | creating-your-first-board / 2 Choose a Board Type | `/boards` (as Maya) | Checkout Revamp card and the **New board** card with **Empty Board** and **AI Optimized**; Marketing card hidden in the page | Header and first grid row |
| `board-creation-step-3.png` | creating-your-first-board / 3 Enter Board Details | `/boards/new?ai_optimized=true` | **New Board** form with a demo name and description, not saved | From the heading to **Save Board** |
| `board-creation-step-4.png` | creating-your-first-board / 4 Start Using Your Board | `/boards/<Checkout>` | Header, tabs and all five columns, page zoomed to 80% | Full width, top of the board |
| `managing-board-settings-step-2.png` | managing-board-settings / 2 Name and Description | `/boards/<Checkout>/settings` (as Maya, the owner) | **Board settings** open at the top: name, description, **Make board publicly readable** unticked. Never tick it for the shot | Crop to the details card |
| `managing-board-settings-step-4.png` | managing-board-settings / 4 Field Visibility | `/boards/<Checkout>/settings` | Scrolled to **Field visibility** with the board's saved toggles; don't click any (they save at once) | Crop to the Field visibility card |
| `managing-board-settings-step-5.png` | managing-board-settings / 5 Labels | `/boards/<Checkout>/settings` | **Labels** with the five demo labels and the empty add row | Crop to the Labels card |
| `finding-work-with-search-and-filters-step-2.png` | finding-work-with-search-and-filters / 2 Searching | `/boards/<Checkout>?q=saved&priority=high` | "saved" in the search box, **High** priority, the "N of M" column counts and the no-drag hint; every menu closed | From the filter bar to the bottom of the first cards, no header or sidebar |
| `finding-work-with-search-and-filters-step-6.png` | finding-work-with-search-and-filters / 6 Keyboard Shortcuts | `/boards/<Checkout>`, `?` button clicked | The **Keyboard shortcuts** panel | Crop to the panel |
| `bulk-editing-cards-step-2.png` | bulk-editing-cards / 2 Selecting Cards | `/boards/<Checkout>`, **Select** clicked | Three Ready cards ticked (W3, W4, W5), nothing applied | The columns below the bulk bar, no header avatars |
| `bulk-editing-cards-step-3.png` | bulk-editing-cards / 3 Moving Cards | `/boards/<Checkout>`, same state | The bulk bar showing "3 selected" with every menu closed; remove any non-demo member's option from the assignee menus in the page | Crop to the bar |
| `archiving-tasks-step-2.png` | archiving-tasks / 2 The Archive Page | `/boards/<Checkout>/archive` | Archive the last three Done cards (D8, W39, W40) with the card archive icon first. Never click **Archive old (30d+)**: it would archive most of the Done column | From the **Archive** heading to **Export CSV**, no sidebar |
| `archiving-tasks-step-4.png` | archiving-tasks / 4 Restoring or Deleting a Task | `/boards/<Checkout>/archive` | D8's actions menu open showing **Restore** and **Delete forever**. Afterwards **Restore** D8, W39 then W40, in that order, so the Done column keeps its order, and check the board has no archived tasks | The three rows and the menu |
| `understanding-columns-step-2.png` | understanding-columns / 2 AI-Optimized Boards: Fixed Columns | `/boards/<Checkout>` | All five column headers with cards, page zoomed to 80% | Column headers and first cards |
| `understanding-columns-step-3.png` | understanding-columns / 3 Custom Boards: Flexible Columns | `/boards/<Marketing>` | Four custom columns, In Progress at 3/3 | Crop the columns |
| `understanding-columns-step-5-1.png` | understanding-columns / 5 WIP Limits | `/boards/<Marketing>/columns/<In Progress>/edit` | Column form with **WIP Limit** 3, nothing focused | Crop the form |
| `understanding-columns-step-5-2.png` | understanding-columns / 5 WIP Limits | `/boards/<Marketing>` | In Progress header showing 3/3, with no + button | Crop the column |
| `adding-task-step-1.png` | adding-your-first-task / 1 Open the Task Form | `/boards/<Checkout>` | Ring and arrow on the Backlog **Add Task** (+) button | Backlog and Ready headers, exactly 560x160 (the image test uses this size) |
| `adding-task-step-2.png` | adding-your-first-task / 2 Enter Task Details | `/boards/<Checkout>/columns/<Backlog>/tasks/new` | New Task form filled with a demo task under the Saved payment methods goal, page zoomed to 80%, not saved | From the heading to **Column** |
| `adding-task-step-4.png` | adding-your-first-task / 4 Save and Start Working | same as above, scrolled to the bottom | Labels (Payments ticked), Dependencies and **Save Task** | Crop the button area |
| `inviting-members-step-1.png` | inviting-team-members / 1 Open the Members Tab | `/boards/<Checkout>` | Ring and arrow on the **Members** tab | Full width, header and tabs |
| `inviting-members-step-2.png` | inviting-team-members / 2 Search by Email | `/boards/<Checkout>/members` | Searched `jordan.alvarez@example.test` (search matches whole emails only); Jordan's card shown | From the heading to Jordan's card |
| `inviting-members-step-3.png` | inviting-team-members / 3 Choose Their Access | `/boards/<Checkout>/members` | Jordan's card and the current users (Maya, Marcus, Priya) | From Jordan's card to **Close** |
| `inviting-team-members-step-4.png` | inviting-team-members / 4 Invite Someone Without an Account | `/boards/<Checkout>/members` | Searched `sam.ortiz@example.test`, which has no account; the invite card shown. Don't click an invite button | Crop the window |
| `using-stride-with-a-team-step-2.png` | using-stride-with-a-team / 2 Plan the Work as Goals | `/boards/<Checkout>` | The Saved payment methods goal card in Ready, its child W10 below and W9 in Doing | Ready and Doing columns, scrolled to the goal |
| `using-stride-with-a-team-step-3.png` | using-stride-with-a-team / 3 Assign Each Goal to a Developer | `/boards/<Checkout>/tasks/<goal>/edit` | **Assigned To** set to Priya Raman with a ring, not saved | Priority to Assigned To |
| `monitoring-task-progress-step-4.png` | monitoring-task-progress / 4 Viewing Task Details | `/boards/<Checkout>` | Details of "Show saved cards in the payment sheet" (W9) open, comment box not focused | The window, from the header to **Edit task** |
| `monitoring-task-progress-step-5.png` | monitoring-task-progress / 5 Using Filters to Focus | `/boards/<Checkout>?assignee=<Marcus id>&priority=high` | Filter bar with High and Marcus Bell set and **Clear filters** showing, at desktop width so the `/` and `?` buttons show | The bar and the first four columns, scaled to 1000px wide |
| `reviewing-completed-work-step-2.png` | reviewing-completed-work / 2 Open the Review Queue | `/review` (as Maya) | The order-summary task selected; the hard-coded "Avg time to review" text hidden in the page | Full window, scaled to 1200px wide |
| `reviewing-completed-work-step-3.png` | reviewing-completed-work / 3 What to Check | `/review` | **Changed files** with `order_summary.ex` clicked open | Crop the Changed files panel |
| `reviewing-completed-work-step-4.png` | reviewing-completed-work / 4 Approving Work | `/review` | The task header with **Request changes** and **Approve**. Don't click **Approve**: it moves the task to Done | From the header to the stats row |
| `reviewing-completed-work-step-5.png` | reviewing-completed-work / 5 Requesting Changes | `/review` | **Request changes** clicked and demo notes typed, not sent; click **Cancel** afterwards | From the header to **Send request** |
| `managing-your-account-step-1.png` | managing-your-account / 1 Opening Settings | `/users/settings` (as Maya, more than 10 minutes after signing in) | The sign-in page with "You must re-authenticate to access this page." and Maya's email filled in; nothing typed in **Password** | From the flash to **Sign in** |
| `managing-your-account-step-2.png` | managing-your-account / 2 The Settings Tabs | `/users/settings` (as Maya, within 10 minutes of signing in) | **Profile** selected, Maya's name and email not edited (this image also serves step 3) | From the page title to below **Notifications**, with the **Profile** card; no sidebar |
| `managing-your-account-step-4.png` | managing-your-account / 4 Changing Your Password | `/users/settings?section=password` | Both password fields empty | Crop the card |
| `managing-your-account-step-6.png` | managing-your-account / 6 Single Sign-On | `/users/settings?section=sso` | The not-linked paragraph (plans off, so no lock) | Crop the card |
| `managing-your-account-step-7.png` | managing-your-account / 7 Before You Can Delete Your Account | `/users/settings?section=danger_zone` | The two board blockers (Checkout Revamp, Marketing Site Launch) with **Transfer ownership to**. If a `RESOURCES_DEMO_VIEWER` account is on the boards, remove its option from both selects in the page so only demo members show. Don't transfer anything: the confirmation window can't be reached without moving a board, so step 8 has no image | From the card title to the last blocker |
| `free-and-paid-boards-step-3.png` | free-and-paid-boards / 3 The Free-Board Limit | `/boards/<Checkout>/members` (as Maya, plans enforced) | The **Add user by email** card with "4 of 3 people" (a demo viewer makes the fourth) and **Get Stride for your organization**, nothing typed | Crop the card, not the member list |
| `free-and-paid-boards-step-4.png` | free-and-paid-boards / 4 Locked Features on a Board | `/boards/<Checkout>` (plans enforced) | The filter bar and the inline **Bulk actions** lock | From the filter bar to the lock, full board width |
| `free-and-paid-boards-step-5.png` | free-and-paid-boards / 5 Integrations and Notifications | `/boards/<Checkout>` **Integrations** window (plans enforced) | The **Integrations** lock panel under Webhooks, nothing focused | From the window title to the lock |
| `working-in-a-workspace-step-2.png` | working-in-a-workspace / 2 Switching Workspaces | `/boards` (as Maya, in Northwind Studio) | The switcher open on Product Team | Crop the top of the sidebar |
| `working-in-a-workspace-step-3.png` | working-in-a-workspace / 3 Opening Workspace Settings | `/workspace/settings` | **Members** tab with Marcus (Guest) and Priya (Member) | From the workspace name to the end of the members card; no sidebar |
| `working-in-a-workspace-step-5.png` | working-in-a-workspace / 5 Moving a Board Here | `/workspace/settings?section=boards` | Mobile App Launch listed; **Move a board here** with Checkout Revamp chosen. Don't click **Move here**: boards can't be moved back. Hide any other boards in the list | Both cards |
| `working-in-a-workspace-step-6.png` | working-in-a-workspace / 6 Inviting People | `/workspace/settings?section=invitations` | **Invite people** filled for `sam.ortiz@example.test` as Guest with Mobile App Launch, not sent; one pending invitation to Jordan, revoked after the shot | Both cards |
| `working-in-a-workspace-step-8.png` | working-in-a-workspace / 8 Exporting a Workspace | `/workspace/settings?section=export` | No exports yet; don't request one | Both cards |
| `accepting-an-invitation-step-2.png` | accepting-an-invitation / 2 Opening the Link Without an Account | `/invitations/<token>`, signed out | **You're invited** with **Create account** and **Sign in**; the address bar (which holds the token) not in the shot | Crop the card |
| `accepting-an-invitation-step-4.png` | accepting-an-invitation / 4 When the Link Doesn't Work | `/invitations/not-a-real-token`, signed out | **Invitation unavailable** | Crop the card |
| `administering-your-organization-step-2.png` | administering-your-organization / 2 The Organization Console | `/org` (as Maya, org-admin of Northwind Studio) | **Details** tab; replace the Organization's test contact and the empty address fields in the page with demo values (48 Harbour Street, Portland, United States, Maya Chen, `maya.chen@example.test`, +1 503 555 0142) | From the Organization name to the end of the Details card, no sidebar |
| `administering-your-organization-step-4.png` | administering-your-organization / 4 Members | `/org?section=members` | Hide the rows of the non-demo test accounts (`#member-1144`, `#member-1145`, `#member-1150`); Maya, Priya and Marcus remain. Don't click **Remove** | Crop the Members card |
| `administering-your-organization-step-6.png` | administering-your-organization / 6 Workspaces | `/org?section=workspaces` | "Design Team" typed in **New workspace name**, not created; the Product Team row. Don't click **Rename** or **Archive** | Crop the card |
| `reading-the-organization-audit-log-step-3.png` | reading-the-organization-audit-log / 3 Filtering | `/org/audit` | No filter set, nothing focused | From the title to the first rows, including the filter bar |
| `reading-the-organization-audit-log-step-5.png` | reading-the-organization-audit-log / 5 Actions Outside Your Organization | `/org/audit` | The rows that show **Outside your Organization** and Maya's workspace rename | Crop those rows with the table header |
| `organization-security-policy-step-2.png` | organization-security-policy / 2 Requiring Two-Factor | `/org/security` | **Require two-factor authentication for every member** ticked, 7 days, not saved (reload afterwards to discard) | Crop the Two-factor authentication card |
| `organization-security-policy-step-5.png` | organization-security-policy / 5 Audit Log Retention | `/org/security` | Retention empty, showing **Keep forever**. Don't save | Crop the Audit log retention card and **Save security policy** |
| `setting-up-single-sign-on-step-2.png` | setting-up-single-sign-on / 2 Verifying a Domain | `/org/sso` | Hide the domain list (`#sso-domain-list`): its row shows a real TXT value. `northwind.example` typed in **Email domain**, not added | Crop the Verified domains card |
| `setting-up-single-sign-on-step-4.png` | setting-up-single-sign-on / 4 Connecting an OpenID Connect Provider | `/org/sso` | **Issuer URL** `https://login.northwind.example` and **Client ID** `stride-northwind-studio` typed, **Client secret** empty; replace the dev origin in **Redirect URI** with `https://stride.example.com` after typing (each keystroke re-renders it). Don't save | Crop the card |
| `setting-up-single-sign-on-step-5.png` | setting-up-single-sign-on / 5 Connecting a SAML Provider | `/org/sso` | All fields empty; replace the dev origin in the entity ID and ACS URL with `https://stride.example.com`. Don't download or save | From the card title to the metadata box |
| `provisioning-users-with-scim-step-2.png` | provisioning-users-with-scim / 2 The SCIM Base URL | `/org/scim` | "Okta provisioning" typed in **Token name**, not created; then replace the dev origin in the base URL with `https://stride.example.com` and hide the token list (`#scim-token-list`). Never create a token for the shot | The base URL and Create a SCIM token cards |
| `two-factor-authentication-step-3.png` | two-factor-authentication / 3 Open Two-Factor Settings | `/users/settings?section=two_factor` | "Two-factor authentication is off." and **Set up two-factor authentication** | Crop the card |
| `two-factor-authentication-step-5.png` | two-factor-authentication / 5 Scan the QR Code | `/users/settings?section=two_factor`, **Set up two-factor authentication** clicked | Before capturing, replace the QR image with a plain placeholder and the key text with `XXXX XXXX XXXX XXXX` in the page; leave **6-digit code** empty. Then click **Cancel**, which deletes the unconfirmed secret, and check Maya has no `user_totps` row. Never click **Verify and turn on**: two-factor stays off for the demo user | Crop the card |
| `hooks-step-2.png` | setting-up-hooks / 2 Create .stride.md | an editor view, not the app | `.stride.md` with the guide's five example sections, `before_doing` to `after_goal`, each "(blocking, 600s timeout)"; no hostnames, home paths or usernames | Crop the editor pane |
| `api-auth-step-1.png` | api-authentication / 1 Generate an API Token | `/boards/<Checkout>/api_tokens` (as Maya) | **Create new token** filled with demo values (Checkout laptop agent, claude-opus-5-5), not submitted; **Active tokens** shows the seeded Checkout agent, **Never used** | From **Create new token** to **Active tokens**, below the window's subtitle |
| `api-auth-step-2.png` | api-authentication / 2 Complete Token Generation | `/boards/<Checkout>/api_tokens` | **Token created** panel for a throwaway token. Replace the whole token text in the page with `stride_dev_` and dots before capturing (match up to whitespace: tokens contain characters such as `+`), check no token text is left, then revoke and delete the token | Crop the panel |
| `api-auth-step-3.png` | api-authentication / 3 Create .stride_auth.md | an editor view, not the app | `.stride_auth.md` from the onboarding template with the fake token `stride_dev_XXXX…` and `maya.chen@example.test` | Crop the editor pane |
| `metrics-button.png` | metrics-dashboard / 1 Access the Metrics Dashboard | `/boards/<Checkout>` (as Maya) | Board title and the owner's full tab row with **Metrics** | From the board title to the bottom of the tab row, no sidebar |
| `metrics-filter.png` | metrics-dashboard / 2 Filter Your Data | `/boards/<Checkout>/metrics` | Defaults: **Last 30 Days**, **All Agents**, **Exclude Weekends** unticked | Crop the **Filters** card |
| `metrics-summary-cards.png` | metrics-dashboard / 3 Understand the Summary Cards | `/boards/<Checkout>/metrics` | Defaults; all five cards, including **Compliance** | Crop the card row |
| `throughput-summary.png` | throughput-metrics / 2 Navigate to Throughput | `/boards/<Checkout>/metrics/throughput` | Defaults | Crop the four stat cards |
| `throughput-chart.png` | throughput-metrics / 3 Reading the Chart | `/boards/<Checkout>/metrics/throughput` | Defaults | **Daily Completions Bar Chart** card, cut after about eleven bars |
| `cycle-time-summary.png` | cycle-time-metrics / 2 Navigate to Cycle Time | `/boards/<Checkout>/metrics/cycle-time` | Defaults | Crop the four stat cards |
| `cycle-time-chart.png` | cycle-time-metrics / 3 Reading the Chart | `/boards/<Checkout>/metrics/cycle-time` | Defaults; hide the filters and stats in the DOM so the whole chart fits | The whole **Cycle Time Trend** card |
| `lead-time-summary.png` | lead-time-metrics / 2 Navigate to Lead Time | `/boards/<Checkout>/metrics/lead-time` | Defaults | Crop the four stat cards |
| `lead-time-chart.png` | lead-time-metrics / 3 Lead Time vs. Cycle Time | `/boards/<Checkout>/metrics/lead-time` | Defaults; hide the filters and stats in the DOM so the whole chart fits | The whole **Lead Time Trend** card |
| `wait-time-metrics-step-2.png` | wait-time-metrics / 2 Navigate to Wait Time | `/boards/<Checkout>/metrics` | Defaults | Crop the **Wait Time** card |
| `review-wait-time.png` | wait-time-metrics / 3 Reading the Two Sections | `/boards/<Checkout>/metrics/wait-time` | Defaults | **Review Wait Time** section: the stats and the first three tasks |
| `backlog-wait-time.png` | wait-time-metrics / 3 Reading the Two Sections | `/boards/<Checkout>/metrics/wait-time` | Defaults; hide the filters and the review section in the DOM | **Backlog Wait Time** section: the stats and the first four tasks |
| `workspace-and-compliance-metrics-step-2.png` | workspace-and-compliance-metrics / 2 Open the Workspace Metrics Page | `/metrics` (as Maya) | Defaults: 14 days, **All boards**, weekends included | From the page title and toolbar to the bottom of the KPI strip, no sidebar |
| `workspace-and-compliance-metrics-step-4.png` | workspace-and-compliance-metrics / 4 Read the Daily Charts and Agents | `/metrics` | Defaults; hide the cycle and lead charts in the DOM | The throughput chart and the agents panel |
| `workspace-and-compliance-metrics-step-8.png` | workspace-and-compliance-metrics / 8 Read Step Dispatch Rates | `/boards/<Checkout>/metrics/compliance` (as Maya, the owner) | Seeded workflow steps: bars in all three colours | From the page title to the bottom of **Step Dispatch Rates** |
| `workspace-and-compliance-metrics-step-9.png` | workspace-and-compliance-metrics / 9 Read Skip Reasons and Agent Compliance | `/boards/<Checkout>/metrics/compliance` | Hide **Step Dispatch Rates** in the DOM | **Skip Reasons** and **Compliance by Agent** |

When you add an image to a guide, add its row here in the same change.
