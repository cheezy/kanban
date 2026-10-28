# Stride Roadmap

This roadmap describes what we are considering for Stride next. What has already shipped is in the [CHANGELOG](CHANGELOG.md). Plans can change as we learn, so treat everything here as a direction rather than a promise.

**Status key:** 🚧 In progress · 🔜 Planned · 💡 Under consideration · 🔄 Ongoing

---

## 💡 Import from other tools

Bring a team's existing work into Stride instead of starting from an empty board.

- **Import from Jira**

  Bring boards and tasks across with their titles, descriptions, comments, labels and status, so a team can move without losing its history.

- **Import from Trello and CSV**

  Bring in Trello boards, or any list of work you can export as a CSV file.

## 💡 AI cost and agent performance

Show what AI work costs and how well each agent does it.

- **AI cost per task**

  Agents report the model and the tokens they used when they complete a task, so you can see what each task, goal and board cost.

- **Monthly AI budgets**

  Set a monthly budget for a board or workspace, and get an alert as spending nears the limit.

- **Agent performance reports**

  Compare agents, models and plugin versions on rework rate, review rounds per task, how often reviews find real problems, time from claim to done, and expired claims.

## 💡 Agent controls and approvals

Give people firm control over what agents may do.

- **Approval policies**

  Require human review automatically for chosen kinds of work, such as tasks that touch certain files, carry security considerations, or are large or critical.

- **Two-person approval**

  Require a second person to approve sensitive work before it counts as done.

- **Agent permissions**

  Decide for each board which agents may claim which kinds of tasks, and how many tasks each may hold at once.

- **Stop switch**

  Pause every agent on a board at once.

- **Live agent view**

  See what each agent is doing right now: its task, its current workflow step and its hook output.

## 💡 Everyday task management

Make day-to-day work on a board easier.

- **Attachments**

  Add files such as screenshots, logs and designs to tasks and comments.

- **Templates**

  Start a board or goal from a template, hooks included.

- **Recurring tasks**

  Create work that comes back on a schedule, such as weekly dependency updates or security scans.

- **Saved views**

  Name a set of board filters and share it with the team.

- **Checklists**

  Track small steps inside a task when they don't need a task of their own.

- **Timeline view**

  See goals and delivery targets laid out over time.

## 💡 Enterprise administration

Meet more of what larger organisations ask for.

- **Self-serve billing**

  Buy the Organization plan online, manage seats and download invoices.

- **Audit log streaming**

  Send the audit log to a security tool such as Splunk, Datadog or a SIEM, and sign audit exports.

- **IP allowlists**

  Limit sign-in and API tokens to the networks you choose.

- **Passkeys and security keys**

  Use a passkey or a hardware security key as a second factor.

- **Retention and legal hold**

  Set how long archived tasks are kept, and hold them when a legal matter requires it.

- **Custom roles**

  Define roles with finer permissions for each workspace.

- **Data region and uptime commitment**

  Choose where your data is stored, with a committed level of uptime.

- **Trust centre**

  Find Stride's security certifications and a ready-made security questionnaire in one place.

## 🔄 Ongoing plugin improvement

Continuous work on the Stride agent plugins to improve:

- **Accuracy**

  Agents follow the workflow correctly, produce better work, and need fewer review rounds.

- **Speed**

  Less time from claiming a task to completing it.

- **Token usage**

  Lower model cost per task, without losing quality.
