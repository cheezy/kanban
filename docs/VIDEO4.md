# Video 4: "Creating Goals with Nested Tasks"

**Duration:** 60 seconds
**Purpose:** Demonstrate hierarchical task organization and goal tracking
**Format:** API-focused screen recording with visual UI feedback
**Target Audience:** Teams planning complex projects with AI agents

---

## Video Concept

Shows the power of goals (parent tasks) with nested child tasks. Demonstrates how goals automatically track progress and move columns based on child task completion. Split between terminal (creating via API) and UI (visual feedback).

**Key Message:** "Organize work hierarchically. Goals track progress automatically."

---

## Script & Timing

### 0:00-0:08 (8 seconds)
**Visual:**
- Fade in to terminal
- Empty Stride board visible in background (blurred)

**Terminal:**
```bash
$ # Creating a goal with nested tasks
$ # Goals organize complex work into manageable pieces
```

**Voiceover:**
> "Goals in Stride let you organize complex work into smaller, manageable tasks. Let's create one."

**On-screen text:** "Creating Goals with Nested Tasks"

---

### 0:08-0:22 (14 seconds)
**Visual:**
- Terminal showing JSON payload
- Code editor appearance with syntax highlighting

**Terminal:**
```bash
$ cat create-goal.json
{
  "goal": {
    "title": "Add User Management System",
    "type": "goal",
    "description": "Complete user management with CRUD operations",
    "why": "Users need full account management capabilities",
    "tasks": [
      {
        "title": "Create user database schema",
        "complexity": "small",
        "key_files": [{"file_path": "priv/repo/migrations/add_users.exs"}]
      },
      {
        "title": "Build user CRUD API endpoints",
        "complexity": "medium",
        "dependencies": ["W1"],
        "key_files": [{"file_path": "lib/kanban_web/controllers/user_controller.ex"}]
      },
      {
        "title": "Add user management UI",
        "complexity": "medium",
        "dependencies": ["W2"],
        "key_files": [{"file_path": "lib/kanban_web/live/user_live.ex"}]
      }
    ]
  }
}
```

**Voiceover:**
> "Create a goal with nested tasks using the API. Each child task has its own metadata and dependencies."

**On-screen annotation:**
- Highlight "type: goal": "Parent task"
- Highlight tasks array: "3 child tasks"
- Highlight dependencies: "Enforces order"

---

### 0:22-0:32 (10 seconds)
**Visual:**
- Execute POST request
- Show formatted JSON response
- Transition to Stride UI

**Terminal:**
```bash
$ curl -X POST https://www.stridelikeaboss.com/api/tasks \
  -H "Authorization: Bearer stride_dev_..." \
  -H "Content-Type: application/json" \
  -d @create-goal.json | jq

{
  "goal": {
    "id": 100,
    "identifier": "G10",
    "title": "Add User Management System",
    "type": "goal",
    "children_count": 3,
    "children_completed": 0,
    "progress_percentage": 0
  },
  "tasks": [
    {"id": 101, "identifier": "W1", "parent_id": 100},
    {"id": 102, "identifier": "W2", "parent_id": 100},
    {"id": 103, "identifier": "W3", "parent_id": 100}
  ]
}
```

**Voiceover:**
> "The goal and all child tasks are created atomically. The goal tracks progress automatically."

**On-screen annotation:**
- Highlight "G10": "Goal identifier"
- Highlight "progress_percentage: 0": "Auto-calculated"

---

### 0:32-0:42 (10 seconds)
**Visual:**
- Full screen Stride board UI
- Show goal card with progress bar at 0%
- Expand goal to show 3 child tasks nested inside

**Stride UI:**
- Goal card "G10 - Add User Management System"
- Progress bar: 0% (0/3 tasks)
- Child tasks visible:
  - W1: Create user database schema ⚪
  - W2: Build user CRUD API endpoints 🔒 (blocked)
  - W3: Add user management UI 🔒 (blocked)

**Voiceover:**
> "In the UI, the goal shows a progress bar. Child tasks show their dependency status."

**On-screen annotation:**
- Point to progress bar: "0/3 tasks complete"
- Point to W2, W3: "Blocked by dependencies"

---

### 0:42-0:52 (10 seconds)
**Visual:**
- Show rapid task completion sequence
- W1 moves to "Done" → Progress updates to 33%
- W2 unlocks and moves to "Done" → Progress updates to 67%
- W3 unlocks and moves to "Done" → Progress updates to 100%

**Animation:**
- Each task completion shows:
  - Checkmark animation on task
  - Progress bar fills incrementally
  - Next task unlocks (blocked icon → ready icon)
  - Smooth transitions (0.5s per task)

**Voiceover:**
> "As child tasks complete, the goal updates automatically. Dependencies unblock in sequence."

**On-screen annotation:**
- Progress bar updates: "33% → 67% → 100%"
- Dependency unlock animation

---

### 0:52-1:00 (8 seconds)
**Visual:**
- Goal card with 100% progress
- Goal automatically moves from current column to next column
- Celebration animation (subtle confetti or glow)
- Zoom out to show full board

**Stride UI:**
- Goal card moves column (e.g., "Doing" → "Done")
- All child tasks are in "Done"
- Board shows multiple goals in various stages

**Voiceover:**
> "When all children complete, the goal moves columns automatically. Complex work, organized simply."

**On-screen text:**
```
Goals: Organize Complex Work
Auto-tracking • Dependencies • Visual Progress

stride likeaboss.com
```

---

## Production Details

### Technical Specifications

**Resolution:** 1920x1080 (1080p)
**Frame Rate:** 60fps (smooth progress bar animations)
**Aspect Ratio:** 16:9
**File Format:** MP4 (H.264)
**Audio:** AAC 320kbps
**Total Duration:** 60 seconds

### Visual Style

**Terminal Segment (0:00-0:32):**
- **Terminal:** iTerm2 with Dracula theme
- **Font:** JetBrains Mono, 15pt
- **JSON Editor:** VS Code appearance with syntax highlighting
- **Window:** Centered, 1400x900

**UI Segment (0:32-1:00):**
- **Browser:** Chrome, clean interface
- **Board View:** Full screen, no distractions
- **Animations:** Native Stride LiveView animations
- **Goal Card:** Prominent, centered for visibility

### Goal Card Design Elements

**Goal Card Appearance:**
```
┌─────────────────────────────────────────┐
│ G10 - Add User Management System        │
│ ━━━━━━━━━━━━━━━░░░░░░░░ 67%           │
│                                         │
│ ├─ W1: Create user database schema  ✓  │
│ ├─ W2: Build user CRUD API endpoints ✓ │
│ └─ W3: Add user management UI       ⚪  │
└─────────────────────────────────────────┘
```

**Progress Bar Animation:**
- Fill color: Orange gradient (#FF6B35 to #F7931E)
- Background: Light gray
- Height: 8px
- Border radius: 4px
- Smooth fill animation: 0.5s ease-in-out

**Dependency Icons:**
- 🔒 Blocked (red-orange)
- ⚪ Ready (blue)
- ✓ Complete (green)

### Voiceover Recording

**Tone:** Informative, slightly technical, confident
**Pace:** Moderate (technical content needs clarity)
**Voice:** Professional, clear enunciation

**Full Script (60 seconds, ~90 words):**
```
Goals in Stride let you organize complex work into smaller, manageable tasks. Let's create one.

Create a goal with nested tasks using the API. Each child task has its own metadata and dependencies.

The goal and all child tasks are created atomically. The goal tracks progress automatically.

In the UI, the goal shows a progress bar. Child tasks show their dependency status.

As child tasks complete, the goal updates automatically. Dependencies unblock in sequence.

When all children complete, the goal moves columns automatically. Complex work, organized simply.
```

### Background Music

**Style:** Organized, methodical, building
**Tempo:** 110 BPM
**Volume:** -24dB
**Arc:** Start calm, build energy as progress fills
**Peak:** At 100% completion (0:52)

### On-Screen Annotations

**Key Annotations:**
1. "Parent task" → type: goal (0:15)
2. "3 child tasks" → tasks array (0:17)
3. "Enforces order" → dependencies (0:20)
4. "Goal identifier" → G10 (0:28)
5. "Auto-calculated" → progress_percentage (0:30)
6. "0/3 tasks complete" → progress bar (0:38)
7. "Blocked by dependencies" → locked tasks (0:40)
8. "33% → 67% → 100%" → progress animation (0:45)

### Animation Sequences

**Task Completion Animation (0:42-0:52):**
```
Frame 1 (0:42): W1 ready
Frame 2 (0:44): W1 → Done, progress → 33%, W2 unlocks
Frame 3 (0:47): W2 → Done, progress → 67%, W3 unlocks
Frame 4 (0:50): W3 → Done, progress → 100%
Frame 5 (0:52): Goal moves columns
```

**Each completion includes:**
- Task card slide to Done column (0.6s)
- Checkmark appear animation (0.3s)
- Progress bar fill (0.4s)
- Next task unlock (0.3s)

**Goal Column Movement (0:52-0:56):**
- Highlight goal card (0.3s glow effect)
- Slide to next column (0.8s smooth motion)
- Subtle confetti burst (0.5s)
- Board reflows (0.4s)

---

## Pre-Production Checklist

### Environment Setup

**Stride Board:**
- [ ] Clean board with standard columns
- [ ] No existing goals (clean slate for demo)
- [ ] API endpoint tested and working
- [ ] LiveView real-time updates working

**Test Data:**
- [ ] Prepare JSON payload (create-goal.json)
- [ ] Verify all field names match schema
- [ ] Test API call returns expected response
- [ ] Verify goal creation works in test environment

### Recording Preparation

**Terminal Recording:**
- [ ] JSON file syntax highlighted and formatted
- [ ] curl command tested and returns 200 OK
- [ ] jq installed and configured
- [ ] Response JSON is properly formatted

**UI Recording:**
- [ ] Browser window sized correctly (1600x900)
- [ ] Goal card is prominent and readable
- [ ] Progress bar animation is smooth
- [ ] Child tasks expand/collapse works
- [ ] Column movements are visible

### Timing Rehearsal

- [ ] Practice complete walkthrough 3 times
- [ ] Verify total time is 60 seconds ±2s
- [ ] Mark exact timestamps for each segment
- [ ] Identify any timing issues

---

## Recording Instructions

### Segment 1: Introduction & JSON (0:00-0:22)

**Terminal Recording:**
```bash
# Start recording
asciinema rec goal-creation-intro.cast

# Show intro comment
echo "$ # Creating a goal with nested tasks"
sleep 2
echo "$ # Goals organize complex work into manageable pieces"
sleep 3

# Show JSON file
echo "$ cat create-goal.json"
sleep 1
cat create-goal.json | jq --color-output
sleep 8

# Stop recording
```

**Post-processing:**
- Add syntax highlighting
- Slow down JSON display if needed
- Ensure readability

### Segment 2: API Call (0:22-0:32)

**Terminal Recording:**
```bash
asciinema rec goal-creation-api.cast

# Execute API call
curl -X POST https://www.stridelikeaboss.com/api/tasks \
  -H "Authorization: Bearer stride_dev_..." \
  -H "Content-Type: application/json" \
  -d @create-goal.json | jq

sleep 5
```

### Segment 3: UI Visualization (0:32-1:00)

**Screen Recording with OBS:**

**Timeline:**
- 0:32: Switch to browser, show board
- 0:35: Click on goal card to expand
- 0:38: Show child tasks nested inside
- 0:42: Start task completion sequence
  - W1 complete at 0:44
  - W2 complete at 0:47
  - W3 complete at 0:50
- 0:52: Goal moves columns
- 0:56: Zoom out to show full board
- 1:00: Fade to end screen

**Camera/Recording Settings:**
- Record at 60fps for smooth animations
- Use screen recording (not physical camera)
- Capture mouse movements
- Enable cursor highlighting

---

## Post-Production

### Editing Workflow

1. **Import segments**
   - Terminal intro (0:00-0:08)
   - JSON display (0:08-0:22)
   - API call (0:22-0:32)
   - UI demonstration (0:32-1:00)

2. **Add transition** (0:32)
   - Terminal fades to background (blur)
   - Browser window fades in
   - Duration: 0.5s crossfade

3. **Add annotations**
   - JSON field highlights
   - Progress bar callouts
   - Dependency indicators
   - Fade in/out: 0.3s

4. **Add voiceover**
   - Record clean audio
   - Sync precisely with visuals
   - Ensure technical terms are clear

5. **Add background music**
   - Import track
   - Fade in at 0:00
   - Build energy during task completion (0:42-0:52)
   - Peak at goal completion (0:52)
   - Fade out at 0:58

6. **Enhance animations**
   - If Stride animations aren't smooth enough:
     - Extract frames
     - Add motion blur in After Effects
     - Recreate progress bar fill with smoother easing

7. **Add end card**
   - Text overlay: "Goals: Organize Complex Work"
   - Sub-text: "Auto-tracking • Dependencies • Visual Progress"
   - URL: "stridelikeaboss.com"
   - Duration: 3 seconds (0:57-1:00)

### Sound Design

**Sound Effects:**
- Task completion "tick" sound (0:44, 0:47, 0:50) - subtle
- Progress bar "fill" sound - gentle whoosh
- Goal completion "success" chime (0:52) - soft
- All at -30dB (barely audible, reinforcing visual)

### Quality Checks

- [ ] JSON is readable and properly formatted
- [ ] API response matches current schema
- [ ] Progress bar fills smoothly
- [ ] Child tasks are visible and clear
- [ ] Dependency blocking is obvious
- [ ] Column movement is smooth
- [ ] All annotations are legible
- [ ] Voiceover is synchronized
- [ ] No dead air or awkward pauses
- [ ] Exactly 60 seconds

---

## Deployment

### File Formats

**Primary Version:**
- Format: MP4 (H.264)
- Resolution: 1920x1080
- Bitrate: 8-10 Mbps
- File size target: 12-18MB

**Optimized Versions:**
- Web: 6 Mbps, ~10MB
- Mobile: 720p, 4 Mbps, ~6MB

**Social Media:**
- Square (1080x1080): Focus on UI section, picture-in-picture terminal
- Short clip (20s): Just the task completion animation (0:42-1:00)
- Vertical (1080x1920): Stack terminal and UI vertically

### Documentation Integration

**Embed in:**
- docs/TASK-WRITING-GUIDE.md (Goals section)
- docs/GETTING-STARTED-WITH-AI.md (after basic task creation)
- Homepage "Features" section
- API documentation for POST /api/tasks

**Sample embed:**
```html
<div class="feature-video">
  <video controls width="100%" poster="goals-poster.jpg">
    <source src="/videos/creating-goals.mp4" type="video/mp4">
    <track src="/videos/creating-goals.vtt" kind="captions" srclang="en">
  </video>
  <p>
    Learn how to create goals with nested tasks for complex project organization.
  </p>
</div>
```

---

## Success Metrics

**Target Goals:**
- 55%+ completion rate
- Featured in "Getting Started" docs
- 400+ YouTube views in first month
- Increase goal creation by 25%
- Reduce support questions about goals by 40%

**Track:**
- Video engagement by segment
- Goal creation API calls before/after
- Documentation page views
- User feedback on goal feature
- Support tickets mentioning goals

---

## Budget Estimate

**DIY Approach (Total: $40-100):**
- Terminal recording: Free (asciinema)
- Screen recording: Free (OBS)
- Video editing: Free (DaVinci Resolve)
- Sound effects: $10-20 (freesound.org)
- Background music: $15-30
- Voiceover: Self or Fiverr ($50)
- Total time: 6-8 hours

**Professional Approach (Total: $1,200-2,000):**
- Script and storyboard: $200-300
- Professional voiceover: $200-300
- Video production: $600-1,200
- Sound design: $100-150
- Animation enhancement: $100-200
- Timeline: 1 week

---

## Alternative Approaches

### Extended Version (90s)
- Show agent claiming child tasks
- Demonstrate parallel work on unblocked tasks
- Show goal history/audit trail

### Animated Explainer
- Motion graphics showing goal/task relationships
- Abstract representation of dependencies
- Cleaner, more conceptual

### Interactive Demo
- Scrimba-style interactive video
- Users can edit JSON and see results
- Higher engagement, complex production

---

## Technical Notes

### Goal JSON Schema

**Complete example with all recommended fields:**
```json
{
  "goal": {
    "title": "Add User Management System",
    "type": "goal",
    "description": "Complete user management with CRUD operations",
    "why": "Users need full account management capabilities",
    "what": "Build user management system with database, API, and UI",
    "where_context": "User management module",
    "complexity": "large",
    "estimated_files": "10-15",
    "needs_review": true,
    "tasks": [
      {
        "title": "Create user database schema",
        "type": "work",
        "complexity": "small",
        "estimated_files": "1",
        "why": "Need database foundation for user data",
        "what": "Create users table with authentication fields",
        "where_context": "Database migrations",
        "key_files": [
          {
            "file_path": "priv/repo/migrations/20260101_add_users.exs",
            "note": "User table migration",
            "position": 0
          }
        ],
        "verification_steps": [
          {
            "step_type": "command",
            "step_text": "mix ecto.migrate",
            "expected_result": "Migration successful",
            "position": 0
          }
        ]
      },
      {
        "title": "Build user CRUD API endpoints",
        "type": "work",
        "complexity": "medium",
        "dependencies": ["W1"],
        "key_files": [
          {
            "file_path": "lib/kanban_web/controllers/user_controller.ex",
            "note": "User CRUD controller"
          }
        ]
      },
      {
        "title": "Add user management UI",
        "type": "work",
        "complexity": "medium",
        "dependencies": ["W2"],
        "key_files": [
          {
            "file_path": "lib/kanban_web/live/user_live.ex",
            "note": "User management LiveView"
          }
        ]
      }
    ]
  }
}
```

### Progress Calculation

**Automatic formula:**
```
progress_percentage = (children_completed / children_count) * 100
```

**Updates trigger:**
- When child task moves to "Done" column
- Real-time via Phoenix PubSub
- Broadcast to all connected clients

---

## Common Issues & Solutions

**Issue:** Progress bar doesn't update in real-time
**Solution:** Ensure PubSub is configured, use LiveView for instant updates

**Issue:** Child tasks don't show as blocked
**Solution:** Verify dependencies reference correct task identifiers

**Issue:** Goal doesn't move columns automatically
**Solution:** Check board configuration has auto-move enabled for goals

**Issue:** JSON too complex for 14-second display
**Solution:** Simplify to 2 child tasks, add "..." to show truncation

---

## Notes for Narrator

**Technical Pronunciation:**
- CRUD: SEE-RUD or spell out: C-R-U-D
- API: A-P-I (spell out)
- UI: YOU-eye
- Schema: SKEE-muh
- Dependencies: dee-PEN-den-sees

**Emphasis Points:**
- "organize complex work" (key value prop)
- "created **atomically**" (technical accuracy)
- "tracks progress **automatically**" (hands-off benefit)
- "moves columns **automatically**" (automation highlight)

---

**Document Version:** 1.0
**Created:** 2026-01-01
**Purpose:** Complete production guide for Goals with Nested Tasks video
**Related:** VIDEO1.md, VIDEO2.md, VIDEO3.md, VIDEOS.md
