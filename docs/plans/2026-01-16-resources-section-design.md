# Stride Resources Section - Implementation Plan

## Overview

Add a comprehensive resources and how-to section to the Stride application, accessible via top-level navigation. This will provide human users (both developers and non-developers) with searchable, browsable guides featuring text instructions, screenshots, and embedded videos.

## Requirements Summary

- **Target Audience:** Human users (not AI agents) - developers and non-developers
- **Access Pattern:** Top-level nav link → `/resources` landing page with search/filter → individual how-to reading view
- **Content Strategy:** Quick reference for experienced users + learning journey for newcomers
- **Initial Implementation:** Embedded content in LiveView modules (simple, version-controlled, deployed with app)
- **Media Hosting:** Screenshots self-hosted in `/priv/static/`, videos on YouTube/Vimeo
- **Future Evolution:** Phase 2 will add community contributions with database storage

## Architecture

### Navigation Integration
- Add "Resources" link in `lib/kanban_web/components/nav_components.ex` next to "About"
- Add routes in `lib/kanban_web/router.ex`:
  - `live "/resources", ResourcesLive.Index` (landing page)
  - `live "/resources/:id", ResourcesLive.Show` (reading view)

### File Structure
```
lib/kanban_web/
├── live/
│   └── resources_live/
│       ├── index.ex          # Landing page with search/filter
│       ├── show.ex           # Individual how-to reading view
│       └── components.ex     # Reusable components (cards, filters)
├── components/
│   └── nav_components.ex     # Add Resources navigation link
└── router.ex                 # Add /resources routes

priv/static/images/
└── resources/                # Screenshots, thumbnails, diagrams
    ├── create-board-thumb.png
    ├── nav-to-boards.png
    └── [other images...]
```

## Data Structure

### How-To Content Model

Each how-to defined as Elixir map in `ResourcesLive.Index`:

```elixir
%{
  id: "create-first-board",
  title: "Creating Your First Board",
  description: "Learn how to create and configure a new Kanban board",
  tags: ["getting-started", "boards", "beginner"],
  content_type: :text_and_images,  # or :video, :text_only
  estimated_minutes: 3,
  thumbnail: "/images/resources/create-board-thumb.png",
  video_url: nil,  # or YouTube/Vimeo URL
  steps: [
    %{
      title: "Navigate to boards",
      content: "Click the 'Boards' link in the top navigation...",
      image: "/images/resources/nav-to-boards.png",
      image_alt: "Navigation bar highlighting the Boards link"
    },
    # Additional steps...
  ]
}
```

### Tag Categories
- `getting-started` - Onboarding guides
- `boards` - Board management
- `tasks` - Task creation and management
- `hooks` - Hook configuration
- `api` - API usage
- `beginner` - Basic concepts
- `advanced` - Advanced features
- `developer` - Technical/developer-focused

## User Interface Design

### Landing Page (`/resources`)

**Header:**
- Page title: "Resources & How-Tos"
- Subtitle: "Learn how to get the most out of Stride"
- Prominent search bar with placeholder "Search for help..."

**Filters & Sorting:**
- Tag filter pills (Getting Started, Boards, Tasks, Hooks, API, etc.)
- Sort dropdown: Most Relevant (default), Newest, A-Z
- Active filters displayed as dismissible badges

**How-To Grid:**
- Responsive card layout (3 columns desktop, 2 tablet, 1 mobile)
- Each card displays:
  - Thumbnail image or icon
  - Title and brief description
  - Tag badges
  - Content type icon (text/video/mixed)
  - Estimated reading time
  - Clickable to open full content

**LiveView State:**
- `all_how_tos` - Complete list from embedded data
- `filtered_how_tos` - After search/filter/sort
- `search_query` - Current search text
- `active_tags` - Selected tag filters
- `sort_by` - Current sort order

### Reading View (`/resources/:id`)

**Content Layout:**
- Full-width hero with title and description
- Optimal reading width content area (~65-75 characters)
- Step-by-step layout:
  - Numbered steps with clear headings
  - Rich text content
  - Annotated screenshots (click to zoom)
  - Embedded video players (responsive iframe wrapper)
- Footer: "Was this helpful?" (placeholder for future tracking)

**Navigation:**
- Back to resources list button
- Previous/Next how-to links (within same tag category)
- Share/copy link button

**Styling:**
- Leverage Tailwind + DaisyUI components
- Prose classes for readable typography
- Consistent with existing About/Changelog pages
- Full dark mode support

## Implementation Components

### ResourcesLive.Index
**Responsibilities:**
- Load all how-tos from embedded data structure on mount
- Handle search input events (live filtering)
- Handle tag filter selection/deselection
- Handle sort order changes
- Render search UI, filters, and how-to grid

**Key Functions:**
- `mount/3` - Initialize state with all how-tos
- `handle_event("search", ...)` - Update search query and filter
- `handle_event("toggle_tag", ...)` - Add/remove tag filter
- `handle_event("sort", ...)` - Update sort order
- `filter_how_tos/3` - Apply search, tags, and sort to list

### ResourcesLive.Show
**Responsibilities:**
- Load specific how-to by ID from embedded data
- Render full content with steps, images, videos
- Handle previous/next navigation

**Key Functions:**
- `mount/3` - Load how-to by ID parameter
- `handle_event("navigate", ...)` - Previous/Next navigation
- Render step-by-step content

### Components (ResourcesLive.Components)

**`resource_card/1`:**
- Displays how-to thumbnail, title, description, tags
- Shows content type icon and reading time
- Links to reading view

**`search_bar/1`:**
- Search input with live update on keyup
- Clear button when query present

**`tag_filter/1`:**
- Clickable tag pills
- Visual indication of active state

**`how_to_content/1`:**
- Renders step-by-step content
- Handles image display with alt text
- Embeds videos with responsive wrapper

## Media Asset Handling

### Images (Self-Hosted)
- **Location:** `/priv/static/images/resources/`
- **Reference:** `~p"/images/resources/filename.png"` using Phoenix routes helper
- **Optimization:** Compress before commit, appropriate resolution for web
- **Formats:** PNG for screenshots, SVG for diagrams/icons
- **Naming:** Descriptive kebab-case (e.g., `create-board-button.png`)

### Videos (External Hosting)
- **Platform:** YouTube or Vimeo
- **Embed:** Responsive iframe wrapper with aspect ratio preservation
- **Loading:** Lazy loading for performance
- **Fallback:** Include text summary for accessibility

## Initial Launch Content

Create 8-12 essential how-tos covering common user needs:

### Getting Started (3-4 guides)
1. Creating your first board
2. Understanding board columns and workflow
3. Adding your first task
4. Inviting team members

### For Non-Developers (2-3 guides)
1. Writing effective tasks for AI agents
2. Monitoring task progress
3. Reviewing completed work

### For Developers (3-4 guides)
1. Setting up hook execution
2. Configuring API authentication
3. Understanding the claim/complete workflow
4. Debugging hook failures

### Best Practices (1-2 guides)
1. Organizing tasks with dependencies
2. Using complexity and priority effectively

## Content Creation Workflow

1. **Capture screenshots** during feature use
2. **Annotate images** with arrows/highlights as needed (use tools like Skitch, Snagit)
3. **Write step-by-step instructions** in clear, concise language
4. **Add to embedded data structure** in `ResourcesLive.Index`
5. **Place images** in `/priv/static/images/resources/`
6. **Test locally** - verify search, filtering, reading view
7. **Deploy** and validate in production

## Verification Steps

### Development Testing
1. Start Phoenix server: `mix phx.server`
2. Navigate to `/resources` and verify landing page renders
3. Test search functionality with various queries
4. Test tag filtering (single and multiple tags)
5. Test sort options
6. Click into individual how-to and verify reading view
7. Test previous/next navigation
8. Verify images load correctly
9. Test video embeds if present
10. Test responsive layout (mobile/tablet/desktop)
11. Verify dark mode styling

### Production Validation
1. Deploy to production environment
2. Verify `/resources` route is accessible
3. Test all functionality from development testing
4. Check that images are served correctly from static assets
5. Verify video embeds work from external hosting

## Future Evolution (Phase 2+)

### Phase 2: Community Contributions
- Add database schema for community-submitted how-tos
- Create admin approval workflow (LiveView admin interface)
- Add user submission form
- Implement voting/rating system
- Distinguish official vs community content

### Phase 3: Advanced Features
- Analytics: Track which how-tos are most helpful
- Contextual help: Add "?" icons throughout app linking to relevant guides
- Onboarding checklist for new users
- Expanded video content library
- Multi-language support (leverage existing i18n system)

### Migration Path
When transitioning to Phase 2:
1. Create database schema matching current data structure
2. Write migration script to seed embedded content into database
3. Update LiveView modules to read from database instead of embedded data
4. Maintain backward compatibility during transition

## Critical Files

- [lib/kanban_web/router.ex](lib/kanban_web/router.ex) - Add routes
- [lib/kanban_web/components/nav_components.ex](lib/kanban_web/components/nav_components.ex) - Add nav link
- `lib/kanban_web/live/resources_live/index.ex` - Landing page (to be created)
- `lib/kanban_web/live/resources_live/show.ex` - Reading view (to be created)
- `lib/kanban_web/live/resources_live/components.ex` - Reusable components (to be created)
- `/priv/static/images/resources/` - Media assets directory (to be created)

## Design Principles

- **YAGNI:** Start simple with embedded content, evolve to database when needed
- **Consistency:** Match existing Stride UI patterns and component library
- **Accessibility:** Alt text for images, semantic HTML, keyboard navigation
- **Performance:** Lazy load videos, optimize images, efficient LiveView updates
- **Maintainability:** Clear component separation, reusable functions
- **Scalability:** Architecture supports future database migration without breaking changes
