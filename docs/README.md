# Stride documentation

This is the index of every markdown file under `docs/`. Each file appears once,
under the audience it is written for, with one line saying what it is for.

## How to use this index

- Find the group that describes you and read it from the top. Board owners
  start with Getting Started with AI Agents, the first entry under End users,
  which walks from a new board to a connected agent. Whoever builds or
  maintains the agent integration goes on to the AI agent integrators group.
- The last group, Historical records, holds plans, requirements, findings,
  validation runs and retired instruction files. They are records of a point
  in time, not current guidance.
- Adding a doc? Add one entry for it under exactly one group, with a link
  written relative to this `docs/` directory and a one-line purpose.
  `test/kanban/docs_index_test.exs` fails until every doc under `docs/` is
  listed here.
- Folders that `.gitignore` excludes under `docs/` (today `docs/blog/`) hold
  local drafts. They are not committed, so they are not listed here.

## End users (board owners and members)

Board owners deciding whether to move their boards to an Organization should
read Organizations and Workspaces, the first entry under Organization admins.

- [Getting Started with AI Agents](GETTING-STARTED-WITH-AI.md) — Start here: set up a board and connect your first AI agent to it.
- [Task Writing Guide](TASK-WRITING-GUIDE.md) — How to write tasks an AI agent can finish without guessing.
- [Review Workflow](REVIEW-WORKFLOW.md) — How tasks that need review move through the Review column and how to approve or reject them.
- [Task Form Field Visibility](TASK-FORM-FIELD-VISIBILITY.md) — Which fields the task form shows and how a board owner turns optional fields on or off.
- [Webhooks and Slack](webhooks.md) — Send a board's task events to your own systems or a Slack or Discord channel, and verify webhook signatures.
- [Two-Factor Authentication](TWO-FACTOR-AUTHENTICATION.md) — Add a second sign-in factor to your account.

## AI agent integrators

### Guides

- [AI Workflow Guide](AI-WORKFLOW.md) — The complete API workflow an agent follows, from claiming a task to completing it.
- [Authentication Guide](AUTHENTICATION.md) — Creating and using the API tokens agents authenticate with.
- [Agent Capabilities](AGENT-CAPABILITIES.md) — How capabilities on a token match agents to the tasks they may claim.
- [Agent Hook Execution Guide](AGENT-HOOK-EXECUTION-GUIDE.md) — How agents run the client-side hooks at each point in a task's lifecycle.
- [Unclaim Tasks Guide](UNCLAIM-TASKS.md) — When and how an agent releases a task it has claimed.
- [Estimation Feedback](ESTIMATION-FEEDBACK.md) — Reporting actual complexity and time when completing a task, so future estimates improve.
- [Stride MCP Server](MCP.md) — Using Stride through its Model Context Protocol server instead of hand-built API calls.
- [Multi-Agent Instructions](MULTI-AGENT-INSTRUCTIONS.md) — Which instruction files each supported AI coding assistant uses and how to set them up.
- [Windows Setup Guide](WINDOWS-SETUP.md) — Running Stride agents on Windows with WSL2, PowerShell or Git Bash.
- [How Agents Remember Stride Context](AGENT-MEMORY-SOLUTION.md) — How agents keep the Stride workflow in mind from one session to the next.

### API reference

- [API Documentation](api/README.md) — Overview of the API for AI agents and the place to start.
- [GET /api/agent/onboarding](api/get_agent_onboarding.md) — Public onboarding information for a new agent.
- [GET /api/boards](api/get_boards.md) — List the boards a token can reach.
- [GET /api/openapi.json](api/get_openapi_json.md) — The machine-readable OpenAPI description of the whole API.
- [GET /api/tasks](api/get_tasks.md) — List tasks, with filters and cursor pagination.
- [GET /api/tasks/:id](api/get_tasks_id.md) — Fetch one task.
- [GET /api/tasks/next](api/get_tasks_next.md) — Find the next task an agent can claim.
- [GET /api/tasks/:id/comments](api/get_tasks_id_comments.md) — List a task's comments.
- [GET /api/tasks/:id/dependencies](api/get_tasks_id_dependencies.md) — List the tasks a task depends on.
- [GET /api/tasks/:id/dependents](api/get_tasks_id_dependents.md) — List the tasks that depend on a task.
- [GET /api/tasks/:id/tree](api/get_tasks_id_tree.md) — Fetch a goal or task with its children.
- [GET /api/tasks/:id/after_goal_status](api/get_tasks_id_after_goal_status.md) — Check whether completing a task armed its goal's `after_goal` hook.
- [PATCH /api/tasks/:id](api/patch_tasks_id.md) — Update a task's fields.
- [PATCH /api/tasks/:id/complete](api/patch_tasks_id_complete.md) — Complete a claimed task.
- [PATCH /api/tasks/:id/mark_done](api/patch_tasks_id_mark_done.md) — Move a task from Review straight to Done.
- [PATCH /api/tasks/:id/mark_reviewed](api/patch_tasks_id_mark_reviewed.md) — Record the outcome of a human review: approved, changes requested or rejected.
- [PATCH /api/tasks/:id/after_goal](api/patch_tasks_id_after_goal.md) — Report the result of a goal's `after_goal` hook.
- [POST /api/tasks](api/post_tasks.md) — Create a task, or a goal with nested tasks.
- [POST /api/tasks/batch](api/post_tasks_batch.md) — Create several goals in one request.
- [POST /api/tasks/claim](api/post_tasks_claim.md) — Claim a task.
- [POST /api/tasks/:id/comments](api/post_tasks_id_comments.md) — Add a comment to a task.
- [POST /api/tasks/:id/unclaim](api/post_tasks_id_unclaim.md) — Release a claimed task.
- [PUT /api/tasks/:id/changed_files](api/put_tasks_id_changed_files.md) — Upload the per-file diff snapshot for a task.

### Multi-agent instruction files

The onboarding endpoint serves these files to tools that have no Stride
plugin: the seven skills to Cursor, Windsurf and Continue.dev, and `AGENTS.md`
to Kimi Code CLI. They are snapshots, edited here; the per-tool Stride plugins
are the maintained source of the skills (see "Served skill copies and the
plugins" in Multi-Agent Instructions, under Guides above).

- [AGENTS.md instructions](multi-agent-instructions/AGENTS.md) — Stride integration instructions for assistants that read an `AGENTS.md` file.
- [stride-workflow skill](multi-agent-instructions/skills/stride-workflow/SKILL.md) — The orchestrator skill that runs a task from claim to completion.
- [stride-claiming-tasks skill](multi-agent-instructions/skills/stride-claiming-tasks/SKILL.md) — The skill for claiming a task.
- [stride-completing-tasks skill](multi-agent-instructions/skills/stride-completing-tasks/SKILL.md) — The skill for completing a task.
- [stride-creating-tasks skill](multi-agent-instructions/skills/stride-creating-tasks/SKILL.md) — The skill for creating work tasks and defects.
- [stride-creating-goals skill](multi-agent-instructions/skills/stride-creating-goals/SKILL.md) — The skill for creating goals with nested tasks.
- [stride-enriching-tasks skill](multi-agent-instructions/skills/stride-enriching-tasks/SKILL.md) — The skill for filling in a sparse task before work starts.
- [stride-subagent-workflow skill](multi-agent-instructions/skills/stride-subagent-workflow/SKILL.md) — The skill that decides when to dispatch subagents during a task.

### Plugin contracts

- [Completion Review Report Contract](completion-contract.md) — What a fully-populated review report on a completion payload must contain.
- [Per-File Diff Contract](diff-contract.md) — The shape of the per-file diff carried on a completion payload.
- [Matrix Row Refusal Contract](matrix-row-refusal-contract.md) — What every agent does with a behaviour/test matrix row it must not follow.

## Organization admins

- [Organizations and Workspaces](organizations.md) — What Organizations and workspaces are, the Free and Organization plans, roles, invitations, moving a board into a workspace and account deletion.
- [Single Sign-On](single-sign-on.md) — Letting an Organization's members sign in through your identity provider.
- [SCIM Provisioning](scim-provisioning.md) — Creating and removing an Organization's members from your identity provider.
- [Organization Security Policies](organization-security-policies.md) — Requiring two-factor authentication for members and setting how long audit events are kept.
- [Workspace Export](workspace-export.md) — Downloading an Organization workspace as a zip archive, and importing one into a self-hosted instance.

## Self-hosting operators

- [Audit Log Database Roles](audit-log-database-roles.md) — Which database roles the audit log needs and the one-time step that hardens production.
- [Audit Log Ownership Hardening](audit-log-hardening.md) — Why the audit log's table owner matters and how ownership keeps it append-only.
- [Error Pages and Error Responses](error-pages.md) — What a browser, API or SCIM client gets when a request fails, and which module renders it.
- [Organizations Launch Runbook](organizations-launch-runbook.md) — The launch-day steps for enforcing plans, the verification checklist and rollback.
- [Telemetry Events](telemetry.md) — Every telemetry event, its privacy rule, attaching a handler and metrics retention.

## Contributors to Stride

- [Stride development guidelines skill](multi-agent-instructions/stride-development-guidelines/SKILL.md) — Points contributors to the development-guidelines skill Claude Code loads, and lists what `mix precommit` runs. Not served to agents.
- [Documentation Link Contract](doc-link-contract.md) — How links inside these docs are written and checked.
- [Documentation Example Enum Contract](doc-example-enum-contract.md) — Rules for enum values in the JSON examples of the API docs and guides.
- [Dark Mode Contract](dark-mode-contract.md) — Theme tokens, prohibited patterns and the dark-mode scanner.
- [Responsive Audit Baseline](responsive-audit.md) — The breakpoints, test widths and layout rules every page follows.
- [Organizing Tailwind CSS](TAILWIND_ORGANIZATION.md) — Keeping Tailwind classes readable in HEEx templates with function components.

## Historical records

> **These are point-in-time records, not current guidance.** Each file records
> what was planned, decided, found or checked on the date it was written.
> Stride has changed since: features may have shipped differently, been renamed
> or never been built, and findings may already be fixed. Do not follow them as
> instructions; for how Stride works today, use the groups above.

### Top-level records

- [Stride Claude Code Skills Implementation Plan](STRIDE-SKILLS-PLAN.md) — The completed January 2026 plan for the first Stride Claude Code skills.
- [Stride Plugin Workflow Enforcement Recommendations](stride-plugin-enforcement-recommendations.md) — Recommendations written after an agent skipped mandatory workflow steps.
- [Security Review Baseline](security-review-baseline.md) — The attack-surface inventory and tooling baseline for the G309 security review.

### Retired instruction files

No endpoint serves these files and they are no longer maintained. Use the
Stride plugin for the tool instead, as Multi-Agent Instructions describes.

- [GitHub Copilot instructions](multi-agent-instructions/copilot-instructions.md) — Former Stride instructions for GitHub Copilot, replaced by the stride-copilot plugin.
- [Gemini Code Assist instructions](multi-agent-instructions/GEMINI.md) — Former Stride instructions for Gemini, replaced by the stride-gemini extension.
- [Stride skill (single file)](multi-agent-instructions/SKILL.md) — The former single-file `stride` skill, replaced by the seven per-skill files and the stride-opencode plugin.
- [Cursor rules](multi-agent-instructions/cursorrules.txt) — Former `.cursorrules` content for Cursor, replaced by the seven Stride skills in `.cursor/skills/`.
- [Windsurf rules](multi-agent-instructions/windsurfrules.txt) — Former `.windsurfrules` content for Windsurf, replaced by the seven Stride skills in `.windsurf/skills/`.

### Plans

- [Import from Jira: Implementation Design](plans/IMPORT-FROM-JIRA-DESIGN.md) — Design for bringing a team's existing Jira work into Stride, written 2026-10-28.
- [Teams and Google Chat Webhooks Evaluation](plans/TEAMS-AND-GOOGLE-CHAT-WEBHOOKS-EVALUATION.md) — Research into Microsoft Teams and Google Chat webhook support.

### Ideation requirements

- [Task-reviewer review data structure (2026-05-19)](ideation/2026-05-19T150732-task-reviewer-review-data-structure-improvements-requirements.md) — Requirements for a structured task-reviewer review report.
- [Review Queue code diffs (2026-05-20)](ideation/2026-05-20T143845-review-queue-code-diffs-requirements.md) — Requirements for showing code diffs in the Review queue.
- [Agents view usefulness (2026-06-19)](ideation/2026-06-19T123205-agents-view-usefulness-requirements.md) — Requirements for making the Agents view useful to ops, product and developers.
- [Agents page delivery value (2026-07-06)](ideation/2026-07-06T115536-agents-page-delivery-value-requirements.md) — Requirements for making the agents page useful to delivery organizations.
- [Agents page delivery value (2026-07-08 12:13)](ideation/2026-07-08T121351-agents-page-delivery-value-requirements.md) — A later revision of the same agents page requirements.
- [Agents page delivery value (2026-07-08 17:37)](ideation/2026-07-08T173722-agents-page-delivery-value-requirements.md) — A continuation of the agents page requirements covering cost and return on investment.
- [G442 Workspaces UI briefing (2026-10-17)](ideation/2026-10-17T112210-g442-workspaces-ui-briefing.md) — What changes on screen when goal G442 is complete.
- [Paying organizations and free-tier limits (2026-10-17)](ideation/2026-10-17T154403-paying-organizations-and-free-tier-limits-for-stride-requirements.md) — Requirements for paying Organizations and free-tier limits.

### Security findings

- [Security Remediation Plan (G310)](security-findings/REMEDIATION-PLAN.md) — Triage and remediation plan for the G309 security review findings.
- [W1592 Authentication and sessions](security-findings/W1592-auth-and-sessions.md) — Findings from the G309 security review: authentication and session management.
- [W1593 API authentication and authorization](security-findings/W1593-api-authz.md) — Findings from the G309 security review: API tokens and capability checks.
- [W1594 IDOR and cross-board scoping](security-findings/W1594-idor-scoping.md) — Findings from the G309 security review: record access across boards.
- [W1595 Injection](security-findings/W1595-injection.md) — Findings from the G309 security review: injection and data-access safety.
- [W1596 XSS and CSP](security-findings/W1596-xss-csp.md) — Findings from the G309 security review: output encoding and content security policy.
- [W1597 Input validation](security-findings/W1597-input-validation.md) — Findings from the G309 security review: input validation and file-path handling.
- [W1598 Secrets, config and deployment](security-findings/W1598-secrets-config-deploy.md) — Findings from the G309 security review: secrets, configuration and deployment hardening.
- [W1599 Dependencies](security-findings/W1599-dependencies.md) — Findings from the G309 security review: dependencies and supply chain.
- [W1600 SSRF and hooks](security-findings/W1600-ssrf-hooks.md) — Findings from the G309 security review: server-side requests and hook execution.
- [W1676 Authentication LiveView flows](security-findings/W1676-auth-liveview-flows.md) — Security findings for the authentication LiveView flows.
- [W1677 LiveView event authorization sweep](security-findings/W1677-liveview-handle-event-authz-sweep.md) — Security findings from a sweep of LiveView event authorization.

### Specs

- [after_goal hook requirements (2026-05-14)](superpowers/specs/2026-05-14T110423-after-goal-hook-requirements.md) — Requirements for a hook that runs when a goal's last task completes.

### Validation runs

- [G67 multi-agent port validation (2026-04)](validation/2026-04-multi-agent-g65.md) — Validation of the Cursor, Windsurf, Continue.dev and Kimi Code ports against the G65 completion gate.
- [G72 onboarding and docs validation (2026-04)](validation/2026-04-onboarding-docs-g65.md) — Validation that the onboarding endpoint and docs cover G65 completion validation.
