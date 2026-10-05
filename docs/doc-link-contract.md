# Documentation Link Contract

This document defines the rules for links written inside the repository's own
markdown: every file under `docs/` and the top-level `README.md`. The test
`test/kanban/docs_relative_links_test.exs` enforces them in the default
`mix test` run, using the helpers in `test/support/doc_links.ex`. Introduced by
D355, after `docs/AI-WORKFLOW.md` was found linking every API page as
`../api/...`, a path that leaves `docs/` and reaches a top-level `api/`
directory that does not exist.

## What is checked

| Covered | Not covered |
|---|---|
| Inline links, `[text](target)` and `[text](<target> "title")` | Images, `![alt](src)` |
| Relative targets, with or without a `#fragment` | Targets with a scheme (`https:`, `mailto:`) or starting `//` |
| Same-file fragments, `[text](#heading)` | A lone `#` |
| Every `docs/**/*.md` file and `README.md` | Links inside fenced code blocks or inline code spans |

A covered link fails the test when:

1. **Its file does not exist.** The target is resolved against the directory of
   the file that contains the link, the way GitHub resolves it. A target that
   starts with `/` is resolved against the repository root. A link to a
   directory, such as `api/`, passes when the directory exists.
2. **It leaves the repository.** A target that climbs above the repository root
   is reported and never read.
3. **Its fragment names no anchor.** The fragment must equal the GitHub slug of
   a heading in the target file, or an explicit `<a id="...">` /
   `<a name="...">` anchor. A fragment on a target that is not a markdown file
   is reported too.

Every failure names the file, the line and the target as written, for example
`docs/AI-WORKFLOW.md:58: ../api/get_tasks_next.md points at api/get_tasks_next.md, which does not exist`.

## Writing a relative link

- **Write the path from the linking file's own directory.** From
  `docs/AI-WORKFLOW.md` an API page is `api/get_tasks.md`. From
  `docs/api/get_tasks.md` the workflow guide is `../AI-WORKFLOW.md`. From the
  repository root, as in `README.md`, it is `docs/AI-WORKFLOW.md`.
- **Link only to files that are committed.** Do not link a planning note or a
  draft that lives only on your machine; link an existing doc or drop the link.
  Never create a stub file to make a link pass.
- **Take fragments from the heading text.** The check uses the slug rule in
  `KanbanWeb.DocAnchors.slug/1`: reduce inline links to their text, drop HTML
  tags, lowercase, drop every character that is not a letter, a combining
  mark, a number, connector punctuation (`_`), `-` or a space, and turn each
  space into `-`. `### Completion Validation Format (G65)` becomes
  `#completion-validation-format-g65`. An emoji is dropped but the invisible
  variation selector that often follows it (U+FE0F) is a mark and stays, so
  `### ⚠️ CRITICAL: mark_done Endpoint Limitations` gets an anchor that starts
  with that invisible character, not with `critical`. A repeated heading gets
  `-1`, `-2`, ... in document order. Headings inside fenced blocks are code,
  not headings, so they have no anchor.

## Nesting code fences

A fence closes only on a line made of the same character, at least as long as
the opener, with nothing after it. A `` ```bash `` line inside a
`` ```markdown `` block does not close it, but the bare `` ``` `` that ends the
inner example does, which closes the outer block early. The next bare
`` ``` `` then opens a new block that can run to the end of the file. On GitHub
everything after it renders as code: its links stop being links and its
headings stop being anchors.

When a code example contains fenced blocks of its own, open and close the
outer block with **four** backticks:

`````markdown
````markdown
## before_doing
```bash
git pull origin main
```
````
`````

The test fails on any file that ends inside an open fence.

## Do not rename doc files or headings

Docs are served by raw GitHub URL as well as rendered on GitHub. The API hands
these URLs to agents: error responses from
`lib/kanban_web/controllers/api/error_docs.ex`, and the onboarding response
from `lib/kanban_web/controllers/api/agent_json.ex`, carry
`https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/...`
links, some with a `#fragment`. `test/kanban_web/controllers/api/error_docs_test.exs`
asserts those URLs and checks each fragment against the doc's headings.
Renaming a file or a heading breaks links that live outside this repository.
When a link and a heading disagree, fix the link.

Repairing a fence can still change a file's anchors, because headings that
were inside the broken block become real headings and template headings that
were outside it stop being headings. Before changing a fence, check that no
link, in this repository or in the API source, uses an anchor that would
disappear.

## Running the check

```bash
mix test test/kanban/docs_relative_links_test.exs
```

It reads local files only, makes no network calls, and does not check external
URLs. It covers every markdown file on disk under `docs/`, including untracked
and gitignored drafts such as `docs/blog/`, so a draft with a broken link fails
the suite locally even though it is never committed.
