# Writing Blog Posts

The blog at `/blog` is an experiment behind the `:blog` feature flag. Its posts
are markdown files committed to this repository and compiled into the app, so
anyone who can open a pull request can write one. This page is for a new
blogger: where a post and its author go, what the front matter must say, what
breaks the build, and how to see the post before anyone else does.

## Where posts live

Each post is one markdown file directly in
[`priv/blog/posts/`](../priv/blog/posts/). Only files ending in lower-case
`.md` are read; files in subdirectories, and files ending in `.MD` or
`.markdown`, are skipped without an error.

- Name the file after the post in lower case with hyphens, such as
  `how-much.md`. The file name is not used in the URL; the `slug` key is.
- A post's page is `/blog/<slug>`. Two published posts with the same slug
  fail the build. Drafts are left out before that check, so a draft can share
  a slug with a published post without an error.
- The index at `/blog` lists every post that is not a draft, newest `date`
  first.

[`KanbanWeb.Blog`](../lib/kanban_web/blog.ex) reads the directory when the app
compiles, through `KanbanWeb.Blog.Loader`. Nothing is read from disk per
request. Adding or removing a post or an image makes the module recompile, so
the next compile picks the change up.

`docs/blog/` is a different, git-ignored folder for local drafts of posts
published on cheezyworld.ca. Nothing in it is rendered by the app.

## Front matter

A post starts with a front matter block between two `---` lines, then the
markdown body. [`KanbanWeb.Blog.FrontMatter`](../lib/kanban_web/blog/front_matter.ex)
parses it strictly and accepts exactly these seven keys:

| Key | Required | Value |
| --- | --- | --- |
| `title` | Yes | A quoted string, the page title |
| `date` | Yes | A quoted ISO 8601 date and time with an offset or `Z`, such as `'2026-02-05T07:39:01-05:00'`, read with `DateTime.from_iso8601/1` |
| `draft` | No, defaults to `false` | Bare `true` or `false`, not quoted |
| `tags` | No, defaults to `[]` | A list of quoted strings, such as `["AI", "Agile"]`. A tag cannot contain a comma |
| `author` | Yes | The `id` of an author in `KanbanWeb.Blog.Authors`, bare or quoted |
| `slug` | Yes | A quoted string, the last part of the URL. Use lower-case letters, digits and hyphens |
| `description` | Yes | A quoted string of 150 to 160 characters, the page's meta description and the summary on the index |

An example:

```markdown
---
title: 'How Much Should I Spend?'
date: '2026-02-05T07:39:01-05:00'
draft: false
tags: ["AI", "Agile", "Continuous Delivery"]
author: cheezy
slug: 'how-much'
description: "How much money should you spend on AI tools? Prices in Canadian dollars for a developer learning at home, a solo developer seeking throughput, and companies."
---

The body of the post starts here.
```

Each line is `key: value`: a lower-case key, a colon, then at least one space
or tab. A single-quoted string can hold a `'` written twice (`'It''s here'`); a
double-quoted string cannot hold a `"` or a `\`. Blank lines in the block are
allowed. The file must start with the opening `---` line, and the closing
`---` must be followed by a line break. This is a small subset of Hugo front
matter, not YAML, so anything else (comments, multi-line values, other keys)
fails the build.

The parser checks that each required key is there and has the right form, not
what it says: an empty `title`, `slug` or `description`, or a `slug` with
spaces or slashes, does not fail the build. The 150 to 160 character
description is checked by the tests, as [Updating the tests](#updating-the-tests)
describes, not by the parser.

A post with `draft: true` is left out everywhere, including for people the
flag is on for. There is no draft preview: to see a post on the site, set
`draft: false` and use the flag, as [Previewing a post](#previewing-a-post)
describes.

## Adding an author

Every post names an author, and the author must be listed in `@authors` in
[`KanbanWeb.Blog.Authors`](../lib/kanban_web/blog/authors.ex). To add one,
append a map with these keys:

- `id`: the value posts put in `author`, lower case, such as `"cheezy"`;
- `name`: the name shown on the index, under the post and in the author card;
- `bio`: one line shown in the card at the end of each post;
- `avatar`: `"/images/blog/authors/<id>.jpg"`, with the image committed as
  `priv/static/images/blog/authors/<id>.jpg`;
- `links`: a list of `%{label: "...", url: "..."}` maps for public profiles.

Only public profile details belong there. Never add an email address.

## Adding images

1. Put the file directly in `priv/static/images/blog/`. Its name may use
   letters, digits, `-` and `_` only, and it must end in lower-case `.png`,
   `.jpg`, `.jpeg`, `.gif` or `.webp`. An upper-case extension such as
   `.PNG` is refused with the same "not a local /img/ image" error as an
   external URL.
2. Reference it in the post as `/img/<file>`, with alt text that says what
   the image shows:

   ```markdown
   ![Monthly cost of one developer using AI tools](/img/one-developer-cost.png)
   ```

The renderer serves it from `/images/blog/<file>` and lazy-loads it. Write
`/img/`, not `/images/blog/`, in the post: any other source is refused,
including an external URL and a `data:` URI. The blog serves images only from
the site itself, so a post never loads third-party content and the Content
Security Policy, which does not allow images from other hosts, never needs
widening.

## What fails the build

Every problem raises `ArgumentError` when the app compiles, so a bad post
never reaches a page. The message names the post's file, except for a shared
slug, where it names the slug. The build fails when a post:

- has no front matter block, a line that is not `key: value`, or a value in
  the wrong form or type;
- uses a key that is not one of the seven above, or uses a key twice;
- leaves out `title`, `date`, `author`, `slug` or `description`;
- has a `date` that `DateTime.from_iso8601/1` cannot read, including one
  with no offset;
- names an author who is not in `KanbanWeb.Blog.Authors`;
- shares its slug with another published post;
- links to anything but an `http`, `https` or `mailto` URL. The one
  exception is `/post/<slug>/`, which becomes a link to that post on
  cheezyworld.ca;
- has an image that is not a local `/img/` image, whose file is missing from
  `priv/static/images/blog/`, or that has no alt text.

Raw HTML in a post is not an error: it is escaped and shows as text.

## Updating the tests

The blog's tests pin the posts and authors that exist today, so adding a post
or an author fails `mix precommit` until you update them:

- `test/kanban_web/blog_test.exs` asserts the exact list of posts, newest
  first, with each post's slug, title, date, tags and author; that every
  description is 150 to 160 characters long; and that the author ids are
  exactly `["cheezy"]`.
- `test/kanban_web/controllers/blog_controller_test.exs` lists every slug, in
  index order, in `@slugs`.

Add the new post or author to those assertions in the same change.

## Previewing a post

The blog pages answer 404 unless the `:blog` flag is on for the visitor, so
the way to see a post is to turn the flag on for your own account:

1. Add the post with `draft: false` and run the app locally, or deploy it.
2. Have a site admin open `/admin/feature-flags`, find **Blog (experiment)**,
   and turn it on for your account, as [The admin page](feature-flags.md#the-admin-page)
   in the feature flags guide describes.
3. Sign in and open `/blog` or `/blog/<slug>`.

Do not turn the flag on for everyone to preview a post: that publishes the
blog to every visitor.

## Why the pages are hidden from search

Both blog pages send noindex, through the `:put_noindex` pipeline in their own
router scope, and neither is in `KanbanWeb.SeoXML.public_paths/0`, so the
sitemap does not list them. The posts are copies of posts published on
cheezyworld.ca, and a second indexed copy would be duplicate content while the
experiment runs. [Search and Social Tags](seo.md) covers noindex and the
sitemap, and [the blog drafts README](blog/README.md) lists the steps for
ending the experiment.

## Not supported yet

The experiment covers markdown posts, authors, tags shown as labels, and local
images. It does not have:

- videos, embeds such as YouTube, or any other raw HTML;
- a page per tag;
- a feed;
- search;
- redirects from the posts' addresses on cheezyworld.ca;
- the rest of the cheezyworld.ca posts. Only two are copied so far.

## See also

- [Feature Flags](feature-flags.md) for how the `:blog` flag is checked and
  toggled.
- [Publishing Guides on the Site](docs-site.md) for the `/docs` guides, the
  other markdown the app compiles in and renders.
- [Documentation Link Contract](doc-link-contract.md) for the rules this
  page's links follow.
