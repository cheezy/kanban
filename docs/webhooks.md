# Webhooks and Slack

Stride can tell other systems when something happens to a task on a board. A
board owner adds **endpoints** on the board's **Integrations** tab, and each
endpoint gets the task events it subscribes to:

- A **generic webhook** endpoint receives a signed JSON `POST` at an HTTPS address you
  run, so you can feed Stride events into your own tools.
- A **Slack** endpoint receives a short message in a Slack channel, through a
  Slack incoming webhook.
- A **Discord** endpoint receives a short message in a Discord channel,
  through a Discord channel webhook.

Only the board's owner can see the Integrations tab or manage its endpoints.
Members, including those with modify access, cannot.

## Events

An endpoint receives only the events ticked when it was added. At least one
must be ticked.

| Event | Sent when |
|---|---|
| `task.created` | A task or goal is created on the board, from the board, the API or an agent. |
| `task.updated` | A task's fields or status change. |
| `task.moved` | A task moves to another column, including a task sent back to Doing, a goal moved to Done when its after_goal hook reports, and a goal promoted to Ready. |
| `task.claimed` | An agent claims a task. |
| `task.unclaimed` | A claim is released. |
| `task.completed` | A task is completed, by an agent or by an approval in the review queue. |
| `task.moved_to_review` | An agent completes a task, which moves it to the Review column. A task that does not need review then moves on to Done at once, so it also sends `task.completed`, and the two can arrive in either order. |
| `task.reviewed` | A reviewer approves a task or requests changes. |
| `task.deleted` | A task is deleted. |

Each change sends one event, and only after the change is saved. A bulk action
sends one event for each task it changed. These changes send nothing:

- a label being added to or removed from a task (labels are not in the payload);
- saving a task without changing any of its fields;
- the tasks below a deleted task moving up to close the gap (the deleted
  task's own `task.deleted` is sent);
- a task becoming unblocked when its last dependency is done;
- a goal moving automatically because one of its tasks moved (the task's own
  event is sent);
- tasks removed along with a deleted board or column.

Events are not guaranteed to arrive in the order they happened. Two events
sent close together, or an event that had to be retried, can reach you in
either order, so use each body's `occurred_at` to put them in order.

## Set up a Slack endpoint

### 1. Create the incoming webhook in Slack

1. Go to <https://api.slack.com/apps>, choose **Create New App**, then
   **From scratch**.
2. Name the app (for example "Stride"), pick your workspace and choose
   **Create App**.
3. Open **Incoming Webhooks** in the sidebar and turn on
   **Activate Incoming Webhooks**.
4. Choose **Add New Webhook to Workspace**, pick the channel the messages
   should go to and choose **Allow**. Your workspace may require an admin to
   approve the app first.
5. Copy the webhook URL. It looks like
   `https://hooks.slack.com/services/T…/B…/…`.

The URL is a credential: anyone who has it can post to that channel. Stride
stores it encrypted and never shows it again.

### 2. Add it to the board

1. Open the board and choose the **Integrations** tab, next to **Settings**.
2. Under **Add an endpoint**, set **Kind** to **Slack**.
3. Paste the webhook URL into **URL**. A Slack endpoint accepts only an
   `https://hooks.slack.com/` address.
4. Tick the events to send, then choose **Add endpoint**.

Slack messages are not signed, so a Slack endpoint has no signing secret and
no **Rotate secret** action.

### What the messages look like

Each message names the task's identifier and title, what happened to it, its
board and its column, with links to the task and the board in Stride. A test
message reads "Stride test message for board …" with a link to the board.

A title, board name or column name cannot ping the channel or become a
disguised link: a title such as `<!channel>` or
`<https://example.com|click here>` is shown as typed. Slack formatting is not
removed, so `*bold*` or `_italic_` in a title still shows as bold or italic,
and a web address in a title is shown as a link to that address. Titles
longer than 200 characters are shortened.

## Set up a Discord endpoint

### 1. Create the webhook in Discord

You need the **Manage Webhooks** permission on the Discord server.

1. In Discord, open **Server Settings**, then **Integrations**.
2. Choose **Webhooks**, then **New Webhook**.
3. Open the new webhook, give it a name (for example "Stride") and pick the
   channel the messages should go to.
4. Choose **Copy Webhook URL**. It looks like
   `https://discord.com/api/webhooks/123456789012345678/AbC-dEf_ghi`.

The URL is a credential: anyone who has it can post to that channel. Stride
stores it encrypted and never shows it again.

### 2. Add the Discord webhook to the board

1. Open the board and choose the **Integrations** tab, next to **Settings**.
2. Under **Add an endpoint**, set **Kind** to **Discord**.
3. Paste the webhook URL into **URL**. A Discord endpoint accepts only a
   Discord webhook address: an `https` URL on `discord.com`,
   `discordapp.com`, `ptb.discord.com` or `canary.discord.com` whose path is
   `/api/webhooks/<id>/<token>` (or `/api/v<n>/webhooks/<id>/<token>`). Any
   other Discord address is refused.
4. Tick the events to send, then choose **Add endpoint**.

Discord messages are not signed, so a Discord endpoint has no signing secret
and no **Rotate secret** action.

### What the Discord messages look like

Each message names the task's identifier and title, linked to the task in
Stride, and what happened to it, with the event, the column and the board,
linked to the board in Stride. A test message reads "Stride test message for
board …" with a link to the board.

Titles, board names and column names are shown as plain text. A title such as
`@everyone`, `<@123456789012345678>` or `[click here](https://example.com)`
cannot ping anyone in the channel or become a link, and Discord formatting in
it is shown as typed. Long titles and names are shortened.

## Set up a webhook endpoint

1. Open the board and choose the **Integrations** tab.
2. Under **Add an endpoint**, leave **Kind** as **Generic webhook**.
3. Enter your receiver's address in **URL**, tick the events to send and choose
   **Add endpoint**.
4. Copy the **signing secret** that appears. It starts with `whsec_` and is
   shown only this once. If you lose it, use **Rotate secret** to get a new one.

### The address

Stride refuses an address it could use to reach its own network:

- It must be `https`. Plain `http` is accepted only when Stride is not running
  in production, for local testing.
- It cannot carry a username or password, and an IP address must be written as
  four plain numbers.
- The host must resolve, and **every** address it resolves to must be a public
  one. Private, loopback, link-local (including the cloud metadata address),
  shared, documentation and multicast ranges are refused, for IPv4 and IPv6.

The address is checked when the endpoint is saved and again before every
delivery, because DNS can change. Stride connects only to the addresses that
passed the check.

### The request

Every delivery is a `POST` with a JSON body and these headers:

| Header | Value |
|---|---|
| `Content-Type` | `application/json` |
| `User-Agent` | `Stride-Webhooks/1` |
| `X-Stride-Event` | The event name, such as `task.moved`, or `ping` for a test. |
| `X-Stride-Delivery` | A UUID for this delivery. It stays the same on every retry, so use it to ignore duplicates. |
| `X-Stride-Signature` | `t=<unix seconds>,v1=<hex HMAC-SHA256>`. See [Verify the signature](#verify-the-signature). |

The body:

```json
{
  "id": "evt_3f2c0e5a-8a51-4a3e-9d0e-1f7b2c9d4e61",
  "version": 1,
  "event": "task.moved",
  "occurred_at": "2026-10-13T17:10:20Z",
  "board": {"id": 1, "name": "Platform", "url": "https://www.stridelikeaboss.com/boards/1"},
  "task": {
    "id": 5,
    "identifier": "W12",
    "title": "Add pagination to the task list",
    "type": "work",
    "status": "in_progress",
    "priority": "medium",
    "complexity": "small",
    "needs_review": false,
    "review_status": null,
    "parent_id": null,
    "assigned_to_id": null,
    "created_by_agent": null,
    "completed_by_agent": null,
    "claimed_at": "2026-10-13T17:02:11Z",
    "completed_at": null,
    "reviewed_at": null,
    "inserted_at": "2026-10-12T09:30:00Z",
    "updated_at": "2026-10-13T17:10:20Z",
    "column": {"id": 3, "name": "Doing"},
    "url": "https://www.stridelikeaboss.com/boards/1/tasks/5/edit"
  }
}
```

The task carries only the fields shown. Its description, notes, review notes,
changed files and other working detail are never sent. A `ping` has
`"event": "ping"` and `"task": null`. The body describes the task as it was
when the event happened, and a retry sends exactly the same body.

To keep track of a task, use `task.id`, which is never reused. Its
`identifier` can be: a new task gets the next number after the highest one
on the board, so when the task holding the highest number is deleted, the
next task created is given the same identifier.

### Verify the signature

The signature is an HMAC-SHA256, keyed with the endpoint's signing secret, over
the timestamp, a `.`, and the raw request body. To check a delivery:

1. Split `X-Stride-Signature` on `,` and take the `t=` value and every `v1=`
   value.
2. Refuse the request if `t` is more than five minutes from your clock. This
   stops an old delivery from being replayed.
3. Compute the HMAC of `"<t>.<raw body>"` with the secret, as lowercase hex.
4. Accept the request if it equals any `v1` value, using a constant-time
   comparison.

Sign the **raw** body bytes as received. Parsing the JSON and encoding it again
can change the bytes and break the match.

Python:

```python
import hashlib
import hmac
import time


def verify(header: str, body: bytes, secret: str, tolerance: int = 300) -> bool:
    parts = [part.split("=", 1) for part in header.split(",") if "=" in part]
    timestamps = [value for key, value in parts if key == "t"]
    signatures = [value for key, value in parts if key == "v1"]
    if len(timestamps) != 1 or not timestamps[0].isdigit() or not signatures:
        return False
    timestamp = timestamps[0]
    if abs(time.time() - int(timestamp)) > tolerance:
        return False
    expected = hmac.new(
        secret.encode(), timestamp.encode() + b"." + body, hashlib.sha256
    ).hexdigest()
    return any(hmac.compare_digest(expected, signature) for signature in signatures)
```

Node.js:

```javascript
const crypto = require("crypto");

function verify(header, rawBody, secret, tolerance = 300) {
  const parts = header.split(",").map((part) => part.split("=", 2));
  const timestamps = parts.filter(([key]) => key === "t").map(([, value]) => value);
  const signatures = parts.filter(([key]) => key === "v1").map(([, value]) => value);
  if (timestamps.length !== 1 || !/^\d+$/.test(timestamps[0]) || signatures.length === 0) {
    return false;
  }
  const timestamp = timestamps[0];
  if (Math.abs(Date.now() / 1000 - Number(timestamp)) > tolerance) return false;
  const expected = crypto
    .createHmac("sha256", secret)
    .update(`${timestamp}.`)
    .update(rawBody)
    .digest("hex");
  return signatures.some(
    (signature) =>
      signature.length === expected.length &&
      crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected))
  );
}
```

Choosing **Rotate secret** replaces the secret at once: the old one stops
working immediately, so update your receiver as soon as you rotate.

### Responding

- Answer with any `2xx` status to accept the delivery. Anything else, including
  a redirect, counts as a failure. Redirects are never followed.
- A `4xx` refuses the delivery for good: Stride records it and does not try
  again. The exceptions are `408` and `429`, which mean "not now" and are
  retried. Answer `5xx` (or `429`) for a problem that will pass.
- Answer within 10 seconds. Stride also gives up if it cannot connect within 5
  seconds.
- Up to 64 KB of your response body is kept in the delivery log, so do not
  echo secrets back in it.

## Test, pause and remove an endpoint

Each endpoint on the Integrations tab has these actions:

- **Edit** changes which events the endpoint gets and, if you want, its
  address. Leave the URL blank to keep the current one; the form shows only
  its host. A new URL gets the same checks as a new endpoint.
- **Send test** sends a `ping`, so you can check the receiver or the Slack or
  Discord channel before real events arrive.
- **Deliveries** shows the 20 most recent attempts, newest first, each with its
  event, status, attempt number, response code, error and time.
- **Disable** stops sending without losing the endpoint; **Enable** resumes. A
  disabled endpoint cannot send a test, and deliveries queued while it is
  disabled are dropped, not held back.
- **Rotate secret** (webhooks only) replaces the signing secret.
- **Delete** removes the endpoint and its delivery log.

Editing an endpoint keeps its delivery log and, for a webhook, its signing
secret, so a receiver at the new address must verify with the same secret. If
the new address belongs to a different receiver, use **Rotate secret** to
replace it. Deliveries already queued or waiting to be retried go to the new
address. An endpoint's kind cannot be changed: to switch between a webhook,
Slack and Discord, delete the endpoint and add a new one.

Integrations are part of the paid plans. When paid plans are enforced and a
board is not in an Organization's workspace, its endpoints are **paused**:
the Integrations tab shows them with a Paused badge and offers only
**Deliveries** and **Delete**, no new endpoint can be added, and no events
are sent. Deliveries already queued or waiting to be retried are dropped, not
held back. Pausing does not disable or delete anything, so when the board
moves into an Organization's workspace each endpoint resumes with the next
event, exactly as it was set up. An endpoint you disabled stays disabled.

## When the person who added an endpoint leaves

An endpoint sends the board's events to an address chosen by whoever added
it. When that person can no longer open the board, Stride disables the
endpoints they added there, so the board's events stop reaching them:

- when they are removed from the board, or from the workspace that holds it,
  unless they still reach it as an org-admin;
- when they leave the Organization that holds the board;
- when their account is deleted;
- when the board moves into an Organization they are not a member of. This
  happens after its ownership has been handed over.

Handing a board to a new owner does not disable anything: the old owner keeps
modify access, so they can still open the board. The disabled endpoint shows
as **Disabled** on the Integrations tab. If you trust its address, choose
**Enable**. That makes you the person who added it, so it is disabled again
only when you lose access.

## Retries

A delivery that fails with a `5xx`, `408`, `429`, a redirect, a timeout or a
connection error is tried again, up to 8 attempts in all, after about 30
seconds, then 1, 2, 4, 8, 16 and 32 minutes. Each wait is stretched by up to a
fifth at random, so the last attempt comes roughly an hour after the first.
Each attempt adds an entry to the delivery log, and every retry carries the
same `X-Stride-Delivery` id and body.

Any other `4xx` stops the delivery after that attempt. For a Slack endpoint
this is what a removed webhook or an archived channel returns (`403`, `404`
or `410`), and for a Discord endpoint it is what a deleted webhook returns
(`404`, or `401` when its token no longer matches), so a broken endpoint
shows one failed entry per event rather than eight. The endpoint stays
enabled; delete it, or edit it with a new webhook URL. An address that is
refused when the delivery is attempted, such as a host that now resolves to a
private address, also fails at once with no retry. A host that does not
resolve at all is retried, because that is often a passing DNS problem.
