# Video 5: "Workflow Hooks in Action"

**Duration:** 75 seconds
**Purpose:** Demonstrate the power and automation of client-side workflow hooks
**Format:** Terminal-focused with split-screen hook execution
**Target Audience:** Developers wanting to automate their AI workflow

---

## Video Concept

Pure terminal demonstration showing hooks executing at each lifecycle point. Emphasizes that hooks run on the agent's machine (not the server), giving full control over the execution environment. Shows both successful hooks and a failing hook (demonstrating blocking behavior).

**Key Message:** "Hooks automate your workflow. Test failures block progress automatically."

---

## Script & Timing

### 0:00-0:08 (8 seconds)
**Visual:**
- Terminal with `.stride.md` file open
- Show hook configuration

**Terminal:**
```bash
$ cat .stride.md
# Stride Agent Configuration

Agent Name: DeployBot

## Hooks

### before_doing
#!/bin/bash
git fetch origin
git rebase origin/main
echo "✓ Code is up to date"

### after_doing
#!/bin/bash
mix format --check-formatted
mix credo --strict
mix test
echo "✓ All checks passed"

### before_review
#!/bin/bash
gh pr create --fill --draft
echo "✓ Draft PR created"

### after_review
#!/bin/bash
gh pr merge --squash
mix release
fly deploy
echo "✓ Deployed to production"
```

**Voiceover:**
> "Workflow hooks in Stride automate your entire development process. They execute on your machine at each lifecycle stage."

**On-screen text:** "Workflow Hooks in Action"
**On-screen annotation:** "Client-side execution = Full control"

---

### 0:08-0:18 (10 seconds)
**Visual:**
- Show task claim API call
- before_doing hook executes immediately

**Terminal:**
```bash
$ curl -X POST https://www.stridelikeaboss.com/api/tasks/claim \
  -H "Authorization: Bearer stride_dev_..." \
  -d '{"agent_name": "DeployBot"}' | jq

{
  "task": {
    "id": 42,
    "identifier": "W15",
    "title": "Fix pagination bug"
  },
  "hooks": {
    "before_doing": "git fetch origin && git rebase origin/main"
  }
}

Executing before_doing hook...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
From https://github.com/user/repo
 * branch            main       -> FETCH_HEAD
Current branch main is up to date.
✓ Code is up to date
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Voiceover:**
> "When claiming a task, the before_doing hook runs first, pulling the latest code automatically."

**On-screen annotation:**
- Highlight "before_doing" in response
- "Executes immediately after claim"

---

### 0:18-0:35 (17 seconds)
**Visual:**
- Show task completion API call
- after_doing hook executes with multiple checks
- All checks pass

**Terminal:**
```bash
$ # Task implementation completed...
$ # Now completing the task

$ curl -X PATCH .../api/tasks/42/complete \
  -d '{
    "completion_summary": "Fixed pagination bug",
    "actual_complexity": "small",
    "time_spent_minutes": 30
  }'

Executing after_doing hook...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[1/3] Running formatter check...
✓ All files properly formatted (125 files)

[2/3] Running static analysis...
✓ Credo found no issues

[3/3] Running test suite...
......................
✓ 22 tests, 0 failures

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ All checks passed
```

**Voiceover:**
> "The after_doing hook runs comprehensive checks: formatting, linting, and all tests. Everything must pass before the task can move forward."

**On-screen annotation:**
- Progress indicator: "1/3, 2/3, 3/3"
- "Blocking: Task won't complete if hooks fail"

---

### 0:35-0:50 (15 seconds)
**Visual:**
- Show hook failure scenario
- Different task completion attempt
- Tests fail, hook blocks completion

**Terminal:**
```bash
$ # Attempting to complete another task...

$ curl -X PATCH .../api/tasks/43/complete \
  -d '{"completion_summary": "Added search feature"}'

Executing after_doing hook...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[1/3] Running formatter check...
✓ All files properly formatted

[2/3] Running static analysis...
✓ Credo found no issues

[3/3] Running test suite...
.........F..........

Failures:

  1) test search returns results (SearchTest)
     test/search_test.exs:15
     Expected: 5 results
     Got: 0 results

✗ 22 tests, 1 failure

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✗ Hook failed: Tests must pass

ERROR: Task completion blocked
Task remains in "Doing" column
Fix the tests and try again
```

**Voiceover:**
> "If tests fail, the hook blocks completion. The task stays in the Doing column until the issue is fixed. No broken code reaches review."

**On-screen annotation:**
- Highlight "1 failure" in red
- "Hook blocks completion"
- "Quality gate: Prevents bad code"

---

### 0:50-1:05 (15 seconds)
**Visual:**
- Show review approval triggering before_review and after_review hooks
- PR creation and deployment

**Terminal:**
```bash
$ # Task W42 approved by reviewer...
$ # Executing review hooks...

Executing before_review hook...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Creating draft pull request...
✓ Draft PR created: #156
  https://github.com/user/repo/pull/156
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Executing after_review hook...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[1/3] Merging pull request...
✓ PR #156 merged to main

[2/3] Building release...
✓ Release v1.2.5 built successfully

[3/3] Deploying to production...
✓ Deployed to production (fly.io)
  https://myapp.fly.dev
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Task W42: Complete ✓
```

**Voiceover:**
> "After approval, hooks create pull requests, merge code, and deploy to production—all automatically. Complete automation from claim to deployment."

**On-screen annotation:**
- "before_review: PR creation"
- "after_review: Merge + Deploy"
- "Full CI/CD automation"

---

### 1:05-1:15 (10 seconds)
**Visual:**
- Show summary of all hooks
- Workflow diagram overlay

**Terminal shows summary:**
```bash
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Workflow Hooks Summary

before_doing  → Pull latest code
after_doing   → Format, lint, test (blocking)
before_review → Create pull request
after_review  → Merge and deploy

All hooks run on YOUR machine
Full control over execution environment
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Workflow Diagram:**
```
Claim → before_doing → Work → Complete
                              ↓
                        after_doing (blocking)
                              ↓
                           Review
                              ↓
                        before_review
                              ↓
                          Approve
                              ↓
                        after_review → Deploy
```

**Voiceover:**
> "Hooks transform Stride into your custom CI/CD pipeline. Your tools, your workflow, fully automated."

**On-screen text:**
```
Workflow Hooks
Client-Side • Blocking • Automated

stridelikeaboss.com/docs/hooks
```

---

## Production Details

### Technical Specifications

**Resolution:** 1920x1080 (1080p)
**Frame Rate:** 30fps (terminal content doesn't need 60fps)
**Aspect Ratio:** 16:9
**File Format:** MP4 (H.264)
**Audio:** AAC 320kbps
**Total Duration:** 75 seconds

### Visual Style

**Terminal Setup:**
- **App:** iTerm2 or Hyper
- **Theme:** Dracula or One Dark Pro
- **Font:** JetBrains Mono, 15pt
- **Prompt:** Minimal (just `$`)
- **Colors:**
  - Success (✓): Green (#50fa7b)
  - Failure (✗): Red (#ff5555)
  - Progress: Cyan (#8be9fd)
  - Headers: Purple (#bd93f9)

**Hook Execution Visual Style:**
- Box separators: `━━━━━` in purple
- Progress indicators: `[1/3]`, `[2/3]`, `[3/3]`
- Clear success/failure symbols
- Command output properly indented

### Voiceover Recording

**Tone:** Technical, authoritative, enthusiastic about automation
**Pace:** Moderate to fast (conveying efficiency)
**Voice:** Confident developer explaining to peer

**Full Script (75 seconds, ~115 words):**
```
Workflow hooks in Stride automate your entire development process. They execute on your machine at each lifecycle stage.

When claiming a task, the before_doing hook runs first, pulling the latest code automatically.

The after_doing hook runs comprehensive checks: formatting, linting, and all tests. Everything must pass before the task can move forward.

If tests fail, the hook blocks completion. The task stays in the Doing column until the issue is fixed. No broken code reaches review.

After approval, hooks create pull requests, merge code, and deploy to production—all automatically. Complete automation from claim to deployment.

Hooks transform Stride into your custom CI/CD pipeline. Your tools, your workflow, fully automated.
```

### Background Music

**Style:** Mechanical, rhythmic, tech-focused
**Tempo:** 128 BPM (upbeat, productive)
**Volume:** -25dB (present but not distracting)
**Mood:** Efficient, automated, modern
**Arc:** Steady energy, slight build during deployment section

### On-Screen Annotations

**Key Annotations:**
1. "Client-side execution = Full control" (0:05)
2. "Executes immediately after claim" (0:12)
3. Progress: "1/3, 2/3, 3/3" (0:22-0:30)
4. "Blocking: Task won't complete if hooks fail" (0:33)
5. Highlight "1 failure" in red box (0:42)
6. "Hook blocks completion" (0:45)
7. "Quality gate: Prevents bad code" (0:48)
8. "before_review: PR creation" (0:55)
9. "after_review: Merge + Deploy" (1:00)
10. "Full CI/CD automation" (1:03)

### Animation Sequences

**Hook Execution Animation:**
- Progress bars for each check
- Checkmarks appear with 0.2s fade
- Failure marks pulse red
- Separators draw in (0.3s)

**Workflow Diagram (1:05-1:15):**
- Animated flow from left to right
- Each stage lights up sequentially
- Arrows draw in progressively
- Blocking point highlighted

---

## Pre-Production Checklist

### Environment Setup

**Stride Configuration:**
- [ ] Create .stride.md with complete hook configuration
- [ ] Test all hooks execute correctly
- [ ] Prepare test failure scenario
- [ ] Configure GitHub CLI (`gh`) for PR creation
- [ ] Set up deployment environment (fly.io or similar)

**Test Scenarios:**
- [ ] Successful task completion (W42)
- [ ] Failed task completion (W43) with test failure
- [ ] Review approval triggering hooks

**Terminal Setup:**
- [ ] Clean shell history
- [ ] Configured with minimal prompt
- [ ] Colors properly configured
- [ ] Screen recording tested

### Script Preparation

**Create executable scripts:**

**`hooks/before_doing.sh`:**
```bash
#!/bin/bash
git fetch origin
git rebase origin/main
echo "✓ Code is up to date"
```

**`hooks/after_doing.sh`:**
```bash
#!/bin/bash
echo "[1/3] Running formatter check..."
mix format --check-formatted && echo "✓ All files properly formatted (125 files)" || exit 1

echo ""
echo "[2/3] Running static analysis..."
mix credo --strict && echo "✓ Credo found no issues" || exit 1

echo ""
echo "[3/3] Running test suite..."
mix test --color
```

**`hooks/after_doing_fail.sh`:**
```bash
#!/bin/bash
# Same as above but with intentional test failure
# Modify to fail one test
```

**`hooks/before_review.sh`:**
```bash
#!/bin/bash
gh pr create --fill --draft
echo "✓ Draft PR created: #156"
echo "  https://github.com/user/repo/pull/156"
```

**`hooks/after_review.sh`:**
```bash
#!/bin/bash
echo "[1/3] Merging pull request..."
gh pr merge 156 --squash && echo "✓ PR #156 merged to main"

echo ""
echo "[2/3] Building release..."
mix release && echo "✓ Release v1.2.5 built successfully"

echo ""
echo "[3/3] Deploying to production..."
fly deploy && echo "✓ Deployed to production (fly.io)"
echo "  https://myapp.fly.dev"
```

### Recording Tools

- [ ] **Terminal Recording:** asciinema or Terminalizer
- [ ] **Animation:** After Effects or Cavalry for workflow diagram
- [ ] **Video Editing:** DaVinci Resolve or Final Cut Pro
- [ ] **Screen Capture:** OBS Studio (for backup/alternatives)

---

## Recording Instructions

### Segment 1: Configuration (0:00-0:08)

```bash
asciinema rec hooks-config.cast

cat .stride.md
sleep 8
```

### Segment 2: before_doing Hook (0:08-0:18)

```bash
asciinema rec before-doing.cast

curl -X POST https://www.stridelikeaboss.com/api/tasks/claim \
  -H "Authorization: Bearer stride_dev_..." \
  -d '{"agent_name": "DeployBot"}' | jq

echo ""
echo "Executing before_doing hook..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
./hooks/before_doing.sh
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
sleep 3
```

### Segment 3: after_doing Success (0:18-0:35)

```bash
asciinema rec after-doing-success.cast

echo "$ # Task implementation completed..."
sleep 1
echo "$ # Now completing the task"
sleep 1
echo ""
curl -X PATCH .../api/tasks/42/complete \
  -d '{"completion_summary": "Fixed pagination bug"}'

echo ""
echo "Executing after_doing hook..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
./hooks/after_doing.sh
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ All checks passed"
sleep 3
```

### Segment 4: after_doing Failure (0:35-0:50)

```bash
asciinema rec after-doing-fail.cast

echo "$ # Attempting to complete another task..."
sleep 2
curl -X PATCH .../api/tasks/43/complete \
  -d '{"completion_summary": "Added search feature"}'

echo ""
echo "Executing after_doing hook..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
./hooks/after_doing_fail.sh
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✗ Hook failed: Tests must pass"
echo ""
echo "ERROR: Task completion blocked"
echo "Task remains in \"Doing\" column"
echo "Fix the tests and try again"
sleep 5
```

### Segment 5: Review Hooks (0:50-1:05)

```bash
asciinema rec review-hooks.cast

echo "$ # Task W42 approved by reviewer..."
sleep 1
echo "$ # Executing review hooks..."
sleep 1
echo ""
echo "Executing before_review hook..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
./hooks/before_review.sh
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
sleep 2

echo ""
echo "Executing after_review hook..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
./hooks/after_review.sh
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Task W42: Complete ✓"
sleep 3
```

### Segment 6: Summary (1:05-1:15)

- Create workflow diagram in After Effects or Keynote
- Export as video overlay
- Composite over terminal background

---

## Post-Production

### Editing Workflow

1. **Combine terminal recordings**
   - Import all asciinema casts
   - Convert to video (agg or svg-term)
   - Stitch together in sequence

2. **Add visual separators**
   - Between major segments
   - Use fade or wipe transitions (0.3s)

3. **Add progress indicators**
   - Overlay `[1/3]`, `[2/3]`, `[3/3]` graphics
   - Animate checkmarks and crosses
   - Color-code: green success, red failure

4. **Add workflow diagram** (1:05-1:15)
   - Animate flow chart
   - Sync with voiceover
   - Highlight each stage sequentially

5. **Add annotations**
   - Text callouts at key moments
   - Arrows pointing to important output
   - Fade in/out smoothly

6. **Add voiceover**
   - Record professional audio
   - Sync precisely with hook execution
   - Ensure technical accuracy

7. **Add background music**
   - Start at 0:00
   - Maintain steady energy
   - Slight build during deployment (0:50-1:05)
   - Fade out at 1:13

8. **Add end card** (1:10-1:15)
   - Summary text overlay
   - Documentation link
   - Brand elements

### Sound Design

**Hook Execution Sounds:**
- Checkmark appear: Soft "tick" (0.1s)
- Progress step: Gentle "blip"
- Failure: Subtle "error" tone
- Deployment success: Gentle "success" chime
- All at -32dB (subliminal reinforcement)

### Quality Checks

- [ ] Terminal text is crisp and readable
- [ ] Colors are accurate and consistent
- [ ] Hook execution timing feels natural
- [ ] Failure scenario is clear
- [ ] Annotations don't obscure terminal output
- [ ] Voiceover matches visuals precisely
- [ ] No awkward pauses or dead air
- [ ] Exactly 75 seconds
- [ ] All technical terms pronounced correctly

---

## Deployment

### File Formats

**Primary Version:**
- Format: MP4 (H.264)
- Resolution: 1920x1080
- Bitrate: 8 Mbps
- File size target: 15-20MB

**Optimized Versions:**
- Web streaming: 6 Mbps, ~12MB
- Mobile: 720p, 4 Mbps, ~8MB

**Social Media:**
- Square (1080x1080): Crop to terminal area
- Short clip (30s): Just the failure scenario (0:35-1:05)
- GIF (800x600): Hook execution loop

### Documentation Integration

**Embed in:**
- docs/AGENT-HOOK-EXECUTION-GUIDE.md (top of page, featured)
- docs/GETTING-STARTED-WITH-AI.md (hooks section)
- Homepage "Automation" section
- API documentation

**Sample embed:**
```html
<div class="automation-showcase">
  <video controls width="100%" poster="hooks-poster.jpg">
    <source src="/videos/workflow-hooks.mp4" type="video/mp4">
    <track src="/videos/workflow-hooks.vtt" kind="captions" srclang="en">
  </video>
  <p class="lead">
    See how workflow hooks automate your entire development pipeline—from code
    formatting to production deployment.
  </p>
  <a href="/docs/agent-hook-execution-guide" class="btn">
    Read the Hooks Guide →
  </a>
</div>
```

---

## Success Metrics

**Target Goals:**
- 65%+ completion rate (high value content)
- Featured prominently in documentation
- 600+ YouTube views in first month
- Increase hook usage by 40%
- Reduce support questions about hooks by 50%
- Social shares from developer community

**Track:**
- Completion rate by segment
- Replay rate (hooks are powerful, people rewatch)
- Documentation page views
- `.stride.md` file creations (proxy for hook adoption)
- Support tickets mentioning hooks

---

## Budget Estimate

**DIY Approach (Total: $50-120):**
- Terminal recording: Free (asciinema)
- Workflow diagram: Free (Keynote/PowerPoint) or $30 (After Effects)
- Video editing: Free (DaVinci Resolve)
- Sound effects: $10-20
- Background music: $15-30
- Voiceover: Self or Fiverr ($50)
- Total time: 8-10 hours

**Professional Approach (Total: $1,500-2,500):**
- Script development: $250-350
- Professional voiceover: $250-350
- Terminal screen recording: $300-500
- Workflow diagram animation: $300-500
- Video editing and post: $400-800
- Timeline: 1-2 weeks

---

## Alternative Approaches

### Live Coding Version
- Real-time hook execution with commentary
- Show actual failures and debugging
- More authentic, less polished

### Split-Screen Version
- Left: Terminal
- Right: Stride UI updating in real-time
- Shows cause and effect simultaneously

### Animated Explainer
- Motion graphics representing hooks
- Abstract but clearer conceptually
- Easier to update as features change

---

## Technical Notes

### Hook Execution Environment

**Environment Variables Available:**
```bash
TASK_ID=42
TASK_IDENTIFIER=W15
TASK_TITLE="Fix pagination bug"
BOARD_ID=1
COLUMN_NAME="Doing"
HOOK_NAME="after_doing"
```

**Use in hooks:**
```bash
#!/bin/bash
echo "Running hook: $HOOK_NAME"
echo "For task: $TASK_IDENTIFIER"
git commit -m "[$TASK_IDENTIFIER] $TASK_TITLE"
```

### Blocking vs Non-Blocking

**Blocking hooks** (prevent progression if they fail):
- `after_doing`: Must pass before task completes
- All other hooks are advisory (failures logged but don't block)

**Exit codes:**
- `0`: Success (continue workflow)
- `1-255`: Failure (block if after_doing, warn otherwise)

### Security Considerations

**Mention in video or docs:**
- Hooks run with your local permissions
- Can access local files and secrets
- Review hook scripts before execution
- Never commit `.stride_auth.md`

---

## Common Scenarios to Show

**Covered in this video:**
- ✅ Successful hook execution
- ✅ Test failure blocking completion
- ✅ Full deployment automation

**Could add in extended version:**
- Database migration in before_doing
- Code coverage check in after_doing
- Slack notification in after_review
- Rollback on deployment failure

---

**Document Version:** 1.0
**Created:** 2026-01-01
**Purpose:** Complete production guide for Workflow Hooks demonstration video
**Related:** VIDEO1.md, VIDEO2.md, VIDEO3.md, VIDEO4.md, VIDEOS.md, docs/AGENT-HOOK-EXECUTION-GUIDE.md
