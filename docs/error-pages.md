# Error Pages and Error Responses

How Stride turns an exception into a response: which module renders it, in
which format, and what the client sees. This covers browser pages and `/api`
JSON bodies, including errors raised before the router runs.

For the API contract itself (status codes, bodies, how to avoid them), see the
[Errors section of the API README](api/README.md#errors). For the theme
bootstrap the error pages share, see
[`dark-mode-contract.md`](dark-mode-contract.md).

## Who renders an error

An exception that escapes a request is caught by
`Phoenix.Endpoint.RenderErrors`, configured in `config/config.exs`:

```elixir
render_errors: [
  formats: [html: KanbanWeb.ErrorHTML, json: KanbanWeb.ErrorJSON],
  layout: false
]
```

It picks the format like this:

1. If the request already has a format set (`conn.private.phoenix_format`),
   that format is used. The `/api` scopes set `json` in their `:api_json`
   pipeline, so a routed `/api` request always renders JSON.
2. Otherwise the `Accept` header is matched against `html` and `json`, in that
   order. No `Accept` header, or `*/*`, gives `html`.
3. If the `Accept` header matches neither, `html` is used.

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
`<.error_page>`; a template always wins over the fallback.

## `/api` bodies (`KanbanWeb.ErrorJSON`)

`/api` errors use the API's `Error` shape, `error` + `message`, with a fixed
message that never echoes the request:

| Status | `error` | `message` |
|--------|---------|-----------|
| 400 | Bad Request | The request is malformed and could not be processed. |
| 406 | Not Acceptable | This API only serves application/json. |
| 413 | Request Entity Too Large | The request body is too large. |
| 415 | Unsupported Media Type | Send the request body as application/json. |

These clauses match only when the request path starts with `/api`. Any other
JSON error, and any other `/api` status, gets Phoenix's generic
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
is unchanged. On any other path it is plain `Plug.Parsers`.

Two rules keep this working:

- **The wrapper must be the first plug that parses the query string.**
  `Phoenix.LiveDashboard.RequestLogger` calls `fetch_query_params`, so it sits
  after the parsers in `lib/kanban_web/endpoint.ex`. A plug that parses the
  query string above the wrapper would raise outside it, and an `/api` client
  would get an HTML page. The cost is confined to that dev tool: its Logger
  metadata is now set after `Plug.Telemetry`'s request-start line and after
  parsing, so the LiveDashboard request-logger stream no longer shows the
  `GET /path` line or anything logged while parsing.
- **The pin is applied only on failure.** A request that parses cleanly leaves
  the wrapper with no format set, so an unrouted `/api` path such as
  `/api/no-such-route` still renders the HTML 404, exactly as before.

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
`test/kanban_web/controllers/error_html_test.exs` and
`test/kanban_web/controllers/error_json_test.exs`.
