# Analytics

Stride counts visits and sign-ups with [Umami](https://umami.is), a
cookie-free, open-source analytics service that runs on Umami Cloud or on a
host you run yourself. This page is for contributors and operators: how
analytics is switched on, which pages load the tracker, which events it sends,
how to add an event, and how to set up the funnel and goal in the Umami
dashboard. The module docs of
[`KanbanWeb.Analytics`](../lib/kanban_web/components/analytics.ex) are the
full reference.

Analytics answers one question the page views alone cannot: which page or
channel produced a user. Umami's funnel, goal and attribution reports need a
conversion step, so the sign-up is sent as an event from the visitor's own
browser, in the same Umami session as the page views before it.

## Configuration

Analytics is off unless all three variables are set. `config/runtime.exs`
reads them in every environment and sets `config :kanban, :umami`.

| Variable | Value | Umami Cloud |
|---|---|---|
| `UMAMI_SCRIPT_URL` | The tracker script, an `https` URL | `https://cloud.umami.is/script.js` |
| `UMAMI_WEBSITE_ID` | The website's UUID from the Umami dashboard | (from the dashboard) |
| `UMAMI_HOST_URL` | Where the tracker sends events, an `https` URL | `https://gateway.umami.is` |

Every value is public: the website id is printed in the HTML of every page
that loads the tracker. Set them as deployment secrets or plain environment
variables, for example with `fly secrets set` on Fly.io. Each value is trimmed
and a blank one counts as unset.

The boot stops, naming the variable and never printing its value, when:

- one or two of the three are set (set all three or none),
- a URL is not `https`, has a host that is not a plain DNS name (a `*`, `;`
  or quote would widen or break the CSP), or carries user info,
- the website id is not a UUID.

`KanbanWeb.Analytics.config/0` checks the configuration again at runtime and
returns `nil` for anything partial or malformed, so a bad application
environment turns analytics off rather than rendering a broken tag.

Nothing is set in `config/test.exs` or in the development config, so tests
and the dev server run with analytics off. Tests that need it put fake values
with `Application.put_env(:kanban, :umami, ...)` in a module that is not
async, and restore the environment afterwards; see
[`analytics_test.exs`](../test/kanban_web/analytics_test.exs).

## Which pages load the tracker

A page loads the tracker only when it opted in with the `:analytics` assign
and Umami is configured. The assign is off by default, so a new page, and in
particular a new signed-in page, never loads the tracker by accident. Pages
opt in in three ways:

- **Controller pages** pipe through the `:put_analytics` pipeline
  (`KanbanWeb.Plugs.PutAnalytics`). The router uses it for the public page
  scope: the home page, `/about`, `/pricing`, `/privacy`, `/product`,
  `/workflows`, the legal pages, `/changelog`, `/docs`, `/integrations` and
  `/compare`.
- **Public LiveView sessions** list `{KanbanWeb.AnalyticsOnMount, :track}` in
  their `on_mount`: `:public` (`/issue`, `/demo`) and `:public_app_shell`
  (`/resources`).
- **Single LiveViews** declare `on_mount {KanbanWeb.AnalyticsOnMount, :track}`
  themselves. Only `/users/register`, `/users/log-in` and
  `/users/confirmation-pending` do this, because the `:current_user` session
  they share also holds the token pages.

Signed-in pages (boards, settings, admin) and pages with a token in their path
(`/users/confirm/:token`, `/users/reset-password/:token`,
`/invitations/:token`) never opt in. A signed-in person still loads the
tracker on a public page such as `/pricing`, because the assign follows the
route, not the person. [`analytics_test.exs`](../test/kanban_web/analytics_test.exs)
walks every path in `KanbanWeb.SeoXML.public_paths/0` and pins which
sessions and views opt in.

The tag is rendered once, in the `<head>` of the root layout of the first
full page load, before `app.js`. Live navigation inside one live_session keeps
that layout, so a page reached only by live navigation from an opted-in page
is counted too; within `:current_user` that can only be another token-free
account page, such as `/users/forgot-password`.

### What the tag carries

```heex
<script defer src={script_url} nonce={@nonce}
  data-website-id={website_id}
  data-host-url={host_url}
  data-domains={KanbanWeb.Endpoint.host()}
  data-exclude-search="true"
  data-exclude-hash="true"
  data-before-send="strideAnalyticsBeforeSend">
</script>
```

- `data-exclude-search` and `data-exclude-hash` keep the query string and the
  fragment out of every URL Umami records. `/users/confirmation-pending`
  carries the new account's email address in its query string, and other URLs
  can carry tokens.
- `data-before-send` names a function in
  [`assets/js/analytics.js`](../assets/js/analytics.js) that also strips the
  query string and fragment from the page URL and the referrer before the
  tracker sends anything, on tracker versions that support the hook. It is
  defence in depth for the referrer, which the two exclude flags do not
  necessarily cover.
- `data-domains` counts only the canonical host, so a staging or local copy
  that shares the website id records nothing.
- Nothing identifies a visitor: no `umami.identify`, no `data-distinct-id`,
  no cookie, and no consent banner is needed.

## The Content Security Policy

When Umami is configured, `KanbanWeb.Plugs.CspNonce` adds exactly two sources:
the script's origin to `script-src`, and a `connect-src` directive with
`'self'` plus the origin of `UMAMI_HOST_URL`. `'self'` keeps the LiveView
socket and its long-poll fallback working, as `default-src 'self'` did before.
No wildcard is ever added, and without the configuration the policy is exactly
the one every page had before. The widening applies to every browser page,
because the policy is set before the router knows whether the page opted in;
pages that do not load the tracker simply never use it.

## The events

Page views are sent by the tracker itself. The events are:

| Event | Properties | Sent when | Sent by |
|---|---|---|---|
| `signup` | none | A registration succeeded; sent once, from `/users/confirmation-pending` | The `AnalyticsSignup` hook |
| `install-command-copied` | `runtime`: the runtime slug, such as `codex` | The visitor copies text from an install command on `/integrations/:runtime` | The copy listener in `analytics.js` |
| `get-started-clicked` | `location`: `nav`, `hero`, `closing`, `pricing`, `product`, `workflows` or `demo` | A sign-up call to action is clicked | The tracker, from `data-umami-event` |
| `github-clicked` | `location`: `footer`, `docs-source`, `integration-listing`, `integration-docs`, `integration-install-note`, `security`, `workflows` or `issue` | A GitHub link is clicked | The tracker, from `data-umami-event` |

Every property is a fixed string or a runtime slug that must match
`^[a-z0-9-]{1,40}$`. No event carries an email address, a token, a user or
account id, or a board name or any task text.

### How the signup event fires once

1. `UserSessionController.register/2` puts the one-shot flash flag
   `:analytics_signup` on a successful registration only, then redirects to
   `/users/confirmation-pending`.
2. `KanbanWeb.UserLive.ConfirmationPending` reads the flag and renders a
   hidden `#analytics-signup-event` element with `phx-hook="AnalyticsSignup"`,
   only when Umami is configured. It does not clear the flash, because the
   connected mount must see it too.
3. The hook calls `umami.track("signup")` once per page load, and does
   nothing when the tracker did not load (an ad blocker, say).

A flash is consumed by the request that reads it, so a reload or a direct
visit renders no element, and a LiveView reconnect receives no flash. A failed
registration sets no flag. The event is never sent from the server to Umami's
`/api/send`, because a server-side event would not join the visitor's Umami
session and the funnel could not use it.

## How to add an event

1. Choose a short kebab-case name and fixed properties. Never put personal
   data, a token, an id or board content in a property.
2. For a click, add `data-umami-event="<name>"` and one
   `data-umami-event-<property>="<value>"` per property to the link. The
   tracker sends it; no JavaScript is needed.
3. For anything else, call `umamiTrack(win, "<name>", {...})` from
   `analytics.js`, which does nothing when the tracker is missing, and add a
   `node --test` case to
   [`analytics.test.mjs`](../assets/js/analytics.test.mjs).
4. Add the event and its allowed values to the allow-lists in
   `analytics_test.exs` and to the table above.

## Setting up the dashboard

The funnel and the goal are set up by hand in the Umami dashboard, once per
website:

1. **Goal:** add a goal for the event `signup`.
2. **Funnel:** add a funnel with three steps: a landing page (for example
   `/` or `/pricing`), then the page `/users/register`, then the event
   `signup`.
3. **Attribution:** Umami's attribution report uses the referrer and the UTM
   parameters of the first page view of a session. Because the query string is
   excluded, UTM parameters are not recorded; use the referrer instead, or
   lift the exclusion only for the `utm_` parameters in a follow-up.

## Verifying it

With a Umami test website configured, register a new account on
`/users/register` and copy an install command on `/integrations/codex`. Umami
should show the page views, one `signup` event and one
`install-command-copied` event with `runtime` `codex`, and no recorded URL
should contain a query string or an email address. Then check the
`content-security-policy` header of `/pricing` with and without the `UMAMI_`
variables, and confirm a signed-in board page loads no tracker.

## Follow-ups

- Serve the tracker and its collection endpoint through our own domain, so
  ad blockers do not drop it. That changes the two CSP origins to `'self'`.
