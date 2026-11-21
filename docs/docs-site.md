# Publishing Guides on the Site

A small set of the guides in this directory is also published on the site at
`/docs`, so people searching for how to give coding agents a task queue find
them on Stride's own domain. `docs/` stays the source of truth: guides are
written, reviewed and linked here, and GitHub keeps rendering them as before.

## What is published

`KanbanWeb.Docs` ([`docs.ex`](../lib/kanban_web/docs.ex)) holds an explicit
allow-list, `@catalog`. Each entry names a fixed slug, the guide's repository
path, its group (`:guide` or `:api`) and an English meta description. Today it
lists:

- the five agent guides: [Getting Started with AI](GETTING-STARTED-WITH-AI.md),
  [AI Workflow](AI-WORKFLOW.md), [MCP](MCP.md),
  [Authentication](AUTHENTICATION.md) and
  [Agent Hook Execution](AGENT-HOOK-EXECUTION-GUIDE.md);
- the [API index](api/README.md) at `/docs/api`;
- the agent endpoint pages in `api/`, at `/docs/api-<method>-<path>` (for
  example `/docs/api-post-tasks-claim`).

The mobile person-API pages (`api/me_*.md`, `api/get_me.md`,
`api/post_oauth_token.md`) are not published, nor is anything else in `docs/`.
Security findings, plans, runbooks and other internal docs must never be added
to the allow-list; `test/kanban_web/docs_test.exs` fails if a source path
looks like one.

The slug is only ever looked up in the allow-list. It is never turned into a
file path, so `/docs/:slug` cannot read anything that is not listed.

## How a guide is rendered

The release image copies `lib/` and `priv/` but not `docs/`, so every published
guide has a committed copy at the same path under `priv/` (for example
`priv/docs/MCP.md`). `KanbanWeb.Docs` reads those copies at compile time and
renders them once with `KanbanWeb.Docs.Renderer`:

- MDEx with tables, autolinks and strikethrough on, as on GitHub;
- raw HTML escaped (`render: [escape: true]`), never rendered;
- every heading given the id GitHub gives it, so `#anchor` links keep working;
- the title taken from the first level-one heading, and the "On this page"
  list from the level-two headings (or the level-three headings, for a guide
  with fewer than two level-two headings).

The build fails when a published guide has no level-one heading or contains an
image, which the site's Content Security Policy would block.

## How links are rewritten

Guides keep writing links the GitHub way, relative to their own file
([Documentation Link Contract](doc-link-contract.md)). `KanbanWeb.Docs.Links`
maps each one when the guide is rendered:

| Link in the guide | On the site |
| --- | --- |
| `#anchor` | unchanged |
| `http`, `https` or `mailto` | unchanged |
| no path, only a query string such as `?tab=1` | unchanged |
| another published guide, such as `api/post_tasks_claim.md#errors` | `/docs/api-post-tasks-claim#errors` |
| `api/` or `api/README.md` | `/docs/api` |
| a directory listed in `@directories` in `KanbanWeb.Docs` | its GitHub `tree` URL |
| any other file in the repository | its GitHub `blob` URL |
| any other scheme, a `//host` link, or a path above the repository root | the link text, with no link |

A rewritten link keeps its query string and its anchor, so
`../CHANGELOG.md?plain=1#L10` becomes the GitHub `blob` URL of `CHANGELOG.md`
with `?plain=1#L10` after it.

Whether a path is a directory is never guessed from its name: `Makefile` and
`LICENSE` are files, and a directory such as `.github` has a dot in its name.
The guides are rendered when the app is compiled, and the release build has no
`docs/`, `test/` or root files to look at, so the directories the guides link
to are listed by hand in `@directories`. When a guide starts linking to an
unpublished directory, add its repository path there (no trailing slash).
`test/kanban_web/controllers/docs_controller_test.exs` fails until you do, and
`test/kanban_web/docs_test.exs` fails when an entry is no longer a directory a
guide links to.

## Publishing another guide or changing one

1. Edit the guide in `docs/` as usual.
2. Copy it to the same path under `priv/`, for example
   `cp docs/MCP.md priv/docs/MCP.md`.
3. For a new guide, add an entry to `@catalog` with a lower-case hyphenated
   slug and a unique English description of 70 to 160 characters.

`test/kanban_web/docs_test.exs` fails when a copy under `priv/docs` differs
from its source in `docs/`, and prints the `cp` command for each stale file. It
also fails when `priv/docs` holds a file that is not on the allow-list.
`test/kanban_web/controllers/docs_controller_test.exs` fails when a link on a
published page goes nowhere: a missing anchor, an unpublished `/docs` slug, or
a GitHub URL for a file the repository does not have.

The sitemap picks the new page up from `KanbanWeb.Docs.sitemap_paths/0`; see
[Search and Social Tags](seo.md).

## Translation

The guides stay in English, and so do their meta descriptions. The page chrome
around them (the index headings, "On this page", "View this page on GitHub")
goes through gettext and is translated into every supported language.
