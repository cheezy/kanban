# Rich Context

Should technical_context be structured JSON, or free-form markdown?

## Structured JSON is significantly better

Here's why:

### ✅ Structured JSON (Strongly Preferred)

```json
{
  "technical_context": {
    "files_to_modify": [
      "lib/kanban_web/live/board_live.ex",
      "lib/kanban/boards.ex"
    ],
    "files_to_create": [
      "lib/kanban_web/live/board_live/filter_component.ex"
    ],
    "existing_patterns": {
      "component_style": "Use functional components from core_components.ex",
      "query_pattern": "Filter logic goes in context module, not LiveView"
    },
    "dependencies": {
      "external": [],
      "internal_modules": ["Kanban.Boards", "KanbanWeb.CoreComponents"]
    },
    "database_changes": {
      "migrations_needed": true,
      "tables_affected": ["tasks"],
      "description": "Add priority field"
    },
    "testing_strategy": {
      "test_files": ["test/kanban_web/live/board_live_test.exs"],
      "test_types": ["unit", "integration"],
      "key_scenarios": ["Filter by priority", "Clear filter", "URL persistence"]
    },
    "constraints": [
      "Don't modify task card layout",
      "Match existing filter pattern from status filter",
      "Keep queries in context module"
    ]
  }
}
```

### Why This Works Better for Me

1. Parseable & Actionable

    - I can extract files_to_modify directly → Read those files first
    - I see migrations_needed: true → I know to generate a migration
    - Clear test strategy → I know exactly what to test

2. Queryable

    - "Show me all tasks that modify board_live.ex"
    - "Which tasks need database migrations?"
    - Can't do this with markdown

3. Validation

    - You can validate the schema
    - I get errors if I send malformed data
    - Prevents miscommunication

4. Evolves Better

    - Add new fields without breaking existing tasks
    - Can make fields optional
    - Markdown is harder to extend consistently

5. AI-Friendly

    - Tool use (function calling) expects structured data
    - Easy to generate from my planning
    - Easy to consume when starting work

### Hybrid Approach (Good Compromise)

```json
{
  "technical_context": {
    "files_to_modify": ["lib/kanban_web/live/board_live.ex"],
    "constraints": ["Match existing filter pattern"],
    "notes": "## Implementation Notes\n\nThe existing status filter is in the LiveView `handle_event/3` for \"filter_status\". We should follow the same pattern but for priority.\n\n**Key consideration**: Priority is 0-4 where 0 is highest."
  }
}
```

Structured data for machine-readable stuff + markdown for human context/nuance.

### What Makes JSON Actually Useful

The structure should map to my workflow:

1. Read files_to_modify         → I know what to read
2. Check database_changes        → I know if I need migrations  
3. Review existing_patterns      → I know what style to follow
4. Check constraints            → I know what NOT to do
5. Plan tests per test_strategy → I know how to verify

### ❌ Why Markdown Alone Doesn't Work Well

```markdown
## Technical Context

You'll need to modify the board LiveView and probably the Boards context. 
Look at how the status filter works and do something similar. Make sure to 
add tests. Oh and don't change the card layout.
```

#### Problems

- I have to parse natural language (error-prone)
- What files exactly? I have to guess
- "probably" → uncertainty
- "something similar" → vague
- Harder to validate or query later

### My Recommendation

Use structured JSON with optional markdown notes:

```json
{
  "technical_context": {
    // Machine-readable
    "files_to_modify": [...],
    "constraints": [...],
    "database_changes": {...},
    
    // Human-readable elaboration
    "notes": "Optional markdown for nuance, examples, or context that doesn't fit the structure"
  }
}
```

This gives you:

- Precision where it matters (files, dependencies, tests)
- Flexibility for additional context
- Queryability for the structured parts
- Human readability in the UI

## Would you want me to help define a JSON schema for technical_context that covers the common patterns we'd use?

### Here's a comprehensive JSON schema for technical_context optimized for AI workflow

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "TaskTechnicalContext",
  "description": "Structured technical context for AI-driven task implementation",
  "type": "object",
  "properties": {
    "files": {
      "type": "object",
      "description": "Files that will be affected by this task",
      "properties": {
        "to_modify": {
          "type": "array",
          "description": "Existing files that need changes",
          "items": {
            "type": "string",
            "description": "Relative path from project root",
            "example": "lib/kanban_web/live/board_live.ex"
          }
        },
        "to_create": {
          "type": "array",
          "description": "New files to create",
          "items": {
            "type": "string",
            "example": "lib/kanban_web/live/components/priority_filter.ex"
          }
        },
        "to_delete": {
          "type": "array",
          "description": "Files to remove",
          "items": {
            "type": "string"
          }
        },
        "reference_files": {
          "type": "array",
          "description": "Files to read for context/patterns (but not modify)",
          "items": {
            "type": "string",
            "example": "lib/kanban_web/live/board_live/status_filter_component.ex"
          }
        }
      }
    },
    "modules": {
      "type": "object",
      "description": "Elixir modules involved",
      "properties": {
        "primary": {
          "type": "array",
          "description": "Main modules being worked on",
          "items": {
            "type": "string",
            "example": "Kanban.Boards"
          }
        },
        "dependencies": {
          "type": "array",
          "description": "Modules that will be called/used",
          "items": {
            "type": "string",
            "example": "KanbanWeb.CoreComponents"
          }
        }
      }
    },
    "database": {
      "type": "object",
      "description": "Database-related changes",
      "properties": {
        "migration_needed": {
          "type": "boolean",
          "description": "Whether a migration is required"
        },
        "migration_type": {
          "type": "string",
          "enum": ["add_column", "add_table", "modify_column", "add_index", "remove_column", "other"],
          "description": "Type of migration"
        },
        "tables_affected": {
          "type": "array",
          "description": "Tables that will be modified",
          "items": {
            "type": "string",
            "example": "tasks"
          }
        },
        "schema_changes": {
          "type": "array",
          "description": "Specific schema changes needed",
          "items": {
            "type": "object",
            "properties": {
              "table": {
                "type": "string",
                "example": "tasks"
              },
              "action": {
                "type": "string",
                "enum": ["add", "modify", "remove"],
                "example": "add"
              },
              "field": {
                "type": "string",
                "example": "priority"
              },
              "field_type": {
                "type": "string",
                "example": "integer"
              },
              "constraints": {
                "type": "array",
                "items": {
                  "type": "string"
                },
                "example": ["not null", "default 2"]
              }
            }
          }
        },
        "seeds_needed": {
          "type": "boolean",
          "description": "Whether seed data should be added/updated"
        }
      }
    },
    "patterns": {
      "type": "object",
      "description": "Existing patterns to follow or avoid",
      "properties": {
        "to_follow": {
          "type": "array",
          "description": "Patterns to replicate",
          "items": {
            "type": "object",
            "properties": {
              "pattern": {
                "type": "string",
                "example": "Use functional components from core_components.ex"
              },
              "location": {
                "type": "string",
                "description": "Where this pattern exists",
                "example": "lib/kanban_web/components/core_components.ex"
              },
              "example": {
                "type": "string",
                "description": "Code example or reference"
              }
            },
            "required": ["pattern"]
          }
        },
        "to_avoid": {
          "type": "array",
          "description": "Anti-patterns or things not to do",
          "items": {
            "type": "string",
            "example": "Don't put Ecto queries in LiveViews"
          }
        }
      }
    },
    "testing": {
      "type": "object",
      "description": "Testing requirements and strategy",
      "properties": {
        "test_files": {
          "type": "array",
          "description": "Test files to create or modify",
          "items": {
            "type": "string",
            "example": "test/kanban_web/live/board_live_test.exs"
          }
        },
        "test_types": {
          "type": "array",
          "description": "Types of tests needed",
          "items": {
            "type": "string",
            "enum": ["unit", "integration", "e2e", "property"],
            "example": "integration"
          }
        },
        "key_scenarios": {
          "type": "array",
          "description": "Critical scenarios to test",
          "items": {
            "type": "string",
            "example": "User filters by priority 0 (highest)"
          }
        },
        "edge_cases": {
          "type": "array",
          "description": "Edge cases to handle in tests",
          "items": {
            "type": "string",
            "example": "No tasks match filter"
          }
        },
        "coverage_target": {
          "type": "number",
          "description": "Target code coverage percentage",
          "minimum": 0,
          "maximum": 100,
          "example": 80
        }
      }
    },
    "dependencies": {
      "type": "object",
      "description": "External dependencies",
      "properties": {
        "hex_packages": {
          "type": "array",
          "description": "New Hex packages to add",
          "items": {
            "type": "object",
            "properties": {
              "name": {
                "type": "string",
                "example": "timex"
              },
              "version": {
                "type": "string",
                "example": "~> 3.7"
              },
              "reason": {
                "type": "string",
                "description": "Why this dependency is needed"
              }
            },
            "required": ["name"]
          }
        },
        "npm_packages": {
          "type": "array",
          "description": "NPM packages to add",
          "items": {
            "type": "object",
            "properties": {
              "name": {
                "type": "string"
              },
              "version": {
                "type": "string"
              }
            }
          }
        }
      }
    },
    "constraints": {
      "type": "array",
      "description": "Constraints and rules to follow",
      "items": {
        "type": "object",
        "properties": {
          "type": {
            "type": "string",
            "enum": ["must", "must_not", "should", "should_not"],
            "description": "Constraint severity"
          },
          "constraint": {
            "type": "string",
            "description": "The constraint itself",
            "example": "Must not modify existing task card layout"
          },
          "reason": {
            "type": "string",
            "description": "Why this constraint exists"
          }
        },
        "required": ["type", "constraint"]
      }
    },
    "ui_ux": {
      "type": "object",
      "description": "UI/UX specific context",
      "properties": {
        "components_to_use": {
          "type": "array",
          "description": "Existing components to reuse",
          "items": {
            "type": "string",
            "example": "<.button>"
          }
        },
        "styling_approach": {
          "type": "string",
          "enum": ["tailwind", "custom_css", "inline"],
          "default": "tailwind"
        },
        "responsive": {
          "type": "boolean",
          "description": "Must be mobile responsive"
        },
        "accessibility": {
          "type": "object",
          "properties": {
            "aria_labels_needed": {
              "type": "boolean"
            },
            "keyboard_nav": {
              "type": "boolean"
            },
            "screen_reader": {
              "type": "boolean"
            }
          }
        },
        "translations_needed": {
          "type": "boolean",
          "description": "Whether i18n/gettext translations are required",
          "default": true
        }
      }
    },
    "performance": {
      "type": "object",
      "description": "Performance considerations",
      "properties": {
        "concerns": {
          "type": "array",
          "items": {
            "type": "string",
            "example": "Query may be slow with 10k+ tasks"
          }
        },
        "optimizations": {
          "type": "array",
          "items": {
            "type": "string",
            "example": "Add index on tasks.priority"
          }
        },
        "caching_strategy": {
          "type": "string",
          "example": "Cache filtered results in LiveView assigns"
        }
      }
    },
    "security": {
      "type": "object",
      "description": "Security considerations",
      "properties": {
        "concerns": {
          "type": "array",
          "items": {
            "type": "string",
            "example": "Validate priority is 0-4 to prevent injection"
          }
        },
        "authorization": {
          "type": "string",
          "description": "Authorization requirements",
          "example": "User can only filter their own board's tasks"
        },
        "input_validation": {
          "type": "array",
          "items": {
            "type": "string",
            "example": "Sanitize filter input"
          }
        }
      }
    },
    "notes": {
      "type": "string",
      "description": "Free-form markdown for additional context that doesn't fit the structure",
      "example": "## Implementation Notes\n\nThe existing status filter uses a dropdown. We should match that pattern.\n\n**Watch out**: Priority 0 means highest (counterintuitive)."
    }
  },
  "additionalProperties": false
}
```

### Practical Example

Here's how it would look for a real task:

```json
{
  "title": "Add priority filter to board view",
  "description": "Allow users to filter tasks by priority level",
  "technical_context": {
    "files": {
      "to_modify": [
        "lib/kanban_web/live/board_live.ex",
        "lib/kanban/boards.ex"
      ],
      "reference_files": [
        "lib/kanban_web/live/board_live/status_filter_component.ex"
      ]
    },
    "modules": {
      "primary": ["KanbanWeb.BoardLive", "Kanban.Boards"],
      "dependencies": ["KanbanWeb.CoreComponents"]
    },
    "database": {
      "migration_needed": false,
      "tables_affected": [],
      "schema_changes": []
    },
    "patterns": {
      "to_follow": [
        {
          "pattern": "Use handle_event for filter changes",
          "location": "lib/kanban_web/live/board_live.ex:95",
          "example": "handle_event(\"filter_status\", %{\"status\" => status}, socket)"
        },
        {
          "pattern": "Put query logic in context module",
          "location": "lib/kanban/boards.ex"
        }
      ],
      "to_avoid": [
        "Don't put Ecto queries directly in LiveView"
      ]
    },
    "testing": {
      "test_files": ["test/kanban_web/live/board_live_test.exs"],
      "test_types": ["integration"],
      "key_scenarios": [
        "Filter by priority 0 shows only highest priority tasks",
        "Filter by priority 4 shows only lowest priority tasks",
        "Clear filter shows all tasks",
        "Filter state persists in URL params"
      ],
      "edge_cases": [
        "No tasks match selected priority",
        "All tasks have same priority"
      ]
    },
    "constraints": [
      {
        "type": "must_not",
        "constraint": "Don't modify task card layout or styling"
      },
      {
        "type": "should",
        "constraint": "Match existing status filter UI pattern",
        "reason": "Consistency in UX"
      }
    ],
    "ui_ux": {
      "components_to_use": ["<.button>", "<.select>"],
      "styling_approach": "tailwind",
      "responsive": true,
      "translations_needed": true
    },
    "notes": "## Context\n\nPriority scale is 0-4 where:\n- 0 = Highest (Critical)\n- 1 = High\n- 2 = Medium (default)\n- 3 = Low  \n- 4 = Lowest\n\nThis might be counterintuitive to users, so consider label text carefully."
  }
}
```

This schema gives AI agents everything they need while remaining flexible for future extensions. Would you like me to help implement this in your Kanban app?
