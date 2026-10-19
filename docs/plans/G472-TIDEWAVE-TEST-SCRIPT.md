# G472 Tidewave test script: paid-feature locks on free boards

This script walks an agent with Tidewave through every behaviour goal G472 added: the shared lock component and its click metric (W2404), Notifications (W2405, W2406), Bulk actions (W2407, plus the later change that keeps the Select toggle), Integrations (W2408), Telemetry task fields (W2409) and MCP (W2410). It also checks the paths that must stay free. W2411 is the automated suite in `test/kanban_web/plans/`; this script is the manual counterpart.

The behaviour each step checks is specified in [the design, section 7](PAYING-ORGANIZATIONS-DESIGN.md#7-paid-feature-locks).

## How to run it

- Run it against the **development** app only: `http://localhost:4000`, database `kanban_dev`.
- Tools:
  - `project_eval` runs Elixir inside the running app.
  - `execute_sql_query` reads the database.
  - `browser_eval` drives the signed-in browser tab. Call its `help` action once before the first browser step.
- Run the steps in order. Every step lists what to do and what to expect. Record each check as PASS or FAIL, with the actual value for a FAIL.
- Each `project_eval` block is self-contained. Blocks share state only through `:persistent_term.get(:g472)`, which step 1 writes.
- After navigating in the browser, wait about 1.5 seconds before reading the page. `browser_eval` shows only what the page code passes to `console.log`.
- The script flips the global `:plans_enforced` flag in the running app and creates data whose names start with `G472`. **Always run the teardown, even after a failure.**

### Before you start

1. The dev server is running the current code. If it has not been restarted since W2404 merged, step A.2 cannot persist the click event; restart it first.
2. The browser tab is signed in as `cheezy@letstango.ca`. This user owns the fixture boards and is not in any Organization.
3. At least one Organization exists (dev has `TW1792287201 Org A`). The script uses the first one.

---

## Step 0: Baseline and telemetry recorder

```elixir
# project_eval
alias Kanban.Repo
false = Kanban.Plans.enforced?()

user = Repo.get_by!(Kanban.Accounts.User, email: "cheezy@letstango.ca")
nil = Kanban.Organizations.get_membership(user)

# A long-lived process owns an ETS table that collects the plan and
# notification events, so later blocks can read them. It is a
# :duplicate_bag so that two identical events are both kept and can be
# counted (C.5 expects two).
owner =
  spawn(fn ->
    :ets.new(:g472_events, [:named_table, :public, :duplicate_bag])
    Process.sleep(:infinity)
  end)

Process.sleep(100)

:telemetry.attach_many(
  "g472-recorder",
  [
    [:kanban, :plan, :feature_refused],
    [:kanban, :plan, :locked_feature_clicked],
    [:kanban, :notification, :email_skipped],
    [:kanban, :mcp, :request, :stop]
  ],
  fn name, _measurements, meta, _ ->
    :ets.insert(:g472_events, {name, Map.drop(meta, [:telemetry_span_context])})
  end,
  nil
)

%{user_id: user.id, recorder: owner}
```

**Expect:** enforcement is off, and the user has no Organization membership. If either is wrong, stop: the dev data is not in the state this script assumes.

To read the recorded events at any later point:

```elixir
# project_eval: recorded events (newest last)
:ets.tab2list(:g472_events)
```

To clear them before a check: `:ets.delete_all_objects(:g472_events)`.

## Step 1: Fixtures

This step creates two AI-optimized boards owned by the user:

- **G472 Free**: stays in the user's personal workspace.
- **G472 Paid**: moved into a new workspace of the first Organization.

Each board gets the observability fields shown, a Ready task, a task whose telemetry fields and logging requirement are already stored, three Backlog tasks for bulk actions, an API token and a webhook endpoint.

The webhook URLs use `example.com`, which does not resolve on this machine. `create_endpoint` checks that the host resolves, so the block passes a fixed resolver for creation only. Deliveries resolve the host again at send time, fail as `:unresolvable` and retry, so **no request is ever sent**. The teardown cancels those retrying jobs.

```elixir
# project_eval
import Ecto.Query
alias Kanban.{Repo, Boards, Columns, Tasks, ApiTokens, Webhooks}
alias Kanban.Accounts.Scope
alias Kanban.Boards.Board
alias Kanban.Workspaces.Workspace

user = Repo.get_by!(Kanban.Accounts.User, email: "cheezy@letstango.ca")
scope = Scope.for_user(user)
org = Kanban.Organizations.Organization |> order_by(:id) |> limit(1) |> Repo.one!()

make_board = fn name ->
  {:ok, board} =
    Boards.create_ai_optimized_board(user, %{name: name, description: "G472 Tidewave fixture"})

  board
  |> Ecto.Changeset.change(field_visibility: Map.put(board.field_visibility || %{}, "observability", true))
  |> Repo.update!()
end

seed = fn board, label ->
  cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
  task = fn col, attrs -> {:ok, t} = Tasks.create_task(cols[col], Map.put(attrs, "created_by_id", user.id)); t end

  ready = task.("Ready", %{"title" => "G472 #{label} ready task", "status" => "open"})

  stored =
    task.("Backlog", %{
      "title" => "G472 #{label} stored telemetry",
      "telemetry_event" => "[:kanban, :g472, :stored]",
      "metrics_to_track" => "g472 stored count",
      "logging_requirements" => "G472 log line check"
    })

  bulk = for n <- 1..3, do: task.("Backlog", %{"title" => "G472 #{label} bulk #{n}"})

  {:ok, {_token, plain}} =
    ApiTokens.create_api_token(user, board, %{
      "name" => "G472 #{label} token",
      "agent_capabilities" => ["code_generation"]
    })

  # The resolver only satisfies the create-time reachability check; see above.
  {:ok, {endpoint, _secret}} =
    Webhooks.create_endpoint(
      scope,
      board,
      %{
        "kind" => "generic",
        "url" => "https://example.com/g472-#{label}",
        "event_types" => ["task.created", "task.moved"]
      },
      resolver: fn _host -> {:ok, [{93, 184, 215, 14}]} end
    )

  %{board_id: board.id, cols: Map.new(cols, fn {k, c} -> {k, c.id} end), ready_id: ready.id,
    stored_id: stored.id, bulk_ids: Enum.map(bulk, & &1.id), token: plain, endpoint_id: endpoint.id}
end

free = make_board.("G472 Free")
paid = make_board.("G472 Paid")
free_ctx = seed.(free, "free")
paid_ctx = seed.(paid, "paid")

personal_workspace_id = Repo.get!(Board, free.id).workspace_id

workspace =
  %{name: "G472 paid workspace"} |> Workspace.create_changeset(false, org.id) |> Repo.insert!()

{1, _} = from(b in Board, where: b.id == ^paid.id) |> Repo.update_all(set: [workspace_id: workspace.id])

true = Kanban.Plans.paid_board?(paid.id)
false = Kanban.Plans.paid_board?(free.id)

:persistent_term.put(:g472, %{
  user_id: user.id, org_id: org.id, workspace_id: workspace.id,
  personal_workspace_id: personal_workspace_id, free: free_ctx, paid: paid_ctx
})

%{free_board: free.id, paid_board: paid.id, org: org.name}
```

**Expect:** both boards are created, and only `G472 Paid` reports as paid. Write down both board ids; the browser steps use them as `FREE` and `PAID`.

The tokens are held in `:persistent_term`. Never print them or paste them outside this session.

## Step 2: With enforcement off, nothing is locked

Enforcement is still off. In the browser:

1. Open `/boards/FREE`.
   - Click `#bulk-select-toggle`. Expect per-card checkboxes (`.bulk-select`) and the real bar `#bulk-action-bar`. There is no `#bulk-action-bar-locked`.
   - Click the toggle again to leave selection mode.
2. Open `/boards/FREE/integrations`. Expect the endpoint form and the endpoint row, with no `#integrations-locked` and no `[data-endpoint-paused]`.
3. Open `/boards/FREE/tasks/<stored_id>/edit`, where `stored_id` is `:persistent_term.get(:g472).free.stored_id`. Expect the Telemetry Event and Metrics to Track inputs holding the stored values, and no `#task-telemetry-locked`.
4. Look at the header bell. Expect `#notification-bell` without a `data-notification-bell-locked` attribute and with no `#notification-bell-lock`.

Then check MCP:

```elixir
# project_eval: MCP initialize on the free board, enforcement off
%{free: %{token: token}} = :persistent_term.get(:g472)

Req.post!("http://localhost:4000/api/mcp",
  json: %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}},
  headers: [authorization: "Bearer #{token}", accept: "application/json, text/event-stream"]
).body
|> Map.take(["result", "error"])
|> Map.update("result", nil, &Map.take(&1, ["serverInfo"]))
```

**Expect:** a `result` containing `serverInfo`, and no `error`.

## Step 3: Turn enforcement on

```elixir
# project_eval
Application.put_env(:kanban, :plans_enforced, true)
:ets.delete_all_objects(:g472_events)
Kanban.Plans.enforced?()
```

**Expect:** `true`.

LiveViews compute their lock flags when they mount, so **reload every open page** after this step.

---

## Section A: The lock component and its click metric (W2404)

**A.0 Pick a feature whose click has not been counted this week.** Each user's click on a feature's prompt is counted once per 7 days, so a feature clicked in an earlier run this week records no new event in A.2. This block reads the limit without counting a click:

```elixir
# project_eval
g = :persistent_term.get(:g472)

clickable =
  for f <- ~w(integrations telemetry mcp notifications bulk_actions)a,
      Kanban.RateLimit.peek(:locked_feature_click, identity: "user:#{g.user_id}:#{f}") == :ok,
      do: f

:persistent_term.put(:g472, Map.put(g, :click_feature, List.first(clickable)))
clickable
```

- **Expect:** a list of features whose clicks this week have not been counted yet. Use the first one as `FEATURE` in A.1 to A.3 (it is also saved as `click_feature`).
- Each feature already clicked also emits a `[:kanban, :rate_limit, :denied]` event; that is expected.
- If the list is empty, every feature was clicked this week. Run A.1, A.3 and A.4 anyway, mark A.2 as skipped for that reason, and do not report it as a FAIL.
- The limit lives in memory, so a dev server restart clears it.

**A.1 The prompt link.** In the browser, open `/locked/FEATURE`.

- **Expect:** the tab lands on `/pricing#contact`, the page has an element with `id="contact"` (the Enterprise card, with the "Talk to us" button), and that card is scrolled into view.

**A.2 The click is counted and persisted, naming only the feature.**

```elixir
# project_eval
Process.sleep(500)

{
  :ets.tab2list(:g472_events)
  |> Enum.filter(fn {name, _} -> name == [:kanban, :plan, :locked_feature_clicked] end),
  Kanban.Repo.query!(
    "select metric_name, metadata, recorded_at from metrics_events where metric_name like 'kanban.plan.locked_feature_clicked%' order by recorded_at desc limit 3"
  ).rows
}
```

- **Expect:** one recorded event whose metadata is exactly `%{feature: :FEATURE}`, with no user id. The newest `metrics_events` row has metadata `{"feature": "FEATURE"}` and a `recorded_at` from just now.
- These rows stay in `metrics_events` by design; the teardown leaves them.
- If the event fires but no row appears, the dev server has not been restarted since W2404. Report this as an environment problem, not a FAIL.

**A.3 The rate limit.** Open `/locked/FEATURE` again.

- **Expect:** it still redirects to `/pricing#contact`, but no second `locked_feature_clicked` event is recorded.

**A.4 An unknown feature.** Open `/locked/not_a_feature`.

- **Expect:** a redirect to `/pricing` without `#contact`, and no event.

**A.5 Signed out.** Send a request with no session cookie:

```elixir
# project_eval
r = Req.get!("http://localhost:4000/locked/mcp", redirect: false, retry: false)
{r.status, Req.Response.get_header(r, "location")}
```


- **Expect:** a redirect to the log-in page, not to pricing.

**A.6 Dark mode.** Do this check for every locked surface in the sections below.

1. Set the theme with `browser_eval`:

   ```js
   localStorage.setItem('phx:theme', 'dark'); document.documentElement.setAttribute('data-theme', 'dark');
   ```

2. Read the computed `color` and `background-color` of the lock's label, its prompt link and its container.
3. Repeat with `light`.

**Expect:** readable contrast in both themes. Compute the contrast on the composited colours, not on raw values that include alpha. The prompt is underlined, and nothing relies on opacity utilities.

## Section B: Notifications (W2405, W2406)

**B.1 Locked bell.** Reload any page.

- **Expect:**
  - `#notification-bell` has `data-notification-bell-locked`.
  - `#notification-bell-lock` is present.
  - There is no `#notification-bell-badge`, even if the user has unread rows.

**B.2 Locked pages.** Open `/notifications`, then `/users/notifications`.

- **Expect:** each page shows `[data-notifications-locked]` with the `:notifications` panel (`[data-locked-feature="notifications"][data-variant="panel"]`), plus the `[data-locked-review-link]` link to `/review` and the `[data-locked-my-work-link]` link to `/my-work`. Both links work. Neither page has a preference form you can submit.

**B.3 Preferences refused in the context.** `unsubscribe` changes the signed-in user's real `review_requested` email setting, so this block first saves the current setting, and the teardown puts it back.

```elixir
# project_eval
alias Kanban.Notifications.Preference
g = :persistent_term.get(:g472)
user = Kanban.Repo.get!(Kanban.Accounts.User, g.user_id)
scope = Kanban.Accounts.Scope.for_user(user)

# nil means the user had no row for this event type (the default applies).
saved =
  case Kanban.Repo.get_by(Preference, user_id: user.id, event_type: :review_requested) do
    nil -> nil
    pref -> %{email: pref.email, in_app: pref.in_app}
  end

unless Map.has_key?(g, :saved_review_pref),
  do: :persistent_term.put(:g472, Map.put(g, :saved_review_pref, saved))

{
  Kanban.Notifications.update_preference(scope, "review_requested", %{"in_app" => true, "email" => false}),
  Kanban.Notifications.unsubscribe(user.id, "review_requested")
}
```

- **Expect:**
  - `update_preference` returns `{:error, {:plan_required, :notifications}}`.
  - `unsubscribe` succeeds (an `:ok` result, not a plan error), because turning email off is never gated.
  - A `feature_refused` event with `%{feature: :notifications, surface: :context}` is recorded.

**B.4 Generation follows the board, not the recipient.**

```elixir
# project_eval
alias Kanban.Notifications
g = :persistent_term.get(:g472)
user = Kanban.Repo.get!(Kanban.Accounts.User, g.user_id)
attrs = fn board_id -> %{title: "G472 notify check", url_path: "/review", board_id: board_id} end

{
  Notifications.notify(:review_requested, [user], attrs.(g.free.board_id)),
  Notifications.notify(:review_requested, [user], attrs.(g.paid.board_id)) |> then(fn {:ok, rows} -> length(rows) end)
}
```

- **Expect:**
  - The free board returns `{:ok, []}`: no row and no email job.
  - The paid board inserts one row, even though the recipient has no paid access.
  - No `feature_refused` event is recorded, because silent drops do not emit one.

**B.5 A queued email is skipped at send time.** This simulates a notification queued before launch: insert the row and its job directly, then let the dev Oban queue run it.

```elixir
# project_eval
alias Kanban.Notifications.{Notification, EmailWorker}
g = :persistent_term.get(:g472)

n =
  Kanban.Repo.insert!(%Notification{
    user_id: g.user_id, board_id: g.free.board_id, event_type: :review_requested,
    title: "G472 queued before enforcement", url_path: "/review"
  })

{:ok, _job} = %{notification_id: n.id} |> EmailWorker.new() |> Oban.insert()
Process.sleep(3000)

{
  Kanban.Repo.get!(Notification, n.id).emailed_at,
  :ets.tab2list(:g472_events) |> Enum.filter(fn {name, _} -> name == [:kanban, :notification, :email_skipped] end)
}
```

- **Expect:** `emailed_at` is `nil`, and an `email_skipped` event carries reason `:plan_locked`. `/dev/mailbox` has no message titled "G472 queued before enforcement".

**B.6 The digest leaves out free boards.** First give each board a task completed last week:

```elixir
# project_eval
import Ecto.Query
alias Kanban.{Repo, Tasks}
g = :persistent_term.get(:g472)
last_week = DateTime.utc_now() |> DateTime.to_date() |> Date.beginning_of_week() |> Date.add(-3) |> DateTime.new!(~T[10:00:00])

for ctx <- [g.free, g.paid] do
  done = Repo.get!(Kanban.Columns.Column, ctx.cols["Done"])
  {:ok, t} = Tasks.create_task(done, %{"title" => "G472 shipped last week", "created_by_id" => g.user_id})
  Repo.update_all(from(x in Kanban.Tasks.Task, where: x.id == ^t.id), set: [completed_at: last_week])
end

user = Repo.get!(Kanban.Accounts.User, g.user_id)

case Kanban.Notifications.Digest.build(user) do
  :empty -> :empty
  digest -> Enum.map(digest.boards, & &1.name) |> Enum.filter(&String.starts_with?(&1, "G472"))
end
```

- **Expect:** `["G472 Paid"]`, which includes the paid board but not `G472 Free`.

**B.7 Account emails still send.**

```elixir
# project_eval
user = Kanban.Repo.get!(Kanban.Accounts.User, :persistent_term.get(:g472).user_id)
Kanban.Accounts.UserNotifier.deliver_reset_password_instructions(user, "http://localhost:4000/g472-reset") |> elem(0)
```

- **Expect:** `:ok`. A reset-password email to the user appears in `/dev/mailbox`.

**B.8 A user with paid access.** Add the user to the Organization as an ordinary member, not as an org-admin:

```elixir
# project_eval
g = :persistent_term.get(:g472)
user = Kanban.Repo.get!(Kanban.Accounts.User, g.user_id)
Kanban.Organizations.add_member(g.org_id, user, :member) |> elem(0)
```

Reload the browser, then check:

- The bell has no lock and shows a badge.
- `/notifications` shows the inbox. "G472 notify check" from the paid board is listed.
- No row for `G472 Free` is listed. Rows hidden this way are not deleted.
- `/users/notifications` shows the preference form, and saving it works.

**Then remove the membership** so the remaining sections run as a free user:

```elixir
# project_eval
import Ecto.Query
g = :persistent_term.get(:g472)
Kanban.Repo.delete_all(from(m in Kanban.Organizations.OrganizationMember, where: m.user_id == ^g.user_id))
```

Reload, and confirm the bell is locked again.

## Section C: Bulk actions (W2407 and the Select-toggle change)

**C.1 A free board looks normal until the toggle is used.** Open `/boards/FREE`.

- **Expect:**
  - `#bulk-select-toggle` is visible with `aria-pressed="false"`.
  - There is no `#bulk-action-bar-locked`, no `#bulk-action-bar`, no `.bulk-select` and no prompt text on the page.

**C.2 The toggle opens the prompt instead of selection mode.** Clear the recorder, then click `#bulk-select-toggle`.

- **Expect:**
  - `#bulk-action-bar-locked` appears above the columns and contains `[data-locked-feature="bulk_actions"]`, the label "Bulk actions" and a link to `/locked/bulk_actions`.
  - The toggle reads "Done selecting" with `aria-pressed="true"`.
  - No `.bulk-select` checkboxes appear, and cards still open: clicking a card's inner `div[phx-click="view_task"]` (the card element itself has no handler) opens the task view.
  - **No flash** is shown.
  - The recorder holds one `feature_refused` event with `%{feature: :bulk_actions, surface: :live_view}`.

**C.3 The toggle closes it.** Click the toggle again.

- **Expect:** the locked bar disappears and the toggle shows "Select" again, with no flash.

**C.4 Crafted events are refused and leave tasks unchanged.**

```js
// browser_eval: push a crafted bulk_archive event from the page
const root = document.querySelector('[data-phx-main]');
window.liveSocket.main.pushEvent('click', root, null, 'bulk_archive', {});
```

- **Expect:**
  - A flash reads "Bulk actions are available to organizations. Nothing was changed."
  - The locked bar opens.
  - No task is archived.

  If `liveSocket.main.pushEvent` is not available in this LiveView version, skip the browser part and rely on C.5. The automated suite covers crafted events.

**C.5 The context refuses any caller.**

```elixir
# project_eval
import Ecto.Query
g = :persistent_term.get(:g472)
user = Kanban.Repo.get!(Kanban.Accounts.User, g.user_id)
scope = Kanban.Accounts.Scope.for_user(user)
free = Kanban.Repo.get!(Kanban.Boards.Board, g.free.board_id)

{
  Kanban.Tasks.bulk_archive_tasks(scope, free, g.free.bulk_ids),
  Kanban.Tasks.bulk_move_tasks(scope, free, g.free.bulk_ids, g.free.cols["Ready"]),
  Kanban.Repo.all(from t in Kanban.Tasks.Task, where: t.id in ^g.free.bulk_ids, select: {t.column_id, t.archived_at})
}
```

- **Expect:**
  - Both calls return `{:error, {:plan_required, :bulk_actions}}`.
  - Every task is unchanged: still in Backlog and not archived.
  - Two `feature_refused` events with `surface: :context` are recorded.

**C.6 Single-task actions stay free.** On `/boards/FREE`, click one "G472 free bulk" card's "Move to Ready" button, then archive another from its card menu.

- **Expect:** both succeed with no lock message.

**C.7 A paid board keeps bulk actions.** Open `/boards/PAID` and click Select.

- **Expect:** checkboxes and `#bulk-action-bar`. Select two "G472 paid bulk" cards and move them to Ready with the bar. The flash reads "Moved 2 tasks to Ready", and the tasks are in Ready.

**C.8 A board upgraded while the page is open unlocks on the next click.** With `/boards/FREE` open and the locked prompt open (click Select), run:

```elixir
# project_eval: move G472 Free into the Organization workspace
import Ecto.Query
g = :persistent_term.get(:g472)
Kanban.Repo.update_all(from(b in Kanban.Boards.Board, where: b.id == ^g.free.board_id), set: [workspace_id: g.workspace_id])
```

Click the toggle once. **Expect:** the prompt closes, and selection mode does not start.

Click it again. **Expect:** real selection mode, with checkboxes and `#bulk-action-bar`, without a reload.

Then move the board back and leave selection mode:

```elixir
# project_eval: move G472 Free back to the personal workspace
import Ecto.Query
g = :persistent_term.get(:g472)
Kanban.Repo.update_all(from(b in Kanban.Boards.Board, where: b.id == ^g.free.board_id), set: [workspace_id: g.personal_workspace_id])
```

**C.9 Dark mode.** Run A.6 on `#bulk-action-bar-locked` and on the pressed toggle.

## Section D: Integrations (W2408)

**D.1 Locked panel, endpoints paused.** Open `/boards/FREE/integrations`.

- **Expect:**
  - `#integrations-locked` is a `:panel` lock for `integrations`.
  - The endpoint `example.com` is listed in `#webhook-endpoints` with a `[data-endpoint-paused]` "Paused" badge.
  - The row offers only Deliveries and Delete. There is no edit, toggle, send-test or rotate control.
  - The endpoint form is absent.

**D.2 The context refuses writes but keeps the configuration.**

```elixir
# project_eval
alias Kanban.{Repo, Webhooks}
alias Kanban.Webhooks.Endpoint
g = :persistent_term.get(:g472)
user = Repo.get!(Kanban.Accounts.User, g.user_id)
scope = Kanban.Accounts.Scope.for_user(user)
free = Repo.get!(Kanban.Boards.Board, g.free.board_id)
endpoint = Repo.get!(Endpoint, g.free.endpoint_id)

%{
  create: Webhooks.create_endpoint(scope, free, %{"kind" => "generic", "url" => "https://example.com/g472-new", "event_types" => ["task.created"]}),
  update: Webhooks.update_endpoint(scope, endpoint, %{"event_types" => ["task.moved"]}),
  rotate: Webhooks.rotate_secret(scope, endpoint),
  send_test: Webhooks.send_test_event(scope, endpoint),
  listed: scope |> Webhooks.list_endpoints(free) |> Enum.map(& &1.id),
  still_enabled: Repo.get!(Endpoint, endpoint.id).enabled
}
```

- **Expect:**
  - `create`, `update`, `rotate` and `send_test` each return `{:error, {:plan_required, :integrations}}`.
  - `listed` still contains the endpoint.
  - `still_enabled` is `true`: the endpoint is paused, not disabled or deleted.

**D.3 Task events queue no delivery.** On `/boards/FREE`, click a card's "Move to Ready" button, which raises `task.moved` (both endpoints subscribe to it). Then:

```elixir
# project_eval
import Ecto.Query
g = :persistent_term.get(:g472)
Kanban.Repo.all(from j in Oban.Job, where: j.worker == "Kanban.Webhooks.DeliveryWorker" and fragment("(?->>'endpoint_id')::int", j.args) == ^g.free.endpoint_id, select: {j.id, j.state})
```

- **Expect:** `[]`, and the task write itself succeeded.

**D.4 A delivery queued before enforcement is dropped at perform time.**

```elixir
# project_eval
alias Kanban.Webhooks.{DeliveryWorker, Payload, Delivery}
import Ecto.Query
g = :persistent_term.get(:g472)
task = Kanban.Repo.get!(Kanban.Tasks.Task, g.free.ready_id)
{:ok, payload} = Payload.build("task.moved", task)
:ets.delete_all_objects(:g472_events)

{:ok, job} =
  %{"endpoint_id" => g.free.endpoint_id, "delivery_id" => "g472-dlv", "event" => "task.moved",
    "payload" => payload |> Jason.encode!() |> Jason.decode!()}
  |> DeliveryWorker.new()
  |> Oban.insert()

Process.sleep(3000)

{
  Kanban.Repo.get!(Oban.Job, job.id).state,
  Kanban.Repo.aggregate(from(d in Delivery, where: d.endpoint_id == ^g.free.endpoint_id), :count),
  :ets.tab2list(:g472_events)
}
```

- **Expect:**
  - The job state is `"completed"`.
  - The `Delivery` row count is `0`: there was no HTTP request and no log.
  - A `feature_refused` event with `%{feature: :integrations, surface: :oban}` is recorded.

**D.5 A paid board is unaffected.** Open `/boards/PAID/integrations`.

- **Expect:** the full form and the row controls, with no Paused badge.

Then click a card's "Move to Ready" button on `/boards/PAID`. Rerun the D.3 query with `g.paid.endpoint_id`: one DeliveryWorker job is expected. It fails as `:unresolvable` and retries without sending anything (see Step 1); that is expected here.

**D.6 Deliveries resume when the board is paid.** Move `G472 Free` into the Organization workspace (the first block in C.8). Reload `/boards/FREE/integrations`.

- **Expect:**
  - The lock and the Paused badge are gone, and the endpoint is editable.
  - Clicking a card's "Move to Ready" button now queues a DeliveryWorker job for `g.free.endpoint_id`.
  - Skipped deliveries are not replayed.

Move the board back (the second block in C.8).

**D.7 Dark mode.** Run A.6 on `#integrations-locked` and on the Paused badge.

## Section E: Telemetry task fields (W2409)

**E.1 Task form.** Open `/boards/FREE/tasks/<free.stored_id>/edit`.

- **Expect:** the Observability section shows `#task-telemetry-locked` with `[data-locked-feature="telemetry"]`, and has no Telemetry Event or Metrics to Track inputs.

Change only the title to "G472 free stored telemetry (edited)" and save. Then:

```elixir
# project_eval
g = :persistent_term.get(:g472)
Kanban.Repo.get!(Kanban.Tasks.Task, g.free.stored_id) |> Map.take([:title, :telemetry_event, :metrics_to_track])
```

- **Expect:** the title has changed, and both stored values are kept: saving did not wipe them.

**E.2 Task view.** Open the same task's view (click its card).

- **Expect:** the stored telemetry event and metrics are not shown. The logging requirement "G472 log line check" from Step 1 still shows under Observability.

**E.3 REST create, update and batch accept the fields but do not store them.**

```elixir
# project_eval
import Ecto.Query
g = :persistent_term.get(:g472)
tele = %{"telemetry_event" => "[:kanban, :g472, :rest]", "metrics_to_track" => "g472 rest count"}

api = fn token, method, path, body ->
  Req.request!(method: method, url: "http://localhost:4000" <> path, json: body,
    headers: [authorization: "Bearer #{token}"], retry: false)
end

stored? = fn id ->
  t = Kanban.Repo.get!(Kanban.Tasks.Task, id)
  {t.telemetry_event, t.metrics_to_track}
end

run = fn ctx ->
  create = api.(ctx.token, :post, "/api/tasks", %{"agent_name" => "G472 script", "task" => Map.merge(%{"title" => "G472 REST create", "type" => "work"}, tele)})
  plain = api.(ctx.token, :post, "/api/tasks", %{"agent_name" => "G472 script", "task" => %{"title" => "G472 REST plain", "type" => "work"}})
  update = api.(ctx.token, :patch, "/api/tasks/#{ctx.ready_id}", %{"task" => tele})
  batch = api.(ctx.token, :post, "/api/tasks/batch", %{"agent_name" => "G472 script", "goals" => [%{"title" => "G472 REST goal", "type" => "goal", "tasks" => [Map.merge(%{"title" => "G472 REST child", "type" => "work"}, tele)]}]})

  # The batch response has no "data" key (it returns goals, success, total
  # and warnings), so read the child's stored fields from the database.
  child =
    Kanban.Repo.one!(
      from t in Kanban.Tasks.Task,
        join: c in assoc(t, :column),
        where: c.board_id == ^ctx.board_id and t.title == "G472 REST child",
        select: {t.telemetry_event, t.metrics_to_track}
    )

  %{
    create: {create.status, create.body["warnings"], stored?.(create.body["data"]["id"])},
    plain_has_warnings_key: Map.has_key?(plain.body, "warnings"),
    update: {update.status, update.body["warnings"], stored?.(ctx.ready_id)},
    batch: {batch.status, batch.body["warnings"], child}
  }
end

%{free: run.(g.free), paid: run.(g.paid)}
```

- **Expect for `free`:**
  - `create` is 201 with a one-item `warnings` list saying the fields need an Organization, and `stored?` is `{nil, nil}`.
  - `update` is 200 with the same warning, and the Ready task's fields are still `nil`.
  - `batch` is 201 with the warning, and the child's fields are `{nil, nil}`.
  - `plain_has_warnings_key` is `false`: requests without the fields get no `warnings` key.
  - `feature_refused` events with `surface: :rest` are recorded.
- **Expect for `paid`:** the same statuses, `warnings` is `nil`, and the fields are stored on the created task, the Ready task and the batch child.

**E.4 Completion is unaffected.** Section G covers this: completion never casts these fields.

## Section F: MCP (W2410)

```elixir
# project_eval
g = :persistent_term.get(:g472)

mcp = fn token, body ->
  r = Req.post!("http://localhost:4000/api/mcp", json: body, retry: false,
    headers: [authorization: "Bearer #{token}", accept: "application/json, text/event-stream"])
  {r.status, r.body}
end

req = fn method, id, params -> %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params} end
task = Kanban.Repo.get!(Kanban.Tasks.Task, g.free.ready_id)

claim = req.("tools/call", 7, %{"name" => "stride_claim_task", "arguments" => %{
  "identifier" => task.identifier, "agent_name" => "G472 script",
  "before_doing_result" => %{"exit_code" => 0, "output" => "ok", "duration_ms" => 1}}})

%{
  initialize: mcp.(g.free.token, req.("initialize", 1, %{})),
  tools_list: mcp.(g.free.token, req.("tools/list", 2, %{})),
  claim: mcp.(g.free.token, claim),
  task_status_after_claim: Kanban.Repo.get!(Kanban.Tasks.Task, task.id).status,
  batch: mcp.(g.free.token, [req.("ping", "a", %{}), %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, req.("ping", "b", %{})]),
  notification_only: mcp.(g.free.token, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}),
  rest_same_token: Req.get!("http://localhost:4000/api/tasks/#{task.id}", headers: [authorization: "Bearer #{g.free.token}"], retry: false).status,
  paid_initialize: g.paid.token |> mcp.(req.("initialize", 1, %{})) |> then(fn {s, b} -> {s, Map.has_key?(b, "result")} end)
}
```

- **Expect:**
  - `initialize`, `tools_list` and `claim` each return status 200 with this body (with their own `id`):

    ```json
    {"jsonrpc": "2.0", "id": …, "error": {"code": -32001, "message": "MCP is available to boards in an Organization. The REST API keeps working for this board.", "data": {"feature": "mcp"}}}
    ```

  - The error never echoes the method or tool name.
  - `task_status_after_claim` is `:open`: no tool ran.
  - `batch` returns two errors, one each for ids `"a"` and `"b"`, and nothing for the notification.
  - `notification_only` returns `{202, ""}`.
  - `rest_same_token` is 200.
  - `paid_initialize` is `{200, true}`.
  - The recorder holds `feature_refused` events with `surface: :mcp`, and `[:kanban, :mcp, :request, :stop]` events with `outcome: :plan_required`.

Then check the transport rules. This runs inside the app so the token never appears on a command line:

```elixir
# project_eval
g = :persistent_term.get(:g472)
get = Req.get!("http://localhost:4000/api/mcp", headers: [authorization: "Bearer #{g.free.token}"], retry: false)
post = Req.post!("http://localhost:4000/api/mcp", json: %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}, retry: false)
{get.status, Req.Response.get_header(get, "allow"), post.status}
```

**Expect:** `405` with `allow: POST` for the GET, and `401` for the unauthenticated POST, which is refused before any plan check.

## Section G: Paths that stay free

**G.1 REST claim and complete on a free board.**

```elixir
# project_eval
g = :persistent_term.get(:g472)
hook = %{"exit_code" => 0, "output" => "ok", "duration_ms" => 1}
h = [authorization: "Bearer #{g.free.token}"]

claim = Req.post!("http://localhost:4000/api/tasks/claim", json: %{"agent_name" => "G472 script", "before_doing_result" => hook}, headers: h, retry: false)
id = claim.body["data"]["id"]

complete = Req.patch!("http://localhost:4000/api/tasks/#{id}/complete", headers: h, retry: false, json: %{
  "agent_name" => "G472 script", "completion_summary" => "G472 check", "actual_complexity" => "small",
  "actual_files_changed" => "1", "time_spent_minutes" => 1, "after_doing_result" => hook, "before_review_result" => hook})

{claim.status, claim.body["data"]["title"], complete.status}
```

- **Expect:** `{200, "G472 free ready task", 200}` (the claim may pick another Ready task on the free board; any of them is fine). If `complete` returns 422 for missing review fields, the dev config has strict completion validation on. That is unrelated to plans, so release the claim with `POST /api/tasks/<id>/unclaim` and count only the claim.

**G.2 The org audit export is gated by org-admin membership, not by the plan.** In the browser, open `/org/audit/export`.

- **Expect:** a redirect to `/boards`, because the user is not an org-admin. This happens with enforcement on or off.

**G.3 Board metrics and the REST API stay open.** Open `/boards/FREE` and its metrics pages.

- **Expect:** they render normally. Section F already showed REST working with the free token.

## Section H: Enforcement off again restores everything

```elixir
# project_eval
Application.put_env(:kanban, :plans_enforced, false)
Kanban.Plans.enforced?()
```

Reload, then check:

- The bell is unlocked.
- On `/boards/FREE`, Select enters real selection mode.
- `/boards/FREE/integrations` shows no lock or Paused badge.
- The free task form shows the telemetry inputs again, with the stored values from E.1 intact.
- Rerunning the Step 2 MCP block returns `result`.

**Expect:** everything works as in Step 2, and nothing was deleted while locked.

---

## Teardown (always run)

```elixir
# project_eval
import Ecto.Query
alias Kanban.Repo
Application.put_env(:kanban, :plans_enforced, false)
:telemetry.detach("g472-recorder")

g = :persistent_term.get(:g472, nil)

if g do
  user = Repo.get!(Kanban.Accounts.User, g.user_id)
  Repo.delete_all(from(m in Kanban.Organizations.OrganizationMember, where: m.user_id == ^g.user_id))
  Repo.delete_all(from(n in Kanban.Notifications.Notification, where: like(n.title, "G472%")))

  # Deliveries to example.com fail DNS and retry; stop them before the
  # endpoints go.
  endpoint_ids = [g.free.endpoint_id, g.paid.endpoint_id]

  Oban.Job
  |> where([j], j.worker == "Kanban.Webhooks.DeliveryWorker")
  |> where([j], j.state in ["available", "scheduled", "retryable", "executing"])
  |> where([j], fragment("(?->>'endpoint_id')::int", j.args) in ^endpoint_ids)
  |> Oban.cancel_all_jobs()

  # Put back the review_requested email setting B.3 changed.
  if Map.has_key?(g, :saved_review_pref) do
    pref = Repo.get_by(Kanban.Notifications.Preference, user_id: g.user_id, event_type: :review_requested)

    case {g.saved_review_pref, pref} do
      {_, nil} -> :ok
      {nil, pref} -> Repo.delete!(pref)
      {saved, pref} -> pref |> Ecto.Changeset.change(saved) |> Repo.update!()
    end
  end

  Enum.each([g.free.board_id, g.paid.board_id], fn id ->
    case Repo.get(Kanban.Boards.Board, id) do
      nil -> :ok
      board -> Kanban.Boards.delete_board(board, user)
    end
  end)

  Repo.delete_all(from(w in Kanban.Workspaces.Workspace, where: w.id == ^g.workspace_id))
  :persistent_term.erase(:g472)
end

case :ets.info(:g472_events, :owner) do
  pid when is_pid(pid) -> Process.exit(pid, :kill)
  _ -> :ok
end

user_id = Repo.get_by!(Kanban.Accounts.User, email: "cheezy@letstango.ca").id

%{
  enforced: Kanban.Plans.enforced?(),
  boards_left: Repo.aggregate(from(b in Kanban.Boards.Board, where: like(b.name, "G472%")), :count),
  review_requested:
    Repo.one(
      from p in Kanban.Notifications.Preference,
        where: p.user_id == ^user_id and p.event_type == :review_requested,
        select: {p.email, p.in_app}
    )
}
```

**Expect:** `enforced: false`, `boards_left: 0`, and `review_requested` back to what it was before B.3 (`nil` if there was no row). If `delete_board` refuses, delete the two boards from the board settings page in the browser. Reset the browser theme to the one you started with.

## Report

Finish with a table that has one row per check (Step 2, A.0 to H), each marked PASS, FAIL or SKIPPED, with the observed value for every FAIL and a note on any environment problem, such as the restart in A.2. List the failing checks first.
