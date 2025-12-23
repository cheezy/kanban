# Based on my analysis of the ViewComponent, here are the task fields that are always displayed (no toggle control):

## Core Metadata (Always Visible):

Identifier (line 71) - Task identifier badge
Type (lines 72-83) - Work/Defect badge
Status (lines 100-107) - Open/In Progress/Completed/Blocked badge
Title (line 119) - Task title
Column (lines 123-126) - Current column name
Priority (lines 128-148) - Low/Medium/High/Critical
Assigned To (lines 150-161) - Assigned user or "Unassigned"
Needs Review (lines 163-174) - Yes/No

## Conditional Fields (Always Visible When Data Exists):

Estimated Files (lines 176-183) - Number estimate
Creator Info (lines 186-218) - Created by user/agent, claimed at, claim expires
Description (lines 254-261) - Task description text
Dependencies (lines 447-456) - List of dependent tasks
Actual vs Estimated (lines 480-530) - Completion metrics when task is completed
Review Status (lines 532-562) - Review information when needs_review is true
Completion (lines 564-594) - Completion details when status is completed
History (lines 596-660) - Task change history
Comments (lines 662-683) - Task comments

## Fields WITH Toggles (Already Implemented):

Complexity (line 84) - controlled by "complexity" toggle
Context (line 220) - controlled by "context" toggle
Acceptance Criteria (line 263) - controlled by "acceptance_criteria" toggle
Key Files (line 272) - controlled by "key_files" toggle
Verification Steps (line 290) - controlled by "verification_steps" toggle
Implementation Guidance (line 327) - controlled by "technical_notes" toggle
Observability (line 361) - controlled by "observability" toggle
Error Handling (line 395) - controlled by "error_handling" toggle
Technology Requirements (line 421) - controlled by "technology_requirements" toggle
Required Agent Capabilities (line 434) - controlled by "required_capabilities" toggle (just added)
Pitfalls (line 458) - controlled by "pitfalls" toggle
Out of Scope (line 469) - controlled by "out_of_scope" toggle

## Summary: The fields without toggles are primarily core task metadata (identifier, title, status, priority, assignments) and system-generated fields (history, comments, completion data, review status). These are considered essential information that should always be visible.