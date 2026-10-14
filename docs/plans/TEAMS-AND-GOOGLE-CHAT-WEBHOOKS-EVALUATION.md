# Microsoft Teams and Google Chat webhooks: evaluation

Status: research only (W2370). No code was changed and no tasks were created.
Vendor documentation was checked on 2026-10-14. The human reading this decides
what to build.

## Context

Stride's board webhooks already support two chat services, Slack and Discord,
in a "paste a URL" way: the board owner creates an incoming webhook in the chat
tool, copies its URL, and pastes it into the board's **Integrations** tab (see
[Set up a Slack endpoint](../webhooks.md#set-up-a-slack-endpoint) and
[Set up a Discord endpoint](../webhooks.md#set-up-a-discord-endpoint)).

That pattern relies on four properties of the chat service:

1. **A fixed host to pin the URL to.** Each chat kind accepts only its vendor's
   webhook address (`Endpoint.slack_url?/1` pins `hooks.slack.com`;
   `Endpoint.discord_url?/1` pins four Discord hosts and the
   `/api/webhooks/<id>/<token>` path, in `lib/kanban/webhooks/endpoint.ex`).
   `Kanban.Webhooks.UrlGuard` on its own only requires `https` and a public
   address, so it accepts any public host and port. Without a per-kind pin, a
   chat kind would be a general outbound-request path (SSRF).
2. **The secret is carried in the URL.** The pasted URL is the whole
   credential. Stride stores it encrypted (`EncryptedString`, `redact: true`),
   never shows it again, and never puts it in a delivery error.
3. **A simple JSON message format** that a small formatter can build, with a
   way to stop task titles and board names from pinging people or becoming
   links (the Discord formatter sets `allowed_mentions` and escapes markdown;
   see [What the Discord messages look like](../webhooks.md#what-the-discord-messages-look-like)).
4. **Clear permanent-failure responses.** The delivery worker treats any `2xx`
   (including `202`) as success, cancels on any `4xx` other than `408` and
   `429`, and retries everything else (`5xx`, `408`, `429`, redirects, timeouts,
   connection errors) up to 8 attempts with exponential backoff. It does not
   read `Retry-After` and never follows a redirect
   ([Retries](../webhooks.md#retries)). A deleted webhook therefore needs to
   answer with a `4xx` to be cancelled after one attempt rather than eight.

Other fixed constraints on any new kind: the URL is at most 2048 bytes, the
guard re-resolves the host and re-checks every address on every attempt
(anti-rebinding), requests time out after 10 seconds, and the query string is
sent as pasted.

## How each service was evaluated

Each service below answers the same questions, under the same headings, in the
same order:

1. Creation and admin approval: how an incoming webhook is created today, and by
   whom.
2. URL format: the exact shape, and which host families exist.
3. Host pinning: whether the host is fixed enough for a `discord_url?/1`-style
   allow-list, and the rule we would use.
4. Secret in the URL.
5. Payload format and how hard a formatter would be.
6. Injection risks (mentions, markup, links) and how to neutralise them.
7. Rate limits and the HTTP statuses for success, throttling and a deleted or
   revoked webhook, against our retry and cancel rules.
8. Deprecation or retirement status.
9. Fit with `UrlGuard`.
10. Estimated effort against the Discord tasks.
11. Recommendation: go, no-go or later.
12. Open questions.

**Sources.** Every vendor claim links to the vendor page it came from. All of
those pages were checked on 2026-10-14; the page's own "updated" date is listed
in [Sources](#sources). Pages from third parties are labelled as such and are
never the only support for a recommendation.

**Unstated facts.** Where the checked vendor pages do not say something, this
document says "not stated in the vendor docs checked" and lists it as an open
question (T-Q*n* for Teams, G-Q*n* for Google Chat). It does not fill the gap
from memory.

No test webhook was created for this evaluation, so no webhook URL or token was
produced, and none appears here. Every URL below is a placeholder.

## Summary

| | Microsoft Teams (Workflows) | Google Chat |
| --- | --- | --- |
| Host pinnable | Only by a Microsoft-owned wildcard suffix plus a strict path; label shape undocumented | Yes: one exact host, `chat.googleapis.com` |
| Secret in URL | Yes (SAS signature; "Anyone" trigger takes no other auth) | Yes (`token`, documented as secret) |
| Payload | Adaptive Card inside a `message` envelope, 28 KB | `text` (or cards), 32,000 bytes |
| Mentions from text | Only with explicit `msteams.entities` | `<users/all>` and `<users/{id}>` in text |
| Failure statuses documented | No | `429` only |
| Deprecation | Old connectors retired May 2026; Workflows URLs changed twice since 2025 | None found |
| Recommendation | **Later** | **Go**, with conditions |

## Microsoft Teams

### Creation and admin approval

Microsoft 365 (formerly Office 365) connectors, which provided the old Teams
"Incoming Webhook", are retired. Microsoft's final update says the rollout to
disable them ran from May 18 to May 22, 2026, and that "after these dates,
Office 365 Connectors will no longer function"
([Microsoft 365 Developer Blog, retirement of Office 365 connectors](https://devblogs.microsoft.com/microsoft365dev/retirement-of-office-365-connectors-within-microsoft-teams/),
checked 2026-10-14). A Stride Teams kind must therefore not accept connector
URLs.

The replacement is the **Workflows** app (Power Automate). A user opens
**Workflows** on a channel, picks a template such as "Send webhook alerts to a
channel", saves it, and copies the webhook link
([Create an Incoming Webhook, Microsoft Learn](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook),
checked 2026-10-14). Microsoft says the templates and the Teams webhook trigger
do not require a premium licence
([Create incoming webhooks with Workflows for Microsoft Teams, Microsoft Support](https://support.microsoft.com/en-us/office/create-incoming-webhooks-with-workflows-for-microsoft-teams-8ae491c7-0394-4861-ba59-055e33f75498),
checked 2026-10-14).

Points that matter for a paste-a-URL integration:

- **The workflow belongs to a person, not the channel.** "Workflows are linked
  only to specific users ... and not to a Teams team or channel", and become
  orphaned when the owner leaves unless co-owners were added
  ([Create an Incoming Webhook](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook),
  checked 2026-10-14). A board's Teams endpoint can stop working because a
  colleague left.
- **Only the "Anyone" trigger works with a pasted URL.** The "When a Teams
  webhook request is received" trigger can be called by "anyone, any user in
  the tenant, or only a specific subset of users". The two tenant options need
  an authentication token in every request, and a token header must not be
  sent with "Anyone"
  ([Microsoft Teams connector reference, Microsoft Learn](https://learn.microsoft.com/en-us/connectors/teams/),
  checked 2026-10-14). Stride sends no token, so only "Anyone" workflows can
  work. Which option each template uses is not stated (T-Q1).
- **Posting into private channels** through the connector "currently isn't
  supported" per the
  [connector reference](https://learn.microsoft.com/en-us/connectors/teams/)
  (checked 2026-10-14), while the
  [retirement blog](https://devblogs.microsoft.com/microsoft365dev/retirement-of-office-365-connectors-within-microsoft-teams/)
  (checked 2026-10-14) says private-channel selection in Workflows was to be
  rolled out by April 20, 2026. The two pages disagree (T-Q2).
- Whether a tenant admin can block or must approve Workflows webhooks is not
  stated in the vendor docs checked (T-Q3).

### URL format

The Teams pages do not show the Workflows URL format. The connector reference
shows only the placeholder `https://xxxxx.logic.azure.com:443/xxxxxxxxx`
([Microsoft Teams connector reference](https://learn.microsoft.com/en-us/connectors/teams/),
checked 2026-10-14).

Power Automate's troubleshooting page says that from November 30, 2025, flows
with HTTP or Teams webhook triggers "that have `logic.azure.com` in the URL move
to a new URL", that the old URLs then stop working, that the new URL "might be
longer than 255 characters", and that from June 2, 2026 the path also carries a
scale-unit segment ("`/direct/cu/20/workflows/...` instead of
`/direct/workflows/...`"), with the old shape still working
([Troubleshoot common problems with Power Automate triggers, Microsoft Learn](https://learn.microsoft.com/en-us/troubleshoot/power-platform/power-automate/flow-run-issues/triggers-troubleshoot),
checked 2026-10-14).

Microsoft's firewall guidance lists the domains for the HTTP request trigger as
`*.api.powerplatform.com` and `*.logic.azure.com`, with separate domains for
the US Government (`*.api.gov.powerplatform.microsoft.us`,
`*.api.high.powerplatform.microsoft.us`, `*.api.appsplatform.us`,
`*.logic.azure.us`) and 21Vianet China (`*.api.powerplatform.partner.microsoftonline.cn`,
`*.logic.azure.cn`) clouds
([IP address configuration, Power Automate, Microsoft Learn](https://learn.microsoft.com/en-us/power-automate/ip-address-configuration),
checked 2026-10-14).

A third-party write-up (not Microsoft documentation) shows only the start of
the new URL:
`https://ENVIRONMENT_ID.aa.environment.api.powerplatform.com:443/powerautomate/automations/direct/workflows/…`
([topedia blog, 20 October 2025](https://blog-en.topedia.com/2025/10/http-and-teams-webhook-trigger-urls-must-be-updated-in-power-automate-and-copilot-studio-agent-flows/),
checked 2026-10-14). The rest of the path, the workflow ID format and the
query parameters are not stated in any page checked. The full shape must be
confirmed against real URLs from a tenant before any pin is written (T-Q4).

So there are several host families: the retired `*.logic.azure.com` form, the
current `*.environment.api.powerplatform.com` form with or without `/cu/NN`,
and the sovereign-cloud forms.

### Host pinning

The host is not fixed: each Power Platform environment gets its own
subdomain. Pinning it is still possible if the rule is narrow. The proposed
`teams_url?/1`, for a first version, is a sketch whose path and query parts
are placeholders until T-Q4 is answered:

- `https`, default port 443, no userinfo (as for Slack and Discord).
- Host ends in `.environment.api.powerplatform.com`, matched on label
  boundaries, with a fixed number of labels in front of a fixed shape (the
  write-up suggests two: the environment ID and a short region label; T-Q4).
  Never accept the broader `*.api.powerplatform.com`: other Power Platform APIs
  live there.
- Path starts `/powerautomate/automations/direct/workflows/` or, from June
  2026, `/powerautomate/automations/direct/cu/NN/workflows/`, and the rest is
  matched by a strict, anchored pattern for the workflow ID and trigger
  segments once their real shape is known (T-Q4). A prefix match alone is not
  enough.
- Query carries the trigger's signature parameter, whose name is also to be
  confirmed (T-Q4).
- Refuse `*.logic.azure.com`: it is retired for Power Automate, and the same
  domain serves Azure Logic Apps, whose workflows can do anything.
- Refuse the sovereign-cloud hosts until someone asks for them (T-Q5).

**Is that enough to prevent SSRF?** Only if three things hold:

1. `UrlGuard` keeps refusing private and reserved addresses on every attempt,
   which it already does.
2. The `environment.api.powerplatform.com` zone is operated by Microsoft and
   its labels are assigned by Microsoft, not chosen by customers (unlike, say,
   `azurewebsites.net`). This is not stated in the vendor docs checked (T-Q6).
3. The path pin keeps requests on the webhook-trigger endpoint and off every
   other API on the same host.

With all three, what remains is "a board can post to any Workflows trigger
someone created", which is the same exposure a Slack kind has with any Slack
workspace. If Microsoft cannot confirm who assigns the labels, the honest
answer is that the host is not yet pinnable enough.

### Secret in the URL

Yes. With the "Anyone" option the trigger takes no authentication header
([Microsoft Teams connector reference](https://learn.microsoft.com/en-us/connectors/teams/),
checked 2026-10-14), so whoever holds the URL can post. Microsoft's
troubleshooting page refers to these trigger URLs carrying Shared Access
Signature (SAS) authentication
([Troubleshoot common problems with Power Automate triggers](https://learn.microsoft.com/en-us/troubleshoot/power-platform/power-automate/flow-run-issues/triggers-troubleshoot),
checked 2026-10-14), which is the secret part of the URL. Stride already
treats a pasted URL as a credential, so no new handling is needed. The new URL
"might be longer than 255 characters"; its maximum length is not stated in any
page checked, so it is expected, not known, to fit within our 2048-byte limit
(T-Q4).

### Payload format and formatter effort

The trigger expects `{"type": "message", "attachments": [...]}`, where each
attachment has `contentType` `application/vnd.microsoft.card.adaptive`,
`contentUrl` `null` and an Adaptive Card as `content`. It accepts POST only
([Microsoft Teams connector reference](https://learn.microsoft.com/en-us/connectors/teams/),
checked 2026-10-14). Workflows also render MessageCard payloads, but their
`HttpPost` buttons do not work, and webhook posts cannot set a custom bot name
or icon
([retirement blog, April 14, 2026 update](https://devblogs.microsoft.com/microsoft365dev/retirement-of-office-365-connectors-within-microsoft-teams/),
checked 2026-10-14). The message size limit is 28 KB
([Create an Incoming Webhook](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook),
checked 2026-10-14).

A `TeamsFormatter` would build one Adaptive Card per event (a `TextBlock` with
the task identifier and title linked to Stride, and a `FactSet` with event,
column and board), and fit the whole body under 28 KB on grapheme boundaries,
like the Discord formatter. The card shape is a little more involved than
Discord's embed, so the formatter is about one and a half times the
`DiscordFormatter` work. What the workflow actually posts also depends on how
the user's template handles the body, which we cannot see (T-Q7).

### Injection risks and neutralisation

- **Markdown.** Adaptive Card `TextBlock`, `Fact.Title` and `Fact.Value` render
  bold (`**x**`), italic (`_x_`), lists and links (`[title](url)`); HTML is not
  supported
  ([Format text in cards, Microsoft Learn](https://learn.microsoft.com/en-us/microsoftteams/platform/task-modules-and-cards/cards/cards-format),
  checked 2026-10-14). A task titled `[click here](https://example.com)` would
  become a link unless it is neutralised. Whether a backslash escape works in
  Teams' Markdown is not stated in the vendor docs checked (T-Q8). Until it is
  confirmed, the safe choice is to replace the Markdown characters in titles,
  board names and column names with plain look-alikes or strip them, and to
  build every link ourselves from Stride URLs (reusing the Discord formatter's
  `safe_url/1` check).
- **Mentions.** A mention in an Adaptive Card needs both `<at>name</at>` in the
  text and a matching `mention` entry in `msteams.entities` with the user's ID
  ([Format text in cards](https://learn.microsoft.com/en-us/microsoftteams/platform/task-modules-and-cards/cards/cards-format),
  checked 2026-10-14). As long as the formatter never writes `msteams.entities`,
  a title containing `<at>Someone</at>` should not ping anyone; that this holds
  for Workflows posts is not stated (T-Q8). A single message can mention at
  most 20 users and 20 tags
  ([Microsoft Teams connector reference](https://learn.microsoft.com/en-us/connectors/teams/),
  checked 2026-10-14).

### Rate limits and failure statuses

- More than four requests a second to an incoming webhook are throttled
  ([Create an Incoming Webhook](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook),
  checked 2026-10-14).
- The Teams connector allows 25 Flow-bot operations (such as "Post an Adaptive
  Card as Flow bot") per connection per 300 seconds
  ([Microsoft Teams connector reference](https://learn.microsoft.com/en-us/connectors/teams/),
  checked 2026-10-14). That is about one post every 12 seconds on average. A
  busy board moving many tasks would exceed it, and the throttling would happen
  inside the workflow, after Stride's request has already succeeded.
- **Success status.** The Teams pages do not document response codes. For the
  Azure Logic Apps Request trigger, a workflow with no Response action
  "immediately returns the **202 ACCEPTED** status"
  ([Receive and respond to inbound HTTPS calls, Azure Logic Apps](https://learn.microsoft.com/en-us/azure/connectors/connectors-native-reqres),
  checked 2026-10-14). If the Teams trigger behaves the same way, which is not
  stated (T-Q9), then a `202` only means "the run was queued". A post that later
  fails (throttled, orphaned owner, bad card) still looks like a success in our
  delivery log, and nothing retries it.
- **Deleted, disabled or orphaned workflow.** The status returned is not stated
  in the vendor docs checked (T-Q10). If it is a `4xx`, our worker cancels after
  one attempt, which is what we want. If it is a `5xx`, each event would be
  retried eight times for about an hour.
- `429` and `408` are retried with our own backoff, without reading
  `Retry-After`, which fits our current rules.

### Deprecation status

The Office 365 connector webhooks are gone (May 18-22, 2026, per the
[retirement blog](https://devblogs.microsoft.com/microsoft365dev/retirement-of-office-365-connectors-within-microsoft-teams/),
checked 2026-10-14). Their replacement has changed URL twice since 2025: the
move off `logic.azure.com` on November 30, 2025, and the `/cu/NN` path segment
from June 2, 2026
([Troubleshoot common problems with Power Automate triggers](https://learn.microsoft.com/en-us/troubleshoot/power-platform/power-automate/flow-run-issues/triggers-troubleshoot),
checked 2026-10-14). A host and path pin for Teams should be expected to need
updates when Microsoft changes the URL again.

### UrlGuard fit

Expected to fit: the URL is `https` on a Microsoft-operated domain, which
should resolve to public addresses, and is expected to be under 2048 bytes,
though its maximum length is not stated (T-Q4). The port in the URL is the
explicit default `:443`, which our default-port check must accept as 443 (the Slack and Discord pins already
compare the parsed port, so this should hold, but a test should cover it).

### Effort against Discord

Discord took four tasks after the per-kind lookup refactor (W2365): formatter
(W2366), kind with validation and delivery (W2367), Integrations tab (W2368)
and docs (W2369), with 22 to 26 minutes between one completion and the
next. Teams would need those four plus a first task done by a human in a
Microsoft 365 tenant: create an "Anyone" Workflows webhook, record the real URL shape (without keeping the
URL), the status codes for an accepted post, a deleted workflow and a disabled
one, delete the workflow, and answer T-Q1 to T-Q10. The formatter and the pin
are each somewhat larger than Discord's. Estimate: five tasks, about one and a
half times the Discord effort, plus the tenant time.

### Recommendation

**Later.** Teams is worth supporting, but today we cannot pin its host with
documented facts, cannot tell a delivered post from a queued one, and do not
know what a deleted workflow returns. Revisit when the tenant check above has
answered T-Q4, T-Q6, T-Q9 and T-Q10; if those come back as expected (Microsoft-
assigned labels, a stable path, a `4xx` for a removed workflow), it becomes a
go with the pin described above.

### Open questions

- T-Q1: Which Workflows webhook templates create an "Anyone" trigger, and can a
  user change it after creation?
- T-Q2: Can a Workflows webhook post to a private channel today? The connector
  reference and the retirement blog disagree.
- T-Q3: Can a tenant admin block or require approval for Workflows webhooks or
  "Anyone" triggers?
- T-Q4: The exact current URL shape: host labels, the `cu` segment, the
  workflow ID format, the required query parameters and the maximum length.
- T-Q5: Do we need the US Government and China clouds?
- T-Q6: Are the `environment.api.powerplatform.com` labels always assigned by
  Microsoft, so a suffix pin cannot reach a customer-controlled host?
- T-Q7: Does every webhook template post the received Adaptive Card unchanged?
- T-Q8: Does a backslash escape Markdown in a Teams Adaptive Card, and can
  `<at>` text without `msteams.entities` ever produce a mention in a Workflows
  post?
- T-Q9: Does the Teams webhook trigger answer `202` before the post is made?
- T-Q10: What status does the trigger return for a deleted, turned-off or
  orphaned workflow?

## Google Chat

### Creation and admin approval

An incoming webhook is created in a space from a browser at chat.google.com
(not the mobile app). It needs "a Business or Enterprise Google Workspace
account with access to Google Chat", and the organisation must allow users to
add and use incoming webhooks; if the **Add webhooks** option is missing, the
admin has not allowed it. A webhook works only in the space it was registered
in ([Send messages to Google Chat with incoming webhooks, Google for Developers](https://developers.google.com/workspace/chat/quickstart/webhooks),
checked 2026-10-14). The page does not cover personal Google accounts; since it
requires a Business or Enterprise Workspace account, personal (Gmail) accounts
should be assumed unable to create one (G-Q1).

### URL format

`https://chat.googleapis.com/v1/spaces/SPACE_ID/messages?key=KEY&token=TOKEN`.
The `key` value is shared between webhooks and the `token` is unique to each.
An optional `messageReplyOption` query parameter controls threading
([Send messages to Google Chat with incoming webhooks](https://developers.google.com/workspace/chat/quickstart/webhooks),
checked 2026-10-14). There is one host family.

### Host pinning

The host is fixed, so this is as strong as the Slack pin. The proposed
`google_chat_url?/1`:

- `https`, default port 443, no userinfo.
- Host exactly `chat.googleapis.com` (lower-cased, as for Slack).
- Path matches `\A/v1/spaces/[A-Za-z0-9_-]{1,128}/messages\z`. The space ID
  alphabet and length are not stated in the vendor docs checked (G-Q2), so the
  pattern needs confirming with real IDs. The path pin matters: other Chat API
  methods live on the same host.
- Query has `key` and `token`, and nothing outside `key`, `token` and
  `messageReplyOption`, the three query parameters the quickstart documents
  (the thread key travels in the body as `thread.threadKey`).

### Secret in the URL

Yes. Google says the token is "a unique value that must be kept secret" and
warns against sharing the webhook URL online
([Send messages to Google Chat with incoming webhooks](https://developers.google.com/workspace/chat/quickstart/webhooks),
checked 2026-10-14). Stride's existing handling (encrypted, never shown again,
never in errors) covers it.

### Payload format and formatter effort

The body is JSON with a `text` field. To post into a thread, the body includes
`thread.threadKey` (any string, reused to reply)
([Send messages to Google Chat with incoming webhooks](https://developers.google.com/workspace/chat/quickstart/webhooks),
checked 2026-10-14). Links in text are written `<url|text>`
([Format Google Chat messages](https://developers.google.com/workspace/chat/format-messages),
checked 2026-10-14), the same shape our `SlackFormatter` already writes. The
maximum message size, text and cards together, is 32,000 bytes
([Send a message using the Google Chat API](https://developers.google.com/workspace/chat/create-messages),
checked 2026-10-14). Whether webhooks can also send `cardsV2` is not stated on
the webhook page (G-Q3).

A `GoogleChatFormatter` sending `text` only is close to the Slack formatter in
size, with Discord-style escaping and a byte-based, grapheme-safe cut at 32,000
bytes. A per-task `threadKey` (for example the task identifier) would group a
task's events into one thread at no extra cost. This is about the same work as
the `DiscordFormatter`.

### Injection risks and neutralisation

Chat text is parsed for formatting: `*bold*`, `_italic_`, `~strike~`,
backquotes for code, `<url|text>` links, and mentions written
`<users/{user}>`, with `<users/all>` mentioning everyone in the space
([Format Google Chat messages](https://developers.google.com/workspace/chat/format-messages),
checked 2026-10-14). The page describes no way to escape formatting or turn off
mention parsing.

So a task titled `<users/all>` would, if passed through, notify the whole
space, and `<https://example.com|click here>` would become a link. A Google
Chat kind must:

- Remove or replace `<` and `>` in every title, board name and column name
  (for example with the look-alikes U+2039 and U+203A), so that no mention or
  link markup can survive. Whether an HTML entity or a zero-width character
  also defeats the parser is not stated (G-Q4); replacing the angle brackets
  does not depend on that answer.
- Replace or strip `*`, `_`, `~` and backquotes, since there is no documented
  escape.
- Build every link itself from Stride URLs, reusing the Discord formatter's
  `safe_url/1` check.

### Rate limits and failure statuses

- Webhooks are limited to "1 request per second, shared among all webhooks in
  the space"
  ([Send messages to Google Chat with incoming webhooks](https://developers.google.com/workspace/chat/quickstart/webhooks),
  checked 2026-10-14). Exceeding a quota returns `429: Too many requests`, and
  Google asks clients to retry with exponential backoff
  ([Usage limits, Google Chat API](https://developers.google.com/workspace/chat/limits),
  checked 2026-10-14).
- This fits our rules: `429` is retried with backoff. Because we do not read
  `Retry-After`, a burst of events on one board (several task moves in the same
  second) would produce a few `429`s that succeed on a later attempt, about 30
  seconds or more later and possibly out of order.
- The status for a deleted webhook, a revoked token or a space the webhook was
  removed from is not stated in the vendor docs checked (G-Q5). Any `4xx` would
  cancel after one attempt, as we want. Google says error message text can
  change and code should check the error code
  ([Send messages to Google Chat with incoming webhooks](https://developers.google.com/workspace/chat/quickstart/webhooks),
  checked 2026-10-14), which matches our status-only rules.

### Deprecation status

No deprecation or retirement notice for incoming webhooks appears on the pages
checked; the webhook quickstart was last updated 2026-10-09
([Send messages to Google Chat with incoming webhooks](https://developers.google.com/workspace/chat/quickstart/webhooks),
checked 2026-10-14).

### UrlGuard fit

Fits: `https`, a Google-operated public host, a short URL, and the default
port. The host never changes, so anti-rebinding re-checks are routine.

### Effort against Discord

The same four tasks as Discord, at about the same size: formatter, kind with
`google_chat_url?/1` and delivery, an Integrations tab entry (label, colours,
URL placeholder and hint in the per-kind lookup), and docs. The `kind` column is
a plain string, so no migration is needed. Estimate: four tasks, about the
Discord effort. A short manual check in a Workspace space (post a test message
with `<users/all>` in a title after the fix, then delete the webhook and record
the status it returns) would answer G-Q4 and G-Q5; the webhook must be deleted
afterwards and its URL kept out of the repository.

### Recommendation

**Go**, with conditions: neutralise mentions and markup as described above,
pin the host and path, document the Business or Enterprise Workspace and admin
prerequisites in the setup guide, and carry G-Q1 to G-Q5 into the first task.

### Open questions

- G-Q1: Can personal (non-Workspace) Google accounts create incoming webhooks
  at all?
- G-Q2: What alphabet and length can a space ID have?
- G-Q3: Can incoming webhooks send `cardsV2`, and would cards help neutralise
  mentions?
- G-Q4: Does an HTML entity or a zero-width character stop `<users/all>` from
  being parsed, or is replacing the angle brackets the only option?
- G-Q5: What status does Chat return for a deleted webhook, a revoked token or
  a removed space?

## Verification

- `mix test test/kanban/docs_relative_links_test.exs` passes with this file.
- The only file added is this one; no application code changed.
- Both services answer all twelve questions under the same headings.
- Every vendor claim links to a vendor page with its checked date, or is an
  open question.
- The document contains placeholder URLs only (`ENVIRONMENT_ID`, `SPACE_ID`, `KEY`,
  `TOKEN`) and no real webhook URL, token or signature.

## Sources

All checked on 2026-10-14. "Updated" is the date the page itself showed.

| Page | Updated |
| --- | --- |
| [Retirement of Office 365 connectors within Microsoft Teams, Microsoft 365 Developer Blog](https://devblogs.microsoft.com/microsoft365dev/retirement-of-office-365-connectors-within-microsoft-teams/) | 2026-04-14 |
| [Create an Incoming Webhook, Microsoft Learn](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook) | 2026-08-03 |
| [Create incoming webhooks with Workflows for Microsoft Teams, Microsoft Support](https://support.microsoft.com/en-us/office/create-incoming-webhooks-with-workflows-for-microsoft-teams-8ae491c7-0394-4861-ba59-055e33f75498) | not shown |
| [Microsoft Teams connector reference, Microsoft Learn](https://learn.microsoft.com/en-us/connectors/teams/) | 2026-10-02 |
| [Troubleshoot common problems with Power Automate triggers, Microsoft Learn](https://learn.microsoft.com/en-us/troubleshoot/power-platform/power-automate/flow-run-issues/triggers-troubleshoot) | 2026-08-11 |
| [IP address configuration, Power Automate, Microsoft Learn](https://learn.microsoft.com/en-us/power-automate/ip-address-configuration) | 2026-05-13 |
| [Format text in cards, Microsoft Learn](https://learn.microsoft.com/en-us/microsoftteams/platform/task-modules-and-cards/cards/cards-format) | 2026-07-20 |
| [Receive and respond to inbound HTTPS calls, Azure Logic Apps](https://learn.microsoft.com/en-us/azure/connectors/connectors-native-reqres) | 2026-09-19 |
| [HTTP and Teams Webhook trigger URLs must be updated, topedia blog (third party)](https://blog-en.topedia.com/2025/10/http-and-teams-webhook-trigger-urls-must-be-updated-in-power-automate-and-copilot-studio-agent-flows/) | October 2025 |
| [Send messages to Google Chat with incoming webhooks, Google for Developers](https://developers.google.com/workspace/chat/quickstart/webhooks) | 2026-10-09 |
| [Usage limits, Google Chat API](https://developers.google.com/workspace/chat/limits) | 2026-10-09 |
| [Format Google Chat messages](https://developers.google.com/workspace/chat/format-messages) | 2026-10-09 |
| [Send a message using the Google Chat API](https://developers.google.com/workspace/chat/create-messages) | 2026-10-09 |
