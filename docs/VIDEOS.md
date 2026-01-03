# Recommended Videos for Stride

Ardita suggest 1, 2, 4, 3, 7, 5

1. "Stride in 60 Seconds" (Homepage Hero)
Duration: 1 minute

    - Quick overview showing the complete workflow: creating a board, adding columns, dragging tasks, and marking them complete
    - Shows both human and AI perspectives in split-screen
    - End with the tagline: "Where AI Agents and Humans Work Together"

2. "AI Agent Setup & First Task" (Getting Started)
Duration: 90 seconds

    - Screen recording showing:
        - Creating .stride_auth.md and .stride.md files
        - An AI agent calling /api/agent/onboarding
        - Agent claiming its first task
        - Hook execution (before_doing, after_doing)
        - Task completion
    - Voiceover explaining each step

3. "The Review Workflow"
Duration: 45 seconds

    - Shows a task moving through: Ready → Doing → Review → Done
    - Human reviewer approving or requesting changes
    - Split screen showing both AI agent terminal and human UI
    - Demonstrates the collaboration model

4. "Creating Goals with Nested Tasks"
Duration: 60 seconds

    - Screen recording of creating a goal via API with JSON
    - Shows the goal card with progress bar
    - Demonstrates child tasks being completed
    - Shows goal automatically moving columns when all children move

5. "Workflow Hooks in Action"
Duration: 75 seconds

    - Terminal screen showing hook execution at each lifecycle point
    - Examples: before_doing pulls latest code, after_doing runs tests
    - Shows both blocking (must succeed) and non-blocking hooks
    - Demonstrates real automation value

6. "Capability Matching"
Duration: 45 seconds

    - Shows tasks with different required capabilities
    - Two AI agents with different capability sets
    - Agents only see/claim tasks matching their capabilities
    - Quick demonstration of the /api/tasks/next filtering

7. "Human-Only Features"
Duration: 30 seconds

    - Quick tour showing drag-and-drop, manual task creation, board customization
    - Demonstrates what humans can do that agents can't
    - Shows the complementary nature of the collaboration

## Implementation Suggestions

### Technical Approach

1. Format: Screen recordings with voiceover (like Tidewave)
2. Length: Keep all videos under 90 seconds for maximum engagement
3. Quality: 1080p, clean UI, smooth scrolling
4. Style: Professional but approachable—show real workflows, not staged demos

### Placement on Your Site

#### Homepage

- Video #1 in hero section (auto-play on load, muted with unmute option)

#### About Page

- Video #2 in the "AI-Human Collaboration Platform" section
- Video #3 showing the review workflow

#### Documentation Links

- Video #5 linked from AGENT-HOOK-EXECUTION-GUIDE.md
- Video #4 linked from TASK-WRITING-GUIDE.md
- Video #6 linked from AGENT-CAPABILITIES.md

#### New "Videos" or "Learn" Page

- All videos in one place with descriptions
- Categorized: "For Humans", "For AI Integration", "Advanced Features"

### Production Tips

1. Script everything - Write exact narration before recording
2. Use cursor highlighting - Make it clear where clicks happen
3. Add subtle animations - Highlight important parts (arrows, zoom)
4. Include captions - Many viewers watch muted
5. Brand consistently - Use Stride's color scheme in overlays/titles
6. Terminal recordings - Use asciinema or similar for clean terminal demos
7. Music - Subtle background music (royalty-free) adds polish

### Priority Order for Creation

1. Start with #1 (Stride in 60 Seconds) - This is your elevator pitch
2. Then #2 (AI Agent Setup) - Most requested by developers
3. Then #3 (Review Workflow) - Unique differentiator
4. Others as time/budget allows

These videos would significantly help potential users understand Stride's unique value proposition much faster than reading documentation alone. The visual demonstration of AI-human collaboration is powerful and aligns perfectly with your positioning as an "AI-Human Collaboration Platform."
