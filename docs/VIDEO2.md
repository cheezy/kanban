# Video 2: "AI Agent Setup & First Task"

**Duration:** 90 seconds
**Purpose:** Getting Started tutorial - onboarding new AI developers
**Format:** Screen recording with voiceover and annotations
**Target Audience:** Developers integrating AI agents with Stride

---

## Video Concept

Terminal-focused tutorial showing the complete setup process from scratch. This is a "follow along" style video where developers can pause and replicate each step.

**Style:** Developer-focused, practical, step-by-step
**Tone:** Educational but not condescending, assumes basic API knowledge

---

## Script & Timing

### 0:00-0:10 (10 seconds)
**Visual:**
- Fade in to empty project directory in terminal
- Show directory tree: `project/` with basic files

**Terminal:**
```bash
$ pwd
/Users/developer/my-project
$ ls -la
total 8
drwxr-xr-x   2 developer  staff   64 Jan  1 10:00 .
drwxr-xr-x  12 developer  staff  384 Jan  1 09:55 ..
-rw-r--r--   1 developer  staff  123 Jan  1 10:00 README.md
```

**Voiceover:**
> "Setting up an AI agent with Stride takes less than two minutes. Let's start from scratch."

**On-screen text:** "AI Agent Setup & First Task"

---

### 0:10-0:25 (15 seconds)
**Visual:**
- Create `.stride_auth.md` file
- Type in API token with syntax highlighting

**Terminal:**
```bash
$ cat > .stride_auth.md << 'EOF'
# Stride Authentication

Board URL: https://www.stridelikeaboss.com
API Token: stride_dev_abc123def456ghi789jkl012mno345pqr678stu901

## Usage

This token is used by AI agents to authenticate with the Stride API.
Never commit this file to version control.
EOF

$ cat .stride_auth.md
```

**Voiceover:**
> "First, create a `.stride_auth.md` file with your board URL and API token. Get your token from your Stride board settings."

**On-screen annotation:**
- Arrow pointing to token: "Get from Board Settings → API Tokens"
- Warning icon: "Add to .gitignore!"

---

### 0:25-0:40 (15 seconds)
**Visual:**
- Create `.stride.md` file
- Show hook configuration

**Terminal:**
```bash
$ cat > .stride.md << 'EOF'
# Stride Agent Configuration

Agent Name: CodeBot-1

## Hooks

### before_doing
```bash
git fetch origin
git rebase origin/main
```

### after_doing
```bash
mix test
mix format --check-formatted
mix credo --strict
```

### before_review
```bash
gh pr create --fill
```

### after_review
```bash
git push origin main
```
EOF

$ cat .stride.md
```

**Voiceover:**
> "Next, create `.stride.md` to configure your agent's workflow hooks. These run automatically at each step."

**On-screen annotation:**
- Highlight hook names: "before_doing, after_doing, before_review, after_review"
- Note: "Hooks run on your machine, not the server"

---

### 0:40-0:55 (15 seconds)
**Visual:**
- Call onboarding endpoint
- Show formatted JSON response with key sections highlighted

**Terminal:**
```bash
$ curl -s https://www.stridelikeaboss.com/api/agent/onboarding \
  -H "Authorization: Bearer stride_dev_abc123..." \
  | jq '.'

{
  "welcome_message": "Welcome to Stride!",
  "board": {
    "id": 1,
    "name": "Main Development Board",
    "columns": [
      {"id": 4, "name": "Backlog"},
      {"id": 5, "name": "Ready"},
      {"id": 6, "name": "Doing"},
      {"id": 7, "name": "Review"},
      {"id": 8, "name": "Done"}
    ]
  },
  "workflow": {
    "claim_task": "POST /api/tasks/claim",
    "complete_task": "PATCH /api/tasks/:id/complete"
  }
}
```

**Voiceover:**
> "Call the onboarding endpoint to verify your setup and learn the workflow. You'll see your board structure and available actions."

**On-screen annotation:**
- Highlight "Ready" column: "Tasks ready to claim"
- Highlight workflow endpoints: "Key API endpoints"

---

### 0:55-1:10 (15 seconds)
**Visual:**
- Call `/api/tasks/claim` endpoint
- Show task being claimed with full details

**Terminal:**
```bash
$ curl -s -X POST \
  https://www.stridelikeaboss.com/api/tasks/claim \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{"agent_name": "CodeBot-1"}' \
  | jq '.'

{
  "data": {
    "id": 42,
    "identifier": "W15",
    "title": "Add user profile page",
    "status": "in_progress",
    "why": "Users need to view and edit their profile info",
    "what": "Create profile page with form to update user details",
    "where_context": "User profile module",
    "key_files": [
      {
        "file_path": "lib/kanban_web/live/profile_live.ex",
        "note": "Main profile LiveView"
      }
    ]
  },
  "hooks": {
    "before_doing": "git fetch origin && git rebase origin/main"
  }
}
```

**Voiceover:**
> "Claim your first task with a POST request. The agent atomically reserves the task and receives all implementation context."

**On-screen annotation:**
- Highlight "W15": "Task identifier"
- Highlight "why/what/where_context": "Implementation guidance"
- Highlight hooks: "Executes automatically"

---

### 1:10-1:20 (10 seconds)
**Visual:**
- Show hook execution in real-time
- Git commands running

**Terminal:**
```bash
Executing before_doing hook...
From https://github.com/user/project
 * branch            main       -> FETCH_HEAD
Current branch main is up to date.
✓ Hook completed successfully

Starting implementation...
[Agent implements the task - show abbreviated output]
✓ Profile page created
✓ Tests written
✓ All checks passing
```

**Voiceover:**
> "The before_doing hook executes, pulling the latest code. Your agent then implements the task."

**On-screen annotation:**
- Progress indicator: "Hook → Implementation → Tests"

---

### 1:20-1:30 (10 seconds)
**Visual:**
- Complete the task
- Show after_doing and before_review hooks executing

**Terminal:**
```bash
$ curl -s -X PATCH \
  https://www.stridelikeaboss.com/api/tasks/42/complete \
  -H "Authorization: Bearer stride_dev_abc123..." \
  -H "Content-Type: application/json" \
  -d '{
    "completion_summary": "Added profile page with edit form",
    "actual_complexity": "medium",
    "actual_files_changed": "2",
    "time_spent_minutes": 45
  }' | jq '.status, .column_name'

Executing after_doing hook...
Running tests: mix test
✓ All tests passing

Executing before_review hook...
Creating PR: gh pr create --fill
✓ PR #123 created

"completed"
"Review"
```

**Voiceover:**
> "Complete the task. Hooks automatically run tests and create a pull request. The task moves to Review for human approval."

**On-screen annotation:**
- Highlight hooks: "Automated testing & PR creation"
- Show task movement: "Doing → Review"

---

### 1:30-1:35 (5 seconds)
**Visual:**
- Split screen: Terminal on left, Stride UI on right
- Show task in Review column with green checkmark
- Show PR link in task details

**Terminal:** (Shows previous command success)

**Stride UI:** (Shows task card in Review column)

**Voiceover:**
> "Your task is now ready for human review. The AI-human collaboration is complete."

---

### 1:35-1:40 (5 seconds)
**Visual:**
- Zoom out showing complete workflow diagram
- Fade to resources screen

**On-screen text:**
```
Next Steps:
→ docs.stridelikeaboss.com/getting-started
→ docs.stridelikeaboss.com/api

Stride - AI-Human Collaboration
```

**Voiceover:**
> "Visit our documentation to learn more about advanced workflows and capabilities."

---

## Production Details

### Technical Specifications

**Resolution:** 1920x1080 (1080p)
**Frame Rate:** 30fps (terminal screencast standard)
**Aspect Ratio:** 16:9
**File Format:** MP4 (H.264)
**Audio:** AAC 320kbps
**Total Duration:** 90 seconds

### Visual Style

**Terminal Setup:**
- **Terminal App:** iTerm2 or Hyper (clean, modern appearance)
- **Shell:** Zsh with minimal prompt (just `$`)
- **Color Scheme:** Dracula or One Dark (professional, easy to read)
- **Font:** Fira Code or JetBrains Mono, 16pt
- **Window Size:** 1200x800 (centered on 1920x1080 canvas)
- **Cursor:** Block cursor with blink

**Code Formatting:**
- Use `jq` for JSON formatting with syntax highlighting
- Use `bat` or `glow` for markdown preview
- Commands should type at realistic speed (not instant paste)
- Add 1-2 second pause after each command output

**Recording Tools:**
- **asciinema** for pure terminal recording
- **OBS Studio** for adding annotations and overlays
- **Terminalizer** as alternative with built-in styling

### Voiceover Recording

**Tone:** Professional developer-to-developer, helpful mentor
**Pace:** Moderate, clear enunciation (technical terms pronounced carefully)
**Voice:** Confident, knowledgeable, friendly

**Full Script (90 seconds, ~130 words):**
```
Setting up an AI agent with Stride takes less than two minutes. Let's start from scratch.

First, create a .stride_auth.md file with your board URL and API token. Get your token from your Stride board settings.

Next, create .stride.md to configure your agent's workflow hooks. These run automatically at each step.

Call the onboarding endpoint to verify your setup and learn the workflow. You'll see your board structure and available actions.

Claim your first task with a POST request. The agent atomically reserves the task and receives all implementation context.

The before_doing hook executes, pulling the latest code. Your agent then implements the task.

Complete the task. Hooks automatically run tests and create a pull request. The task moves to Review for human approval.

Your task is now ready for human review. The AI-human collaboration is complete.

Visit our documentation to learn more about advanced workflows and capabilities.
```

### Background Music

**Style:** Subtle, ambient, tech-focused
**Tempo:** 90-100 BPM (slower, less distracting)
**Volume:** -25dB to -30dB (very subtle)
**Duration:** Full 90 seconds with fade out
**Mood:** Focused, professional, calm

### On-Screen Annotations

**Style:**
- **Arrows:** Orange gradient, pointing to important elements
- **Highlights:** Yellow box with slight transparency
- **Warning icons:** Red with exclamation for security notes
- **Success checkmarks:** Green with animation
- **Text boxes:** White text on dark semi-transparent background

**Timing:**
- Annotations should appear 0.5s after voiceover mentions them
- Duration: 3-5 seconds on screen
- Fade in/out: 0.3s

**Key Annotations:**
1. "Get from Board Settings → API Tokens" (0:15)
2. "Add to .gitignore!" (0:20)
3. "Hooks run on your machine" (0:35)
4. "Tasks ready to claim" (0:50)
5. "Implementation guidance" (1:00)
6. "Automated testing & PR creation" (1:25)

### Captions/Subtitles

**Format:** SRT and WebVTT
**Style:** White text, black background (80% opacity)
**Position:** Bottom center
**Font:** Arial or Helvetica, bold
**Size:** 48px for 1080p
**Timing:** Word-accurate with technical terms spelled out

---

## Pre-Production Checklist

### Environment Setup

- [ ] Clean Stride instance with pre-created board
- [ ] Create test API token: `stride_dev_abc123def456ghi789jkl012mno345pqr678stu901`
- [ ] Prepare example task in Ready column:
  - Title: "Add user profile page"
  - ID: W15
  - All metadata fields populated
- [ ] Set up clean project directory
- [ ] Configure terminal with clean prompt
- [ ] Install and configure `jq` for JSON formatting
- [ ] Test all API endpoints work correctly

### Test Scripts

Create shell scripts for each segment to ensure accuracy:

**`01-create-auth.sh`:**
```bash
#!/bin/bash
cat > .stride_auth.md << 'EOF'
# Stride Authentication

Board URL: https://www.stridelikeaboss.com
API Token: stride_dev_abc123def456ghi789jkl012mno345pqr678stu901

## Usage

This token is used by AI agents to authenticate with the Stride API.
Never commit this file to version control.
EOF

cat .stride_auth.md
```

**`02-create-config.sh`:**
```bash
#!/bin/bash
# Similar structure for .stride.md
```

**`03-onboarding.sh`:**
```bash
#!/bin/bash
curl -s https://www.stridelikeaboss.com/api/agent/onboarding \
  -H "Authorization: Bearer stride_dev_abc123..." \
  | jq '.'
```

**`04-claim-task.sh`:**
```bash
#!/bin/bash
# Task claiming with full JSON response
```

**`05-complete-task.sh`:**
```bash
#!/bin/bash
# Task completion with hooks
```

### Recording Tools

- [ ] **Terminal Recording:** asciinema 2.3+
- [ ] **Video Editing:** DaVinci Resolve or Final Cut Pro
- [ ] **Annotations:** Screenflow or Camtasia
- [ ] **JSON Formatting:** jq 1.6+
- [ ] **Auto-typing:** Use `pv` command for realistic typing speed
  - Example: `cat script.sh | pv -qL 30` (30 chars/sec)

---

## Recording Instructions

### Segment-by-Segment Recording

**Best Practice:** Record each segment separately, then edit together. This allows for retakes and ensures perfect timing.

#### Segment 1: Introduction (0:00-0:10)
```bash
# Record with asciinema
asciinema rec segment1.cast

# In the recording:
pwd
ls -la
# Wait 2 seconds
# Stop recording
```

#### Segment 2: Create Auth File (0:10-0:25)
```bash
asciinema rec segment2.cast

# Type command (use pv for realistic speed)
cat 01-create-auth.sh | pv -qL 30 | bash
# Pause 2 seconds to show output
```

#### Segment 3: Create Config File (0:25-0:40)
```bash
asciinema rec segment3.cast
# Similar to segment 2
```

#### Segment 4: Onboarding Call (0:40-0:55)
```bash
asciinema rec segment4.cast
# API call with formatted output
```

#### Segment 5: Claim Task (0:55-1:10)
```bash
asciinema rec segment5.cast
# Task claiming
```

#### Segment 6: Hook Execution (1:10-1:20)
```bash
asciinema rec segment6.cast
# Show simulated hook execution
```

#### Segment 7: Complete Task (1:20-1:30)
```bash
asciinema rec segment7.cast
# Task completion with hooks
```

### Converting asciinema to Video

```bash
# Option 1: Use agg (asciinema gif generator)
agg segment1.cast segment1.gif --speed 1.0

# Option 2: Use asciicast2gif
asciicast2gif -s 2 segment1.cast segment1.gif

# Option 3: Use svg-term
svg-term --in segment1.cast --out segment1.svg

# Then convert to video with ffmpeg
ffmpeg -i segment1.gif -pix_fmt yuv420p segment1.mp4
```

---

## Post-Production

### Editing Workflow

1. **Import segments** - Bring all terminal recordings into editor
2. **Align timing** - Match segments to script timestamps
3. **Add transitions** - 0.3s crossfades between segments
4. **Add annotations** - Arrows, highlights, text boxes
5. **Add voiceover** - Record and sync with visuals
6. **Add background music** - Subtle ambient track
7. **Add captions** - Generate SRT file
8. **Color correction** - Ensure terminal colors are accurate
9. **Export** - Multiple formats for different platforms

### Annotation Placement

**Keynote or PowerPoint approach:**
1. Take screenshot at annotation timestamp
2. Add annotation in presentation software
3. Export as overlay PNG
4. Composite in video editor

**Video editor approach:**
1. Use built-in annotation tools
2. Add arrows, shapes, text directly
3. Animate in/out

### Quality Checks

- [ ] All terminal commands are accurate
- [ ] JSON responses are properly formatted
- [ ] Timing matches voiceover perfectly
- [ ] Annotations appear at correct moments
- [ ] No typos in on-screen text
- [ ] Audio levels are consistent
- [ ] Background music doesn't overpower voice
- [ ] Captions are accurate and synchronized
- [ ] Video is exactly 90 seconds
- [ ] All URLs and tokens are sanitized (no real credentials)

---

## Deployment

### File Formats

**Primary Version:**
- Format: MP4 (H.264)
- Resolution: 1920x1080
- Bitrate: 8 Mbps
- Audio: AAC 320kbps
- File size target: 15-20MB

**YouTube Version:**
- Same as primary
- Custom thumbnail showing terminal with key code
- Title: "Stride AI Agent Setup Tutorial - First Task in 90 Seconds"
- Description with timestamps

**Social Media Versions:**
- Square (1080x1080): For LinkedIn/Instagram feed
- Short clips (30s): Key moments for Twitter/X
- With burned-in captions (80% watch muted)

### Documentation Integration

**Link from these docs:**
- docs/GETTING-STARTED-WITH-AI.md (embed at top)
- docs/AUTHENTICATION.md (link in setup section)
- docs/AGENT-HOOK-EXECUTION-GUIDE.md (reference in intro)

**Embed code:**
```html
<video controls width="100%">
  <source src="/videos/ai-agent-setup.mp4" type="video/mp4">
  <track src="/videos/ai-agent-setup.vtt" kind="captions" srclang="en" label="English">
</video>
```

---

## Success Metrics

**Target Goals:**
- 70%+ completion rate (tutorial value)
- 500+ YouTube views in first month
- 25%+ clickthrough to docs
- Featured in "Getting Started" section
- Reduce support questions about setup by 30%

**Track:**
- Video completion rate
- Click to documentation links
- Time spent on page with video
- User feedback/comments
- Support ticket reduction

---

## Budget Estimate

**DIY Approach (Total: $30-100):**
- Terminal recording: Free (asciinema)
- Video editing: Free (DaVinci Resolve)
- Background music: $15-30
- Voiceover: Self-recorded or Fiverr ($50)
- Total time: 6-8 hours

**Professional Approach (Total: $800-1,500):**
- Script refinement: $150-250
- Professional voiceover: $200-300
- Video production: $400-800
- Music licensing: $50
- Timeline: 1 week

---

## Alternative Approaches

### Interactive Version
- Create with Scrimba or similar
- Users can pause and edit code
- Higher engagement, more complex production

### Animated Version
- Use Motion Canvas or similar
- Cleaner, more polished look
- Terminal animations with exact control
- Higher production time/cost

### Live Coding Version
- Real implementation with commentary
- More authentic, less polished
- Shows actual development workflow

---

## Notes for Production

**Terminal Tips:**
1. Use `script` command to log session for backup
2. Pre-test all commands in isolated environment
3. Use environment variables for API token (easier to sanitize)
4. Clear terminal history before recording
5. Disable terminal bell/notifications
6. Set terminal title to something clean

**Voiceover Tips:**
1. Record in quiet room with acoustic treatment
2. Use pop filter and good microphone
3. Record multiple takes of each paragraph
4. Leave 1-second silence before/after each take
5. Speak technical terms slowly and clearly

**Common Mistakes to Avoid:**
- Terminal text too small to read
- Typing too fast (looks fake)
- Not pausing after command output
- Background noise in audio
- Incorrect API responses (test thoroughly!)
- Forgetting to sanitize real credentials

---

## Technical Pronunciation Guide

**Terms to pronounce clearly:**
- Stride: STRYDE (rhymes with "pride")
- API: A-P-I (spell out)
- JSON: JAY-sawn
- OAuth: OH-auth
- curl: CURL (like hair curl)
- jq: JAY-queue
- LiveView: LIVE-view (not lie-view)
- Elixir: ee-LIX-er

---

**Document Version:** 1.0
**Created:** 2026-01-01
**Purpose:** Complete production guide for AI Agent Setup tutorial video
**Related:** VIDEO1.md, VIDEOS.md, docs/GETTING-STARTED-WITH-AI.md
