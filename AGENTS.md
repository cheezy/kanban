# This is a web application written using the Phoenix web framework

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps
- Use the HexDoc mcp server to read the documentation about project dependencies
- When you add a new dependency or update an existing dependency run `mix usage_rules.sync` to update the AGENTS.md file and phoenix-framework Skill
- Always provide translations of all text that is visible in the UI
- Never put Ecto queries directly in LiveViews. Instead always put them in the appropriate context module

### Module design and complexity

**IMPORTANT**: When working with modules that are becoming too large or complex:

- **Monitor module size and complexity**: If a module exceeds ~500-600 lines or contains deeply nested logic with high cyclomatic complexity, consider refactoring
- **Break out logical concerns**: Extract related functionality into separate, focused modules that handle a single responsibility
- **Use helper modules**: For complex domains (like task management), consider creating dedicated modules for specific sub-concerns:
  - Positioning logic (e.g., `Tasks.Positioning`)
  - Dependency management (e.g., `Tasks.Dependencies`)
  - Validation logic (e.g., `Tasks.Validation`)
  - Query builders (e.g., `Tasks.Queries`)
- **Extract helper functions**: When a function becomes complex (cyclomatic complexity > 9), extract complex conditional logic into smaller, well-named helper functions
- **Maintain clear module boundaries**: Each module should have a clear, single purpose with a well-defined public API
- **Document module organization**: When splitting modules, update documentation to explain the new structure and how modules relate to each other

This approach improves:
- Code maintainability and readability
- Test isolation and coverage
- Collaboration between developers
- Ability to reason about individual components
- Credo compliance and code quality metrics

### UI/UX guidelines

- **Always follow existing application styles and patterns** when adding new UI elements
- Before creating custom styles, check `core_components.ex` for existing components like `<.input>`, `<.button>`, `<.form>`, etc.
- When adding form fields, use the standard component structure with `fieldset`, `label`, and `span.label` classes to match existing forms
- New buttons should use the `<.button>` component without custom classes unless specifically requested
- Maintain consistency with existing color schemes, spacing, and typography throughout the application

### Dark Mode Verification Guidelines

**CRITICAL**: Always verify UI changes work in BOTH light and dark modes before considering a task complete.

#### When to Verify Dark Mode
- After adding or modifying any UI component
- After changing CSS styles or Tailwind classes
- After updating modal, form, or layout components
- When users report visibility issues
- Before marking any UI-related task as complete

#### Common Dark Mode Issues and Fixes

**1. Hardcoded Colors**
- **Issue**: Using hardcoded Tailwind colors like `text-gray-900`, `bg-white`, `border-gray-200`
- **Fix**: Replace with theme-aware daisyUI colors:
  - `text-gray-900` → `text-base-content`
  - `text-gray-600` → `text-base-content opacity-70`
  - `text-gray-500` → `text-base-content opacity-60`
  - `bg-white` → `bg-base-100`
  - `bg-gray-50` → `bg-base-200`
  - `border-gray-200` → `border-base-300`

**2. Form Elements**
- **Issue**: Labels and inputs invisible in dark mode
- **Fix**: Ensure labels use `text-base-content` with full opacity
- **Fix**: Ensure inputs have `bg-base-100` background and `text-base-content` text
- Add visible borders with `border-base-300`

**3. Buttons and Links**
- **Issue**: Low contrast buttons/links in dark mode
- **Fix**: Use `btn-primary` classes or override with `var(--color-primary)` background
- **Fix**: Ensure button text uses `var(--color-primary-content)`
- **Fix**: Links should use `var(--color-primary)` for visibility

**4. Modal Backgrounds**
- **Issue**: White modal backgrounds in dark mode
- **Fix**: Use `bg-base-100` instead of `bg-white`
- **Fix**: Modal backdrop should use `bg-base-200/90` for proper overlay

#### Dark Mode Verification Process

**Step 1: Use browser_eval to test both modes**
```elixir
# Test in dark mode
await page.eval(() => {
  localStorage.setItem('phx:theme', 'dark');
  document.documentElement.setAttribute('data-theme', 'dark');
});

# Check element visibility
await page.eval(() => {
  const el = document.querySelector('.your-element');
  const style = window.getComputedStyle(el);
  console.log('Color:', style.color);
  console.log('Background:', style.backgroundColor);
});

# Test in light mode
await page.eval(() => {
  localStorage.setItem('phx:theme', 'light');
  document.documentElement.setAttribute('data-theme', 'light');
});
```

**Step 2: Verify contrast**
- Light mode: Dark text (oklch ~0.21) on light backgrounds (oklch ~0.98)
- Dark mode: Light text (oklch ~0.97) on dark backgrounds (oklch ~0.30)
- Buttons: High contrast in both modes using primary colors

**Step 3: Test all sections**
- Headers/titles
- Form labels and inputs
- Buttons and links
- Text content
- Borders and dividers
- Modal overlays

#### CSS Patterns for Dark Mode Support

**In assets/css/app.css:**
```css
@layer components {
  /* Labels with full opacity */
  .label {
    color: var(--color-base-content) !important;
    opacity: 1 !important;
  }

  /* Inputs with theme-aware backgrounds */
  input.input,
  textarea.textarea,
  select.select {
    background-color: var(--color-base-100) !important;
    color: var(--color-base-content) !important;
    border-color: var(--color-base-300) !important;
  }

  /* High contrast buttons */
  .btn-primary {
    background-color: var(--color-primary) !important;
    color: var(--color-primary-content) !important;
  }

  /* Visible links */
  a {
    color: var(--color-primary) !important;
  }
}
```

**In templates:**
```heex
<!-- Use theme-aware classes -->
<h1 class="text-base-content">Title</h1>
<p class="text-base-content opacity-70">Subtitle</p>
<div class="bg-base-100 border-base-300">Content</div>
```

#### Remember: Session Summary

During this session, the following dark mode fixes were applied:
1. Modal container backgrounds (`bg-white` → `bg-base-100`)
2. Form labels (added full opacity and `text-base-content`)
3. Text inputs (added `bg-base-100` and `text-base-content`)
4. Headers and subtitles (`text-gray-900` → `text-base-content`)
5. Task History section (all text and borders)
6. Comments section (backgrounds and text)
7. Buttons and links (increased contrast with primary colors)

**Files modified:**
- `lib/kanban_web/components/delayed_modal.ex`
- `lib/kanban_web/components/core_components.ex`
- `lib/kanban_web/live/task_live/form_component.html.heex`
- `assets/css/app.css`

### Quality guidelines  

**ALWAYS** follow these quality guidelines:

- **IMPORTANT**: When you complete a task that has new functions write unit tests for the new function
- **IMPORTANT**: When you complete a task that updates code make sure all existing unit tests pass and write new tests if needed
- Each time you write or update a unit test run them with `mix test` and ensure they pass
- **IMPORTANT**: When you complete a task run `mix test --cover` and ensure coverage is above the threshold.
- **IMPORTANT**: When you complete a task run `mix credo --strict` to check for code quality issues and fix them

### Security guidelines

**ALWAYS** follow these security guidelines:

- **IMPORTANT**: When you add or update a dependency run `mix deps.audit` and `mix hex.audit` to check for security issues
- **IMPORTANT**: When you add or update a dependency run `mix hex.outdated` to check for outdated dependencies
- **IMPORTANT**: When you complete a task run `mix sobelow --config` to check for security issues and fix any issue

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique, world-class design
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- phoenix-gen-auth-start -->
## Authentication

- **Always** handle authentication flow at the router level with proper redirects
- **Always** be mindful of where to place routes. `phx.gen.auth` creates multiple router plugs and `live_session` scopes:
  - A plug `:fetch_current_scope_for_user` that is included in the default browser pipeline
  - A plug `:require_authenticated_user` that redirects to the log in page when the user is not authenticated
  - A `live_session :current_user` scope - for routes that need the current user but don't require authentication, similar to `:fetch_current_scope_for_user`
  - A `live_session :require_authenticated_user` scope - for routes that require authentication, similar to the plug with the same name
  - In both cases, a `@current_scope` is assigned to the Plug connection and LiveView socket
  - A plug `redirect_if_user_is_authenticated` that redirects to a default path in case the user is authenticated - useful for a registration page that should only be shown to unauthenticated users
- **Always let the user know in which router scopes, `live_session`, and pipeline you are placing the route, AND SAY WHY**
- `phx.gen.auth` assigns the `current_scope` assign - it **does not assign a `current_user` assign**
- Always pass the assign `current_scope` to context modules as first argument. When performing queries, use `current_scope.user` to filter the query results
- To derive/access `current_user` in templates, **always use the `@current_scope.user`**, never use **`@current_user`** in templates or LiveViews
- **Never** duplicate `live_session` names. A `live_session :current_user` can only be defined __once__ in the router, so all routes for the `live_session :current_user`  must be grouped in a single block
- Anytime you hit `current_scope` errors or the logged in session isn't displaying the right content, **always double check the router and ensure you are using the correct plug and `live_session` as described below**

### Routes that require authentication

LiveViews that require login should **always be placed inside the __existing__ `live_session :require_authenticated_user` block**:

    scope "/", AppWeb do
      pipe_through [:browser, :require_authenticated_user]

      live_session :require_authenticated_user,
        on_mount: [{KanbanWeb.UserAuth, :require_authenticated}] do
        # phx.gen.auth generated routes
        live "/users/settings", UserLive.Settings, :edit
        live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
        # our own routes that require logged in user
        live "/", MyLiveThatRequiresAuth, :index
      end
    end

Controller routes must be placed in a scope that sets the `:require_authenticated_user` plug:

    scope "/", AppWeb do
      pipe_through [:browser, :require_authenticated_user]

      get "/", MyControllerThatRequiresAuth, :index
    end

### Routes that work with or without authentication

LiveViews that can work with or without authentication, **always use the __existing__ `:current_user` scope**, ie:

    scope "/", MyAppWeb do
      pipe_through [:browser]

      live_session :current_user,
        on_mount: [{KanbanWeb.UserAuth, :mount_current_scope}] do
        # our own routes that work with or without authentication
        live "/", PublicLive
      end
    end

Controllers automatically have the `current_scope` available if they use the `:browser` pipeline.

<!-- phoenix-gen-auth-end -->

<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best 
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
# Elixir Core Usage Rules

## Pattern Matching
- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid
- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design
- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures
- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing
- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
# OTP Usage Rules

## GenServer Best Practices
- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication
- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance
- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async
- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
