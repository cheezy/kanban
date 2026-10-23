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
  - the goal "Saved payment methods" with three children;
  - "Move the order summary above the fold" waiting in Review, with a comment
    from Priya that mentions Maya;
  - an API token record named "Checkout agent";
  - four weeks of completed work by several agents, so every metrics page
    has data.
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

Never forge a session cookie to sign in as someone else.

Organization and workspace screens (`/org`, `/org/audit`, `/org/security`,
`/workspace/settings`) can't use the
seed, because Organizations can't be deleted and the seed won't create one.
Use an existing dev Organization that the person who owns the dev data names,
and check that every name and email on screen is a test account.

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
6. **Crop** to the part of the UI the step talks about, plus enough around it
   to find it. On macOS, `sips -c <height> <width> --cropOffset <y> <x> in.png --out out.png`
   crops without other tools.
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
| `board-creation-step-1.png` | creating-your-first-board / 1 Access Your Boards Dashboard | any page | Sidebar with **Boards** | Crop the sidebar item |
| `board-creation-step-2.png` | creating-your-first-board / 2 Click New Board | `/boards` (as Maya) | The new-board control | Crop the control |
| `board-creation-step-3.png` | creating-your-first-board / 3 Enter Board Details | `/boards/new` | Form filled with a demo name and description | Crop the form |
| `board-creation-step-4.png` | creating-your-first-board / 4 Start Using Your Board | `/boards/<Checkout>` | Board header and first columns | Full width, top of the board |
| `understanding-columns-step-2.png` | understanding-columns / 2 AI-Optimized Boards: Fixed Columns | `/boards/<Checkout>` | All five column headers with cards | Full width, column headers and first cards |
| `understanding-columns-step-3.png` | understanding-columns / 3 Custom Boards: Flexible Columns | `/boards/<Marketing>` | Four custom columns | Crop the column headers |
| `understanding-columns-step-5-1.png` | understanding-columns / 5 WIP Limits | `/boards/<Marketing>/columns/<In Progress>/edit` | Column form with the WIP limit | Crop the form |
| `understanding-columns-step-5-2.png` | understanding-columns / 5 WIP Limits | `/boards/<Marketing>` | In Progress header showing 3 of 3 | Crop the header |
| `adding-task-step-1.png` | adding-your-first-task / 1 Open the Task Form | `/boards/<Checkout>` | Ring and arrow on the Backlog **Add Task** (+) button | Backlog and Ready headers |
| `adding-task-step-2.png` | adding-your-first-task / 2 Enter Task Details | `/boards/<Checkout>/columns/<Backlog>/tasks/new` | New Task form filled with a demo task | Crop the form |
| `adding-task-step-4.png` | adding-your-first-task / 4 Save and Start Working | same as above | The form's save button | Crop the button area |
| `inviting-members-step-1.png` | inviting-team-members / 1 Access Board Settings | `/boards/<Checkout>` | Board tabs with **Members** | Full width, header and tabs |
| `inviting-members-step-2.png` | inviting-team-members / 2 Search for Users | `/boards/<Checkout>/members` | Search for "Jordan" showing Jordan Alvarez | Crop the search panel |
| `inviting-members-step-3.png` | inviting-team-members / 3 Set Permission Level | `/boards/<Checkout>/members` | Access level choice for Jordan | Crop the panel |
| `hooks-step-2.png` | setting-up-hooks / 2 Create .stride.md | an editor, not the app | `.stride.md` with the guide's example hooks | Crop the editor pane |
| `api-auth-step-1.png` | api-authentication / 1 Generate an API Token | `/boards/<Checkout>/api_tokens` | Token form filled with a demo name | Crop the form |
| `api-auth-step-2.png` | api-authentication / 2 Complete Token Generation | `/boards/<Checkout>/api_tokens` | New-token panel, token text replaced with a fake value | Crop the panel |
| `api-auth-step-3.png` | api-authentication / 3 Create .stride_auth.md. | an editor, not the app | `.stride_auth.md` with placeholder values | Crop the editor pane |
| `metrics-button.png` | metrics-dashboard / 1 Access the Metrics Dashboard | `/boards/<Checkout>` | Board tabs with **Metrics** | Crop the tabs |
| `metrics-filter.png` | metrics-dashboard / 2 Filter Your Data | `/boards/<Checkout>/metrics` | Filters card | Crop the card |
| `metrics-summary-cards.png` | metrics-dashboard / 3 Understand the Summary Cards | `/boards/<Checkout>/metrics` | Summary cards with data | Crop the card row |
| `throughput-summary.png` | throughput-metrics / 2 Navigate to Throughput | `/boards/<Checkout>/metrics/throughput` | Summary stats | Crop the stat row |
| `throughput-chart.png` | throughput-metrics / 3 Reading the Chart | `/boards/<Checkout>/metrics/throughput` | Daily completions chart | Crop the chart |
| `cycle-time-summary.png` | cycle-time-metrics / 2 Navigate to Cycle Time | `/boards/<Checkout>/metrics/cycle-time` | Summary stats | Crop the stat row |
| `cycle-time-chart.png` | cycle-time-metrics / 3 Reading the Chart | `/boards/<Checkout>/metrics/cycle-time` | Cycle time chart | Crop the chart |
| `lead-time-summary.png` | lead-time-metrics / 2 Navigate to Lead Time | `/boards/<Checkout>/metrics/lead-time` | Summary stats | Crop the stat row |
| `lead-time-chart.png` | lead-time-metrics / 3 Lead Time vs. Cycle Time | `/boards/<Checkout>/metrics/lead-time` | Lead time chart | Crop the chart |
| `review-wait-time.png` | wait-time-metrics / 3 Reading the Tables | `/boards/<Checkout>/metrics/wait-time` | Review wait table | Crop the table |
| `backlog-wait-time.png` | wait-time-metrics / 3 Reading the Tables | `/boards/<Checkout>/metrics/wait-time` | Backlog wait table | Crop the table |

When you add an image to a guide, add its row here in the same change.
