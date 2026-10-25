# Stride Roadmap

This roadmap describes what is coming to Stride and what has recently shipped. Items are listed in the order we plan to deliver them. Plans can change as we learn, so treat anything not yet marked complete as a direction rather than a promise.

**Status key:** ✅ Complete · 🚧 In progress · 🔜 Planned · 🔄 Ongoing

---

## ✅ Notifications and weekly digests

Stride tells people when something needs their attention instead of waiting for them to check.

- A bell in the top bar with a live unread count, and a notification inbox where you can open, filter and mark notifications as read.
- Notifications when:
  - an agent finishes work that needs review
  - a review is approved or changes are requested, including the reviewer's notes
  - a task is assigned to you
  - an agent gives a task back (with its reason) or its claim expires
  - a goal is completed or its after-goal hook fails
  - your board access changes
  - a delivery target you own becomes at risk or misses its date
- Email delivery for each notification, with a one-click unsubscribe link that works without logging in.
- Per-event notification preferences, with separate in-app and email switches, under Settings.
- A weekly digest email summarising board activity, the review queue and what was finished.
- Available in every language Stride supports.

## ✅ Task comments, @mentions and agent comments

Turn task comments into a real conversation between people and agents.

- Every comment shows who wrote it: the person, or the agent when it was posted through the API.
- Authors can edit their own comments, marked as edited; authors and board owners can delete them.
- @mention board members, with suggestions as you type. Mentioned people are notified.
- Comments appear live for everyone viewing the task, without a reload.
- One consistent comment thread in both the task view and the edit form, in light and dark mode.
- Agents can read and post task comments through the API, so they can leave notes and pick up human feedback on the work they're doing.

## ✅ Board search, filters, labels and My Work

Make busy boards fast to work with.

- Search and filter a board by text, type, priority, assignee and label. Filtered views live in the URL, so you can share or bookmark them.
- Board labels with names and colours, managed in board settings and shown on task cards. Label changes appear on every open copy of the board straight away.
- A **My Work** page listing the open tasks assigned to you across all your boards, grouped by board.
- Select several tasks at once to move, assign, label or archive them together.
- Keyboard shortcuts: press `/` to search the board and `?` to see every shortcut.
- Labels available through the API and MCP server, so agents can set them and filter by them.
- Read-only members keep full search and filtering, but never see editing actions.

Deadlines stay with delivery targets rather than individual tasks, so tasks don't get their own due dates.

## ✅ Organizations and the Free plan

Give teams that work together a paid home in Stride, and keep Stride free for everyone else.

- Organizations, the paid plan for teams. Stride sets each one up and appoints its first org-admin, who manages it from an Organization console.
- An Organization audit log of its security events, with filters and CSV or JSON export.
- A Free plan for boards outside an Organization. A free board holds up to 3 people, and AI agents never count. Notifications, bulk actions, integrations, task telemetry and MCP access are for Organization boards, and each one shows "Available to organizations" on a free board.
- Plans are switched on by the Stride operator. A self-hosted Stride that doesn't switch them on keeps every feature on every board, with no member limit.
- Updated pricing, terms and privacy pages for the two plans.

## ✅ Workspaces, invitations and account lifecycle

Give teams a home for their boards and people.

- Workspaces that group boards and people. Every account has a personal workspace, and an Organization can have several, with a workspace switcher in the side navigation. Inside a workspace, people are Members, who can create boards there, or Guests, who can't.
- Every existing board moved into its owner's personal workspace automatically, and everyone kept the access they had.
- Invite people to a workspace, and optionally to one of its boards, by email, whether or not they already have an account. The owner of a free board can invite someone to that board.
- A single workspace API token that works across every AI Optimized board in the workspace, alongside board tokens.
- Delete your own account from your account settings, once any board other people use has been handed over.
- Export a workspace archive, and restore it on a self-hosted Stride instance. The archive never contains passwords, tokens or webhook secrets.

## ✅ Enterprise identity and compliance

Meet the security and compliance needs of larger organisations.

- Two-factor authentication with an authenticator app, plus single-use recovery codes, a reminder after sign-in for people who haven't turned it on, and a step-by-step setup guide.
- A permanent, tamper-proof audit log of important account and board activity.
- An audit log viewer for administrators, with filters and CSV or JSON export.
- Telemetry for every important event — sign-ins and account changes, board access, task and goal activity, agent work, notifications, rate limits and data exports — with a documented event catalogue, no personal data in event details, and a configurable retention period for stored metrics.
- Organization security policies: require two-factor authentication for every member, with a grace period so nobody is locked out the moment it's turned on, and set how long the Organization's audit events are kept.
- Single sign-on with OIDC and SAML identity providers, limited to email domains the Organization has verified. Verified domains are re-checked every day.
- Automatic user provisioning and deprovisioning through SCIM. Removing someone ends their access to the Organization's boards and revokes their API tokens there, and an account the Organization manages is also signed out everywhere.

## 🚧 Developer integrations

Plug Stride into the tools teams and agents already use.

- ✅ A task API that pages through large boards and filters results, with no change for existing integrations.
- ✅ A published, machine-readable OpenAPI description of the Stride API, so client libraries can be generated.
- ✅ Outbound webhooks for task events: signed, retried automatically, with a delivery log and a test button.
- ✅ Slack notifications for board activity.
- GitHub integration that links pull requests to tasks by their identifier, shows pull request and CI status on task cards and in the task view, and moves a task to a chosen column when its pull request merges.
- ✅ An MCP server, so MCP-capable agents can find, claim, complete and comment on tasks directly, using their existing API token.

## 🔄 Ongoing plugin improvement

Continuous work on the Stride agent plugins to improve:

- **Accuracy**: agents follow the workflow correctly, produce better work, and need fewer review rounds.
- **Speed**: less time from claiming a task to completing it.
- **Token usage**: lower model cost per task, without losing quality.

Recently shipped for OpenCode (Stride for OpenCode 1.41.0 and 1.42.0, and OpenCode exploratory testing 0.4.0):

- ✅ Before starting, agents compare what a task says about the code with the code itself and report anything out of date.
- ✅ Stricter reviews: each planned test is traced to a real test, new and changed tests are shown to fail when the behaviour they guard is broken, factual statements in a change are checked against the code, and files that are meant to change together are flagged when only one did.
- ✅ New tasks get a full behaviour test matrix by default and a consistency check across their fields before they are created.
- ✅ Lighter instructions: background reading moved out of the always-loaded skills, and finding the next task asks for a smaller reply.
- ✅ Exploratory testing can save its full report to a file, re-check a single fixed bug, and turn findings into regression tests without stopping to ask questions.

Recently shipped for the security reviewer (Stride Security Review 2.7.1 and 2.7.2, and Stride Security Review for OpenCode 0.2.0):

- ✅ When the reviewer tries out a suspicious snippet, it runs in a confined copy of your project that hides your home directory.
- ✅ The reviewer's git commands no longer start the hooks, diff tools or signing programs a reviewed repository configures.
- ✅ On OpenCode, the reviewer gives a verdict on each of a task's security considerations, loads its framework rules only when they apply, saves its full result to a file, and removes credential-shaped text from that result.
