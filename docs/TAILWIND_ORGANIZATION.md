# Organizing Tailwind CSS in Phoenix HEEx Templates

This document is for contributors writing HEEx templates in Stride who want long
Tailwind class lists to stay readable. It shows how to move them into function
components. The examples use placeholder module names and only theme-aware
classes, as the [Dark Mode Contract](dark-mode-contract.md) requires, so the
same classes pass `mix dark_mode.scan` when you copy them into
`lib/kanban_web/`.

## The Challenge

When using Tailwind CSS in HEEx templates, long lists of utility classes can make templates hard to read and maintain. Stride's house rule is never to use `@apply` when writing raw CSS (see the "JS and CSS guidelines" in [AGENTS.md](../AGENTS.md)), so we need other ways to keep class lists manageable.

## Solution: Phoenix Function Components

The recommended approach is to extract reusable UI elements into Phoenix function components. This provides:

1. **Readability**: Templates focus on structure, not styling details
2. **Reusability**: Components can be used across multiple pages
3. **Maintainability**: Style changes happen in one place
4. **Type Safety**: Attributes declared with `attr` are checked at compile time: a missing required attribute or an undeclared one produces a compiler warning
5. **Flexibility**: Components can accept dynamic classes via `@class` attribute

## Implementation Example

The module and file names below are placeholders: replace `<Feature>` with the
area you are working on. For real components built this way, see
`lib/kanban_web/components/nav_components.ex` (for example `nav_btn_primary/1`)
and `lib/kanban_web/components/marketing_components.ex`.

### 1. Create a Component Module

File: `lib/kanban_web/components/<feature>_components.ex`

```elixir
defmodule KanbanWeb.<Feature>Components do
  use Phoenix.Component

  attr :href, :string, required: true
  attr :class, :string, default: ""
  slot :inner_block, required: true

  def btn_primary(assigns) do
    ~H"""
    <.link
      href={@href}
      class={[
        "btn btn-primary text-sm font-medium px-4 py-2",
        "rounded-lg shadow-sm hover:shadow-md transition-all",
        @class
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end
end
```

### 2. Import Components in Your HTML Module

File: `lib/kanban_web/controllers/<feature>_html.ex`

```elixir
defmodule KanbanWeb.<Feature>HTML do
  use KanbanWeb, :html

  import KanbanWeb.<Feature>Components

  embed_templates "<feature>_html/*"
end
```

`lib/kanban_web/controllers/page_html.ex` does the same with
`import KanbanWeb.MarketingComponents`.

### 3. Use Components in Templates

**Before** (hard to read):
```heex
<.link
  href={~p"/users/register"}
  class="btn btn-primary text-sm font-medium px-4 py-2 rounded-lg shadow-sm hover:shadow-md transition-all"
>
  {gettext("Get Started Free")}
</.link>
```

**After** (clean and readable):
```heex
<.btn_primary href={~p"/users/register"}>
  {gettext("Get Started Free")}
</.btn_primary>
```

## Best Practices

### 1. Use List Syntax for Classes

When defining components, use list syntax for better organization:

```elixir
class={[
  "base classes here",
  "hover states here",
  "responsive classes here",
  @class  # Allow override
]}
```

### 2. Support Class Override

Always include a `@class` attribute to allow customization:

```elixir
attr :class, :string, default: ""
slot :inner_block, required: true

def my_component(assigns) do
  ~H"""
  <div class={["base-classes", @class]}>
    {render_slot(@inner_block)}
  </div>
  """
end
```

### 3. Use Conditional Classes

For variants, use conditional logic in the class list. Keep every variant on
theme-aware classes; the token mapping table in the
[Dark Mode Contract](dark-mode-contract.md) lists the substitutions for
hardcoded colours:

```elixir
attr :tone, :string, default: "neutral", values: ~w(neutral danger)
slot :inner_block, required: true

def card(assigns) do
  ~H"""
  <div class={[
    "p-4 rounded-lg border border-base-300",
    @tone == "neutral" && "bg-base-200 text-base-content",
    @tone == "danger" && "bg-base-100 text-[var(--color-error-ink)]"
  ]}>
    {render_slot(@inner_block)}
  </div>
  """
end
```

### 4. Keep Layout Classes in Templates

Don't extract everything into components. Keep layout-specific classes in templates:

```heex
<div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
  <.page_title>
    {gettext("My Title")}
  </.page_title>
</div>
```

### 5. Handle Translations Properly

Every string a user can see is translated with `gettext`. A component translates
its own fixed text (for example the empty-state and binary-file messages in
`lib/kanban_web/components/review_diff_panel.ex`, which gets `gettext` through
`use KanbanWeb, :html`). Text the caller passes in is translated by the caller:

```elixir
# Component definition
attr :title, :string, required: true

def card_title(assigns) do
  ~H"""
  <h3>{@title}</h3>
  """
end

# Template usage
<.card_title title={gettext("My Title")} />
```

## Benefits Over Custom CSS

1. **Full Tailwind Integration**: Uses actual Tailwind classes, not custom CSS
2. **Responsive**: All Tailwind responsive modifiers work
3. **Theme Compatible**: Works in light and dark mode when the classes use daisyUI or Stride tokens
4. **JIT Optimized**: Tailwind's JIT compiler can optimize usage
5. **IntelliSense**: Editor autocomplete works for Tailwind classes
6. **Documentation**: Tailwind docs are directly applicable

## Alternative: Component Files

For larger groups of components, give each area its own component file. These
are some of the existing ones in `lib/kanban_web/components/`:

```
lib/kanban_web/components/
  ├── core_components.ex       # Shared inputs, buttons, icons
  ├── nav_components.ex        # Top-nav links and buttons
  └── marketing_components.ex  # Marketing page sections
```

This keeps related components organized and makes them easier to find.
