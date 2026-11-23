# Search visibility: our plan compared with Ahrefs and Umami

This document compares the work in goals G559 and G560 with what Ahrefs sells
and with what Umami, the analytics tool planned for task W2897, measures. It
then lists the gaps in our current plan and what it would take to close each
one. It was written on 2026-11-21 from the public Ahrefs and Umami sites and
the state of both goals on that day. It was updated on 2026-11-23, when Gap 1
was closed.

## The short version

Ahrefs, Umami and our two goals work on three different layers of the same
problem:

| Layer | Question it answers | Who covers it |
| --- | --- | --- |
| Make the site findable | Can search engines and AI assistants read, trust and show our pages? | **G559 and G560** |
| Measure our own visitors | Who came, from where, and what did they do? | **Umami** (W2897) |
| Measure the outside world | What do people search for, who links to us, do AI assistants mention us, how do we rank? | **Ahrefs** |

Our plan is strong on the first layer, has a tool chosen for the second, and
has almost nothing for the third. The most serious gaps are not exotic SEO
features. They are basic measurement:

1. **Nobody had told Google or Bing the site exists.** The site had never been
   added to Google Search Console or Bing Webmaster Tools, so the sitemap from
   W2891 had never been submitted and we couldn't see a single search query,
   impression or ranking. **Now closed:** on 2026-11-23 the site was verified
   in both and the sitemap submitted to each (see Gap 1).
2. **W2897 as first written could not see a signup.** The sign-up page used a
   layout the analytics script was not added to, and a successful sign-up
   lands on a page the script never reached. Without a signup event, no Umami
   funnel, goal or attribution report can say which page or channel brings
   users. **Now built:** W2897 was rewritten on 2026-11-21 to use Umami and
   record a signup event, and was built on 2026-11-22. It records nothing
   until the Umami settings are set in production (see Gap 2).
3. **We have no baseline.** Most of G559 and five G560 tasks have shipped, and
   nothing recorded where search traffic, backlinks or AI mentions stood
   before them, so their effect can't be measured.

All three are cheap to fix, and none needs a paid Ahrefs plan. Gap 1 was
closed on 2026-11-23. Gap 2's code was built on 2026-11-22 and needs only its
Umami settings and dashboard. Gap 3 still needs a person to act.

## What Ahrefs does

Ahrefs is a paid marketing data company, headquartered in Singapore and
self-funded. It runs its own crawler and its own data centres and sells access
to what they collect through a suite of tools. The figures below are what its
site states:

- **Its own crawl of the web.** AhrefsBot crawls 7–8 billion pages a day. The
  link index is refreshed every 15–30 minutes and goes back about 16 years.
- **Keyword data.** About 29 billion filtered keywords across 217 countries and
  regions, each with an estimated search volume.
- **Traffic estimates** for any site, from 543 million ranking keywords.
- **AI answer data.** About 585 million prompts used to measure how often AI
  assistants mention a brand.

Its tools turn that data into answers:

| Tool | What it does |
| --- | --- |
| Site Explorer | Any site's backlinks, ranking keywords and estimated search traffic |
| Keywords Explorer | What people search for, how often, and how hard it is to rank |
| Site Audit | Crawls your site and reports technical SEO problems |
| Rank Tracker | Where your pages rank for chosen keywords, over time |
| Content Explorer | Who mentions you, and pages that might link to you |
| Brand Radar and Prompt Tracking | How often ChatGPT, Gemini, Perplexity, Copilot, Claude and Google's AI features mention your brand |
| Web Analytics | Its own cookie-free visitor analytics, similar to Umami |
| Webmaster Tools | Free: backlinks and a site audit for a site you prove you own |

Plans run from $29 to $449 a month. Most of the AI-visibility work is sold as
add-ons, from $199 a month. The free tools include Webmaster Tools, an AI
Visibility Checker and trackers for Google's AI Overviews and AI Mode.

## What Umami does

Umami is open-source, cookie-free analytics for your own site. It only sees
visitors who load a page carrying its script.

- **Measures:**
  - page views, visitors, visits, bounce rate and visit duration;
  - referrers, UTM parameters and ad click IDs;
  - country, region and city, from IP geolocation;
  - browser, operating system, device and language;
  - optional Core Web Vitals (`data-performance`).
- **Custom events** with properties, fired from a `data-umami-event` attribute
  or `umami.track()`, or sent server-side to `/api/send`.
- **Reports:**
  - funnels, journeys and retention;
  - goals and attribution (first click or last click);
  - UTM, revenue, segments, cohorts and comparison with an earlier period.
- **Privacy:**
  - no cookies;
  - the IP address is hashed into a visitor ID, not stored as a field;
  - the salt rotates monthly by default.

  Its pricing page says no consent banner is needed. Its FAQ is more careful
  and says it depends on what else the site does.
- **Hosting:**
  - **Self-hosted:** free under the MIT licence; needs Node 20.19+ and
    PostgreSQL 12.14+.
  - **Umami Cloud:** Hobby is free (100K events a month, 1 site, 6-month
    retention, no API). Pro is $20 a month (1M events, API, MCP, Google Search
    Console report). Business is $200 a month.

  On Cloud, every stored event property counts as an event.
- **Does not do:**
  - keyword research, backlinks or rank tracking;
  - any tracking of AI assistants.

  It also doesn't label ChatGPT or Perplexity as AI sources; they appear as
  ordinary referrers. Its one search-engine feature, the Google Search
  Console report, is on Cloud Pro and above only, not self-hosted.

## Where our plan stands

**G559, the search groundwork (all seven tasks done).**
- A shared `seo_head`, plus a title and description for every page in all
  seven languages (W2888, W2889).
- `noindex` on private pages, a `robots.txt` that answers per host, and a
  sitemap (W2890, W2891).
- A default preview image, structured data, and `docs/seo.md` (W2892–W2894).

The conventions are in [the SEO conventions document](../seo.md).

**G560, the discovery content.**

- **Done:**
  - the blog links to cheezyworld.ca (W2895);
  - the release feed (W2896);
  - `/docs` (W2898);
  - `/integrations` (W2899);
  - `/llms.txt` and the AI crawler policy (W2900);
  - analytics (W2897), built on 2026-11-22 but not yet switched on.
- **Open:**
  - comparison pages (W2901);
  - the public demo board (W2902);
  - social proof (W2903);
  - per-page preview images and the `/docs` links (W2904);
  - the release email list (W2905);
  - the directory listing kit (W2906).

## Capability by capability

| Capability | Ahrefs | Umami | Our plan | Gap |
| --- | --- | --- | --- | --- |
| Pages search engines can read and trust (titles, canonical URLs, sitemap, structured data) | Audits for it | No | **Done** (G559) | None |
| Telling search engines the site exists, and submitting the sitemap | Free Webmaster Tools reads Search Console | Cloud Pro shows Search Console data | **Done** 2026-11-23: Search Console and Bing Webmaster Tools | **Gap 1**, closed |
| Search queries, impressions, clicks and rankings for our pages | Rank Tracker, GSC Insights | Cloud Pro, via Search Console | Search Console, collecting since 2026-11-23 | **Gap 1**, closed |
| Visitors, sources and campaigns | Web Analytics | **Yes** | **Built** (W2897, with Umami), off until its settings are set | Hosting choice still open; campaign tags not recorded yet (see Gap 2) |
| Which page or channel produces sign-ups | Not its focus | Funnels, goals, attribution, but only with a sign-up event | **Built** (W2897: signup and click events) | **Gap 2**, closes once Umami is switched on and the funnel is set up |
| What people search for, to choose topics and wording | Keywords Explorer | No | Topics chosen by judgement | **Gap 4** |
| Backlinks: who links to us, gaining links | Site Explorer, Content Explorer | No | W2906 lists Stride in directories; nothing measures links | **Gap 5** |
| Readable by AI crawlers | Audits AI bot crawling | No | **Done** (W2900, llms.txt) | None |
| Whether AI assistants mention or recommend Stride | Brand Radar, free AI Visibility Checker | No | Not planned | **Gap 6** |
| Visits arriving from AI assistants | Bot Analytics shows crawlers, not visits | Referrers only, unlabelled | Not planned | **Gap 6** |
| Health of the live site: broken links, redirects, speed | Site Audit | Web Vitals only | Guard tests in CI; no crawl of production | **Gap 7** |
| A before-and-after record | Historical data | From the day it starts | None | **Gap 3** |
| What competitors rank for | Site Explorer, Content Gap | No | W2901 compares features, not search demand | Part of **Gap 4** |
| Brand mentions across the web | Content Explorer, Firehose | No | Not planned | Low priority, see below |

## The gaps

### Gap 1: the site is not registered with any search engine

**Status: closed on 2026-11-23.** What was done, all without a code change:
- **Google Search Console:** a Domain property for `stridelikeaboss.com`,
  verified by a DNS TXT record in Cloudflare. It covers `www`, the bare domain
  and every subdomain. The sitemap
  `https://www.stridelikeaboss.com/sitemap.xml` is submitted.
- **Bing Webmaster Tools:** the site is verified and the same sitemap is
  submitted.
- **IndexNow:** Cloudflare's Crawler Hints is switched on. It sends IndexNow
  notices to Bing and the other engines that use it whenever pages change.
  Google doesn't use IndexNow, so it relies on the sitemap.

Search Console and Bing only report from the day a site is verified, so
2026-11-23 is the start date for Gap 3's baseline.

**What was missing.** The site had not been added to Google Search Console or
Bing Webmaster Tools. There was no verification meta tag in the code. The
domain did have a `google-site-verification` TXT record, beside an SPF record
for Google's mail servers, most likely from setting up Google Workspace, but
it had never been used to add the site to Search Console. So:
- the sitemap from W2891 had never been submitted;
- nobody got Google's or Bing's reports on indexing errors, mobile problems
  or manual penalties;
- not one search query or ranking for the site was visible anywhere.

**Why it matters.** Search Console is the only source of *actual* search
queries and positions for our pages; Ahrefs and every other tool estimate
them. It is free. It also feeds every other option here:
- Umami Cloud Pro's search report reads it;
- Ahrefs Webmaster Tools can verify ownership through it.

Bing matters more than its market share suggests: its index is one of the
sources behind Copilot and ChatGPT search.

**Fix, as first planned.** A small human task:
- add DNS records for both services on `stridelikeaboss.com`;
- submit `https://www.stridelikeaboss.com/sitemap.xml` to each;
- record the date.

DNS verification needs no code change. Optionally, add IndexNow so Bing
hears about new pages straight away; Ahrefs lists IndexNow among its own
tools. All of it, IndexNow included, was done on 2026-11-23, as the status
above records.

### Gap 2: analytics can't see a sign-up

**Status: built, not yet switched on.** W2897 was rewritten on 2026-11-21
and built on 2026-11-22, and the code is in production: the `/privacy` page
already describes Umami. Analytics stays off until all three Umami settings
are set, and on 2026-11-23 the production content security policy still had
no Umami addresses, so nothing is recorded yet.
[The analytics guide](../analytics.md) has the configuration, the events and
the dashboard steps.

What closing the gap still takes, all done by a person:
- **Choose the hosting,** Umami Cloud or self-hosted, and on Cloud the US or
  EU region (item 4 below).
- **Create the website** for `www.stridelikeaboss.com` in Umami and copy its
  website ID.
- **Set `UMAMI_SCRIPT_URL`, `UMAMI_WEBSITE_ID` and `UMAMI_HOST_URL`** on
  production, all three in one `fly secrets set`. The boot stops when only one
  or two are set, when a URL isn't `https`, or when the ID isn't a UUID.
- **Run the checks W2897 handed back:**
  - register a test account and see one `signup` event;
  - copy an install command on `/integrations/codex` and see
    `install-command-copied`;
  - confirm no recorded URL has a query string or an email address;
  - confirm `/pricing`'s content security policy lists the two Umami
    addresses;
  - confirm a signed-in board page loads no tracker.
- **Set up the dashboard:** the `signup` goal, and the funnel from a landing
  page through `/users/register` to the `signup` event.

Two limits of what was built:
- **Campaign tags aren't recorded.** `data-exclude-search` drops every query
  string, so `utm_` tags and Google's ad click ID (`gclid`) are lost along
  with emails and tokens. Sign-ups can be traced to a page and a referring
  site, not to a campaign. Allowing only those parameters through would be a
  small code task, worth doing before any ads or tagged campaigns.
- **`/privacy` doesn't yet say where the data is kept or for how long**
  (item 6 below). Once the hosting and region are chosen, it needs that
  sentence in all seven languages.

**What was missing.** W2897 added the script to the `marketing` and `app_chrome`
layouts, on public pages only. That left three holes:
- **The sign-up form was never tracked.** `/users/register` and `/users/log-in`
  render in the `root` layout (with the `auth_frame` component), which W2897
  did not touch.
- **A finished sign-up was never tracked.** After registering, the user is
  redirected to `/users/confirmation-pending`, another `root` layout page the
  script never reached.
- **No events were defined,** so nothing recorded the actions that show
  interest without a sign-up:
  - copying an install command on an `/integrations` page;
  - clicking through to GitHub;
  - opening the API reference.

**Why it matters.** Umami's funnel, goal and attribution reports only work
with a conversion step. Without one, Umami can say how many people visited
`/integrations/codex` but not whether any of them signed up. That is the
question W2897's own "why" says analytics exists to answer: "which bets
paid".

**How W2897 now covers it.**
- **Which pages load the script.** Each page opts in through an `:analytics`
  assign, and the default is off, so the layout no longer decides. Every
  public page opts in, and so do `/users/register`, `/users/log-in` and
  `/users/confirmation-pending`. Signed-in pages never load the script, and
  neither do pages with a token in their path (`/users/confirm/:token`,
  `/users/reset-password/:token`, `/invitations/:token`).
- **`signup`.** After a successful registration the user is redirected to
  `/users/confirmation-pending`. The registration sets a one-time flag, and
  that page sends the event once, from the visitor's browser. A failed
  registration, a reload or a direct visit sends nothing.
- **`install-command-copied`**, with the runtime's slug, when someone copies
  an install command on an `/integrations` page. Those pages have no copy
  buttons, so a small script listens for the browser's copy event on the
  command text.
- **`github-clicked` and `get-started-clicked`**, each with a `location`
  property, on the GitHub links and on the sign-up calls to action in the nav,
  hero, closing section, pricing, product and workflows pages.
- **Dashboard setup,** done by hand and documented in the new
  `docs/analytics.md`: one funnel (landing page, `/users/register`, the
  `signup` event) and one goal (the `signup` event).

**What changed from the fix first suggested here.**
- **The signup event comes from the browser.** The first suggestion was to
  send it from our server to Umami's `/api/send`. An event sent that way
  would not join the visitor's Umami session, so the funnel and attribution
  reports couldn't link it to the pages that led there.
- **No event for opening the API reference.** It can be added later by
  following `docs/analytics.md`.
- **Query strings must never be recorded.** `/users/confirmation-pending`
  carries the new user's email in its query string, so
  `data-exclude-search` is required, not just advisable.

### Gap 3: no baseline

**What's missing.** G559 is finished and G560 is half done, with no "before"
measurement of indexed pages, search clicks, backlinks or AI mentions. Search
Console only shows data from the day a site is verified, and Umami only from
the day its script goes live.

**Why it matters.** Without a baseline we can't tell which goal paid off, or
whether the next one is worth building.

**Fix.** Gap 1 and W2897 start the clock. Gap 1 started it on 2026-11-23;
switch on W2897's analytics soon. As close to 2026-11-23 as possible, record a one-off
snapshot in a short dated note:
- Ahrefs Webmaster Tools: referring domains and site-audit score;
- the free AI Visibility Checker for "Stride" and for "kanban for AI agents";
- a `site:stridelikeaboss.com` search on Google and Bing.

### Gap 4: topics are chosen without search data

**What's missing.** The comparison pages (W2901), the integration pages and
the descriptions written in W2889 rest on judgement about what people
search for. Nobody checked whether anyone searches for "Linear for AI
agents", "Claude Code task board" or "Jira alternative for agents", or how
the competitors already ranking for those are doing.

**Why it matters.** A page about a question nobody asks ranks first for
nothing. A small change in wording, such as "AI agent kanban" rather than
"kanban for AI agents", can be the difference between one search a month
and a thousand.

**Fix.** Before W2901 is built, add a short research step:
- take its candidate queries from Search Console (once Gap 1 has run for a
  few weeks), from Ahrefs' free keyword tools, or from one month of an
  Ahrefs Starter plan ($29);
- put the results in W2901's description, so each comparison page targets a
  query people actually search for.

### Gap 5: backlinks are gained but never measured

**What's missing.**
- **W2906**, the directory listing kit, is the plan's only link-building
  work.
- **The blog** has 19 links to stridelikeaboss.com.
- **The plugin repositories** and their marketplace listings link back too.
- **Nothing counts any of them,** or notices when a new site links to Stride.

**Why it matters.** Links from other sites are still one of the strongest
signals search engines use to rank a page. They are also how ChatGPT and
Perplexity decide which tools are worth naming.

**Fix.**
- Ahrefs Webmaster Tools, free once the site is verified, lists every known
  backlink and referring domain.
- Search Console's Links report gives a second, smaller view.
- Check both monthly. Add a line to W2906 so each listing it produces is
  confirmed live there.

### Gap 6: AI visibility is prepared but not measured

**What's missing.** W2900 makes the site readable by AI crawlers and gives
them `/llms.txt`. That is the input side. Nothing measures the output:
- whether ChatGPT, Claude, Gemini or Perplexity mention Stride when asked
  about task boards for agents;
- how many visitors arrive from them.

Umami records those visits but files them under ordinary referrers
(`chatgpt.com`, `perplexity.ai`, `claude.ai`, `gemini.google.com`,
`copilot.microsoft.com`).

**Why it matters.** Developers increasingly ask an assistant rather than a
search engine, and for a tool sold to people who run AI agents this may
become the main way in.

**Fix.**
- Save a Umami segment, "AI assistants", that matches those referrer hosts,
  and watch it next to organic search.
- Run the free AI Visibility Checker each quarter with the same few
  questions and keep the answers.
- Ahrefs Brand Radar ($199 a month and up) is the paid version. It isn't
  worth paying for until the free check shows Stride appearing at all.

### Gap 7: nobody checks the live site

**What's missing.** G559's guard tests check the code: every public page has
a title, a description and the right `noindex` setting. Nothing crawls the
deployed site for:
- broken links and redirect chains;
- slow pages;
- pages that came out different from the code's intent.

That covers both `/docs` pages that link out to GitHub and the 50 Resources
guides.

**Fix.**
- Ahrefs Webmaster Tools includes a free site audit of a verified site; run
  it monthly.
- Umami's `data-performance` attribute adds Core Web Vitals from real
  visitors at no extra cost on self-hosted. On Cloud each measurement counts
  toward the event allowance.

### Lower priority

- **Other languages in search.** Only English pages are indexed: every
  `?locale=` page points its canonical at the English page, and there are no
  `hreflang` tags (see [the SEO conventions document](../seo.md)). Umami's
  country and language breakdowns will show whether non-English demand
  justifies changing that.
- **Brand mentions.** Ahrefs Content Explorer and Firehose find articles that
  mention Stride without linking to it, which are easy link requests. Until
  Stride is mentioned often, a Google Alert for "Stride" with "AI agents" does
  the same job for free.

## Changes W2897 needs now that Umami is chosen

W2897 said "Plausible or Umami". With Umami decided, it needed these
changes. **On 2026-11-21 W2897 was rewritten with all of them except item 4**,
the hosting choice, which is still open: W2897 reads the script and
collection addresses from `UMAMI_SCRIPT_URL` and `UMAMI_HOST_URL`, so it works
with Umami Cloud or a self-hosted server, loaded directly. Proxying through
our own domain is left as a follow-up.

1. **Name Umami and its settings.** Runtime config holds:
   - the script URL;
   - the website ID (`data-website-id`);
   - optionally the collection host (`data-host-url`).
2. **Set `data-exclude-search="true"`.** By default Umami records the query
   string. W2897's own security rule says nothing must record a full URL with
   a query string, because those can carry tokens. Also set
   `data-exclude-hash="true"`.
3. **Set `data-domains="www.stridelikeaboss.com"`.** The review app and the
   `fly.dev` origin then never send data, matching the per-host rule in
   W2891.
4. **Decide: Cloud or self-hosted, proxied or not.** This sets the CSP change:
   - **Umami Cloud, loaded directly.** The CSP gains `cloud.umami.is` in
     `script-src` and `gateway.umami.is` in `connect-src`. Ad blockers, common
     among developers, will block it often.
   - **Umami Cloud through our own domain.** The app serves the script and
     forwards `/api/send`. The CSP stays `'self'`, ad blockers block it less
     often, and we keep a small forwarding route to maintain.
   - **Self-hosted on Fly.** A Node app and a PostgreSQL database to run,
     patch and back up. It's free, with no event cap and no event
     allowance to watch, but has no Search Console report.

   My recommendation: Umami Cloud Pro, proxied through our domain. At $20 a
   month it adds the Search Console report (part of Gap 1) and the API. The
   proxy keeps the CSP at `'self'` and the numbers closer to the truth. Start
   on the free Hobby plan if the traffic is under 100K events a month, and
   move up when the report or the API is needed.
5. **Cover the `root` layout** for the sign-up and log-in pages, and add the
   events in Gap 2.
6. **Say exactly what `/privacy` should state:**
   - Umami sets no cookies;
   - IP addresses are used only to create a short-lived hashed visitor ID and
     an approximate location, and are not stored;
   - where Umami Cloud keeps the data, US or EU, chosen at signup;
   - how long the data is kept.

   Choose the EU region if Canadian and European visitors' data should stay
   outside the US.
7. **Do not set a Distinct ID** (`data-distinct-id`) or call
   `umami.identify()`. Umami's docs point out the value is visible in the
   page, and identifying visitors is the opposite of why we chose a
   cookie-free tool.

## What not to copy from Ahrefs

A paid Ahrefs plan doesn't fit Stride at this stage. Most of what it sells
answers questions about a site with a lot of search traffic and competitors
worth tracking keyword by keyword. Its free tools already cover three of the
gaps above:
- Webmaster Tools for backlinks and a site audit;
- the AI Visibility Checker for AI mentions;
- its free keyword tools for topic research.

Revisit a paid plan when Search Console shows steady traffic and the
comparison pages need ongoing rank tracking.

## Suggested next steps, in order

1. **Gap 1 (human, 30 minutes):** verify the site in Google Search Console and
   Bing Webmaster Tools by DNS and submit the sitemap. **Done on
   2026-11-23.**
2. **Gap 3 (human, 30 minutes):** record the baseline snapshot as close to
   2026-11-23 as possible.
3. **Switch on W2897.** It was updated on 2026-11-21 with the Umami changes
   above and the Gap 2 events, and built on 2026-11-22. Decide Umami Cloud or
   self-hosted (item 4 above), set the three Umami settings on production,
   then set up the funnel and goal in the Umami dashboard. Gap 2 lists the
   steps.
4. **Gap 4:** after four to six weeks of Search Console data, add the keyword
   research to W2901 before building it.
5. **Gaps 5, 6 and 7:** a monthly 15-minute review of backlinks, the AI
   assistants segment and the site audit; a quarterly AI Visibility Checker
   run.

Steps 1, 2 and 5 are work for a person, not code. If they should be tracked
on the board, they can be Stride tasks marked as human tasks.

## Sources

Read on 2026-11-21. Figures are as each site stated them that day.

- Ahrefs: `https://ahrefs.com/`, `/pricing`, `/about`, `/big-data` and
  `/free-seo-tools`.
- Umami: `https://umami.is/`, `/pricing` and `/features`, and the docs at
  `https://docs.umami.is/` (tracker configuration, track events, metric
  definitions, collect data, environment variables, attribution, bypassing
  ad blockers, Cloud FAQ, Google Search Console and data export).
- Stride: goal G559 and its tasks W2888–W2894, goal G560 and its tasks
  W2895–W2906, `lib/kanban_web/router.ex` (the registration route and its
  `root` layout) and `lib/kanban_web/robots_txt.ex` (the AI crawler list).

## Evaluating the Creative Squad proposal

Creative Squad, a marketing agency that works with Ahrefs, sent a growth
proposal for Stride dated 18 November 2026. This section compares it with
G559, G560 and the gaps above. It covers what they would repeat, what they
would add, and where their plan conflicts with decisions already made.

### What they propose

| Package | What it includes | Price (CAD) |
| --- | --- | --- |
| A: social media and paid social | 3 posts a week on LinkedIn, X, YouTube and Reels; Meta retargeting; social ad management | $249 a month, $650 a quarter, $1,100 for six months |
| B: Google Ads, SEO and GEO | Search ad campaigns; SEO and AI-answer ("GEO") work on 35 search phrases; comparison and per-agent pages | $249 a month, $650 a quarter, $1,100 for six months |
| A and B together | Both, with one strategist and one combined monthly report | $498 a month, $1,300 a quarter, $2,200 for six months |

- **Not included:** ad spend, which goes directly to Google and the social
  platforms.
- **Setup fees:** none.
- **Quarterly and six-month prices:** we read these as totals for the period.
  That works out to about $217 and $183 a month per package. Confirm this with
  them.

The plan runs for 90 days:
- **Month 1:** tracking, meta tags and structured data, a new hero, brand and
  category ads, and social accounts.
- **Month 2:** comparison pages, per-agent pages, the blog, a demo video and
  retargeting.
- **Month 3:** cut what doesn't convert, test LinkedIn, audit AI answers and
  review.

The monthly report counts what they call teams found, signed up, activated,
upgraded, trusted and followed.

### How current their findings are

The review describes the site as it was on 18 November. The facts about
Stride are right:
- $12 CAD per user a month on the Organization plan;
- up to 250 users before pricing is on request;
- 3 human members on a free board, with agents not counted;
- MIT licence and self-hosting;
- seven languages.

Several of the problems they found have been fixed since:

| Their finding | Status |
| --- | --- |
| 01: no meta description; every title is "Stride · Task Management" | Fixed by W2888 and W2889, committed 20 November: every public page has its own title and description in all seven languages |
| 04: the best content lives on outside blogs | Decided on 21 November: the posts stay on cheezyworld.ca, and the site links to them (W2895) |
| Technical fixes: meta tags, schema, `llms.txt` | Done: W2888–W2893 and W2900 |
| One page per agent | Done: `/integrations/:runtime` for six runtimes (W2899). They count five agents and miss Pi |
| "v2.3.0 is the current release" | Out of date: the home page now shows v3.2.0 |
| "Language tags" | Deliberately deferred: only English pages are indexed for now (see Lower priority above) |

"Committed" isn't the same as live: these fixes reach the public site with
the next deployment.

### Item by item

| Proposal item | Our plan | What they would add |
| --- | --- | --- |
| Meta tags, schema, `llms.txt` | **Done** (G559, W2900) | Nothing; don't pay for it again |
| Per-agent setup pages | **Done** (W2899) | Ad landing pages and keyword targeting for pages that already exist |
| Comparison pages for Linear, Jira and GitHub Projects | **Planned** (W2901) | Search volumes to choose and word them (Gap 4), and the copywriting |
| A "Vibe Kanban alternative" page | Not planned | **New.** They report that Vibe Kanban's company shut down on 10 April 2026 and its users are looking for a new home. If that's true, this is the most time-sensitive idea in the proposal. We have not verified it |
| Moving the blog to stridelikeaboss.com/blog | **Decided against** (W2895 is link-only) | Conflicts with that decision; see below |
| Proof bar, testimonials, user counts | **Planned** (W2903: tasks-completed counter, GitHub stars, quote slots) | Collecting real quotes from users, which W2903 leaves empty |
| A 2-minute demo video | Not planned. W2902 is a live replay board, not a video | **New:** video production, reused for social posts and ads |
| Benefit-first hero and copy without jargon | Not planned | **New.** Fair point: the home page's mini board shows "Stream task_moved via PubSub" before it says who Stride is for |
| "Meet the makers": founder and team on the About page | Not planned. The About page links to Tango but names no one | **New.** Cheap to do in-house, and needs your decision on who appears |
| Listings on G2, Product Hunt, AlternativeTo and "best of" roundups | **Partly planned:** W2906 prepares listing copy and a checklist | Doing the submissions, chasing reviews and pitching roundups, which W2906 doesn't do |
| Owning the name: "Stride kanban" and "Stride for AI agents" | Not planned | **New.** They found three other AI products called Stride. A real risk we hadn't noticed; we have not verified the three products |
| Keyword research: 35 phrases with volumes and difficulty | Not planned (Gap 4) | **Closes Gap 4**, with paid tools we don't have |
| Google search ads: category, per agent, competitors, brand defence | Not planned | **New.** Brand-defence ads answer the name problem straight away |
| Social content: LinkedIn, X, YouTube, Reels; 3 posts a week | Not planned; only GitHub today | **New, and the largest piece of work.** Needs the founder's time and face to work |
| Paid social and retargeting | Not planned | **New**, but conflicts with the cookie-free analytics; see below |
| Tracking signups, activation and upgrades by channel | **Planned:** W2897 records visits and signups by channel (Gap 2) | Ad-platform conversion tracking. Activation and upgrades we can already measure ourselves; see below |
| AI-answer audit across assistants | Not planned (Gap 6) | **Closes Gap 6**, as a monthly check |
| Search Console and analytics access | Search Console since 2026-11-23 (Gap 1); analytics built but not yet switched on (W2897) | They assume Google Analytics. Our setup is Umami plus Search Console |

### Where they add real value

In order of value for the money, given what's already built:

1. **Search data and a phrase list (Gap 4).** Volumes and difficulty for 35
   phrases, before any more pages are written. This is the work the free
   tools do worst, and it decides whether W2901 is worth building.
2. **The name problem.** Brand-defence ads on "Stride kanban" and consistent
   use of "Stride for AI agents" protect every other channel. A developer who
   hears about Stride and searches for it should land on us.
3. **The Vibe Kanban opening,** if it checks out. A comparison page and ads
   aimed at its former users are a short-lived chance.
4. **Getting listed and reviewed.** G2, Product Hunt, AlternativeTo and
   roundup articles give backlinks (Gap 5) and the sources AI assistants
   quote (Gap 6). W2906 only prepares the material; they would do the
   legwork.
5. **Social content and video.** The biggest gap in our plan, because no task
   covers it. Its value depends on the founder appearing in it; the
   proposal's step 3 asks you to confirm "the face of Stride".
6. **A monthly report** that includes AI answers and rankings, which covers
   Gaps 3 and 6, if it uses our data sources.

### Where it conflicts with our decisions

**The blog move.** They recommend moving the build series onto
stridelikeaboss.com, the plan W2895 started with. You chose to keep the posts
on cheezyworld.ca and link to them. Their argument is right that the product
domain gets the search value only if it hosts the posts. What it leaves out:
- two copies would compete with each other;
- the posts already rank where they are.

Keep the decision, and tell them it's settled. If you change your mind later,
the clean way is to move the Stride posts and point the cheezyworld.ca copies
at them with canonical links, not to republish them.

**Tracking and privacy.** W2897 is built on "no cookies, no consent banner".
Three parts of the proposal need tags that set cookies:
- Google Ads conversion tracking;
- Meta retargeting;
- LinkedIn's Insight Tag.

Using any of them means:
- a consent banner (Quebec's Law 25 and the GDPR expect one for advertising
  cookies);
- a wider content security policy;
- a rewritten privacy page.

There are three ways to handle it:

| Option | What it means |
| --- | --- |
| Search ads without pixels | Umami records the `gclid` on each ad click, once the query-string exclusion lets it through (see Gap 2). Send signups back to Google Ads as offline conversions from our server. No cookie on our site, and most of the measurement remains |
| Ads with platform tags and a consent banner | Full retargeting and platform reporting, at the cost of the cookie-free position and extra build work (the banner, the CSP, the privacy page) |
| No paid social | Keep Package A to organic posts only |

Our recommendation is the first option for Package B. Skip retargeting until
there's a reason to give up the cookie-free stance.

**URLs.** Their sample ads and phrase list use `/claude-code`, `/codex` and
`/vs/...`. The per-agent pages already live at `/integrations/claude-code` and
so on, and W2901 will set the comparison URLs. Ask them to use the existing
pages, not create duplicates.

**Access.** They ask for website, Google Analytics, Search Console, Google Ads
and social account access:
- **Search Console:** a restricted user.
- **Umami:** a share link or a view-only account.
- **The website:** no code or deployment access. Copy and page changes go
  through Stride tasks like any other change, so they keep the translations,
  the guard tests and the dark mode checks.

### Measurement we already have

The proposal's funnel has five stages: discover, visit, sign up, activate,
upgrade. They want a tracked event for each. Stride already emits telemetry
for most of these server-side, without any client tags:

| Stage | Already recorded |
| --- | --- |
| Sign up | `[:kanban, :user, :registration]` |
| Activate: board created | `[:kanban, :board, :creation]` |
| Activate: agent connected | `[:kanban, :api, :token_created]` and `[:kanban, :api, :token_used]` |
| Upgrade | `[:kanban, :organization, :created]` and `[:kanban, :organization, :member_added]` |
| Discover and visit | Not yet: Umami (W2897) and Search Console (Gap 1) |

What's missing is the link between a signup and the channel it came from,
which is Gap 2. W2897 now covers it with a `signup` event in the visitor's
Umami session. It is built; once it is switched on, we can produce the "signed up", "activated"
and "upgraded" parts of their report ourselves. They would only report on the
channels they run.

### Is it worth it?

- **The price is modest:** $498 CAD a month for both packages, before ad
  spend. The question is not cost but fit:
  - about a third of Package B, the technical SEO and the per-agent pages, is
    already built;
  - part of what remains, the comparison pages, is planned.
- **Little evidence from developer tools.** Their reviews come from
  landscaping, physiotherapy, home care and accounting businesses. The
  software clients they name are a SOC 2 compliance service, an AI
  bookkeeping product and an IT consultancy. None is a developer tool, and
  developers respond poorly to generic marketing.

**Recommendation.** Don't sign for A and B as proposed. Offer a single
quarter of Package B ($650 CAD, if that's the quarterly price), rewritten
to:
- **include:**
  - the 35-phrase keyword research, delivered in week 1 for W2901 and future
    pages;
  - brand-defence and category search ads, with offline conversions and no
    pixels;
  - the Vibe Kanban check and, if it holds, ads to its comparison page;
  - submissions to G2, Product Hunt and AlternativeTo, and roundup pitches;
  - a monthly AI-answer audit.
- **exclude:**
  - technical SEO and per-agent pages, which are done;
  - moving the blog, which is decided;
  - any change to the site's code.

**Decide on Package A separately,** once you know whether you'll appear in
videos and posts yourself. Without the founder, three posts a week from an
agency would read as generic content.

**Do now, before any contract:**
- Gap 3, and switching on W2897's analytics (Gap 2). Gap 1 was closed on
  2026-11-23;
- the About page with real people;
- a benefit-first hero.

Without the first item, no one, us or them, can show what the money did.
The last two cost nothing but a decision.

### Questions to ask them

1. Can you show results for a developer tool or an open-source product,
   measured in signups rather than clicks?
2. Can you run Google Ads with offline conversion import from our server and
   no tracking pixels on our site?
3. Are $650 and $1,100 totals for the quarter and six months, and can a
   single quarter of Package B be rescoped as above?
4. Which tool supplies the search volumes and the AI-answer audit, and do we
   keep the data and the phrase list if we stop?
5. Who writes the social and video content? How much founder time does it
   need each week?
6. What evidence is there for the Vibe Kanban shutdown and for the three
   other "Stride" products? Please send the sources.
