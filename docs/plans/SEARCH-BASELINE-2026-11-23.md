# Search baseline: 2026-11-23

This note records where Stride stood in search, links and AI assistants on
the day the site was registered with Google and Bing. It is the "before"
that [Gap 3](SEARCH-VISIBILITY-GAP-ANALYSIS.md#gap-3-no-baseline) of the
search visibility gap analysis asks for. Later checks repeat the same steps
with the same questions and compare against these numbers.

Fill in each blank (`…`) once. Keep the raw numbers and answers, not a
summary, and don't change a filled-in value later: a corrected baseline
can't be compared with anything.

- **Date the checks were run:** …
- **Run by:** …
- **Location and search language:** … (results vary by country)

## What was live on this date

### Measurement

| Tool | Started | Note |
|---|---|---|
| Google Search Console | 2026-11-23 | Domain property, verified by DNS TXT record; sitemap submitted |
| Bing Webmaster Tools | 2026-11-23 | Verified, sitemap submitted |
| IndexNow | 2026-11-23 | Through Cloudflare Crawler Hints |
| Umami analytics | **Not on** | W2897 was built on 2026-11-22 but its settings aren't set in production, so visitor numbers start later than search numbers (Gap 2) |

### Search and discovery work already shipped

The completion dates are from Stride and are in UTC. A completed task isn't
live until the next production deployment, so fill in the live date from the
deployment that carried it; that is the date to measure from.

**G559, the search groundwork** (goal completed 2026-11-21):

| Task | What it added | Completed | Live in production |
|---|---|---|---|
| W2888 | Shared SEO head in all three root layouts | 2026-11-20 | … |
| W2889 | A title and meta description per public page, in all seven locales | 2026-11-20 | … |
| W2890 | `noindex` on token, account and signed-in pages | 2026-11-20 | … |
| W2891 | `robots.txt` per host and `sitemap.xml` | 2026-11-20 | … |
| W2892 | Default Open Graph image | 2026-11-20 | … |
| W2893 | Organization and SoftwareApplication structured data | 2026-11-21 | … |
| W2894 | `docs/seo.md` | 2026-11-21 | … |

**G560, the discovery content** (goal still open):

| Task | What it added | Completed | Live in production |
|---|---|---|---|
| W2895 | Marketing nav and footer links to the Stride posts | 2026-11-21 | … |
| W2896 | Atom feed of releases at `/changelog/feed.xml` | 2026-11-21 | … |
| W2897 | Umami analytics and the sign-up and click events | 2026-11-22 | Built, not switched on |
| W2898 | Guides published at `/docs` | 2026-11-21 | … |
| W2899 | A page per agent runtime at `/integrations/:runtime` | 2026-11-21 | … |
| W2900 | `/llms.txt` and the AI crawler policy | 2026-11-21 | … |
| W2901 | Comparison pages against GitHub Projects, Linear and Jira | 2026-11-21 | … |
| W2902 | Public demo board at `/demo` | 2026-11-21 | … |
| W2904 | Preview image per guide and integration page; `/docs` links in Resources, footer and mobile menu | 2026-11-21 | … |
| W2905 | Double opt-in email signup for release announcements | 2026-11-21 | … |
| W2906 | Listing copy and a submission checklist for directories | Not done | Not done |

W2903, social proof, is no longer on the board.

## 1. Ahrefs Webmaster Tools

Verified through Google Search Console.

| Measure | Value |
|---|---|
| Domain Rating | … |
| Referring domains | … |
| Backlinks | … |
| Organic keywords | … |
| Estimated organic traffic | … |
| Site Audit Health Score | … |

**Top linking sites** (up to 10, from the export):

1. …

**Top Site Audit issues:**

1. …

## 2. Search Console and Bing

**Google Search Console**

| Report | Value |
|---|---|
| Performance: clicks, last 3 months | … |
| Performance: impressions, last 3 months | … |
| Performance: earliest date with data | … (history from before verification is a better baseline than zero) |
| Links: linking sites | … |
| Pages: indexed | … (check again within a week if it says processing) |
| Pages: not indexed | … |
| Pages: date read | … |

**Top linking sites in Search Console:**

1. …

**Bing Webmaster Tools**

| Report | Value |
|---|---|
| Search Performance: clicks | … |
| Search Performance: impressions | … |
| Backlinks: referring domains | … |

## 3. Searches by hand

Use a private window, signed out.

| Search | Google | Bing |
|---|---|---|
| `site:stridelikeaboss.com`: results shown | … | … |
| "Stride kanban": our position, if any | … | … |
| "Stride AI agents": our position, if any | … | … |
| "Stride for AI agents": our position, if any | … | … |
| "kanban for AI agents": on page 1? | … | … |
| "AI agent kanban": on page 1? | … | … |

**Other products named Stride that rank above us:** …

## 4. AI assistants

**Ahrefs AI Visibility Checker**

| Query | Result |
|---|---|
| "Stride" | … |
| "kanban for AI agents" | … |

**The fixed questions.** Ask each one in a fresh chat with web search on.
Don't reword them later: [Gap 6](SEARCH-VISIBILITY-GAP-ANALYSIS.md#gap-6-ai-visibility-is-prepared-but-not-measured)
repeats this check each quarter, and a changed question can't be compared.

1. "What's a good task board for coordinating AI coding agents?"
2. "How can I give Claude Code or Codex a kanban board to work from?"
3. "What is Stride for AI agents?"

Record for each answer whether Stride is mentioned and which tools are named
instead. Save the full text or a screenshot alongside this note.

| Assistant | Q1: Stride mentioned? Others named | Q2: Stride mentioned? Others named | Q3: Stride mentioned? Others named |
|---|---|---|---|
| ChatGPT | … | … | … |
| Claude | … | … | … |
| Gemini | … | … | … |
| Perplexity | … | … | … |
| Copilot | … | … | … |

## When to check again

- **Within a week:** Search Console's Pages report, if it said processing.
- **Monthly:** referring domains and backlinks in Ahrefs and Search Console
  (Gap 5).
- **Quarterly:** the AI Visibility Checker and the fixed questions (Gap 6),
  plus the searches by hand.
