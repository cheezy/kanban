# Agent Integration Pages

Stride ships a plugin for six coding agents: Claude Code, Codex CLI, Gemini
CLI, GitHub Copilot, OpenCode and Pi. The site has one public page for each, at
`/integrations/<runtime>`, and an index at `/integrations` that the marketing
footer links on every marketing page. Each page says what the plugin adds,
gives its install commands, links the marketplace or repository it is listed in
and the plugin's README, and walks through a first task.

## Where the data lives

`KanbanWeb.Integrations` ([`integrations.ex`](../lib/kanban_web/integrations.ex))
holds the list. Each runtime has:

- a fixed slug (`claude-code`, `codex`, `gemini-cli`, `github-copilot`,
  `opencode`, `pi`), which is only ever looked up in the list, so an unknown
  one answers 404;
- its name, a tagline and the capabilities its README claims;
- its install steps, each a translated title and a command;
- where it is listed: a `:marketplace`, an `:extension_index` (Gemini CLI has
  no marketplace of its own) or, where there is neither, the plugin's
  `:repository`;
- its README on GitHub;
- an optional install note, for a step the commands alone do not cover, with a
  link to the README section that explains it. Codex has one: its script
  installs copy the hook, but the hook must be registered once by hand;
- a `preview` flag, which shows a Preview badge on both pages. No runtime is
  in preview today.

`KanbanWeb.IntegrationsController` renders the pages under the marketing
layout, and `KanbanWeb.Integrations.sitemap_paths/0` puts all seven pages in
the sitemap ([Search and Social Tags](seo.md)).

## The install commands

The commands are copied by hand from each plugin's README. They are never
fetched at runtime and never translated: they are literals in the data module,
outside `gettext`, and the page renders them in `<pre translate="no">`.

Each command must be the whole body of one fenced code block in the README its
step names as `:source`. Codex's marketplace commands come from the
`stride-codex-marketplace` README, because the `stride-codex` README does not
give them.

The plugin repositories are separate checkouts that sit, gitignored, beside the
app, so a test cannot read them in CI. Instead, the install section of each
README is committed under `test/support/fixtures/plugin_readmes/<repo>.md`, and
`test/kanban_web/integrations_test.exs` checks:

- that every command on the pages is a code block in its README's committed
  install section, and that the README is the runtime's own;
- that no command is one of the uninstall, clean-up or not-yet-available
  commands those sections also hold;
- when a plugin checkout is present, that its README's install section still
  matches the committed copy. The failure names the file to recopy.

## When a plugin README changes its install steps

1. Copy the changed section into its fixture file. The section runs from its
   `## Installation` heading (`## Adding the marketplace` for
   `stride-codex-marketplace`) to the next level-two heading outside a code
   fence. A fence opens with three or more backticks or tildes and closes only
   on a line of the same character, at least as long. `KanbanWeb.PluginReadme.section/2` in `test/support/plugin_readme.ex`
   reads it the same way.
2. Update the commands in `KanbanWeb.Integrations` to match.
3. If a capability changed, update the capability strings, run
   `MIX_ENV=test mix gettext.extract --merge`, and translate every new string in
   all seven locales.
4. Run `mix test test/kanban_web/integrations_test.exs
   test/kanban_web/controllers/integrations_controller_test.exs`.

## Adding a runtime

Add a clause to `KanbanWeb.Integrations.all/0` and its slug to `@slugs`, commit
its README's install section as a fixture and add the repository to the
section map in `KanbanWeb.PluginReadme`. The sitemap, the index and the footer
link pick the runtime up with no further step. Then update the runtime count in
the tests that pin it, and the index page's meta description, which names every
runtime.

Claim only what the plugin's README says it does, and link only to the
official Stride repositories and marketplaces. The catalog test fails on any
other link.

`KanbanWeb.OnboardingPlugins`, used by the onboarding screens, reads its
workflow-plugin install commands and their titles from these install steps.
Its `@install_blocks` names the steps it shows by position, so when you add,
remove or reorder a runtime's steps, check that map too;
`test/kanban_web/onboarding_plugins_test.exs` pins what each agent shows. Its
ideation-plugin commands are not in this catalog and are kept in that module.
