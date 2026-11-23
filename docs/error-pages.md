# Error Pages and Error Responses

This document is for operators running Stride who need to know what a
browser, API or SCIM client gets when a request fails, and that nothing from
the request reaches it, and for contributors changing the error modules. It
explains how Stride turns an exception into a response: which module renders
it, in which format, and what the client sees. This covers browser pages,
`/api` JSON bodies and `/scim` SCIM errors, including errors raised before the
router runs.

For the API contract itself (status codes, bodies, how to avoid them), see the
[Errors section of the API README](api/README.md#errors). For the theme
bootstrap the error pages share, see
[`dark-mode-contract.md`](dark-mode-contract.md).

## Who renders an error

An exception that escapes a request is caught by
`Phoenix.Endpoint.RenderErrors`, configured in `config/config.exs`:

```elixir
render_errors: [
  formats: [
    html: KanbanWeb.ErrorHTML,
    json: KanbanWeb.ErrorJSON,
    scim: KanbanWeb.SCIM.ErrorJSON
  ],
  layout: false
]
```

It picks the format like this:

1. If the request already has a format set (`conn.private.phoenix_format`),
   that format is used. The `/api` scopes set `json` in their `:api_json`
   pipeline, so a routed `/api` request always renders JSON. The `/scim/v2`
   scope's `:scim` pipeline sets `scim` (`application/scim+json`), so a routed
   SCIM request renders through `KanbanWeb.SCIM.ErrorJSON`.
2. Otherwise the `Accept` header is matched against `html`, `json` and `scim`,
   in that order. No `Accept` header, or `*/*`, gives `html`.
3. If the `Accept` header matches none of them, `html` is used.

The template name is `"<status>.<format>"`, for example `"404.html"` or
`"400.json"`. Keep `html` first in `formats`: it is what an unmatched browser
404 or 500 needs.

## Browser pages (`KanbanWeb.ErrorHTML`)

`lib/kanban_web/controllers/error_html.ex` renders every HTML error page with
the shared `error_page/1` component: a standalone document with its own theme
bootstrap, the status code, a heading, a message and a Go Home link.

| Status | Source | Heading |
|--------|--------|---------|
| 404 | `error_html/404.html.heex` | Page Not Found |
| 500 | `error_html/500.html.heex` | Internal Server Error |
| 400 | `render/2` fallback | Bad Request |
| 406 | `render/2` fallback | Not Acceptable |
| 413 | `render/2` fallback | Request Too Large |
| 415 | `render/2` fallback | Unsupported Media Type |
| any other | `render/2` fallback | Something Went Wrong |

The `render/2` fallback (D353) handles every status without a template. Before
it existed, such a status raised `ArgumentError` while rendering, and the client
got a 500 instead of the real status. The common ways in are:

- a malformed query string on a browser path, such as `/about?a=%FF` (400);
- a browser route requested with an `Accept` header it does not serve, such as
  `GET /about` with `Accept: image/png` (406).

All wording is translated through Gettext. Both cases above fail before the
`:browser` pipeline's `Locale` plug runs (the 406 is raised by `accepts`, its
first plug), so they render in the default locale. The page
shows the status code and fixed text only: nothing from the request (query
string, headers, body) or the exception reaches it.

To give a status its own page, add `error_html/<status>.html.heex` that calls
`<.error_page>` and passes it `csp_nonce={assigns[:csp_nonce]}`; a template
always wins over the fallback.

### Security headers on browser error pages

A browser POST with a missing, malformed or foreign CSRF token is refused by
`:protect_from_forgery` in the `:browser` pipeline, which raises
`Plug.CSRFProtection.InvalidCSRFTokenError`. That renders as a 403 through the
`render/2` fallback (Something Went Wrong), in the default locale, before any
controller runs. The body shows nothing from the request or the CSRF state.

The router re-raises an exception with the conn as it entered the failing
pipeline, so anything a plug inside `:browser` had set is lost. For that
reason the browser security headers live in their own `:browser_headers`
pipeline, piped through before `:browser` on every browser route (D467). A CSRF
403, or any other error raised inside a browser route, therefore carries
`put_secure_browser_headers`' headers (`referrer-policy`,
`x-content-type-options` and the rest) and `KanbanWeb.Plugs.CspNonce`'s nonce'd
`content-security-policy`, the same policy every page gets.

That policy only admits inline scripts that carry the request's nonce, so
`error_page/1` takes a `csp_nonce` attribute and puts it on the theme
bootstrap script. Every caller passes `assigns[:csp_nonce]`. An error raised
before the router (a malformed query string, an unrouted 404) has no nonce and
no policy, and the script carries no `nonce` attribute.

## `/api` bodies (`KanbanWeb.ErrorJSON`)

`/api` errors use the API's `Error` shape, `error` + `message`, with a fixed
message that never echoes the request:

| Status | `error` | `message` |
|--------|---------|-----------|
| 400 | Bad Request | The request is malformed and could not be processed. |
| 406 | Not Acceptable | This API only serves application/json. |
| 413 | Request Entity Too Large | The request body is too large. |
| 415 | Unsupported Media Type | Send the request body as application/json. |

These clauses match only when the request path is under `/api`, `/api/me`
included. Two other APIs have their own clauses (D462):

- **`/api/me`** answers a 404 with `{"error": "Not Found"}`, the body its
  controllers return for a missing record.
- **`/oauth`**, except the browser's `/oauth/authorize` page and the paths
  under it, answers a 400,
  404, 413 or 415 with the RFC 6749 shape, `{"error": "invalid_request",
  "error_description": "<fixed text>"}`, and a 406 with the API's
  `Not Acceptable` body above.

The path is matched by `KanbanWeb.PathScope` on its decoded segments, as the
router matches routes, so `/%61pi/me/x` is under `/api/me`. Any other JSON
error, and any other status on these paths, gets Phoenix's generic
`{"errors": {"detail": "<reason phrase>"}}` body.

## Errors raised before the router

`Plug.Parsers` runs in the endpoint, before the router, so the `:api_json`
pipeline has not set the format when it raises. `RenderErrors` renders with the
conn as it entered the endpoint, unless the exception is a
`Plug.Conn.WrapperError`, in which case it uses the wrapped conn.

`KanbanWeb.Plugs.Parsers` (`lib/kanban_web/plugs/parsers.ex`) wraps
`Plug.Parsers` for that reason. On an `/api` path it re-raises any parse
failure as a `WrapperError` whose conn has its format pinned to json, so the
error renders through `ErrorJSON` whatever the `Accept` header says. The status
is unchanged. Other paths are handled too:

- **`/scim` paths** are re-raised the same way, with the format pinned to
  `scim`, so the error renders through `KanbanWeb.SCIM.ErrorJSON` as a SCIM
  error.
- **A malformed JSON body on `POST /api/mcp`** is not raised. The wrapper
  flags it and empties the body, the request goes on to the `:api` pipeline,
  and once the request is authenticated the MCP endpoint answers with a 400
  whose body is a JSON-RPC `-32700` parse error. An unauthenticated request
  gets its 401 first. A 413, a 415 or a malformed query string on that route
  still raises as on every other `/api` path.
- **The browser's `/oauth/authorize` page** (and the paths under it, D463)
  gets no format pin, so its errors render in the format the `Accept` header
  asks for, as on every other browser path (HTML for a browser, JSON for
  `Accept: application/json`), but it gets `cache-control: no-store` before
  parsing. The log-in redirect, the organization two-factor redirect, a wrong
  verb's 404 and a malformed query's 400 are all sent before
  `KanbanWeb.OAuthController` runs, and none of them may be cached. A parse
  failure there is re-raised as a `WrapperError` carrying that conn, so its
  400 keeps the header.

On any other path it is plain `Plug.Parsers`.

Two rules keep this working:

- **The wrapper must be the first plug that parses the query string.**
  `Phoenix.LiveDashboard.RequestLogger` calls `fetch_query_params`, so it sits
  after the parsers in `lib/kanban_web/endpoint.ex`. A plug that parses the
  query string above the wrapper would raise outside it, and an `/api` client
  would get an HTML page. The cost is confined to that dev tool: its Logger
  metadata is now set after `Plug.Telemetry`'s request-start line and after
  parsing, so the LiveDashboard request-logger stream no longer shows the
  `GET /path` line or anything logged while parsing.
- **On the agent API the pin is applied only on failure.** A request that
  parses cleanly leaves the wrapper with no format set, so an unrouted `/api`
  path such as `/api/no-such-route` still renders the HTML 404, exactly as
  before. The person API (`/api/me`) and the device sign-in token API
  (`/oauth`, except the browser's `/oauth/authorize` page and the paths under
  it) are pinned to json
  before parsing instead (D462), so a path there that matches no route
  answers its API's own JSON 404 body, `{"error": "Not Found"}` under
  `/api/me` and an `invalid_request` under `/oauth`, whatever the `Accept`
  header says. `KanbanWeb.PathScope` decides which API a path is under, on
  the decoded segments the router matches.

`Plug.Parsers` is configured with `pass: ["*/*"]`, so it does not raise a 415
for an unknown content type today; the 415 clauses exist so that the response
stays correct if that option changes.

## Testing error responses

Phoenix re-raises after rendering most errors, so a plain `get/2` raises in a
test. Use `assert_error_sent/2`, which also exercises the production render
path (`debug_errors` is set only in `config/dev.exs`):

```elixir
{400, headers, body} =
  assert_error_sent(400, fn -> get(build_conn(), "/api/openapi.json?a=%FF") end)
```

`NoRouteError` is the exception: it is rendered but not re-raised, so an
unrouted 404 is tested with a plain `get/2`.

The tests for this behaviour are in
`test/kanban_web/controllers/api/pre_router_errors_test.exs`,
`test/kanban_web/controllers/api/not_acceptable_test.exs`,
`test/kanban_web/controllers/error_html_test.exs`,
`test/kanban_web/controllers/error_json_test.exs` and, for the CSRF 403's
headers, `test/kanban_web/controllers/oauth_authorize_test.exs` and
`test/kanban_web/browser_headers_pipeline_test.exs`.
