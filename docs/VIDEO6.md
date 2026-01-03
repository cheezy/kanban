# Video 6: "Capability Matching"

**Duration:** 45 seconds
**Purpose:** Demonstrate how agents only see tasks matching their capabilities
**Format:** Split-screen showing two AI agents with different capability sets
**Target Audience:** Teams using specialized AI agents for different tasks

---

## Video Concept

Split-screen demonstration showing two agents with different capabilities calling the same `/api/tasks/next` endpoint but receiving different tasks. Demonstrates intelligent task routing based on agent skills.

**Left side:** CodeBot (code_generation, testing)
**Right side:** DataBot (data_analysis, database)

**Key Message:** "Agents only claim tasks they're qualified to handle."

---

## Script & Timing

### 0:00-0:05 (5 seconds)
**Visual:**
- Fade in to split screen
- Left: Terminal labeled "CodeBot"
- Right: Terminal labeled "DataBot"

**On-screen text:** "Capability Matching"

**Voiceover:**
> "Capability matching ensures AI agents only claim tasks they're qualified to handle."

---

### 0:05-0:15 (10 seconds)
**Visual:**
- Both terminals show agent configuration files

**Left (CodeBot):**
```bash
$ cat .stride.md
# CodeBot Configuration

Agent Name: CodeBot
Capabilities:
  - code_generation
  - testing
  - code_review
```

**Right (DataBot):**
```bash
$ cat .stride.md
# DataBot Configuration

Agent Name: DataBot
Capabilities:
  - data_analysis
  - database
  - migrations
```

**Voiceover:**
> "CodeBot specializes in code and tests. DataBot handles data and database work."

**On-screen annotation:**
- Arrows pointing to capabilities lists
- "Different specializations"

---

### 0:15-0:28 (13 seconds)
**Visual:**
- Both agents call `/api/tasks/next` simultaneously
- Each receives different tasks

**Left (CodeBot):**
```bash
$ curl https://www.stridelikeaboss.com/api/tasks/next \
  -H "Authorization: Bearer codebot_token..."

{
  "task": {
    "id": 101,
    "identifier": "W10",
    "title": "Add input validation",
    "required_capabilities": [
      "code_generation",
      "testing"
    ]
  }
}

✓ Task W10 matches my capabilities
```

**Right (DataBot):**
```bash
$ curl https://www.stridelikeaboss.com/api/tasks/next \
  -H "Authorization: Bearer databot_token..."

{
  "task": {
    "id": 102,
    "identifier": "W11",
    "title": "Optimize database queries",
    "required_capabilities": [
      "database",
      "data_analysis"
    ]
  }
}

✓ Task W11 matches my capabilities
```

**Voiceover:**
> "When both agents query for available tasks, the API returns different results. Each agent gets tasks matching their capabilities."

**On-screen annotation:**
- Highlight "required_capabilities" in both responses
- "Intelligent routing"

---

### 0:28-0:38 (10 seconds)
**Visual:**
- Show task board with multiple tasks
- Highlight which tasks each agent can see/claim

**Stride Board UI:**
```
Ready Column:
┌─────────────────────────────────┐
│ W10: Add input validation       │  ← CodeBot can claim
│ Required: code_generation       │
├─────────────────────────────────┤
│ W11: Optimize database queries  │  ← DataBot can claim
│ Required: database              │
├─────────────────────────────────┤
│ W12: Write unit tests           │  ← CodeBot can claim
│ Required: testing               │
├─────────────────────────────────┤
│ W13: Create data migration      │  ← DataBot can claim
│ Required: migrations            │
└─────────────────────────────────┘
```

**Voiceover:**
> "Tasks specify required capabilities. Agents only see tasks they're qualified for, preventing mismatches."

**On-screen annotation:**
- Color-code tasks: Blue for CodeBot, Green for DataBot
- "Automatic filtering"

---

### 0:38-0:45 (7 seconds)
**Visual:**
- Quick montage of both agents working in parallel
- Terminal outputs showing successful completions

**Left (CodeBot):**
```bash
✓ W10 completed
Claiming next task...
✓ W12 claimed
```

**Right (DataBot):**
```bash
✓ W11 completed
Claiming next task...
✓ W13 claimed
```

**Voiceover:**
> "Both agents work in parallel on tasks suited to their strengths. Maximum efficiency, zero conflicts."

**On-screen text:**
```
Capability Matching
Right Task • Right Agent • Every Time

stridelikeaboss.com/docs/capabilities
```

---

## Production Details

### Technical Specifications

**Resolution:** 1920x1080 (1080p)
**Frame Rate:** 30fps
**Aspect Ratio:** 16:9
**File Format:** MP4 (H.264)
**Audio:** AAC 320kbps
**Total Duration:** 45 seconds

### Visual Style

**Split Screen Layout:**
- **Left (CodeBot):** 960x1080, blue accent color
- **Right (DataBot):** 960x1080, green accent color
- **Divider:** 2px vertical line, gradient blue→green
- **Labels:** Top of each screen, subtle badge

**Terminal Setup:**
- Font: JetBrains Mono, 14pt
- Left theme: Blue-tinted dark theme
- Right theme: Green-tinted dark theme
- Clear visual distinction between agents

### Voiceover Recording

**Tone:** Professional, explanatory
**Pace:** Moderate
**Voice:** Clear, authoritative

**Full Script (45 seconds, ~60 words):**
```
Capability matching ensures AI agents only claim tasks they're qualified to handle.

CodeBot specializes in code and tests. DataBot handles data and database work.

When both agents query for available tasks, the API returns different results. Each agent gets tasks matching their capabilities.

Tasks specify required capabilities. Agents only see tasks they're qualified for, preventing mismatches.

Both agents work in parallel on tasks suited to their strengths. Maximum efficiency, zero conflicts.
```

### Background Music

**Style:** Organized, systematic, tech
**Tempo:** 115 BPM
**Volume:** -23dB
**Mood:** Efficient, intelligent

### On-Screen Annotations

**Key Annotations:**
1. "Different specializations" (0:12)
2. Highlight capabilities in responses (0:20)
3. "Intelligent routing" (0:24)
4. Color-code tasks by agent (0:32)
5. "Automatic filtering" (0:35)

---

## Pre-Production Checklist

### Environment Setup

- [ ] Create two Stride API tokens (CodeBot, DataBot)
- [ ] Create tasks with different required_capabilities
- [ ] Test `/api/tasks/next` filtering works correctly
- [ ] Prepare .stride.md files for both agents

### Test Data

**Tasks to create:**
```json
[
  {
    "title": "Add input validation",
    "identifier": "W10",
    "required_capabilities": ["code_generation", "testing"]
  },
  {
    "title": "Optimize database queries",
    "identifier": "W11",
    "required_capabilities": ["database", "data_analysis"]
  },
  {
    "title": "Write unit tests",
    "identifier": "W12",
    "required_capabilities": ["testing"]
  },
  {
    "title": "Create data migration",
    "identifier": "W13",
    "required_capabilities": ["migrations"]
  }
]
```

---

## Recording Instructions

### Record both sides separately, then sync

**Left Side (CodeBot):**
```bash
# Show config
cat .stride.md
sleep 5

# Query tasks
curl https://www.stridelikeaboss.com/api/tasks/next \
  -H "Authorization: Bearer codebot_token..." | jq
sleep 5

# Show completion
echo "✓ Task W10 matches my capabilities"
sleep 3
```

**Right Side (DataBot):**
```bash
# Show config (synchronized timing)
cat .stride.md
sleep 5

# Query tasks
curl https://www.stridelikeaboss.com/api/tasks/next \
  -H "Authorization: Bearer databot_token..." | jq
sleep 5

# Show completion
echo "✓ Task W11 matches my capabilities"
sleep 3
```

---

## Post-Production

### Editing Workflow

1. Import both terminal recordings
2. Sync to play simultaneously
3. Add split-screen effect
4. Add color-coding (blue/green tints)
5. Add labels ("CodeBot", "DataBot")
6. Add board UI visualization (0:28-0:38)
7. Add voiceover
8. Add annotations
9. Add background music
10. Add end card

---

## Deployment

**Primary Version:** MP4, 1080p, 8 Mbps, ~8MB
**Social Media:** Square crop, focus on one agent at a time

**Embed in:**
- docs/AGENT-CAPABILITIES.md
- docs/GETTING-STARTED-WITH-AI.md
- Homepage "Features" section

---

## Success Metrics

**Target Goals:**
- 60%+ completion rate
- 350+ YouTube views in first month
- Increase use of required_capabilities field by 30%

---

## Budget Estimate

**DIY:** $30-80 (terminal recording, editing, voiceover)
**Professional:** $800-1,200

---

**Document Version:** 1.0
**Created:** 2026-01-01
**Purpose:** Complete production guide for Capability Matching video
**Related:** VIDEO1-5.md, VIDEOS.md, docs/AGENT-CAPABILITIES.md
