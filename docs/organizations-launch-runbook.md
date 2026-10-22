# Organizations launch runbook

This runbook takes Stride from "every goal merged with plans off" to "plans
enforced", in order, and back again if needed. It is the operator's copy of
the launch plan in
[Paying Organizations design § 12](plans/PAYING-ORGANIZATIONS-DESIGN.md#12-launch-plan)
(decision D12). Run the steps in the order written: the internal Organization
and the board move come before the flag, so Stride's own boards never lose a
feature.

Nothing here needs a secret written into a command. Every command names a
function, a page or an environment variable only. Where an email address is
needed, use a real account's address at run time; the `example.com` addresses
below are placeholders.

## Before you start

- **Who runs it.** A site admin with shell access to the production release.
  The `/admin` pages need a site admin account; the board move needs that
  person to be an org-admin of the internal Organization too (see
  [Launch day](#launch-day)).
- **How release functions run.** The `Kanban.Release` functions below run in
  the production release with `bin/kanban eval`, the same way as the audit
  log steps in [Audit log database roles](audit-log-database-roles.md), except
  `send_launch_announcement/1`, which is best run with `bin/kanban rpc` (see
  step 5 of [Before launch](#before-launch)). Pipe the result to
  `IO.inspect/1` so it is printed:

  ```bash
  /app/bin/kanban eval 'Kanban.Release.report_over_cap_boards() |> IO.inspect()'
  ```

- **What the flag does.** `STRIDE_PLANS_ENFORCED` is read by
  `config/runtime.exs` at boot. Only the exact string `true` turns
  enforcement on; any other value, or no value, leaves it off. Because it is
  read at boot, a change takes effect only after a restart.
  `Kanban.Plans.enforced?/0` is the only reader, and every lock and the member
  cap go through `Kanban.Plans`.

## Before launch

1. **Report the boards over the member cap.** Free boards hold 3 people (AI
   agents do not count). Boards already over that are grandfathered: they keep
   every member and refuse additions until they are under 3.

   ```bash
   /app/bin/kanban eval 'Kanban.Release.report_over_cap_boards() |> IO.inspect(limit: :infinity)'
   ```

   It is read-only and returns one map per board with `:board_id`,
   `:owner_user_id` (or `nil`) and `:member_count`, or `[]`. It prints no
   names or emails. Look up each owner in `/admin/users` and contact them
   before launch: their board keeps its members, but cannot add anyone, and
   moving it into an Organization lifts the cap.

2. **Check the public pages.** `/pricing`, `/terms` and `/privacy` carry the
   Free and Organization plan wording (W2412 to W2414). Confirm they are what
   production serves; if they are not deployed yet, deploy them now or on
   launch day (step 1 of [Launch day](#launch-day)).

3. **Set the launch date and publish the changelog entry.** The
   "Announcing Organizations and the Free plan" entry on `/changelog` (W2415)
   says "Launch date: to be announced on this page." Replace that sentence
   with the agreed date in
   `lib/kanban_web/controllers/page_html/changelog.html.heex`, update its
   translations, and deploy. The launch email links to this page.

4. **Post the broadcast message.** In `/admin/messages`, create a message.
   The form has a title and a body only; the message shows to every signed-in
   user until they dismiss it. Draft:

   ```text
   Title: Organizations are coming to Stride

   Body: Stride is adding a paid Organization plan. Stride stays free for
   individuals and small teams. On launch day, free boards hold up to 3 people
   (AI agents do not count; existing boards keep every member they have), and
   Notifications, Bulk actions, Integrations (webhooks), Task telemetry fields
   and MCP access become Organization-only. Webhooks on free boards are paused,
   not deleted. Unlimited boards, tasks and goals, the full REST API and
   client-side hooks, and metrics and exports stay free. If you review tasks on
   a free board, use the Review queue and My Work instead of notification
   emails. The launch date and details are on the changelog. To move your team
   into an organization, contact us from the Pricing page.
   ```

   Edit the date sentence into the body once the date is set.

5. **Send the launch announcement email.** Run it with `bin/kanban rpc`, inside
   the running app, so its `fanout_completed` telemetry is stored. It also
   runs under `bin/kanban eval`, but then the printed counts are the only
   record. Run a dry run first. It counts the recipients and enqueues nothing:

   ```bash
   /app/bin/kanban rpc 'Kanban.Release.send_launch_announcement(key: "organizations-launch", dry_run: true) |> IO.inspect()'
   ```

   It returns `{:ok, %{announcement: "organizations-launch", dry_run: true,
   recipients: n, enqueued: 0, already_enqueued: 0, unconfirmed: 0}}`. Type
   `dry_run: true` exactly: a misspelled option, or a value other than `true`
   or `false`, raises an `ArgumentError` and sends nothing. Check that
   `recipients` is close to the number of confirmed, enabled users. A dry run
   always reports `already_enqueued: 0`, so it cannot tell you whether a real
   run already happened; check your own record of the send before running it
   for real:

   ```bash
   /app/bin/kanban rpc 'Kanban.Release.send_launch_announcement(key: "organizations-launch") |> IO.inspect()'
   ```

   - It enqueues one job per confirmed, enabled user on the `:notifications`
     queue, whatever their notification preferences or plan, because it is a
     service notice. The running app sends them.
   - Jobs are unique per user and announcement, so a second run within seven
     days enqueues 0 and reports the rest as `already_enqueued`. That includes
     jobs that were cancelled or discarded: to stop a bad send, cancel its
     jobs, and running it again will not re-send to those users. To send one
     a discarded job again, retry that job in Oban. The Oban Pruner removes
     finished jobs after seven days; **do not run it again after that**, or
     everyone gets the email twice.
   - `unconfirmed` counts users whose job another run was inserting at the
     same moment. It is 0 unless two runs overlapped; if it is not, run it
     again to cover them.
   - A job left in `executing` by a node that was killed mid-send is not sent
     again: there is no Oban Lifeline plugin to rescue it, and a re-run counts
     that user as covered. Avoid deploying while the send is running.
   - Keep the printed counts as the record of the run.
   - `{:error, :unknown_announcement}` means the key is misspelled.

## Launch day

1. **Deploy the rewritten pages,** if step 2 of
   [Before launch](#before-launch) found them missing.

2. **Create the internal Organization.** Stride's own boards run inside an
   internal Organization from launch day.

   ```bash
   /app/bin/kanban eval 'Kanban.Release.ensure_internal_organization(acting_admin_email: "admin@example.com", contact_name: "Ops", contact_email: "ops@example.com", org_admin_emails: ["lead@example.com"]) |> IO.inspect()'
   ```

   - `acting_admin_email` is required and must be an enabled site admin.
     `name` defaults to `"Stride"`. `contact_name` and `contact_email` are
     required only on the run that creates the Organization; address fields
     are optional. `org_admin_emails` is a list, or one comma-separated
     string.
   - Success is `%{status: :ok, organization: %{id: ..., name: ...,
     created: true}, ...}`, with every listed email sorted into `appointed`,
     `already_org_admin`, `skipped_unknown` (no account; none is created) or
     `refused` (with a reason).
   - It is idempotent and provisions no accounts. A repeat run returns
     `created: false` and must list at least the same org-admin emails as the
     first.
   - Check that `appointed` (or `already_org_admin`) is not empty before the
     board move. A first run that appointed nobody leaves an Organization with
     no org-admin, and every later run is refused with `:name_taken`; appoint
     an org-admin in `/admin/organizations` instead of running it again.
   - `%{status: :refused, reason: ...}` writes nothing. The reasons are
     `:unknown_acting_user`, `:not_site_admin`, `:invalid_org_admin_emails`,
     `:invalid_organization` (with `errors`) and `:name_taken`, which means an
     Organization of that name exists that staff do not run. Never work around
     `:name_taken` by taking that Organization over; choose another `name`.

3. **Move Stride's own boards into it.** This is the board move from G442
   (W2218, `Kanban.Workspaces.move_board_to_workspace/3`).
   - In `/org`, on the Workspaces tab, create the internal Organization's
     workspace.
   - Every user on a board must already be a member of the internal
     Organization, or the move is refused and names them. Invite them to the
     workspace first (Invitations in `/workspace/settings`), or remove them
     from the board.
   - The person moving a board must be an org-admin of the internal
     Organization **and** the board's owner, with the board in their personal
     workspace.
   - Switch to the new workspace, open `/workspace/settings`, and use
     **Move here** under "Move a board here" for each board.
   - A move revokes the board's open board-only invitations and disables
     webhook endpoints created by people outside the Organization. It is
     one-way: rollback does not move a board back.

   Do not set the flag until every Stride board you rely on has moved. A board
   that is still personal locks like any other free board once the flag is
   on.

4. **Turn enforcement on.** Set `STRIDE_PLANS_ENFORCED=true` in the
   deployment environment and restart the app. The flag takes effect only
   after the restart.

5. **Run the verification checklist.**

   | Check | Expected |
   |---|---|
   | A free board | Shows the Organization-only features as locked, and refuses a fourth member |
   | A paid board (one of the moved Stride boards) | Works as before, with nothing locked |
   | MCP with a free board's API token | Refused with "MCP is available to boards in an Organization. The REST API keeps working for this board." |
   | REST claim and complete on a free board | Still work |
   | Account emails for a free user, such as a password reset | Still sent. Notification emails to free users are skipped; account emails are not |

   If any check fails, roll back (below) before investigating.

## Rollback

Unset `STRIDE_PLANS_ENFORCED` (or set it to anything other than `true`) and
restart the app. Every lock and the member cap switch off at once.

**No data needs restoring,** because locks never delete data: webhook
endpoints keep their configuration, hidden notification rows reappear, and
grandfathered boards kept every member. Rollback cannot bring back:

- notifications that were never generated, or were dropped at send time,
  while locked;
- webhook deliveries skipped while paused (they are not replayed);
- telemetry fields that free agents sent and Stride did not store.

Organizations, memberships and moved boards stay as they are; they are valid
with or without enforcement. To launch again, set the flag and restart.

## Weekly locked-feature clicks

The leading launch metric is weekly locked-feature clicks per feature. Each
click on a locked feature's prompt stores one `metrics_events` row named
`kanban.plan.locked_feature_clicked.count`, with the feature in
`metadata->>'feature'` (see
[Plan events](telemetry.md#plan-events)). A user is counted at most once per
feature in any 7 days, so a weekly count is close to the number of distinct
users who asked for that feature.

No lock prompt is shown while enforcement is off, but the click route does not
check the flag: a signed-in user who opens `/locked/<feature>` directly before
launch still records a row. Count from the moment the flag was turned on by
adding `AND recorded_at >= '<launch time>'` to the query.

```sql
SELECT date_trunc('week', recorded_at) AS week,
       metadata->>'feature' AS feature,
       count(*) AS clicks
FROM metrics_events
WHERE metric_name = 'kanban.plan.locked_feature_clicked.count'
GROUP BY 1, 2
ORDER BY 1, 2;
```

- Run it read-only against the production database.
- `metrics_events` rows are deleted after 90 days by the daily retention job
  (see [Metrics retention](telemetry.md#metrics-retention)). To compare
  weeks across the 6 months after launch, save each week's counts, or raise
  `retention_days`, before the first rows age out.
