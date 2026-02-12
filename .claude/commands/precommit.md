---
description: Run all precommit checks (tests, credo, sobelow, coverage)
---

Run the full precommit checklist for this project:

1. Run `mix test --cover` and ensure all tests pass with adequate coverage
2. Run `mix credo --strict` and fix any code quality issues
3. Run `mix sobelow --config` and fix any security issues
4. Run `mix format --check-formatted` to verify code formatting
5. Report the results of all checks

If any check fails, fix the issues and re-run until all checks pass.
