# Flat Table Structure - Implementation Note

## Decision

The tasks table will remain **flat** - all data stored in the tasks table itself using text fields for collections, rather than creating separate normalized tables.

## Text Field Format

Collections (key_files, verification_steps, pitfalls, out_of_scope) are stored as text with simple line-based formatting:

### Key Files
```
lib/kanban/tasks.ex | Task context module
lib/kanban/schemas/task.ex | Task schema
lib/kanban_web/controllers/api/task_controller.ex | API controller
```
Format: `file_path | note` (one per line, note is optional)

### Verification Steps
```
command | mix test test/kanban/tasks_test.exs | All tests pass
manual | Click on task card | Task details modal opens
command | mix precommit | No errors or warnings
```
Format: `step_type | step_text | expected_result` (one per line, expected_result is optional)

### Pitfalls
```
Don't forget to preload associations
Remember to handle nil values gracefully
Avoid N+1 queries when loading task lists
```
Format: One pitfall per line (plain text)

### Out of Scope
```
OAuth authentication
Multi-factor auth
Password reset via SMS
```
Format: One item per line (plain text)

## API/UI Conversion

The `Kanban.Tasks.TextFieldParser` module handles conversion between:
- **Storage format** (text in database)
- **Structured format** (maps/lists for JSON API and UI)

### Example Flow

**Creating a task via API:**
1. API receives JSON with structured data:
   ```json
   {
     "key_files": [
       {"file_path": "lib/kanban/tasks.ex", "note": "Context module"}
     ]
   }
   ```
2. `TextFieldParser.format_key_files/1` converts to text: `"lib/kanban/tasks.ex | Context module"`
3. Text stored in tasks.key_files column

**Retrieving a task via API:**
1. Task loaded from database with text fields
2. `TextFieldParser.parse_key_files/1` converts to structured data
3. JSON API returns structured format

## Benefits

1. **Simple schema** - No joins, no foreign keys, no cascading deletes
2. **Easy migrations** - Just add text columns, no new tables
3. **Flexible** - Can change format without schema migrations
4. **Performance** - Single table query, no N+1 issues
5. **Backward compatible** - All new fields are nullable

## Trade-offs

1. **No database-level querying** of collection items (can't do "find all tasks with file X")
2. **Parsing overhead** when converting to structured format
3. **Text format constraints** (pipe character limitations)

This is acceptable because:
- Collections are small (typically 3-10 items)
- Querying collections is rare
- Parsing is fast and simple
- Text format is human-readable

## Files Updated

- [01-extend-task-schema.md](01-extend-task-schema.md) - Updated with flat structure
- 04-implement-task-crud-api.md - Needs TextFieldParser integration
- 05-add-task-ready-endpoint.md - Text fields don't affect this
- 07-implement-task-dependencies.md - Text fields don't affect this
- 08-display-rich-task-details.md - Parse text fields for display
- 09-add-task-creation-form.md - Format structured input to text fields
