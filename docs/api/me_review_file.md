# GET /api/me/reviews/:task_id/files/:index

One changed file of a task waiting in Review, for the Stride mobile app's
flagged-file screen ([design](../plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md),
§6.5, §7.5): the file's path, language and counts, its flag, its diff
highlighted on the server, and the reviewer's notes on it. The app asks for one
file at a time, so opening a review never downloads every diff.

This is not an agent endpoint. Agents keep using the routes in the
[API reference](README.md) with their API token.

## Authentication

A device access token, sent as `Authorization: Bearer <token>`, exactly as for
[GET /api/me](get_me.md#authentication), with the same
[`X-Stride-App` header](get_me.md#the-version-header).

## Who can see a file

The same checks as [the review detail](me_reviews.md#who-can-see-a-review) run
first, in the same order: the person's plan, then whether they may decide the
review, then the task's board ([Plans](me_reviews.md#plans)). A task the
person cannot see answers `404` before the index is looked at, so an index only
ever reaches that task's own diffs.

`index` is a file's `index` from the review detail's
[`files`](me_reviews.md#the-files): its position in the task's stored changed
files. It must be a non-negative integer. An index that is not one, is past
the last stored file, or names an entry with no path answers
`404 {"error": "Not Found"}`, and so does any index on a task that stored no
diffs, whose files the detail lists with a `null` index.

## The response

`200 OK`:

```json
{
  "data": {
    "index": 0,
    "path": "lib/kanban/reviews/mobile_review.ex",
    "language": "elixir",
    "file_count": 6,
    "additions": 11,
    "deletions": 2,
    "truncated": false,
    "flagged": true,
    "flag_reason": "issue",
    "lines": [
      {"kind": "hunk", "old": null, "new": null, "spans": [{"class": "plain", "text": "@@ -10,2 +10,3 @@"}]},
      {"kind": "ctx", "old": 10, "new": 10, "spans": [{"class": "keyword", "text": "def"}, {"class": "plain", "text": " files"}]},
      {"kind": "add", "old": null, "new": 11, "spans": [{"class": "plain", "text": "  rows"}]}
    ],
    "notes": [
      {"line": 11, "anchored": true, "severity": "important", "category": "pattern", "description": "This query belongs in the context."}
    ],
    "review_requested_at": "2026-11-18T09:30:00Z"
  }
}
```

- `path` is the file's path as the detail lists it, and `file_count` is how many
  files the detail lists, for the screen's "1 of 6".
- `language` is `elixir`, `heex`, `erlang` or `plain`, from the file's
  extension: the language the diff was highlighted as.
- `additions`, `deletions` and `truncated` describe this file's stored diff;
  `truncated` says whether it was cut at the per-diff cap. When one path was
  stored twice, it is one file here as in the detail: the counts are summed and
  `lines` holds each of its diffs in stored order.
- `flagged` and `flag_reason` are exactly the detail's.
- `lines` holds at most 500 lines per stored diff. Each has a `kind` (`add`, `del`, `ctx` or
  `hunk`), its `old` and `new` line numbers (`null` on the side it has none)
  and its `spans`. A span's `class` is one of `keyword`, `string`, `atom`,
  `comment`, `function`, `module`, `number`, `operator` and `plain`; its `text`
  is text, never HTML, so the app renders it as text. An empty or missing diff
  returns `[]`.
- `notes` holds every reviewer issue whose file names this path, in the
  reviewer's order, matched as the detail matches flags: an issue names one
  listed file, the longest one its path ends in, so a note on `test/lib/a.ex`
  never also shows on `lib/a.ex`. `line` is the issue's
  line when it gave a positive integer. `anchored` is `true` when a line in
  `lines` has that number as its `new` number; the app shows the note at that
  line. Otherwise the note belongs to the file as a whole, including when its
  line is beyond the diff.
- `review_requested_at` is the detail's. A resubmit, or an agent replacing
  the stored files in place, can make an index the app kept name another file
  now, and the second leaves `review_requested_at` unchanged: compare `path`
  (and `review_requested_at`) with the detail row the app opened, and reload
  the detail when they differ.

Highlighting is cached by task, index, the diff's hash and the path, so a
changed diff or a renamed file is never answered from an older highlight.

## Errors

- `401 {"error": "Invalid access token"}` for a missing, expired or revoked
  device token.
- `403` with the [`plan_required` body](me_reviews.md#plans).
- `404 {"error": "Not Found"}` as described in
  [Who can see a file](#who-can-see-a-file).
