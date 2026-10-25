# Stride Roadmap

This roadmap describes what we are considering for Stride next. What has already shipped is in the [CHANGELOG](CHANGELOG.md). Plans can change as we learn, so treat everything here as a direction rather than a promise.

**Status key:** 🚧 In progress · 🔜 Planned · 💡 Under consideration · 🔄 Ongoing

---

## 💡 Import from other tools

Bring a team's existing work into Stride instead of starting from an empty board.

- Import boards and tasks from Linear and Jira, keeping titles, descriptions, comments, labels and status.
- Import from Trello and from a CSV file.

## 💡 AI cost and agent performance

Show what AI work costs and how well each agent does it.

- Agents report the model and tokens they used when they complete a task, so AI cost shows for each task, goal and board.
- Monthly AI budgets for a board or workspace, with alerts as spending nears the limit.
- Agent performance reports: rework rate, review rounds per task, how often reviews find real problems, time from claim to done, and expired claims, compared by agent, model and plugin version.

## 💡 Agent controls and approvals

Give people firm control over what agents may do.

- Approval policies that require human review automatically, for example for tasks that touch chosen files, carry security considerations, or are large or critical.
- Two-person approval for sensitive work.
- Agent permissions for each board: which agents may claim which kinds of tasks, and how many tasks each may hold at once.
- A stop switch that pauses every agent on a board at once.
- A live view of what each agent is doing right now: its task, its current workflow step and its hook output.

## 💡 Everyday task management

Make day-to-day work on a board easier.

- File attachments on tasks and comments, such as screenshots, logs and designs.
- Board and goal templates, including their hooks.
- Recurring tasks, such as weekly dependency updates or security scans.
- Saved views: name a set of board filters and share it with the team.
- Checklists inside a task, for small steps that don't need their own task.
- A timeline view of goals and delivery targets.

## 💡 Enterprise administration

Meet more of what larger organisations ask for.

- Self-serve billing: buy the Organization plan online, manage seats and download invoices.
- Stream the audit log to a security tool such as Splunk, Datadog or a SIEM, and sign audit exports.
- IP allowlists for sign-in and API tokens.
- Passkeys and security keys as a two-factor option.
- Retention policies for archived tasks, and legal hold.
- Custom roles with finer permissions for each workspace.
- A choice of data region, and an uptime commitment.
- A trust centre with Stride's security certifications and a ready-made security questionnaire.

## 🔄 Ongoing plugin improvement

Continuous work on the Stride agent plugins to improve:

- **Accuracy**: agents follow the workflow correctly, produce better work, and need fewer review rounds.
- **Speed**: less time from claiming a task to completing it.
- **Token usage**: lower model cost per task, without losing quality.
