# Blog drafts

This folder is a drafting area for posts about Stride. Nothing here is
published from this repository, rendered by the app, or shipped in a release.

Finished posts are copied into the Hugo blog repository and published on
cheezyworld.ca. Every Stride post carries the Stride tag, so the tag page
lists them all:

- Posts: https://cheezyworld.ca/tags/stride/
- Feed: https://cheezyworld.ca/tags/stride/index.xml

The marketing footer links to the tag page through
`KanbanWeb.MarketingClosing.blog_url/0` while the `:blog` flag is off for the
visitor; with the flag on, its Blog link goes to `/blog` instead. Change the
URL there, and only there.

Do not render these drafts or list the blog in `sitemap.xml`: the posts live
on cheezyworld.ca, and a second copy here would be duplicate content. The one
exception is the `:blog` experiment (W2950, W2951), which serves posts copied
into `priv/blog/posts/` at `/blog` only to visitors the flag is on for, with
noindex and outside the sitemap.

To end the experiment by making the blog public: delete the flag gate in
`KanbanWeb.BlogController`, drop `:put_noindex` from the blog's router scope
and reword its comment, add `/blog` and each `/blog/<slug>` to
`KanbanWeb.SeoXML.public_paths/0` and to `@public_paths` in
`test/kanban_web/seo_noindex_test.exs`, invert the W2951 test there and the
flag-off tests in `test/kanban_web/controllers/blog_controller_test.exs`,
reword the blog paragraph in `docs/seo.md` and this section, keep only the
`/blog` Blog link in `KanbanWeb.MarketingClosing.marketing_footer/1` (drop its
`:blog` check and the flag-off tests in
`test/kanban_web/components/marketing_components_test.exs`), then remove the
`:blog` flag as `docs/feature-flags.md` describes. To end it by dropping the
blog, delete the controller, its templates, the route and those tests instead,
and keep only the `blog_url()` Blog link in the footer, with its flag check and
flag-on tests removed: a leftover `~p"/blog"` warns once the route is gone, and
a leftover `:blog` check raises once the flag is unregistered.

The folder is listed in `.gitignore`, so drafts stay local until they are
published. This README is the one tracked file here: it was added with
`git add -f`, and git keeps tracking it despite the ignore rule.
