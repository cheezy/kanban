# Comparison Pages

People choosing a tool search for "X vs Y" and "X alternative". The site has
one public page per comparison, at `/compare/<competitor>`:

- `/compare/github-projects`: Stride and GitHub Projects
- `/compare/linear`: Stride and Linear
- `/compare/jira`: Stride and Jira

Each page says where Stride fits for work done by AI coding agents and where
the other product is the better choice, shows the date the page was last
reviewed, and links a source for every claim about the other product. The
marketing footer links every comparison page.

Developers distrust one-sided comparison pages, so these pages only work if
they are honest. The sourcing rule below exists for that reason.

## Where the data lives

`KanbanWeb.Comparisons` ([`comparisons.ex`](../lib/kanban_web/comparisons.ex))
holds the list. Each comparison has:

- a fixed slug, which is only ever looked up in the list, so an unknown one
  answers 404;
- the other product's name, a literal that is never translated;
- `last_reviewed`, the date every claim on the page was last checked against
  its source;
- `better_choice`, the cases where the other product is the better choice.
  Each one is a `Claim` with a translated `text` and one or more `sources`.

The "Where Stride fits" points come from `stride_fits/0` and are the same on
every page. Each one only states what Stride's own docs say, and a comment
beside it names that doc.

`KanbanWeb.CompareController` renders the pages under the marketing layout,
with a translated page title and meta description. The last-reviewed date is
rendered with `<.local_time>`, as [Dates and Times](dates-and-times.md)
requires. Every source opens in a new tab with `rel="noopener noreferrer"`.

## The sourcing rule

Every statement about another product is a `Claim`, and every `Claim` has at
least one source.

- A source is a page of the other product's **own** documentation: its docs
  site, developer docs or support site. Never a third-party article, review or
  forum post.
- Paraphrase. Never copy the other product's wording, and never use its logo.
- Never state a price, a plan limit or a numeric cap of another product. They
  change often and are rarely worth the risk of being wrong.
- Never say another product lacks a feature. An absence cannot be sourced, and
  the claim becomes false the day the product ships it. Say what Stride does
  instead, in `stride_fits/0`.
- If a claim cannot be confirmed from a source, leave it out.

## Refreshing a comparison

1. Open every source of the comparison and check that its claim still holds.
2. Rewrite or remove any claim that no longer holds. Replace a source that
   moved or no longer loads.
3. Set `last_reviewed` to the date you checked.
4. If any text changed, run `MIX_ENV=test mix gettext.extract --merge` and
   translate the new text in every locale, leaving nothing fuzzy or empty.
5. Run `mix test test/kanban_web/controllers/compare_controller_test.exs`.

## Adding a comparison

1. Add `{slug, name}` to `@competitors` in `KanbanWeb.Comparisons` and add its
   entry to `all/0`, following the sourcing rule.
2. Translate the new text, as in step 4 above.
3. Run the comparison tests, the [SEO](seo.md) guard tests and
   `test/kanban_web/components/marketing_components_test.exs`. The sitemap
   and the footer pick the new page up from the list. The noindex check
   covers the `/compare/:competitor` route as a whole, so it needs no change.
