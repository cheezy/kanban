# Organizing Tailwind CSS in Phoenix HEEx Templates

## The Challenge

When using Tailwind CSS in HEEx templates, long lists of utility classes can make templates hard to read and maintain. Since Tailwind v4 doesn't support the `@apply` directive, we need alternative approaches.

## Solution: Phoenix Function Components

The recommended approach is to extract reusable UI elements into Phoenix function components. This provides:

1. **Readability**: Templates focus on structure, not styling details
2. **Reusability**: Components can be used across multiple pages
3. **Maintainability**: Style changes happen in one place
4. **Type Safety**: Component attributes are validated at compile time
5. **Flexibility**: Components can accept dynamic classes via `@class` attribute

## Implementation Example

### 1. Create a Component Module

File: `lib/kanban_web/components/home_components.ex`

```elixir
defmodule KanbanWeb.HomeComponents do
  use Phoenix.Component
  import KanbanWeb.CoreComponents

  attr :class, :string, default: ""
  slot :inner_block, required: true

  def btn_primary(assigns) do
    ~H"""
    <.link
      href={@href}
      class={[
        "inline-flex items-center justify-center px-8 py-4 text-base font-semibold",
        "text-white bg-gradient-to-r from-blue-600 to-blue-700",
        "hover:from-blue-700 hover:to-blue-800 rounded-lg shadow-lg hover:shadow-xl",
        "transition-all transform hover:-translate-y-0.5",
        @class
      ]}
    >
      <%= render_slot(@inner_block) %>
    </.link>
    """
  end
end
```

### 2. Import Components in Your HTML Module

File: `lib/kanban_web/controllers/page_html.ex`

```elixir
defmodule KanbanWeb.PageHTML do
  use KanbanWeb, :html

  import KanbanWeb.HomeComponents

  embed_templates "page_html/*"
end
```

### 3. Use Components in Templates

**Before** (hard to read):
```heex
<.link
  href={~p"/users/register"}
  class="inline-flex items-center justify-center px-8 py-4 text-base font-semibold text-white bg-gradient-to-r from-blue-600 to-blue-700 hover:from-blue-700 hover:to-blue-800 rounded-lg shadow-lg hover:shadow-xl transition-all transform hover:-translate-y-0.5"
>
  Get Started Free
</.link>
```

**After** (clean and readable):
```heex
<.btn_primary href={~p"/users/register"}>
  Get Started Free
</..btn_primary>
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

def my_component(assigns) do
  ~H"""
  <div class={["base-classes", @class]}>
    <%= render_slot(@inner_block) %>
  </div>
  """
end
```

### 3. Use Conditional Classes

For variants, use conditional logic in the class list:

```elixir
attr :color, :string, default: "blue"

def card(assigns) do
  ~H"""
  <div class={[
    "p-4 rounded-lg",
    @color == "blue" && "bg-blue-50 text-blue-900",
    @color == "red" && "bg-red-50 text-red-900"
  ]}>
    <%= render_slot(@inner_block) %>
  </div>
  """
end
```

### 4. Keep Layout Classes in Templates

Don't extract everything into components. Keep layout-specific classes in templates:

```heex
<div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
  <HomeComponents.hero_title>
    My Title
  </HomeComponents.hero_title>
</div>
```

### 5. Handle Translations Properly

Pass translated text as attributes, don't use `gettext` inside components:

```elixir
# Component definition
attr :title, :string, required: true

def card(assigns) do
  ~H"""
  <h3>{@title}</h3>
  """
end

# Template usage
<HomeComponents.card title={gettext("My Title")} />
```

## Benefits Over Custom CSS

1. **Full Tailwind Integration**: Uses actual Tailwind classes, not custom CSS
2. **Responsive**: All Tailwind responsive modifiers work
3. **Theme Compatible**: Works with dark mode and other Tailwind themes
4. **JIT Optimized**: Tailwind's JIT compiler can optimize usage
5. **IntelliSense**: Editor autocomplete works for Tailwind classes
6. **Documentation**: Tailwind docs are directly applicable

## Alternative: Component Files

For very complex components, you can also create separate component files:

```
lib/kanban_web/components/
  ├── home_components.ex      # Home page specific
  ├── card_components.ex      # Reusable cards
  └── button_components.ex    # Reusable buttons
```

This keeps related components organized and makes them easier to find.
