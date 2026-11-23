# The person API: /api/me

The routes the Stride mobile apps call for the signed-in person
([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md), §7, §9.2, §10).
This page is the map: how every route authenticates, which routes are
plan-gated, the errors they share and how they are cached. Each route's own page
has its request, response and errors.

These are not agent endpoints. Agents keep using the routes in the
[API reference](README.md) with their API token.

**Device tokens are not for agents.** The person API takes only a device access
token, which the app gets by signing a phone or tablet in
([the OAuth flow](oauth.md)). An agent API token is refused here with `401`, and
a device token is refused with `401` on every agent route that takes an API
token, the same response an unknown token gets.

## Authentication

Every route takes a device access token, sent as
`Authorization: Bearer <access token>`
([authentication](get_me.md#authentication)). It lasts one hour, and the app
renews it with its refresh token.

Every app request also carries the `X-Stride-App` header with the app's platform
and version. A version below the platform's minimum is refused with `426` before
the token is checked, so an outdated app reaches its update screen even when its
token has expired ([the version header](get_me.md#the-version-header)).

## The routes

| Route | Page | Plan-gated |
|---|---|---|
| `GET /api/me` | [GET /api/me](get_me.md) | No |
| `GET /api/me/devices` | [The device routes](me_devices.md) | No |
| `PUT /api/me/devices/current` | [The device routes](me_devices.md) | No |
| `DELETE /api/me/devices/current` | [The device routes](me_devices.md) | No |
| `DELETE /api/me/devices/:id` | [The device routes](me_devices.md) | No |
| `POST /api/me/socket_token` | [The live-updates socket](me_socket_token.md) | Yes |
| `GET /api/me/notification_settings` | [Push settings](me_notification_settings.md) | Yes |
| `PUT /api/me/notification_settings` | [Push settings](me_notification_settings.md) | Yes |
| `GET /api/me/decisions` | [Decisions and the review queue](me_decisions.md) | Yes |
| `GET /api/me/reviews` | [Decisions and the review queue](me_decisions.md) | Yes |
| `GET /api/me/reviews/:task_id` | [One pending review](me_reviews.md) | Yes |
| `GET /api/me/reviews/:task_id/files/:index` | [One changed file](me_review_file.md) | Yes |
| `POST /api/me/reviews/:task_id/approval_challenge` | [Approve a review](me_review_approval.md) | Yes |
| `POST /api/me/reviews/:task_id/approve` | [Approve a review](me_review_approval.md) | Yes |
| `POST /api/me/reviews/:task_id/request_changes` | [Request changes](me_review_request_changes.md) | Yes |
| `GET /api/me/boards` | [The Boards tab](me_boards.md) | Yes |
| `GET /api/me/boards/:id/columns/:name` | [The Boards tab](me_boards.md) | Yes |
| `POST /api/me/boards/:id/promote` | [The Boards tab](me_boards.md) | Yes |
| `GET /api/me/tasks/:id` | [Task actions](me_tasks.md) | Yes |
| `POST /api/me/tasks/:id/comments` | [Task actions](me_tasks.md) | Yes |
| `POST /api/me/tasks/:id/move_to_backlog` | [Task actions](me_tasks.md) | Yes |
| `POST /api/me/tasks` | [Task actions](me_tasks.md) | Yes |
| `GET /api/me/agents` | [The Agents tab](me_agents.md) | Yes |
| `GET /api/me/goals/:id/after_goal` | [The Agents tab](me_agents.md) | Yes |
| `GET /api/me/goals` | [The Goals list and Goal screen](me_goals.md) | Yes |
| `GET /api/me/goals/:id` | [The Goals list and Goal screen](me_goals.md) | Yes |
| `GET /api/me/targets` | [The Targets list and Target screen](me_targets.md) | Yes |
| `GET /api/me/targets/:id` | [The Targets list and Target screen](me_targets.md) | Yes |

The live updates travel on the socket at `/api/socket`, joined with a token from
`POST /api/me/socket_token`, on the `me:inbox` and `me:agents` channels
([the live channels](me_channels.md)).

## Plans

The Stride apps are an Organization feature, the `mobile_app` plan feature.

- **Never gated:** `GET /api/me` and the four device routes, so a person without
  the plan can still sign in, see that the app is locked, and sign out.
- **Every other route** checks the person's plan. Most check it first. The
  three review decision routes (`approval_challenge`, `approve` and
  `request_changes`) first answer `404` for a review the person cannot see and
  `409` for one already decided, and only then refuse on the plan
  ([the checks, in order](me_review_approval.md#the-checks-in-order)). A
  route that reads or changes one board, task or goal also checks that board,
  so a person in an Organization still cannot use the app on a board outside
  it. The lists leave out boards the plan does not unlock.

A refusal is `403 Forbidden` with `"error": "plan_required"` and
`"feature": "mobile_app"` ([the plan refusal](me_reviews.md#plans)). While paid
plans are not enforced, every route is unlocked and `GET /api/me` returns
`app_unlocked: true`.

## Errors every route can return

| Status | When |
|---|---|
| `400` | The query string or body cannot be parsed ([details](README.md#400-for-a-malformed-query-string-or-body)) |
| `401` | `{"error": "Missing or invalid Authorization header"}` without a `Bearer` header, or `{"error": "Invalid access token"}` for an unknown, expired or revoked token, a disabled account or an agent API token |
| `403` | `plan_required`, on the plan-gated routes only |
| `404` | `{"error": "Not Found"}` for a path under `/api/me` that matches no route, such as a verb a route does not serve, as JSON whatever the `Accept` header says |
| `406` | The `Accept` header rules out JSON ([details](README.md#406-not-acceptable)) |
| `426` | `{"error": "app_update_required", "store_url": "…"}` when the app is below the minimum version |
| `429` | `{"error": "Too many requests"}` after too many failed authentications from one address, with `retry-after`. A token that has only expired is not counted |

Each route's page lists the errors that are its own, such as `404` for a board,
task, review or target the person cannot see.

## Caching

Every `/api/me` response, success or error, is sent with
`cache-control: private, no-store`. The one exception is a response that carries
an `ETag`, which is sent with `cache-control: private, max-age=0,
must-revalidate` so the app can revalidate it with `If-None-Match`
([caching of the person API](README.md#caching-of-the-person-api)).

## The contract

The routes are described in the OpenAPI contract,
`priv/openapi/stride-api.json`, which is served at `GET /api/openapi.json`
([OpenAPI specification](get_openapi_json.md)). `MIX_ENV=test mix mobile.api`
checks it and copies it into `mobile/shared/` for the apps' generated clients,
next to the example responses in `mobile/shared/fixtures/`
([shared mobile files](../../mobile/shared/README.md)).

## See also

- [Device sign-in: the OAuth flow](oauth.md)
- [The Stride Mobile Apps](../mobile-apps.md)
- [Push Notifications](../push-notifications.md)
