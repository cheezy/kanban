# Blog drafts

This folder is a drafting area for posts about Stride. Nothing here is
published from this repository, rendered by the app, or shipped in a release.

Finished posts are copied into the Hugo blog repository and published on
cheezyworld.ca. Every Stride post carries the Stride tag, so the tag page
lists them all:

- Posts: https://cheezyworld.ca/tags/stride/
- Feed: https://cheezyworld.ca/tags/stride/index.xml

The marketing nav, the mobile marketing menu and the marketing footer link to
the tag page through `KanbanWeb.MarketingClosing.blog_url/0`. Change the URL
there, and only there.

Do not add a `/blog` route, render these drafts, or list the blog in
`sitemap.xml`: the posts live on cheezyworld.ca, and a second copy here would
be duplicate content.

The folder is listed in `.gitignore`, so drafts stay local until they are
published. This README is the one tracked file here: it was added with
`git add -f`, and git keeps tracking it despite the ignore rule.
