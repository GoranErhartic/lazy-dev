---
title: "Generate PRD"
description: "Generate a Product Requirements Document (PRD) for a new feature. Use when planning a feature, starting a new project, or when asked to create a PRD. Triggers on: create a prd, write prd for, plan this feature, requirements for, spec out."
author: "Goran Erhartic"
---

Generate a structured Product Requirements Document (PRD) from human-readable feature requirements. This command guides you through clarifying questions and produces a `prd.json` file that is fully compatible with the lazy-dev autonomous agent loop.

**DO NOT IMPLEMENT THE FEATURE. Only generate the PRD.**

---

## PHASE 1: Gather Requirements

1. **Receive Initial Input:**
   * The user will provide a description of the feature they want to implement.
   * This can be in any format: natural language, bullet points, rough ideas, or partial specifications.

2. **Parse and Understand:**
   * Extract the core intent of the feature.
   * Identify any explicit acceptance criteria mentioned.
   * Note any technical constraints or preferences mentioned.
   * Identify the target project/codebase context.

---

## PHASE 2: Iterative Clarification Loop

Before generating the PRD, engage in an **iterative clarification process** to eliminate ALL ambiguity. This is NOT a one-shot questionnaire—it's a conversation that continues until you are 100% confident you understand the requirements.

### The Clarification Loop

```
┌─────────────────────────────────────────────────────────────┐
│  1. ANALYZE → Identify gaps and ambiguities in requirements │
│  2. ASK → Ask targeted questions (only what's unclear)      │
│  3. RECEIVE → Get user's answers                            │
│  4. RE-EVALUATE → Check if new ambiguities emerged          │
│  5. LOOP → If unclear areas remain, go back to step 2       │
│  6. CONFIRM → Summarize understanding before proceeding     │
└─────────────────────────────────────────────────────────────┘
```

### Round 1: Initial Questions

Ask questions **only for what is genuinely unclear**. The number of questions depends entirely on the input quality:

- **Crystal clear input** → May need 0-2 questions
- **Vague input** → May need 4-6 questions
- **Complex/ambiguous input** → May need more

**Question Format (for quick responses):**

```
1. [Specific question about unclear aspect]
   A. [Option based on context]
   B. [Option based on context]
   C. [Option based on context]
   D. Other: [please specify]
```

### Round 2+: Follow-Up Questions

After receiving answers, **re-evaluate the requirements** for:

1. **New ambiguities revealed** - Did an answer create new questions?
2. **Contradictions** - Does anything conflict with earlier statements?
3. **Implicit assumptions** - Are you making assumptions that need verification?
4. **Edge cases** - Are there scenarios that aren't covered?
5. **Technical implications** - Did the scope change based on answers?

**If ANY of these exist, ask follow-up questions.** Continue until you can answer "yes" to:

> "Could I write detailed, unambiguous acceptance criteria for every aspect of this feature?"

### Focus Areas for Questions

- **Problem/Goal:** What problem does this solve? What's the primary objective?
- **Core Functionality:** What are the key actions/capabilities?
- **Scope/Boundaries:** What should it NOT do? (Critical for managing scope)
- **Success Criteria:** How do we know it's done?
- **Target User:** Who will use this feature?
- **Technical Constraints:** Any existing patterns, libraries, or limitations?
- **Edge Cases:** What happens in unusual scenarios?
- **Data Requirements:** What external data is needed? What are the sources?

### ⚠️ CRITICAL: Data & Research Requirements

**For stories that require external data** (market data, prices, news, statistics), you MUST clarify:

1. **What data is needed?** (e.g., "BTC prices for Jan 1-11, 2026")
2. **What sources are acceptable?** (e.g., "CoinGecko, CoinMarketCap, official exchange APIs")
3. **Is placeholder data acceptable?** If yes, document this in the story notes
4. **Are there specific data points required?** (e.g., "price, market cap, 24h volume, % change")

**Why this matters:** The agent has `mcp_open-websearch_search` and browser tools to gather data during implementation. But if the PRD doesn't specify WHAT data is needed and WHERE to find it, the agent cannot work autonomously.

**Example: Research Story Done Right**
```json
{
  "id": "US-002",
  "title": "Research market data for January 2026",
  "acceptanceCriteria": [
    "Use mcp_open-websearch_search to find BTC/ETH prices for Jan 1-11, 2026",
    "Source data from CoinGecko or CoinMarketCap",
    "Document prices at start/end of period with % change",
    "List top 5 performing altcoins with sources cited",
    "Save research to research-notes.md with all sources"
  ],
  "notes": "Agent should use mcp_open-websearch_search tool for all data gathering"
}
```

### Clarification Guidelines

* **Ask only what is unclear** - skip obvious questions entirely.
* **Provide lettered options (A, B, C, D)** for quick selection.
* **Include "Other: [please specify]"** option when appropriate.
* **No artificial limits** - ask as many questions as needed for clarity.
* **Adapt options to the context** - don't use generic options when specific ones fit better.
* **Acknowledge progress** - tell the user what's now clear before asking more.
* **For research/data tasks** - clarify data sources, acceptable alternatives, and specific data points needed. The agent has `mcp_open-websearch_search` but needs to know WHAT to search for.

### Confirmation Before Proceeding

Before moving to Phase 3, output a **Requirements Summary** for user confirmation:

```markdown
## ✅ Requirements Summary

Based on our discussion, here's my understanding:

**Feature:** [One-line description]

**Core Requirements:**
- [Requirement 1]
- [Requirement 2]
- [Requirement 3]

**Scope Boundaries (Out of Scope):**
- [What this feature will NOT do]

**Technical Approach:**
- [Any constraints or patterns to follow]

**Confidence Level:** [High/Medium] - [Explain any remaining uncertainty]

---

Does this accurately capture what you want? If yes, I'll proceed with generating the PRD.
If anything is wrong or missing, please let me know.
```

**Only proceed to Phase 3 after user confirms the summary.**

---

## PHASE 3: Generate PRD Structure

After the user confirms the Requirements Summary, generate the PRD.

### Writing for Implementation

The PRD reader may be a junior developer or AI agent. Therefore:
- **Be explicit and unambiguous** - avoid vague terms like "works correctly"
- **Avoid jargon** or explain it when used
- **Provide enough detail** to understand purpose and core logic
- **Use concrete examples** where helpful
- **Number requirements** for easy reference

### PRD Components to Capture

While the output format is `prd.json`, mentally structure the feature as:

1. **Introduction/Overview** → Goes into `description` field
2. **Goals** → Specific, measurable objectives (inform story creation)
3. **User Stories** → The `userStories` array
4. **Functional Requirements** → FR-1, FR-2, etc. (inform acceptance criteria)
5. **Non-Goals (Out of Scope)** → Critical for scope management (add to notes)
6. **Technical Considerations** → Constraints, dependencies (add to notes)
7. **Success Metrics** → How success is measured (inform acceptance criteria)

### User Story Decomposition Rules:

1. **Each user story should be completable in one agent iteration** (roughly 15-30 minutes of work).
2. **Order stories by dependency** - foundational work first, dependent features later.
3. **Aim for 2-7 user stories** for a typical feature.
4. **Each story should have 2-5 acceptance criteria** that are:
   - Specific and verifiable (NOT vague like "works correctly")
   - Concrete (e.g., "Button shows confirmation dialog before deleting")
   - Not overlapping with other stories
   - Include at minimum: "Build/typecheck passes"
   - **For UI stories:** Always include "Verify in browser" as acceptance criterion
   - **For research/data stories:** Include specific instructions to use `mcp_open-websearch_search` tool and which sources to use

### Story ID Convention:
- Use `US-001`, `US-002`, etc. for sequential numbering.
- Stories should be independent enough to be worked on in separate agent iterations.

### Priority Guidelines:
- Priority 1: Core functionality, must-have, no dependencies
- Priority 2: Important features that depend on Priority 1
- Priority 3: Nice-to-have, polish, or optional enhancements
- Priority 998: Auto-generated code review step (US-REVIEW)
- Priority 999: Auto-generated implement recommendations step (US-IMPLEMENT-RECS, always last)

### ⚠️ CRITICAL: Unique Priorities Required

**Every user story MUST have a unique priority value.** No two stories can share the same priority.

- If multiple stories seem equally important, assign them sequential priorities (e.g., 1, 2, 3 instead of 1, 1, 1)
- The agent loop processes stories in priority order—duplicate priorities create ambiguity
- Use decimals if needed for fine-grained ordering (e.g., 1, 1.5, 2)

**Example of WRONG priorities:**
```json
{ "id": "US-001", "priority": 1 },
{ "id": "US-002", "priority": 1 },  // ❌ Duplicate!
{ "id": "US-003", "priority": 2 }
```

**Example of CORRECT priorities:**
```json
{ "id": "US-001", "priority": 1 },
{ "id": "US-002", "priority": 2 },  // ✅ Unique
{ "id": "US-003", "priority": 3 }
```

### Auto-Generated Review Steps:
Every PRD automatically includes two final user stories for quality assurance. These ensure proper code review and implementation of fixes **at the end of every feature**:

1. **US-REVIEW** (Priority 998): Detailed code review of implementation
2. **US-IMPLEMENT-RECS** (Priority 999): Implement code review recommendations

The lazy-dev agent loop calculates iterations as: `(user story count) + 2` to account for these review steps.

---

## PHASE 4: Create PRD File

1. **Determine Feature Location and Jira Task:**
   * Ask the user for the feature name/identifier (for branch naming and folder).
   * **Check if user mentioned a Jira task number** (e.g., MED-123, PROJ-456) in their initial request or during clarification.
   * If Jira task was mentioned, capture it for branch naming and commit messages.
   
   **Branch name format:**
   - **Without Jira:** `feature/<feature-name>` or `fix/<feature-name>` (kebab-case)
   - **With Jira:** `feature/<JIRA-ID>_<feature-name>` or `fix/<JIRA-ID>_<feature-name>`
   
   **Examples:**
   - Without Jira: `feature/task-priority`
   - With Jira MED-123: `feature/MED-123_task-priority`
   - Bug fix with Jira: `fix/MED-456_login-validation`

2. **Create Feature Directory:**
   * Create folder: `.cursor/lazy-dev/features/<feature-name>/`
   * This folder will contain:
     - `prd.json` - The PRD file
     - `progress.txt` - Will be created during implementation
     - `discovered/` - Will store feature-specific patterns (optional)

3. **Generate `prd.json`:**
   * Use the following schema:
   * **Include `jiraTaskId` field if the user provided a Jira task number**

   ```json
   {
     "project": "[Project name from context or user input]",
     "jiraTaskId": "[JIRA-123 if provided, otherwise omit this field]",
     "branchName": "feature/[JIRA-123_]feature-name-kebab-case",
     "description": "[One-line summary of what this feature accomplishes]",
     "userStories": [
       {
         "id": "US-001",
         "title": "[First story - highest priority]",
         "description": "As a [user type], I want [goal] so that [benefit].",
         "acceptanceCriteria": [
           "[Specific, verifiable criterion 1]",
           "[Specific, verifiable criterion 2]",
           "Build/typecheck passes"
         ],
         "priority": 1,
         "passes": false,
         "notes": "Follow project rules in .cursor/rules/ folder"
       },
       {
         "id": "US-002",
         "title": "[Second story - unique priority]",
         "description": "As a [user type], I want [goal] so that [benefit].",
         "acceptanceCriteria": [
           "[Specific, verifiable criterion]",
           "Build/typecheck passes"
         ],
         "priority": 2,
         "passes": false,
         "notes": "Follow project rules in .cursor/rules/ folder"
       },
      {
        "id": "US-REVIEW",
        "title": "Detailed code review of implementation",
        "description": "As a principal engineer, I need to perform a thorough code review of all changes made during this feature implementation.",
        "acceptanceCriteria": [
          "Review all new/modified files for code quality",
          "Check for performance issues (N+1 queries, memory leaks, etc.)",
          "Verify security (input validation, XSS, SQL injection)",
          "Ensure proper error handling throughout",
          "Confirm test coverage is adequate",
          "Document any technical debt introduced",
          "Build/typecheck passes"
        ],
        "priority": 998,
        "passes": false,
        "notes": "Auto-generated review step. Follow project rules in .cursor/rules/ folder."
      },
      {
        "id": "US-IMPLEMENT-RECS",
        "title": "Implement code review recommendations",
        "description": "As a developer, I need to implement the recommendations and fixes identified during code review.",
        "acceptanceCriteria": [
          "Address all issues identified in code review",
          "Re-verify all previous acceptance criteria still pass",
          "Run full test suite - all tests pass",
          "Build/typecheck passes"
        ],
        "priority": 999,
        "passes": false,
        "notes": "Auto-generated implementation step - runs after review. Follow project rules in .cursor/rules/ folder."
      }
    ]
  }
  ```
   
   **Note:** The `US-REVIEW` and `US-IMPLEMENT-RECS` stories are **required** in every PRD. Add them with priorities 998 and 999 respectively to ensure they always run last. Each story should include a note to "Follow project rules in .cursor/rules/ folder".

4. **Generate Initial `progress.txt`:**
   * Create an initial progress file with the template:

   ```markdown
   # Progress Log

   ## Codebase Patterns

   <!-- 
   Consolidated patterns discovered during implementation.
   Add REUSABLE patterns here - things that apply across the codebase.
   Keep entries concise (1-2 lines each).
   -->

   ---

   ## Session Log

   <!-- 
   Each iteration appends its progress here.
   Do not modify previous entries.
   -->
   ```

---

## PHASE 5: Dual-Perspective PRD Review Loop

Before finalizing the PRD, conduct a **rigorous review from two expert perspectives**. This is a critical quality gate that ensures the PRD is ready for autonomous implementation.

> **⚠️ DO NOT SKIP THIS PHASE.** Poorly refined PRDs lead to wasted implementation cycles, scope creep, and rework.

### The Review Loop

```
┌─────────────────────────────────────────────────────────────┐
│  1. REVIEW → Both personas review the PRD                   │
│  2. ASSESS → Each gives "Ready" or "Needs Refinement"       │
│  3. APPLY → Fix all issues found                            │
│  4. CHECK → Are BOTH personas satisfied?                    │
│  5. LOOP → If either says "Needs Refinement", go to step 1  │
│  6. PROCEED → Only when BOTH say "Ready"                    │
└─────────────────────────────────────────────────────────────┘
```

**You MUST repeat the review cycle until BOTH personas give "Ready" status.** A single pass is not sufficient if issues were found.

### Review 1: Principal Product Owner Perspective

Review the PRD as if you are a **Principal Product Owner** with 15+ years of experience. Focus on:

#### Business Value & Clarity
- [ ] **Problem Statement** - Is it crystal clear what problem this solves?
- [ ] **User Benefit** - Does each story deliver tangible user value?
- [ ] **Prioritization** - Are priorities correct? Could anything be deferred?
- [ ] **Scope Boundaries** - Are non-goals explicitly documented?
- [ ] **Success Metrics** - How will we know this feature succeeded?

#### Story Quality
- [ ] **Completeness** - Are there missing stories that should exist?
- [ ] **Granularity** - Is each story small enough for one iteration (~30 min)?
- [ ] **Independence** - Can stories be worked on without tight coupling?
- [ ] **User-Centric** - Are stories written from user perspective, not developer tasks?

#### Acceptance Criteria Quality
- [ ] **Verifiable** - Can each criterion be objectively verified as pass/fail?
- [ ] **Specific** - No vague terms like "works correctly" or "handles well"?
- [ ] **Complete** - Do criteria fully define "done" for each story?
- [ ] **Testable** - Could QA write test cases from these criteria?

**Output Format:**
```markdown
### 🎯 Product Owner Review

**Overall Assessment:** [Ready / Needs Refinement]

**Strengths:**
- [What's well-defined]

**Issues Found:**
1. [Issue 1 - with specific fix]
2. [Issue 2 - with specific fix]

**Recommended Changes:**
- [Specific change to make]
```

---

### Review 2: Principal Fullstack Developer Perspective

Review the PRD as if you are a **Principal Fullstack Developer** with 20+ years of experience. Focus on:

#### Technical Feasibility
- [ ] **Implementation Path** - Is there a clear path to implement each story?
- [ ] **Dependencies** - Are technical dependencies between stories clear?
- [ ] **Codebase Fit** - Does this align with existing architecture/patterns?
- [ ] **Edge Cases** - Are technical edge cases addressed in acceptance criteria?

#### Story Decomposition
- [ ] **Right Size** - Is each story implementable in one agent iteration?
- [ ] **Logical Order** - Will implementing in priority order make sense?
- [ ] **No Hidden Work** - Are there implied tasks not captured in stories?
- [ ] **API Contracts** - If frontend/backend, are interfaces clear?

#### Acceptance Criteria Depth
- [ ] **Sufficient Detail** - Does a developer know exactly what to build?
- [ ] **Error Handling** - Are error states and edge cases specified?
- [ ] **Data Validation** - Are input constraints documented?
- [ ] **UI Specifics** - For UI stories, are interactions clearly defined?

**Output Format:**
```markdown
### 🔧 Developer Review

**Overall Assessment:** [Ready / Needs Refinement]

**Technical Strengths:**
- [What's well-specified technically]

**Technical Gaps:**
1. [Gap 1 - with specific addition needed]
2. [Gap 2 - with specific addition needed]

**Recommended Changes:**
- [Specific technical detail to add]
```

---

### Apply Review Findings and Re-Review

After both reviews, **immediately apply all recommended changes** to the PRD:

1. Update story descriptions with missing context
2. Add missing acceptance criteria
3. Split stories that are too large
4. Add notes for technical considerations
5. Clarify any vague language

### Re-Review After Changes

**If either review showed "Needs Refinement", you MUST re-review the updated PRD:**

1. Apply all recommended changes to the PRD
2. Re-run BOTH reviews on the updated PRD
3. Check if both now show "Ready"
4. If not, apply new changes and repeat

**Output for each review round:**
```markdown
### 📋 Review Round [N]

**Product Owner:** [Ready / Needs Refinement]
**Developer:** [Ready / Needs Refinement]

[If Needs Refinement, list changes made and re-review]
```

**Only proceed to Phase 6 when BOTH reviews show "Ready" in the same round.**

---

## PHASE 6: Validation & Summary

1. **Validate PRD Structure:**
   * Verify `prd.json` is valid JSON.
   * Verify all required fields are present.
   * Verify each story has `passes: false`.
   * Verify priorities are unique (no duplicates) and sequential.
   * Verify story IDs are unique and sequential.

2. **Display Summary:**
   * Show the generated PRD in a readable format.
   * List all user stories with their titles and priorities.
   * Confirm the feature directory location.

3. **Next Steps Guidance:**
   * Inform the user that the PRD is ready for the agent loop.
   * Provide the command to start implementation:
     ```
     cd .cursor/lazy-dev && ./go.sh features/<feature-name>
     ```
   * Explain that the agent will:
     - Pick up the highest priority incomplete story
     - Break it into sub-tasks
     - Implement and verify
     - Mark as complete
     - Repeat until all stories pass

---

## Example Interaction Flow

### User Input:
> "I need to add priority levels to tasks so users can focus on what matters most"

### Round 1 - Initial Clarifying Questions:

```
I have a few questions to ensure I understand the requirements:

1. What priority levels should be supported?
   A. Simple: High / Low
   B. Standard: High / Medium / Low
   C. Extended: Critical / High / Medium / Low / None
   D. Other: [please specify]

2. What is the scope for this feature?
   A. Just store priority (database only)
   B. Store + display priority badges
   C. Store + display + filter/sort by priority
   D. Full feature with notifications for high priority

3. Should priority affect task ordering?
   A. Yes, high priority always at top
   B. Optional sort by priority
   C. No, maintain existing order
   D. Let user configure
```

### User Response:
> "1B, 2C, 3B"

### Round 2 - Follow-Up Questions:

```
Thanks! That clarifies the core scope. A few follow-up questions based on your answers:

1. For the filter/sort functionality (2C), should filter preferences persist?
   A. No, reset on page reload
   B. Yes, persist per session
   C. Yes, persist permanently per user
   D. Other: [please specify]

2. What's the default priority for new tasks?
   A. None/unset (user must choose)
   B. Medium (sensible default)
   C. Low (conservative default)
   D. Other: [please specify]

3. For the priority badges, do you have a preferred visual style?
   A. Colored dots (minimal)
   B. Colored labels with text
   C. Icons (flag, exclamation, etc.)
   D. Match existing task card styling - I'll review
```

### User Response:
> "1B, 2B, 3D - match existing styling"

### Round 3 - Final Confirmation:

```markdown
## ✅ Requirements Summary

Based on our discussion, here's my understanding:

**Feature:** Add priority levels (High/Medium/Low) to tasks with visual indicators and filtering

**Core Requirements:**
- Three priority levels: High, Medium, Low
- Default priority for new tasks: Medium
- Visual priority badges on task cards (matching existing card styling)
- Filter tasks by priority level
- Optional sort by priority (not forced)
- Filter preferences persist per session

**Scope Boundaries (Out of Scope):**
- No priority-based notifications
- No automatic priority assignment
- No permanent filter persistence (session only)

**Technical Approach:**
- Follow existing task card component patterns for badges
- Store priority in existing tasks table

**Confidence Level:** High - All requirements are clear.

---

Does this accurately capture what you want? If yes, I'll proceed with generating the PRD.
```

### User Response:
> "Yes, looks good!"

### Generated PRD (`prd.json`):

```json
{
  "project": "TaskApp",
  "branchName": "feature/task-priority",
  "description": "Add priority levels (high/medium/low) to tasks with visual indicators and filtering capabilities",
  "userStories": [
    {
      "id": "US-001",
      "title": "Add priority field to database",
      "description": "As a developer, I need to store task priority so it persists across sessions.",
      "acceptanceCriteria": [
        "Add priority column to tasks table: 'high' | 'medium' | 'low' (default 'medium')",
        "Generate and run migration successfully",
        "Build/typecheck passes"
      ],
      "priority": 1,
      "passes": false,
      "notes": "Follow project rules in .cursor/rules/ folder"
    },
    {
      "id": "US-002",
      "title": "Display priority indicator on task cards",
      "description": "As a user, I want to see task priority at a glance so I know what needs attention first.",
      "acceptanceCriteria": [
        "Each task card shows colored priority badge (red=high, yellow=medium, gray=low)",
        "Priority visible without hovering or clicking",
        "Build/typecheck passes",
        "Verify in browser"
      ],
      "priority": 2,
      "passes": false,
      "notes": "UI story - requires browser verification"
    },
    {
      "id": "US-003",
      "title": "Add priority selector to task edit",
      "description": "As a user, I want to change a task's priority when editing it.",
      "acceptanceCriteria": [
        "Priority dropdown in task edit modal",
        "Shows current priority as selected",
        "Saves on selection change",
        "Build/typecheck passes",
        "Verify in browser"
      ],
      "priority": 3,
      "passes": false,
      "notes": "Follow project rules in .cursor/rules/ folder"
    },
    {
      "id": "US-004",
      "title": "Filter and sort tasks by priority",
      "description": "As a user, I want to filter the task list to see only high-priority items when I'm focused.",
      "acceptanceCriteria": [
        "Filter dropdown with options: All | High | Medium | Low",
        "Sort option to order by priority",
        "Empty state message when no tasks match filter",
        "Build/typecheck passes",
        "Verify in browser"
      ],
      "priority": 4,
      "passes": false,
      "notes": "Non-goals: No priority-based notifications, no automatic priority assignment. Follow project rules in .cursor/rules/ folder"
    }
  ]
}
```

---

## Error Handling

- If the user provides insufficient information, **ask for clarification** rather than making assumptions about core functionality.
- If the feature is too large (would require >7 stories), **suggest breaking it into multiple PRDs**.
- If there are conflicting requirements, **highlight the conflict** and ask for resolution.

---

## Checklist Before Saving

Before finalizing the PRD, verify:

**Clarification Phase:**
- [ ] Completed iterative clarification loop (asked follow-up questions until 100% clear)
- [ ] Presented Requirements Summary and received user confirmation
- [ ] Incorporated ALL clarification answers into the PRD

**Dual-Perspective Review:**
- [ ] Completed Product Owner review (business value, story quality, acceptance criteria)
- [ ] Completed Developer review (technical feasibility, decomposition, implementation detail)
- [ ] Applied ALL recommended changes from both reviews
- [ ] Both reviews show "Ready" status

**Story Quality:**
- [ ] User stories are small and specific (completable in one iteration)
- [ ] Acceptance criteria are verifiable, not vague
- [ ] UI stories include "Verify in browser" criterion
- [ ] Priorities are unique and sequential (no duplicates: 1, 2, 3...)
- [ ] Story IDs are unique and sequential (US-001, US-002...)
- [ ] Non-goals/out-of-scope items documented in notes
- [ ] **US-REVIEW included with priority 998** (code review step)
- [ ] **US-IMPLEMENT-RECS included with priority 999** (implement recommendations)
- [ ] **Each story includes note:** "Follow project rules in .cursor/rules/ folder"
- [ ] **If Jira task was mentioned:** `jiraTaskId` field is set and branch name includes it
- [ ] `prd.json` is valid JSON
- [ ] `progress.txt` template created

---

**Proceed with the PRD generation process. Start by asking the user for their feature requirements if not already provided.**
