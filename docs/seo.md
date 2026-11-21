# Search and Social Tags

This is how a page tells search engines and link-preview crawlers what it is.
It is written for contributors and agents adding a public page, or a page that
must stay out of search results. The tags themselves come from one component,
[`KanbanWeb.SeoComponents`](../lib/kanban_web/components/seo_components.ex),
and the module docs of the modules named below are the full reference.

When you add a page, decide three things: its title and description, whether
it is public or `noindex`, and whether the sitemap lists it. The guard tests in
[The guard tests](#the-guard-tests) fail until the first two are decided for a
new route.

## Where the tags come from

The three root layouts (`root`, `app_chrome` and `marketing`, in
`lib/kanban_web/components/layouts/`) each render the same head: a
`<.live_title>` and then one call to `seo_head/1`.

```heex
<.live_title default={gettext("Stride")} suffix={gettext(" · Task Management")}>
  {assigns[:page_title]}
</.live_title>
<.seo_head
  title={assigns[:page_title]}
  description={assigns[:meta_description]}
  noindex={assigns[:noindex] == true}
  path={request_path(assigns[:conn])}
  locale={Gettext.get_locale(KanbanWeb.Gettext)}
  og_image={assigns[:og_image]}
  feed_path={assigns[:feed_path]}
  feed_title={assigns[:feed_title]}
/>
```

So a page controls its tags through six assigns, and never by writing a
`<meta>` tag itself:

| Assign | What it sets | When it is absent |
|---|---|---|
| `:page_title` | `<title>`, `og:title` and `twitter:title` | "Stride" |
| `:meta_description` | `description`, `og:description` and `twitter:description` | `SeoComponents.default_description/0` |
| `:noindex` | `<meta name="robots" content="noindex, nofollow">`, only when exactly `true` | The page is indexable |
| `:og_image` | `og:image` and `twitter:image` | The default image |
| `:feed_path` | `<link rel="alternate" type="application/atom+xml">`, with an absolute `href` built like the canonical | No feed link |
| `:feed_title` | The `title` of that feed link | The link has no title |

Every page also gets `og:type`, `og:site_name`, `og:locale`, a
`summary_large_image` Twitter card and a light and a dark `theme-color`.

## Titles and descriptions

Set `page_title` and `meta_description` on every public page, translated with
`gettext` so they follow the visitor's locale.

- A `KanbanWeb.PageController` page adds a clause to the private `seo/1`
  function in
  [`page_controller.ex`](../lib/kanban_web/controllers/page_controller.ex)
  and renders with `render(conn, :name, seo(:name))`. It is a function rather
  than a module attribute so that `gettext` runs per request.
- A LiveView assigns them in `mount/3` or `handle_params/3`, as
  `KanbanWeb.ResourcesLive.Index` and `KanbanWeb.ResourcesLive.Show` do.
  `KanbanWeb.ResourcesLive.Seo` shortens a how-to's summary to fit.

The browser `<title>` gets the " · Task Management" suffix from
`<.live_title>`. `og:title` and `twitter:title` carry the bare title.

Write each description between 70 and 160 characters in English, and keep
every translation at 160 characters or fewer. No two public pages may share a
title or a description.

## Canonical URLs and locales

`SeoComponents.canonical_url/1` builds the `<link rel="canonical">` and
`og:url` from `KanbanWeb.Endpoint.url/0` and the request path only. It never
reads the Host header, which a client controls. It drops the query string and
fragment and collapses repeated slashes, so `/pricing?locale=fr` and
`/pricing?utm_source=x` both name `/pricing` as their canonical.

That is what keeps search on one language. A crawler carries no session, so
`KanbanWeb.Plugs.Locale` serves it the default English page. The `?locale=`
variants all point their canonical at the bare English path. The app emits no
`hreflang` alternates, and the sitemap lists only bare paths. The page's
locale still reaches `og:locale` (for example `fr_FR`), with `en_US` as the
fallback.

`canonical_url/1` returns `nil`, and the canonical and `og:url` tags are left
out, for a path that carries a secret token (see `KanbanWeb.TokenPaths`),
including a percent-encoded one, and for a path with a `.` or `..` segment.

Live navigation inside one `live_session` does not re-render the root layout,
so the canonical keeps the path of the first full page load. Crawlers always
do full loads, so this affects only what a person's browser shows.

## Noindex

Noindex is opt-in. The `:browser` pipeline never adds it, so a new public page
is indexable without any extra step, and a page that must stay out of search
results has to ask for it. A token URL in a search result leaks the token,
which is why the token and account pages, as well as every signed-in page, ask
for it.

Noindex is a request to crawlers, not access control. A token page must still
validate its token.

There are two ways to mark a page, and the signed-in and token pages use both:

- `KanbanWeb.Plugs.PutNoindex`, through the router's `:put_noindex` pipeline,
  assigns `noindex: true` and sets the `x-robots-tag: noindex, nofollow`
  header. Pipe it second, straight after `:browser`, so a later plug that
  halts or redirects still carries the header. A controller that is not in
  such a scope can plug it directly, as
  `KanbanWeb.NotificationUnsubscribeController` does.
- `KanbanWeb.SeoOnMount` with `on_mount {KanbanWeb.SeoOnMount, :noindex}`
  assigns `noindex: true` on a LiveView, which renders the robots meta tag. A
  LiveView socket cannot set response headers, so the route also needs the
  `:put_noindex` pipeline for the header.

The `:admin`, `:require_sudo_mode` and `:require_authenticated_user` live
sessions list `SeoOnMount` in their `on_mount`. In the `:current_user`
session, each token and account LiveView declares it itself, and a nested
scope adds the pipeline. `/users/log-in` and `/users/register` stay
indexable, because people search for them.

A LiveView can also assign `noindex: true` for one state, as
`KanbanWeb.ResourcesLive.Show` does for an unknown guide id, which renders a
200 "Not Found" page.

## robots.txt

`KanbanWeb.SeoController` serves `/robots.txt` through the router's `:seo`
pipeline, which fetches no session and sets no cookie. Its body depends on the
host, so that no copy of the site is indexed as a duplicate of the real one.

It allows crawling, disallows `/api/` and names the sitemap only when both of
these hold:

- the deployment is indexable. `config/runtime.exs` sets
  `config :kanban, KanbanWeb.SeoController, indexable: true` only when the
  `SEO_INDEXABLE` environment variable is `"true"`, and only
  [`fly.production.toml`](../fly.production.toml) sets it. Never set it on the
  review app.
- the request came to the canonical host, the host of
  `KanbanWeb.Endpoint.url/0` (`www.stridelikeaboss.com` in production). The
  match is exact and ignores case.

Everywhere else it is `Disallow: /`. That covers the review app, the
`kanban-prod.fly.dev` origin and dev. `SEO_INDEXABLE` changes only
`robots.txt`, not a page's robots meta tag.

`robots.txt` does not disallow the noindex pages. A crawler sees a page's
noindex only by fetching it, so a disallowed page could still be listed from
links alone.

## The sitemap

`/sitemap.xml` is built by `KanbanWeb.SeoXML`. It lists the public marketing
pages in `SeoXML.public_paths/0` (the `@public_paths` attribute in
[`seo_xml.ex`](../lib/kanban_web/controllers/seo_xml.ex)) and one
`/resources/<id>` page per how-to from
`KanbanWeb.ResourcesLive.HowToData.all_how_tos/0`. `public_paths/0` also
includes `/docs` and one `/docs/<slug>` per published guide, from
`KanbanWeb.Docs.sitemap_paths/0`, so a guide added to that allow-list reaches
the sitemap with no further step ([Publishing Guides on the Site](docs-site.md)).
Every `<loc>` comes from
`canonical_url/1`, so it matches the canonical the page renders, and is
XML-escaped.

**A new public page must be added to `@public_paths` by hand.** The sitemap
test derives the `PageController` pages from the router and fails until a new
one is listed. A public LiveView page is not derived, so nothing fails if you
forget it. Leave out account pages such as log-in and register, and never list
a token, account, board, admin or API path.

## The changelog feed

`/changelog/feed.xml` is an Atom feed of releases, so a feed reader learns
when a new one ships. `KanbanWeb.SeoController` serves it through the same
`:seo` pipeline as the sitemap, as `application/atom+xml`. It is not on
`:browser`, whose `accepts` plug would refuse a reader that asks for
`application/atom+xml`.

The page and the feed share one source. `KanbanWeb.PageHTML` parses
`priv/changelog/body.html` once, at compile time, with
[`KanbanWeb.Changelog`](../lib/kanban_web/changelog.ex). The parse gives each
release section an `id` such as `release-3-2-0`, so the release file itself
never carries one. `PageHTML.changelog_body/0` is the page and
`PageHTML.changelog_releases/0` is the feed's list: every section headed
`[X.Y.Z] - YYYY-MM-DD`, newest first. `[Unreleased]` has not shipped and an
undated version has no date for an entry, so neither is in the feed.

[`KanbanWeb.ChangelogFeed`](../lib/kanban_web/changelog_feed.ex) builds one
entry per release, linking to `/changelog#release-X-Y-Z`. Each entry carries
the release notes as `<content type="html">`, without their `class` and
`style` attributes and XML-escaped, so a note cannot add markup to the feed.
Every URL comes from `canonical_url/1`, so it is absolute.

The changelog page advertises the feed by setting `:feed_path` and
`:feed_title` in its `seo(:changelog)` clause. No other page sets them, so no
other page links a feed. The feed is not in the sitemap, which lists pages.

## The Open Graph image

The default link-preview image is the 1200x630 PNG at
`priv/static/images/og/stride-og.png`. It is a raster image because Slack,
LinkedIn and X do not render an SVG preview. It is sent with its
`og:image:width`, `og:image:height` and a translated `og:image:alt` and
`twitter:image:alt`.

A page can set its own image with the `:og_image` assign, either as a path
starting with `/` or as an `http://` or `https://` URL.
`SeoComponents.og_image_url/1` makes a path absolute through the endpoint's
static URL and digested static path, because link-preview crawlers ignore a
relative image. A page's own image carries no width, height or alt, since
those describe the default image. A value it cannot make absolute, such as a
protocol-relative `//host/...`, falls back to the default.

## Structured data

`SeoComponents.structured_data/1` renders a schema.org JSON-LD block. A page
calls it from its own template, not from the layout, and passes the request's
CSP nonce:

```heex
<.structured_data data={pricing_structured_data()} nonce={assigns[:csp_nonce]} />
```

Two pages render one today, both built in
[`page_html.ex`](../lib/kanban_web/controllers/page_html.ex). The home page
has an `Organization` from `home_structured_data/0`. The pricing page has a
`SoftwareApplication` with one `Offer` per fixed-price plan from
`pricing_structured_data/1`. There is deliberately no rating or review.

Build `data` in code, never from request params. `encode_json_ld/1` encodes it
with `Jason.encode!(data, escape: :html_safe)`, so every `<` becomes `\u003C`
and every `/` becomes `\/`. No value can then close the script element or open
a comment, and only that encoded string is emitted unescaped. The JSON is
escaped rather than the HTML because a browser does not decode HTML entities
inside a script element. The content security policy is never loosened for
the block.

### Prices have one source

The plan prices are written down only in
[`KanbanWeb.Pricing`](../lib/kanban_web/pricing.ex). The pricing page shows
them through `Pricing.price_label/1`, and the structured data turns
`Pricing.fixed_price_plans/1` into its offers, so the page and the block
cannot disagree. A plan priced on request has no amount and is left out of the
structured data.

The display currency is the single `@currency` attribute. `price_label/1` has
a clause only for a currency it knows how to word, so switching the currency
without adding a label raises rather than rendering a page whose text no
longer matches its structured data. Plan names are English literals rather
than `gettext`, because the structured data stays in one language whatever the
page locale is.

## What never goes in a tag

Never put a token, a session value, an email address or other personal data in
a meta tag, the structured data, the sitemap or a log line. Every value in
them is public and cached by crawlers, and the same holds for the changelog
feed. That is why the canonical drops the query string and why a token path
gets no canonical at all.

## The guard tests

These run as part of `mix test`:

- [`test/kanban_web/controllers/page_controller_seo_test.exs`](../test/kanban_web/controllers/page_controller_seo_test.exs)
  walks every `GET` route on `PageController`. It fails when a page lacks a
  title or description, when two pages share one, or when a description is
  outside the lengths above or untranslated. It does not cover LiveView pages
  apart from the resources pages it names.
- [`test/kanban_web/seo_noindex_test.exs`](../test/kanban_web/seo_noindex_test.exs)
  fails "every browser GET route is classified" until a new browser `GET`
  route is either in its public list or behind `:put_noindex`. A controller
  that plugs `KanbanWeb.Plugs.PutNoindex` directly also needs its path in the
  test's `@controller_noindex_paths`. It also fails
  "every live_session is classified as signed-in or public" until a new
  `live_session` is listed.
- [`test/kanban_web/components/seo_components_test.exs`](../test/kanban_web/components/seo_components_test.exs)
  covers `seo_head/1`: the canonical rules, escaping, the fallbacks, the robots
  tag and `og:locale`.
- [`test/kanban_web/controllers/seo_controller_test.exs`](../test/kanban_web/controllers/seo_controller_test.exs)
  covers `robots.txt` per host and fails until a new `PageController` page is
  in the sitemap.
- [`test/kanban_web/controllers/changelog_feed_test.exs`](../test/kanban_web/controllers/changelog_feed_test.exs)
  covers the changelog parse, the feed's Atom shape and escaping, and the
  `rel="alternate"` link. It fails when the page and the feed list different
  releases, or when an entry links to an `id` the page does not have.
- [`test/kanban_web/controllers/og_image_test.exs`](../test/kanban_web/controllers/og_image_test.exs)
  covers the default and per-page images.
- [`test/kanban_web/components/structured_data_test.exs`](../test/kanban_web/components/structured_data_test.exs)
  covers the JSON-LD blocks and their escaping.

- [`test/kanban_web/controllers/docs_controller_test.exs`](../test/kanban_web/controllers/docs_controller_test.exs)
  and [`test/kanban_web/docs_test.exs`](../test/kanban_web/docs_test.exs)
  cover the published guides at `/docs`: their titles and descriptions, the
  allow-list, and that every link on every guide resolves.

So a new public `PageController` page needs a `seo/1` clause, an entry in the
noindex test's public list and an entry in `@public_paths`. A new public
LiveView page needs the same, except that nothing fails if it lacks a title,
a description or a sitemap entry.
