# Video 1: "Stride in 60 Seconds"

**Duration:** 60 seconds
**Purpose:** Homepage hero video - elevator pitch showing complete workflow
**Format:** Split-screen demonstration with voiceover
**Target Audience:** First-time visitors, potential users evaluating Stride

---

## Video Concept

Split-screen format showing:
- **Left side:** Human using Stride web UI
- **Right side:** AI agent terminal executing commands

Both sides work in parallel, demonstrating true collaboration.

---

## Script & Timing

### 0:00-0:08 (8 seconds)
**Visual:**
- Fade in to Stride logo
- Quick transition to split screen showing empty board on left, terminal prompt on right

**Voiceover:**
> "Stride: where AI agents and humans work together. Watch them collaborate in real-time."

**On-screen text:** "Stride - AI-Human Collaboration Platform"

---

### 0:08-0:18 (10 seconds)
**Visual - Human side (left):**
- Click "Create AI Optimized Board"
- Board appears with columns: Backlog, Ready, Doing, Review, Done
- Quick pan across the board showing the clean interface

**Visual - AI side (right):**
```bash
$ curl https://www.stridelikeaboss.com/api/agent/onboarding \
  -H "Authorization: Bearer stride_dev_..."
# Response shows available columns, workflow
```

**Voiceover:**
> "Create an AI-optimized board with built-in workflow columns. Your AI agent connects via API."

---

### 0:18-0:28 (10 seconds)
**Visual - Human side:**
- Click "New Task" button
- Quick form fill showing:
  - Title: "Add user authentication"
  - Complexity: "medium"
  - Key files listed
  - Drag task to "Ready" column

**Visual - AI side:**
Terminal shows:
```bash
# Agent discovers the new task
$ curl https://www.stridelikeaboss.com/api/tasks/next
# Shows W21: "Add user authentication"
```

**Voiceover:**
> "Humans create structured tasks with context. AI agents discover them instantly."

---

### 0:28-0:38 (10 seconds)
**Visual - Human side:**
- Task card shows "Claimed by: AI Agent"
- Watch task move from "Ready" → "Doing" (auto-update via LiveView)

**Visual - AI side:**
Terminal shows:
```bash
$ curl -X POST .../api/tasks/claim
# Task claimed
# Hook: before_doing - Pulling latest code...
✓ Ready to implement
```

**Voiceover:**
> "Agents claim tasks atomically. Hooks execute automatically—pulling code, running tests."

---

### 0:38-0:48 (10 seconds)
**Visual - Human side:**
- Task moves to "Review" column
- Human clicks on task to see details
- Shows completion summary and PR link

**Visual - AI side:**
Terminal shows:
```bash
# Implementation happening (accelerated)
✓ Tests passing
✓ Code written
$ curl -X PATCH .../api/tasks/W21/complete
# Hook: after_doing - Running tests...
# Hook: before_review - Creating PR...
✓ Moved to Review
```

**Voiceover:**
> "Agents complete work, run tests, create pull requests—all automated."

---

### 0:48-0:56 (8 seconds)
**Visual - Human side:**
- Human clicks "Approve" button on task
- Task smoothly moves to "Done" column
- Green checkmark animation
- Board updates showing progress

**Visual - AI side:**
Terminal shows:
```bash
# Agent checking for next task
$ curl https://www.stridelikeaboss.com/api/tasks/claim
# Hook: after_review - Merging PR...
# Hook: after_review - Deploying...
✓ Task W21 complete - claiming next task...
```

**Voiceover:**
> "Humans review and approve. AI handles deployment and moves to the next task."

---

### 0:56-1:00 (4 seconds)
**Visual:**
- Zoom out to show full board with multiple tasks in different stages
- Split screen merges into single view showing both perspectives overlaid
- Fade to Stride logo with tagline

**On-screen text:**
```
Stride
Where AI Agents and Humans Work Together
stridelikeaboss.com
```

**Voiceover:**
> "Stride. Where AI agents and humans work together."

---

## Production Details

### Technical Specifications

**Resolution:** 1920x1080 (1080p)
**Frame Rate:** 60fps (for smooth animations)
**Aspect Ratio:** 16:9
**File Format:** MP4 (H.264)
**Audio:** AAC 320kbps
**Total Duration:** Exactly 60 seconds

### Visual Style

**Left Side (Human UI):**
- Screen recording of actual Stride web interface
- Clean, uncluttered - close unnecessary browser tabs/bookmarks
- Cursor should be clearly visible (consider cursor highlighting)
- Smooth scrolling and transitions
- Use Chrome or Safari for clean rendering

**Right Side (AI Terminal):**
- Use `asciinema` or similar for terminal recording
- Font: Monaco or Menlo, size 14pt
- Color scheme: Dark background with syntax highlighting
- Commands should auto-type (not instant paste)
- Use `glow` or similar for formatted API response viewing
- Show HTTP status codes in green (200 OK)

**Split Screen Layout:**
- 50/50 split with subtle divider line
- Left: Web UI (1:1 pixel recording)
- Right: Terminal (may need slight zoom for readability)
- Synchronized timing between both sides

### Voiceover Recording

**Tone:** Professional but friendly, energetic
**Pace:** Clear and deliberate - avoid rushing
**Voice:** Neutral accent, confident delivery
**Recording Quality:** Studio-quality, no background noise
**Post-processing:** Compression, EQ, de-essing

**Full Script (60 seconds):**
```
Stride: where AI agents and humans work together. Watch them collaborate in real-time.

Create an AI-optimized board with built-in workflow columns. Your AI agent connects via API.

Humans create structured tasks with context. AI agents discover them instantly.

Agents claim tasks atomically. Hooks execute automatically—pulling code, running tests.

Agents complete work, run tests, create pull requests—all automated.

Humans review and approve. AI handles deployment and moves to the next task.

Stride. Where AI agents and humans work together.
```

### Background Music

**Style:** Upbeat, modern, tech-focused
**Tempo:** 120-130 BPM
**Volume:** -20dB to -25dB (subtle, not overpowering voiceover)
**Sources:** Epidemic Sound, Artlist, or AudioJungle
**Keywords:** "corporate tech", "innovation", "productivity"
**License:** Royalty-free with commercial use rights

### On-Screen Text & Graphics

**Font:** Inter or similar modern sans-serif
**Colors:** Match Stride brand colors
- Primary: Orange gradient (#FF6B35 to #F7931E)
- Secondary: Blue (#3B82F6)
- Text: White with subtle drop shadow for readability

**Animations:**
- Fade in/out for text overlays
- Smooth task card movements
- Checkmark animations on completion
- Subtle glow effects on interactive elements

### Captions/Subtitles

**Format:** SRT file
**Timing:** Word-level timing for accuracy
**Style:** White text, black background box with 70% opacity
**Position:** Bottom center, above any on-screen text
**Font Size:** Large enough for mobile viewing

---

## Pre-Production Checklist

### Environment Setup

- [ ] Clean Stride instance with no existing data
- [ ] Pre-create demo user account: "Demo Human"
- [ ] Pre-configure AI agent with auth token
- [ ] Set up split-screen recording software (OBS Studio recommended)
- [ ] Test terminal recording with `asciinema`
- [ ] Verify all API endpoints are working
- [ ] Create test repository for "Add user authentication" task

### Test Data Preparation

- [ ] Pre-write task details to paste quickly:
  - Title: "Add user authentication"
  - Description: Pre-written with why/what/where_context
  - Key files: List of 3-4 files
  - Complexity: medium
  - Verification steps

- [ ] Pre-write API commands in script file for accuracy
- [ ] Test complete workflow end-to-end before recording
- [ ] Time each section to ensure 60-second total

### Recording Tools

- [ ] **Screen Recording:** OBS Studio (free, professional)
- [ ] **Terminal Recording:** asciinema + agg (for gif conversion)
- [ ] **Cursor Highlighting:** KeyCastr or similar
- [ ] **Voiceover:** Audacity or Adobe Audition
- [ ] **Video Editing:** Final Cut Pro, Adobe Premiere, or DaVinci Resolve
- [ ] **Music:** Epidemic Sound or Artlist subscription

---

## Post-Production

### Editing Steps

1. **Sync audio and video** - Align voiceover with screen recordings
2. **Color correction** - Ensure UI looks crisp and colors are accurate
3. **Add on-screen text** - Titles, tagline, URL
4. **Insert transitions** - Smooth fades between sections
5. **Add background music** - Duck music during voiceover
6. **Create captions** - Generate SRT file and burn-in subtitles
7. **Add animations** - Highlight clicks, zoom effects
8. **Export settings:**
   - Format: MP4
   - Codec: H.264
   - Resolution: 1920x1080
   - Frame Rate: 60fps
   - Bitrate: 8-10 Mbps (balance quality/file size)

### Quality Checks

- [ ] Watch at full volume - check audio levels
- [ ] Watch muted - verify captions are readable
- [ ] Watch on mobile - ensure text is legible
- [ ] Check transitions are smooth (no jarring cuts)
- [ ] Verify all URLs and text are correct
- [ ] Test autoplay with mute (for homepage)
- [ ] Confirm 60-second duration

---

## Deployment

### File Formats

Create multiple versions:

1. **Hero Video (Homepage):**
   - Format: MP4
   - Resolution: 1920x1080
   - Bitrate: High (10 Mbps)
   - Autoplay: Yes (muted)
   - Loop: Yes

2. **YouTube Upload:**
   - Format: MP4
   - Resolution: 1920x1080
   - Bitrate: Maximum quality
   - Thumbnail: Custom (showing split screen)

3. **Social Media:**
   - Square version (1080x1080) for Instagram/LinkedIn
   - Vertical version (1080x1920) for Stories/Reels
   - Captions burned-in (many watch muted)

### Homepage Integration

**HTML:**
```html
<video
  autoplay
  muted
  loop
  playsinline
  class="hero-video"
  poster="stride-video-poster.jpg"
>
  <source src="/videos/stride-60-seconds.mp4" type="video/mp4">
  <track src="/videos/stride-60-seconds.vtt" kind="captions" srclang="en" label="English">
</video>
<button class="unmute-btn" aria-label="Unmute video">
  <i class="volume-icon"></i>
</button>
```

**Optimization:**
- Compress video using HandBrake or ffmpeg
- Target: Under 10MB file size
- Consider WebM format for better compression
- Use lazy loading if not above fold

---

## Success Metrics

After deployment, track:

- [ ] Video completion rate (% who watch to end)
- [ ] Click-through rate on CTA after video
- [ ] Bounce rate before/after adding video
- [ ] User feedback/comments
- [ ] Sign-up conversion from homepage
- [ ] YouTube views and engagement
- [ ] Social media shares and reactions

**Target Goals:**
- 50%+ completion rate
- 10%+ increase in homepage CTR
- 15%+ reduction in bounce rate
- 1000+ YouTube views in first month

---

## Budget Estimate

**DIY Approach (Total: $50-200):**
- Background music license: $15-30/month (Epidemic Sound)
- Screen recording software: Free (OBS Studio)
- Video editing: Free (DaVinci Resolve) or $30/month (Adobe Premiere)
- Voice talent: Self-recorded or Fiverr ($50-150)
- Total time: 8-12 hours

**Professional Approach (Total: $1,500-3,000):**
- Script writing: $200-400
- Professional voiceover: $300-500
- Video production: $800-1,500
- Music licensing: $50-100
- Revisions and edits: Included
- Timeline: 1-2 weeks

---

## Alternative Ideas

If 60 seconds proves too tight, consider:

**Plan B - 90 Second Version:**
- Add 30 seconds showing dependency management
- Show multiple tasks completing in sequence
- Demonstrate task blocking/unblocking

**Plan C - Animated Version:**
- Use motion graphics instead of screen recording
- Cleaner, more polished look
- Easier to update as UI changes
- Higher production cost

---

## Notes for Narrator

**Pronunciation Guide:**
- Stride: STRYDE (rhymes with "pride")
- API: A-P-I (spell it out)
- stridelikeaboss.com: stride-like-a-boss-dot-com

**Emphasis Points:**
- "AI agents and humans **work together**" (emphasize collaboration)
- "Hooks execute **automatically**" (emphasize automation)
- "Agents **discover them instantly**" (emphasize speed)

**Pacing:**
- Total word count: ~105 words
- Speaking rate: 105 words/min (slightly slower for clarity)
- Pause after "Watch them collaborate in real-time" (1 second)
- Pause after "Stride." before final tagline (0.5 seconds)

---

## Contingency Plans

**If recording runs long:**
- Remove 0:18-0:28 task creation detail
- Show task already in Ready column
- Cut straight to agent claiming task

**If split-screen is too busy:**
- Alternate between human and AI views
- Picture-in-picture with main focus switching

**If terminal is hard to read:**
- Use larger font (16-18pt)
- Show only key commands, hide verbose output
- Add text overlays explaining what's happening

---

## Next Steps

1. **Pre-production meeting** - Review script with stakeholders
2. **Schedule recording session** - Block 4-hour window
3. **Prepare demo environment** - Set up clean instance
4. **Record A-roll** - Screen recordings
5. **Record voiceover** - Professional or self-recorded
6. **Edit video** - 2-3 days for editing
7. **Review cycle** - Get feedback, make revisions
8. **Final export** - Multiple formats
9. **Deploy to homepage** - Update website
10. **Promote** - Social media, YouTube, newsletter

**Estimated Timeline:** 2-3 weeks from start to deployment

---

## Contact & Resources

**Video Production Resources:**
- OBS Studio: https://obsproject.com/
- asciinema: https://asciinema.org/
- DaVinci Resolve: https://www.blackmagicdesign.com/products/davinciresolve
- Epidemic Sound: https://www.epidemicsound.com/
- Fiverr (voiceover): https://www.fiverr.com/categories/music-audio/voice-overs

**Reference Examples:**
- Tidewave demo: Similar style and pacing
- Linear's product videos: Clean UI demonstrations
- Loom's homepage video: Good split-screen example

---

**Document Version:** 1.0
**Created:** 2026-01-01
**Purpose:** Complete production guide for Stride's hero video
