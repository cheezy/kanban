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

## 🚧 Developer integrations

Plug Stride into the tools teams and agents already use.

- ✅ A task API that pages through large boards and filters results, with no change for existing integrations.
- ✅ A published, machine-readable OpenAPI description of the Stride API, so client libraries can be generated.
- Outbound webhooks for task events: signed, retried automatically, with a delivery log and a test button.
- Slack notifications for board activity.
- GitHub integration that links pull requests to tasks by their identifier, shows pull request and CI status on task cards and in the task view, and moves a task to a chosen column when its pull request merges.
- ✅ An MCP server, so MCP-capable agents can find, claim, complete and comment on tasks directly, using their existing API token.

## 🚧 Enterprise identity and compliance

Meet the security and compliance needs of larger organisations.

- Two-factor authentication with an authenticator app, plus single-use recovery codes.
- ✅ A permanent, tamper-proof audit log of important account and board activity.
- ✅ An audit log viewer for administrators, with filters and CSV or JSON export.
- Telemetry for every important event — sign-ins and account changes, board access, task and goal activity, agent work, notifications, rate limits and data exports — with a documented event catalogue, no personal data in event details, and a configurable retention period for stored metrics.
- Workspace security policies: require two-factor authentication for all members (with a grace period for existing members) and set how long audit records and archived tasks are kept.
- Single sign-on with OIDC and SAML identity providers, limited to email domains the workspace has verified.
- Automatic user provisioning and deprovisioning through SCIM. Removing someone signs them out everywhere and revokes their API tokens.

## 🔜 Workspaces, invitations and account lifecycle

Give teams a home for their boards and people.

- Workspaces that group boards and people, with owner, admin, member and guest roles.
- Every existing board moves into its owner's personal workspace automatically, and everyone keeps the access they have today.
- Invite people to a workspace or board by email, whether or not they already have an account.
- A single workspace API token that works across every board in the workspace you can access, alongside today's board tokens.
- Delete your own account from Settings, once any boards you own have been handed over.
- Export a complete workspace archive, and restore it on a self-hosted Stride instance.

## 🔜 Task comments, @mentions and agent comments

Turn task comments into a real conversation between people and agents.

- Every comment shows who wrote it: the person, or the agent when it was posted through the API.
- Authors can edit their own comments, marked as edited; authors and board owners can delete them.
- @mention board members, with suggestions as you type. Mentioned people are notified.
- Comments appear live for everyone viewing the task, without a reload.
- One consistent comment thread in both the task view and the edit form, in light and dark mode.
- Agents can read and post task comments through the API, so they can leave notes and pick up human feedback on the work they're doing.

## 🔜 Board search, filters, labels, due dates and My Work

Make busy boards fast to work with.

- Search and filter a board by text, type, priority, assignee, label and due date. Filtered views live in the URL, so you can share or bookmark them.
- Board labels with names and colours, managed in board settings and shown on task cards.
- Optional due dates on tasks, with overdue and due-soon indicators on the cards.
- A **My Work** page listing everything assigned to you across all your boards, grouped by board or by when it's due.
- Select several tasks at once to move, assign, label or archive them together.
- Keyboard shortcuts: press `/` to search the board and `?` to see every shortcut.
- Labels and due dates available through the API, so agents can set them and filter by them.
- Read-only members keep full search and filtering, but never see editing actions.

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
