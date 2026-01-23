# Read-Only Boards Design

**Date:** 2026-01-23
**Purpose:** Enable boards to be publicly accessible via direct link for open source projects

## Overview

Add a board-level `read_only` flag that allows non-member users to view a board when they have the direct URL. This enables public sharing of project boards while maintaining access control for modifications.

## Requirements

- Owner can toggle read-only mode via board settings
- When `read_only: true`, anyone with the board URL can view it
- Non-members are treated as read-only viewers
- Owner and "modify" users retain full permissions
- Board index only shows boards where user is a member (no public listing)
- API access bypasses this restriction (uses API token authentication)
- Non-member viewers get the same UX as explicitly assigned read-only users

## Database Schema

### Migration

Add `read_only` boolean field to `boards` table:

```elixir
add :read_only, :boolean, default: false, null: false
```

### Board Schema (lib/kanban/boards/board.ex)

```elixir
field :read_only, :boolean, default: false
```

Update changeset to include `:read_only`:
```elixir
|> cast(attrs, [:name, :description, :field_visibility, :read_only])
```

## Authorization & Access Control

### Current Behavior

```elixir
# Boards.get_board!(id, user)
# Raises if user is not a board member
```

### New Behavior

When accessing `/boards/:id`:

1. Check if user is a board member
2. If no membership exists:
   - Load board by ID only
   - Check if `board.read_only == true`
   - If yes: Allow access with `user_access = nil`
   - If no: Raise 404/unauthorized (current behavior)
3. If membership exists: Use actual `user_access` from `BoardUser`

### Permission Calculation

```elixir
user_access = Boards.get_user_access(board.id, user.id) # nil for non-members
can_modify = user_access in [:owner, :modify]          # false when nil
is_owner = user_access == :owner                        # false when nil
```

When `user_access` is `nil`:
- `can_modify: false` → all modification buttons hidden
- `is_owner: false` → no settings/admin controls visible
- Full read-only experience (same as assigned read-only users)

### Board Index

No changes - continues to show only boards where user is a member via `BoardUser` relationship.

## UI Components

### Board Settings Page

Add checkbox in board edit form (owner-only access):

```heex
<.input
  field={@form[:read_only]}
  type="checkbox"
  label="Make board publicly readable"
/>
<p class="text-sm text-gray-600 mt-1">
  When enabled, anyone with the link can view this board. Only assigned members can make changes.
</p>
```

### Board View Banner

Show notice when non-member views a read-only board:

```heex
<%= if is_nil(@user_access) do %>
  <div class="bg-blue-50 border-l-4 border-blue-400 p-4 mb-4">
    <p class="text-sm text-blue-700">
      You are viewing this board in read-only mode.
    </p>
  </div>
<% end %>
```

### Existing Permission Controls

No changes needed - all action buttons/forms already hidden when `can_modify: false`.

## Implementation Plan

### Files to Modify

1. **Migration:** `priv/repo/migrations/TIMESTAMP_add_read_only_to_boards.exs`
2. **Schema:** `lib/kanban/boards/board.ex`
3. **Context:** `lib/kanban/boards/boards.ex`
4. **LiveView:** `lib/kanban_web/live/board_live/show.ex`
5. **Form:** `lib/kanban_web/live/board_live/form.ex` or similar
6. **Template:** `lib/kanban_web/live/board_live/show.html.heex`

### Context Changes (lib/kanban/boards/boards.ex)

Update `get_board!/2` to handle read-only boards:

```elixir
def get_board!(id, user) do
  board = Repo.get!(Board, id)
  user_access = get_user_access(board.id, user.id)

  cond do
    user_access != nil ->
      # User is a member - return board with their access level
      %{board | user_access: user_access}

    board.read_only ->
      # Non-member accessing read-only board - allow with nil access
      %{board | user_access: nil}

    true ->
      # Non-member accessing private board - raise
      raise Ecto.NoResultsError
  end
end
```

Ensure `get_user_access/2` returns `nil` for non-members (not raising).

## Testing Strategy

### Unit Tests

- Board changeset accepts `read_only` field
- Board changeset validates `read_only` is boolean

### Integration Tests

1. **Non-member access when read_only: true**
   - Non-member can view board
   - `user_access` is `nil`
   - `can_modify` is `false`
   - All modification actions hidden

2. **Non-member access when read_only: false**
   - Non-member receives 404/unauthorized
   - Cannot view board content

3. **Member access when read_only: true**
   - Owner retains full permissions
   - Modify users retain full permissions
   - Read-only users keep read-only access

4. **Toggle read_only setting**
   - Owner can update `read_only` field
   - Non-owners cannot update `read_only` field

5. **Board index**
   - Non-members don't see read-only boards in their list
   - Members see their boards regardless of `read_only` status

## Edge Cases

### Non-authenticated Users

Require login - read-only boards are accessible to any authenticated user, not anonymous visitors.

### API Access

No changes to API - API tokens already provide their own authorization mechanism independent of BoardUser relationships.

### Task Operations

Non-members (with `user_access: nil`) should be blocked from:
- Creating tasks
- Editing tasks
- Moving tasks
- Deleting tasks
- Adding comments (if that feature exists)

This should work automatically since all these operations already check `can_modify`.

## Security Considerations

- Board ID is not secret - read-only boards are discoverable via URL
- Sensitive information should not be stored on read-only boards
- Board can be made private again by toggling `read_only: false`
- Rate limiting on board access should prevent enumeration attacks
