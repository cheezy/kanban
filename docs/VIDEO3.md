# Video 3: "The Review Workflow"

**Duration:** 45 seconds
**Purpose:** Demonstrate human-AI collaboration through review process
**Format:** Split-screen with synchronized human and AI perspectives
**Target Audience:** Teams evaluating Stride for collaborative workflows

---

## Video Concept

Split-screen demonstration showing both the human reviewer and AI agent working together in real-time. Emphasizes the collaboration model where AI implements and humans provide quality oversight.

**Left side:** Human using Stride web UI (reviewing work)
**Right side:** AI agent terminal (responding to feedback)

**Key Message:** "AI handles implementation, humans ensure quality"

---

## Script & Timing

### 0:00-0:05 (5 seconds)
**Visual:**
- Fade in to split screen
- Left: Stride board with task in "Review" column
- Right: AI agent terminal showing completed work

**On-screen text:** "The Review Workflow - Human-AI Collaboration"

**Voiceover:**
> "Here's how humans and AI collaborate through Stride's review workflow."

---

### 0:05-0:15 (10 seconds)
**Visual - Human side (left):**
- Cursor hovers over task card in Review column
- Task title: "W23 - Add password strength indicator"
- Click to open task details modal
- Details show:
  - Completion summary
  - Files changed: 2
  - Tests: Passing ✓
  - PR link: "#145"

**Visual - AI side (right):**
Terminal shows waiting state:
```bash
$ # Task W23 in Review
$ # Waiting for human feedback...
$ curl https://www.stridelikeaboss.com/api/tasks/W23
{
  "status": "completed",
  "review_status": null,
  "column_name": "Review"
}
```

**Voiceover:**
> "The AI agent has completed the task and moved it to Review. Now a human reviews the implementation."

**On-screen annotation:**
- Arrow to PR link: "View changes"
- Arrow to tests: "Automated verification"

---

### 0:15-0:25 (10 seconds)
**Visual - Human side:**
- Click "View Pull Request" button
- Split-screen transitions:
  - Left: GitHub PR view (in browser)
  - Right: Still showing AI terminal

**GitHub PR shows:**
- Title: "Add password strength indicator"
- 2 files changed (+45, -3)
- Code diff visible
- Tests passing badge ✓

**Human actions:**
- Scroll through code changes
- Notice issue: Missing validation for empty password

**Voiceover:**
> "The reviewer checks the pull request and notices the implementation needs improvement."

**On-screen annotation:**
- Highlight code section: "Missing edge case handling"

---

### 0:25-0:32 (7 seconds)
**Visual - Human side:**
- Return to Stride UI (task modal still open)
- Click "Request Changes" button
- Type review notes:
  ```
  Good start! Please add:
  1. Handle empty password input
  2. Add test for min length validation
  ```
- Click "Submit Review"
- Task card animates moving to "Ready" column

**Visual - AI side:**
Terminal shows real-time update:
```bash
# Webhook notification
Task W23 review status: changes_requested

Review notes:
- Handle empty password input
- Add test for min length validation

Status: open
Column: Ready
```

**Voiceover:**
> "The reviewer requests changes. The task automatically moves back to Ready for the AI to address."

**On-screen annotation:**
- Show task movement: "Review → Ready"

---

### 0:32-0:40 (8 seconds)
**Visual - Human side:**
- Board view showing task in "Ready" column
- Watch task move from "Ready" → "Doing" (real-time update)

**Visual - AI side:**
Terminal shows agent responding:
```bash
$ curl -X POST .../api/tasks/claim
# Task W23 claimed

$ # Implementing requested changes...
✓ Added empty password validation
✓ Added min length test
✓ All tests passing (15 tests)

$ curl -X PATCH .../api/tasks/W23/complete
# Moving to Review...
```

**Voiceover:**
> "The AI agent reclaims the task, implements the requested changes, and resubmits for review."

**On-screen annotation:**
- Progress bar: "Changes implemented in 30 seconds"

---

### 0:40-0:45 (5 seconds)
**Visual - Human side:**
- Task card in Review column with green checkmark
- Click "Approve" button
- Task smoothly moves to "Done" column
- Celebration animation (subtle confetti or checkmark pulse)

**Visual - AI side:**
Terminal shows:
```bash
# Task W23 approved
Executing after_review hook...
✓ Merging PR #145
✓ Deploying to staging

Task W23: Done ✓
Claiming next task...
```

**Voiceover:**
> "The reviewer approves. The AI merges and deploys automatically. Collaboration complete."

**On-screen text:**
```
Human reviews. AI implements.
Quality + Speed = Stride
```

---

## Production Details

### Technical Specifications

**Resolution:** 1920x1080 (1080p)
**Frame Rate:** 60fps (smooth UI animations)
**Aspect Ratio:** 16:9
**File Format:** MP4 (H.264)
**Audio:** AAC 320kbps
**Total Duration:** 45 seconds

### Visual Style

**Split Screen Layout:**
- **Left (Human UI):** 960x1080 pixels
- **Right (AI Terminal):** 960x1080 pixels
- **Divider:** 2px orange gradient line
- **Sync:** Both sides update simultaneously

**Left Side (Human UI):**
- Full Stride web interface
- Chrome browser, clean (no bookmarks/extensions visible)
- Cursor movements should be smooth and deliberate
- Use cursor highlighting for clicks

**Right Side (AI Terminal):**
- Dark terminal (matching brand colors)
- Font: JetBrains Mono, 14pt
- Colors: Syntax highlighting for JSON
- Commands auto-type at 30 chars/sec
- Output appears immediately after command

### Voiceover Recording

**Tone:** Confident, emphasizing collaboration
**Pace:** Moderate to slightly fast (energetic)
**Voice:** Professional, clear, enthusiastic

**Full Script (45 seconds, ~70 words):**
```
Here's how humans and AI collaborate through Stride's review workflow.

The AI agent has completed the task and moved it to Review. Now a human reviews the implementation.

The reviewer checks the pull request and notices the implementation needs improvement.

The reviewer requests changes. The task automatically moves back to Ready for the AI to address.

The AI agent reclaims the task, implements the requested changes, and resubmits for review.

The reviewer approves. The AI merges and deploys automatically. Collaboration complete.
```

### Background Music

**Style:** Modern, upbeat, collaborative
**Tempo:** 120 BPM
**Volume:** -22dB (noticeable but not overpowering)
**Mood:** Energetic, positive, productive
**Arc:** Build energy through the workflow, peak at approval

### On-Screen Annotations

**Style:**
- **Arrows:** Blue gradient (matches Stride brand)
- **Highlights:** Yellow box with pulsing animation
- **Status indicators:** Green checkmark, orange warning
- **Text boxes:** Semi-transparent dark background, white text

**Key Annotations:**
1. "View changes" arrow to PR link (0:10)
2. "Automated verification" badge (0:12)
3. "Missing edge case handling" highlight (0:20)
4. Task movement animation "Review → Ready" (0:30)
5. Progress bar "Changes implemented in 30 seconds" (0:37)
6. Final message "Human reviews. AI implements." (0:43)

### Transitions & Effects

**Split-Screen Transition (0:17):**
- Left side wipes to GitHub view
- Right side stays static (terminal)
- Duration: 0.5s smooth wipe

**Task Movement Animations:**
- Card slides between columns (0.8s ease-in-out)
- Subtle glow effect on destination column
- Real LiveView animation (record actual Stride behavior)

**Approval Celebration (0:42):**
- Subtle confetti burst from task card
- Green checkmark pulse
- Duration: 1 second

### Captions/Subtitles

**Format:** SRT and WebVTT
**Style:** White text, dark background (75% opacity)
**Position:** Bottom center, above annotations
**Font:** Inter, bold, 44px

---

## Pre-Production Checklist

### Environment Setup

**Stride Board:**
- [ ] Clean board with minimal tasks
- [ ] Pre-create task W23 "Add password strength indicator"
- [ ] Pre-populate all task metadata
- [ ] Create GitHub PR #145 with intentional "bug" (missing validation)
- [ ] Prepare second version of PR with fixes

**Test User Accounts:**
- [ ] Human reviewer: "Sarah Chen" (or similar professional name)
- [ ] AI agent: "CodeBot-1"
- [ ] Both authenticated and ready

**Terminal Setup:**
- [ ] Configure with clean prompt
- [ ] API token configured
- [ ] Pre-write all curl commands
- [ ] Test webhook notifications work

### Test Data

**Task W23 Initial State:**
```json
{
  "id": 23,
  "identifier": "W23",
  "title": "Add password strength indicator",
  "status": "completed",
  "column_name": "Review",
  "completion_summary": "Added password strength indicator with visual feedback",
  "actual_files_changed": "2",
  "pr_url": "https://github.com/org/repo/pull/145"
}
```

**GitHub PR #145 Content:**
- Intentionally missing: Empty password validation
- Intentionally missing: Min length test
- Everything else correct and working

**Review Feedback Template:**
```
Good start! Please add:
1. Handle empty password input
2. Add test for min length validation
```

### Recording Sequence

**Record in this order:**

1. **Record terminal side first** (right side)
   - All commands and outputs
   - Use screen recording with asciinema
   - Export to video

2. **Record UI side second** (left side)
   - Play terminal video on second monitor for timing reference
   - Match actions to terminal state changes
   - Record with OBS or ScreenFlow

3. **Combine in editor**
   - Sync both videos precisely
   - Add split-screen effect
   - Add transitions and annotations

### Recording Tools

- [ ] **Left side:** OBS Studio (UI recording)
- [ ] **Right side:** asciinema + agg (terminal)
- [ ] **Browser:** Chrome with clean profile
- [ ] **Cursor highlighting:** KeyCastr or MousePosé
- [ ] **Sync reference:** Audio beep or visual flash at start

---

## Detailed Recording Scripts

### Terminal Script (Right Side)

**File: `review-workflow-terminal.sh`**
```bash
#!/bin/bash

# Segment 1: Check task status (0:05-0:15)
echo "$ # Task W23 in Review"
sleep 2
echo "$ # Waiting for human feedback..."
sleep 2
echo "$ curl https://www.stridelikeaboss.com/api/tasks/W23"
sleep 1
cat << 'EOF' | jq
{
  "status": "completed",
  "review_status": null,
  "column_name": "Review"
}
EOF
sleep 3

# Segment 2: Receive review feedback (0:25-0:32)
echo ""
echo "# Webhook notification"
sleep 1
echo "Task W23 review status: changes_requested"
sleep 1
echo ""
echo "Review notes:"
echo "- Handle empty password input"
echo "- Add test for min length validation"
sleep 2
echo ""
echo "Status: open"
echo "Column: Ready"
sleep 3

# Segment 3: Re-implement and complete (0:32-0:40)
echo ""
echo "$ curl -X POST .../api/tasks/claim"
sleep 1
echo "# Task W23 claimed"
sleep 1
echo ""
echo "$ # Implementing requested changes..."
sleep 2
echo "✓ Added empty password validation"
sleep 1
echo "✓ Added min length test"
sleep 1
echo "✓ All tests passing (15 tests)"
sleep 2
echo ""
echo "$ curl -X PATCH .../api/tasks/W23/complete"
sleep 1
echo "# Moving to Review..."
sleep 3

# Segment 4: Approval and deploy (0:40-0:45)
echo ""
echo "# Task W23 approved"
sleep 1
echo "Executing after_review hook..."
sleep 1
echo "✓ Merging PR #145"
sleep 1
echo "✓ Deploying to staging"
sleep 1
echo ""
echo "Task W23: Done ✓"
sleep 1
echo "Claiming next task..."
```

### UI Recording Script (Left Side)

**Segment timings to match terminal:**

**0:05-0:15:**
- Hover over W23 task card in Review column
- Click to open modal
- Show details (completion summary, files, tests, PR link)
- Hold for 3 seconds

**0:15-0:25:**
- Click "View Pull Request"
- Browser opens to GitHub PR #145
- Scroll through code diff
- Pause on validation function (missing edge case)

**0:25-0:32:**
- Return to Stride (tab switch or close GitHub)
- Task modal still open
- Click "Request Changes"
- Type review notes (prepared in advance, paste or fast-type)
- Click "Submit Review"
- Watch task move to Ready column

**0:32-0:40:**
- Board view showing Ready column
- Watch task move Ready → Doing (triggered by API)
- Watch task move Doing → Review (triggered by API)

**0:40-0:45:**
- Task in Review column
- Click task to open modal
- Click "Approve" button
- Celebration animation
- Task moves to Done

---

## Post-Production

### Editing Workflow

1. **Sync videos** (critical step)
   - Use audio beep at start as sync point
   - Align terminal and UI actions precisely
   - Verify task movements match API calls

2. **Create split-screen**
   - 50/50 left-right split
   - Add 2px divider line (orange gradient)
   - Ensure both sides are in focus

3. **Add annotations**
   - Arrows, highlights, text boxes
   - Animated entrance/exit (0.3s fade)
   - Coordinate with voiceover

4. **Add voiceover**
   - Record clean audio
   - Sync with visual actions
   - Ensure perfect timing

5. **Add background music**
   - Start subtle, build energy
   - Duck under voiceover
   - Peak at approval moment

6. **Add task movement effects**
   - Highlight column transitions
   - Add motion graphics for card movement
   - Sync with sound effect (subtle whoosh)

7. **Add final text overlay**
   - "Human reviews. AI implements."
   - "Quality + Speed = Stride"
   - Fade in at 0:43, hold until end

### Animation Details

**Task Card Movement:**
- Export Stride's actual LiveView animation
- If not smooth enough, recreate in After Effects
- Bezier curve: ease-in-out
- Duration: 0.8 seconds
- Add subtle glow on destination column

**Approval Celebration:**
- Confetti particles: 15-20 pieces
- Colors: Green, orange, blue (brand colors)
- Physics: Gentle fall with slight rotation
- Duration: 1 second
- Sound: Subtle "success" chime

### Sound Design

**Background Elements:**
- Keyboard typing sounds (when human types review notes)
- Mouse clicks (subtle, on UI interactions)
- Whoosh sound (task movements, very subtle)
- Success chime (approval moment, 0:42)
- All sounds at -30dB to -35dB (barely audible)

### Quality Checks

- [ ] Both sides are in perfect sync
- [ ] Task movements align with API calls
- [ ] All text is readable (especially terminal)
- [ ] Cursor movements are smooth
- [ ] No UI elements are cut off
- [ ] Annotations don't block important info
- [ ] Audio levels are balanced
- [ ] Voiceover is clear and pace is right
- [ ] Music doesn't overpower voice
- [ ] Video is exactly 45 seconds
- [ ] Captions are accurate

---

## Deployment

### File Formats

**Primary Version:**
- Format: MP4 (H.264)
- Resolution: 1920x1080
- Bitrate: 10 Mbps (high quality for split-screen)
- File size target: 10-15MB

**Optimized Versions:**
- Web (streaming): 6 Mbps, 8-10MB
- Mobile: 720p, 4 Mbps, 4-6MB

**Social Media:**
- Square crop (1080x1080): Focus on human side, picture-in-picture terminal
- Vertical (1080x1920): Stack views vertically
- Short clip (15s): Just the approval moment for quick social posts

### Documentation Integration

**Embed in these docs:**
- docs/REVIEW-WORKFLOW.md (top of page)
- docs/GETTING-STARTED-WITH-AI.md (after setup section)
- Homepage "Features" section
- About page demonstrating collaboration

**Embed code:**
```html
<div class="video-container">
  <video controls width="100%" poster="review-workflow-poster.jpg">
    <source src="/videos/review-workflow.mp4" type="video/mp4">
    <track src="/videos/review-workflow.vtt" kind="captions" srclang="en" label="English">
  </video>
  <p class="video-caption">
    See how humans and AI collaborate through Stride's review workflow
  </p>
</div>
```

---

## Success Metrics

**Target Goals:**
- 60%+ completion rate
- Featured in product demos
- Shared by users on social media
- 300+ YouTube views in first month
- Increase understanding of review workflow (reduce support questions)

**Track:**
- Video completion rate by segment
- Replay rate (people rewatching)
- Social shares
- Conversion from video to sign-up
- Support ticket mentions of "review workflow"

---

## Budget Estimate

**DIY Approach (Total: $40-120):**
- Screen recording: Free (OBS + asciinema)
- Video editing: Free (DaVinci Resolve)
- Sound effects: $10-20 (freesound.org or premium pack)
- Background music: $15-30
- Voiceover: Self or Fiverr ($50)
- Total time: 5-7 hours

**Professional Approach (Total: $1,000-2,000):**
- Script and storyboard: $150-250
- Professional voiceover: $150-250
- Video production and editing: $500-1,200
- Sound design: $100-200
- Music licensing: $50-100
- Timeline: 1 week

---

## Alternative Approaches

### Extended Version (90s)
- Add segment showing multiple review cycles
- Show dependency unblocking after approval
- Demonstrate review notes with code snippets

### Animated Version
- Use motion graphics instead of screen recording
- More polished, professional look
- Easier to update as UI changes
- Can exaggerate important moments

### Picture-in-Picture
- Main focus on human reviewer
- Terminal in small corner window
- More emphasis on human decision-making

---

## Notes for Production

### Timing Challenges

**Critical sync points:**
1. Task appears in Review (0:10) - must match terminal check
2. Review submitted (0:30) - terminal should show webhook immediately
3. Task returns to Review (0:37) - both sides must update together
4. Approval (0:42) - terminal hook execution must be instant

**Solution:** Record terminal first with exact timing marks, then match UI recording to terminal playback.

### Common Issues

**Problem:** UI animations are slower than expected
**Solution:** Record at higher framerate (60fps), slightly speed up in post (1.1x)

**Problem:** Task movements not smooth
**Solution:** Use Stride's LiveView animations, they're already optimized

**Problem:** Terminal text hard to read on split screen
**Solution:** Increase font size to 16pt, use high-contrast theme

### Testing Checklist

Before final recording:
- [ ] Run through workflow 3 times to verify timing
- [ ] Ensure all API endpoints respond correctly
- [ ] Test webhook delivery is instant
- [ ] Verify GitHub PR exists and loads fast
- [ ] Clear browser cache for clean loading
- [ ] Close all unnecessary apps (performance)

---

## Technical Notes

### Webhook Setup

For instant terminal notifications, use:

```bash
# In separate terminal, watch for webhooks
curl -N https://www.stridelikeaboss.com/api/tasks/W23/watch

# Or simulate webhook with timed script
sleep 25 && echo "# Webhook notification" && echo "Task W23 review status: changes_requested"
```

### Realistic Timing

**Actual implementation time:** 2-3 minutes
**Video time:** Show in 8 seconds (0:32-0:40)

**Approach:**
- Show abbreviated steps with "..." ellipsis
- Use progress indicator: "Implementing changes... (accelerated)"
- Keep checkmarks appearing at realistic intervals (1 second apart)

---

**Document Version:** 1.0
**Created:** 2026-01-01
**Purpose:** Complete production guide for Review Workflow demonstration video
**Related:** VIDEO1.md, VIDEO2.md, VIDEOS.md, docs/REVIEW-WORKFLOW.md
