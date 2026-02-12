---
description: Database operations (migrations, seeds, queries)
---

Help with database operations:

1. Ask the user what database operation they need
2. For migrations: Use `mix ecto.gen.migration <name>` to create, then help write the migration
3. For running migrations: Use `mix ecto.migrate`
4. For queries: Use the TideWave MCP server's `mcp__tidewave__execute_sql_query` to run SQL queries
5. For schemas: Use `mcp__tidewave__get_ecto_schemas` to list available schemas

Always follow Ecto best practices from AGENTS.md.
