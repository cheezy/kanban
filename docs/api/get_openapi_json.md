# GET /api/openapi.json

Get the machine-readable [OpenAPI 3.1](https://spec.openapis.org/oas/v3.1.0)
description of the whole Stride API. It covers every `/api` route: paths, verbs,
query and path parameters, request bodies, response schemas, and which
operations need a Bearer token. Client generators, MCP tooling and API viewers
can read it directly. The markdown pages in this directory are still the
narrative reference.

## Authentication

**No authentication required.** This endpoint is public, the same as
[GET /api/agent/onboarding](get_agent_onboarding.md): it is how a new client
finds out how to authenticate. The document contains no tokens, no example
credentials and no internal hostnames. If you send an `Authorization` header,
it is ignored.

## Request

**Method:** GET
**Endpoint:** `/api/openapi.json`
**Parameters:** None

The endpoint runs through the same `accepts ["json"]` pipeline as the rest of
the API. Send no `Accept` header, `Accept: application/json`, `Accept: */*`, or
the OpenAPI media type `application/vnd.oai.openapi+json`. All of them return
the document. Any other value, such as `text/html` or `application/xml`, returns
[406 Not Acceptable](#not-acceptable-406-not-acceptable) with a JSON error body.

## Response

### Success (200 OK)

The response body is the OpenAPI document, served byte-for-byte from
`priv/openapi/stride-api.json`.

| Header | Value |
|--------|-------|
| `content-type` | `application/json; charset=utf-8` |
| `cache-control` | `public, max-age=3600` |

The document only changes when Stride is deployed, so clients and proxies may
cache it for an hour.

```json
{
  "openapi": "3.1.0",
  "info": { "title": "Stride API", "version": "1.0.0", "description": "..." },
  "servers": [{ "url": "/" }],
  "security": [{ "bearerAuth": [] }],
  "paths": {
    "/api/tasks": {
      "get": { "operationId": "listTasks", "parameters": [ ... ], "responses": { ... } },
      "post": { "operationId": "createTask", ... }
    },
    "/api/tasks/{id}/complete": {
      "parameters": [{ "$ref": "#/components/parameters/TaskId" }],
      "patch": { "operationId": "completeTask", ... }
    },
    "/api/openapi.json": {
      "get": { "operationId": "getOpenApiSpec", "security": [], ... }
    }
  },
  "components": {
    "securitySchemes": { "bearerAuth": { "type": "http", "scheme": "bearer" } },
    "parameters": { ... },
    "responses": { ... },
    "schemas": { "Task": { ... }, "TaskSummary": { ... }, "PageMeta": { ... }, ... }
  }
}
```

### Bad Request (400 Bad Request)

Returned when the query string cannot be parsed, for example `?a=%FF` (an
invalid percent-encoding). The body is always JSON, whatever the `Accept`
header says, with a fixed message that never echoes the request:

```json
{
  "error": "Bad Request",
  "message": "The request is malformed and could not be processed."
}
```

Every `/api` route behaves the same way. See
[Errors](README.md#400-for-a-malformed-query-string-or-body) in the API README.

### Not Acceptable (406 Not Acceptable)

Returned when the `Accept` header (or a `_format` query parameter) asks for a
format other than JSON, for example `Accept: text/html`. The body is JSON, with
a fixed message that never echoes the header back:

```json
{
  "error": "Not Acceptable",
  "message": "This API only serves application/json."
}
```

Every `/api` route behaves the same way. See
[Errors](README.md#406-not-acceptable) in the API README.

### Server Error (500 Internal Server Error)

This is returned only if the spec file is missing from the release. The server
logs `OpenAPI spec unavailable at priv/openapi/stride-api.json: <reason>`. A
failed read is never cached, so the endpoint recovers on the next request once
the file is restored.

```json
{
  "error": "OpenAPI specification unavailable"
}
```

## What the Document Contains

- **Every `/api` route.** That includes `GET /api/tasks/:id/after_goal_status`,
  `PATCH /api/tasks/:id/after_goal` and the `PUT` alias of
  `PATCH /api/tasks/:id`, none of which has its own markdown page. Router
  `:id` segments are written in OpenAPI form, `{id}`. Its type is `string`
  because it accepts both a numeric id and an identifier such as `W21`.
- **Security.** `bearerAuth` (an HTTP Bearer scheme) is the document-wide
  default, so it applies to every operation behind the authenticated `:api`
  pipeline. The two public operations, `getAgentOnboarding` and
  `getOpenApiSpec`, override it with `security: []`.
- **All of `GET /api/tasks`'s query parameters:** `limit`, `cursor`, `status`,
  `type`, `priority`, `assigned_to_id`, `parent`, `updated_since`, `column_id`
  and `response_view`. See [GET /api/tasks](get_tasks.md#pagination-and-filters).
- **Shared component schemas.** These are `Task` (the full render),
  `TaskSummary` (the `response_view=slim` row), `TaskAck` (the slim
  `/complete` and `/changed_files` acknowledgement), `PageMeta`, `Hook`,
  `HookResult`, `Error` and `ValidationError`, plus the per-endpoint envelopes.
  Where one endpoint can return the full view or the slim view, the response
  uses `anyOf`.
- **A relative server, `"/"`.** Resolve paths against the host you fetched the
  document from. That is `https://www.stridelikeaboss.com` for the hosted
  service, and your own host when you self-host.

## Keeping the Spec in Sync

The spec is written by hand. `test/kanban_web/controllers/api/open_api_contract_test.exs`
makes sure it cannot quietly fall behind the router. The test checks that:

1. **The router and the spec match in both directions.** It lists
   `KanbanWeb.Router.__routes__/0` and keeps every route under `/api`. It
   rewrites `:id` as `{id}` and fails on any route and verb missing from the
   spec, for example:
   `GET /api/tasks/{id}/foo (router: /api/tasks/:id/foo) is missing from priv/openapi/stride-api.json`.
   It also fails on any operation the spec documents that the router does not
   serve.
2. **Authentication matches the pipeline.** It resolves each route with
   `Phoenix.Router.route_info/4`. Routes piped through `:api` must require
   `bearerAuth`, and routes piped through `:api_public` must declare
   `security: []`. A route in any other pipeline fails until the test is taught
   how to classify it.
3. **The document is internally sound.** Every `$ref` resolves, every
   `operationId` is unique, every operation has a 2xx response, and every
   `{name}` in a path has a required path parameter. Every operation also
   documents a `406` as a `$ref` to `#/components/responses/NotAcceptable`, and
   that component's example must equal what `KanbanWeb.ErrorJSON` renders for a
   406. Likewise every operation documents a `400` as a `$ref` to
   `#/components/responses/BadRequest`, whose example must equal what
   `KanbanWeb.ErrorJSON` renders for an `/api` 400.
4. **The schemas match what the API returns.** The property keys of `Task`,
   `TaskSummary` and `TaskAck` must equal the keys that
   `KanbanWeb.API.TaskJSON` renders, and `GoalSummary` the keys of
   `KanbanWeb.API.TaskController.render_goal_with_children/1`. `PageMeta` must
   equal the `meta` of a real paginated `GET /api/tasks` response. Every
   `status`, `type`, `priority` and `complexity` enum, on the schemas and on the
   `GET /api/tasks` filter parameters, must equal the `Ecto.Enum` values on
   `Kanban.Tasks.Task`. A real `TaskJSON.error/1` body for an invalid embedded
   `key_files` entry must fit the `ValidationError` value types.
5. **The document is safe to publish.** It contains no token-shaped strings,
   no `localhost` or internal hostnames, and only the relative server.

### Adding a New `/api` Route

When you add a route under `/api` in `lib/kanban_web/router.ex`:

1. Add an operation for it to `priv/openapi/stride-api.json`. Give it a unique
   `operationId`, a `summary`, a `tags` entry and at least one 2xx response.
   Add 4xx responses as `$ref`s to `#/components/responses/*`. Every operation
   needs `"406": { "$ref": "#/components/responses/NotAcceptable" }`, because
   every `/api` route rejects a non-JSON `Accept` header, and
   `"400": { "$ref": "#/components/responses/BadRequest" }`, because every
   `/api` route rejects a query string or body that cannot be parsed.
2. If the path contains `{id}`, put
   `"parameters": [{ "$ref": "#/components/parameters/TaskId" }]` on the path
   item. It is already there if the path item exists.
3. Set its security. An authenticated route inherits `bearerAuth` and needs no
   `security` key. A route in the `:api_public` scope must set `"security": []`.
4. Reuse the existing component schemas. If you add fields to
   `KanbanWeb.API.TaskJSON`, add them to the matching schema as well, or the
   parity tests will fail.
5. Run the contract test:

   ```bash
   mix test test/kanban_web/controllers/api/open_api_contract_test.exs
   ```

6. Add a markdown page for the endpoint in `docs/api/`, and add it to the
   endpoint index and the summary table in [README.md](README.md).

The file is served exactly as stored, so a change reaches clients on the next
deploy, once their cached copy is more than an hour old. The server also keeps
the bytes in memory after the first request, so in development restart the
Phoenix server to see an edit to the spec served; the contract test always
reads the file itself.

## Using the Spec

### Fetch it

```bash
curl -s https://www.stridelikeaboss.com/api/openapi.json -o stride-api.json
```

### Browse it in a viewer

Stride does not host a documentation UI. Import the URL or the downloaded file
into any OpenAPI 3.1 viewer, for example Swagger Editor, Redocly or Scalar. To
call the API from the viewer, enter your token in its `bearerAuth`
authorization dialog. Never paste a token into the spec file itself.

### Generate a client

Any OpenAPI 3.1-capable generator works. Two examples:

```bash
# TypeScript types
npx openapi-typescript https://www.stridelikeaboss.com/api/openapi.json -o stride-api.d.ts

# A full client SDK (choose your generator and language)
npx @openapitools/openapi-generator-cli generate \
  -i https://www.stridelikeaboss.com/api/openapi.json \
  -g python -o ./stride-client
```

A generated client must still send `Authorization: Bearer <your_api_token>` on
every authenticated call. Read the token from your own configuration (for
example `.stride_auth.md`), never from the spec.

### Agent and MCP tooling

The `operationId`s (`claimTask`, `completeTask`, `listTasks`, and so on) and
their request schemas can be turned into tool definitions directly. The
onboarding response links to the spec as `api_reference.openapi_url`; see
[GET /api/agent/onboarding](get_agent_onboarding.md).

## Example Usage

### Check the spec version and list the operations

```bash
curl -s https://www.stridelikeaboss.com/api/openapi.json \
  | jq -r '.openapi, (.paths | to_entries[] | .key as $p | .value | to_entries[]
           | select(.key != "parameters") | "\(.key | ascii_upcase) \($p) \(.value.operationId)")'
```

### Read the query parameters of an operation

```bash
curl -s https://www.stridelikeaboss.com/api/openapi.json \
  | jq '.paths["/api/tasks"].get.parameters'
```

## Notes

- The spec describes response *shapes*, not every error message. Most error
  bodies carry an `error` string, and most 4xx bodies add documentation keys.
  Changeset failures instead return `ValidationError`: `errors` keyed by field,
  where an embedded list field such as `key_files` holds one object per
  entry in the resulting list rather than a list of strings, and
  `documentation` becomes a list of URLs when several fields fail.
- `PUT /api/tasks/{id}` is documented because the router serves it (Phoenix
  `resources` generates it). It behaves exactly like `PATCH`.
- `response_view` accepts any string. Only `slim` changes the response.

## See Also

- [API README](README.md) - Endpoint index and workflow overview
- [GET /api/agent/onboarding](get_agent_onboarding.md) - Onboarding payload (links to this spec)
- [GET /api/tasks](get_tasks.md) - Pagination and filter parameters
- [PATCH /api/tasks/:id/complete](patch_tasks_id_complete.md) - Completion payload, described in prose
