# MindMux Brain Schema

You are reading a MindMux knowledge base. The brain has **two kinds** of files:

1. **Root pages** (`brain/*.md`) — a fixed set of structured project-wide outputs, always maintained together:
   - `background.md` · project background (positioning, goals, non-goals, target user)
   - `architecture.md` · system architecture (with mermaid graph)
   - `flow.md` · key flows (with mermaid sequenceDiagram)
   - `mindmap.md` · feature mindmap (with mermaid mindmap)
   - `stack.md` · tech-stack choices (table + open items)
   - `roadmap.md` · milestones and roadmap (with mermaid gantt)

   These 6 files have a **fixed count, update-only, never-created-new** — they are the project's "hard outputs". Write via `update_root_page`.

2. **Pages** (`brain/pages/*.md`) — incremental, unbounded in count. Each Page represents an entity (person, concept, project, decision). Each Page is compiled_truth + timeline.

3. **Workspace skills** (`brain/skills/`) — optional project-specific skill rulebooks. Default shape is `brain/skills/<skill-name>/SKILL.md` with optional bundled docs/scripts/assets beside it; legacy single-file `brain/skills/<skill-name>.md` skills are still readable. Unlike Pages/root pages, these are operational playbooks for the AI rather than project knowledge outputs.

---

## Recommended flow for a new session

1. Read `index.md` for the Page list.
2. If the task touches overall project structure, read the relevant root page.
3. If the task is about a specific decision / person / concept, pull that Page's compiled_truth.
4. At the end of the task:
   - The project's overall shape changed → `update_root_page`
   - New knowledge about a specific entity → append_timeline / update_compiled_truth / create_page
   - New Page → `index.md` is refreshed automatically

## Page format

Each Page is `pages/<id>.md`, YAML frontmatter + compiled_truth + timeline:

```markdown
---
id: <page-id>
category: project | concept | decision | person | reference
tags: [tag1, tag2]
title: <title>
created: YYYY-MM-DDTHH:mm:ss
updated: YYYY-MM-DD | YYYY-MM-DDTHH:mm | YYYY-MM-DDTHH:mm:ss
---

## compiled_truth

Current best understanding. Fully rewritable. Use [[page-id]] for cross-refs.

## timeline

- time: 2026-04-15T10:30:00
  kind: decision | observation | source | reversal
  summary: one-sentence description of what happened
  source: origin (session, file path, URL)
  affects: [page-id1]
  evidence: key evidence excerpt (optional)
```

## Root page format

```markdown
---
slug: background | architecture | flow | mindmap | stack | roadmap
kind: root-page
title: <title>
updated: YYYY-MM-DDTHH:mm:ss
---

# <title>

<body — may include ```mermaid``` code blocks>
```

## Conventions

- Timeline is append-only; overturn an older conclusion with a new `kind: reversal` entry.
- compiled_truth can be reordered, merged, or rewritten on each update.
- Root page updates are whole-body overwrites, **no timeline** (git preserves history).
- Cross-refs use `[[page-id]]` only; don't rely on a frontmatter refs field.
- Write Pages and timeline summaries in the user's working language; this schema is in English only because it's the reference document.
