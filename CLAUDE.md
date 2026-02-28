@AGENTS.md

## Development Rules (MANDATORY)

Before writing or editing ANY file in lib/, test/, or assets/, you MUST invoke the `stride-development-guidelines` skill. This is not optional. Do not write code without first invoking this skill.

Before writing or editing ANY code that is using the phoenix framework you MUST invoke the `phoenix-framework` skill. This is not optional. Do not write code without first invoking this skill.

## Stride Workflow Rules

When working in the Stride workflow, do NOT prompt the user for confirmation before making API calls. The user has already authorized claiming and working on tasks by initiating the Stride workflow. Proceed directly with API calls (claiming tasks, completing tasks, etc.) without asking for permission.
