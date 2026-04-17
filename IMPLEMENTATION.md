# Claude Memory Stack — Implementation Guide

Portable reference for replicating the full memory, context, and knowledge graph
stack on any project. Written so another Claude Code instance can read this and
set everything up.

---

## How to Transfer This to Another Project

The Remember pipeline lives entirely inside `.claude/remember/`. Every script,
prompt template, and Python module is **project-agnostic** — nothing in the
pipeline references a specific project name, directory, or repo. The scripts
resolve paths at runtime using environment variables that Claude Code sets
automatically (`CLAUDE_PROJECT_DIR`, `CLAUDE_PLUGIN_ROOT`).

This means transferring is a straight copy:

```bash
# From the reference project (e.g., Melon-app):
cp -r /path/to/Melon-app/.claude/remember/ /path/to/new-project/.claude/remember/
```

Then customize exactly **two files**:

1. **`.claude/remember/identity.md`** — Rewrite this for the new project.
   This defines who the AI is, what it values, and how it works. The current
   one says "engineering partner on Melon Market Theory" — change it to
   describe the new project's domain, responsibilities, and working protocol.
   (See Section 1.6 for a blank template.)

2. **`.claude/remember/config.json`** — Update the `timezone` field if needed.
   Everything else (cooldowns, thresholds, features) works as-is for most
   projects. Only tune if you find saves too frequent or too sparse.

Finally, **wire the hooks** by adding the hook block to the new project's
`.claude/settings.local.json` (copy-paste ready in Section 1.3). If this file
doesn't exist yet, create it. If it already has content, merge the `"hooks"`
key into the existing JSON.

The `.remember/` data directory (where `now.md`, `today-*.md`, `recent.md`,
`archive.md` live) is auto-created on first session start. It gitignores itself
(`*` in `.remember/.gitignore`), so memory data never enters version control.

**Requirements:** Python 3.x on PATH, `claude` CLI on PATH (for Haiku calls),
`ANTHROPIC_API_KEY` in environment. Optional: `jq` (falls back to a Python-based
JSON reader if missing — fully handled by `detect-tools.sh`).

---

## 1. Remember Pipeline (`.claude/remember/`)

Automated session memory system. After every ~50 tool calls, it extracts the
session transcript, sends it to Haiku for summarization, and appends the result
to a rolling memory buffer. Memory compresses over time: live buffer -> daily
staging -> weekly recent -> monthly archive.

### 1.1 Directory Structure

```
.claude/remember/
  identity.md              # WHO the AI is for this project
  config.json              # Timers, thresholds, feature flags
  hooks/hooks.json         # Hook definitions (reference copy)
  hooks.d/                 # Extensible lifecycle event dirs (put .gitkeep in each)
    before_session_start/  after_session_start/
    before_save/           after_save/
    before_consolidate/    after_consolidate/
    before_post_tool/      after_post_tool/
  scripts/
    session-start-hook.sh  # SessionStart: inject memory into context
    post-tool-hook.sh      # PostToolUse: trigger save when delta > threshold
    user-prompt-hook.sh    # UserPromptSubmit: inject timestamp + context %
    save-session.sh        # Main pipeline: JSONL -> Haiku -> now.md
    run-consolidation.sh   # Compress staging -> recent + archive
    detect-tools.sh        # Cross-platform python/jq detection
    resolve-paths.sh       # Plugin + project path resolution
    log.sh                 # Shared logging, config, dispatch, log rotation
  pipeline/                # Python modules for extraction + prompt building
    __init__.py
    __main__.py            # Entry point (usage info)
    extract.py             # JSONL transcript parser
    haiku.py               # Haiku API wrapper
    prompts.py             # Prompt template builder
    consolidate.py         # Staging file merger
    shell.py               # CLI interface called by bash scripts
    types.py               # Shared type definitions
  prompts/
    save-session.prompt.txt        # Session -> 1-3 sentence summary
    compress-ndc.prompt.txt        # Now-Day Compression prompt
    consolidate-staging.prompt.txt # Multi-day -> recent/archive prompt
    session-history-hint.txt       # Hint injected at session start
```

### 1.2 Data Flow

```
Claude Code Session (JSONL transcript at ~/.claude/projects/<slug>/<id>.jsonl)
  |
  v
post-tool-hook.sh (fires after every tool call)
  - Counts new JSONL lines since last save
  - If delta > 50 lines, launches save-session.sh in background
  |
  v
save-session.sh
  1. extract.py: parse human/assistant exchanges from JSONL
  2. Get last memory entry (for dedup / SKIP detection)
  3. Build prompt from save-session.prompt.txt template
  4. Call Haiku (sandboxed: cwd=/tmp, no tools, max-turns 1)
  5. Parse response — detect SKIP (no new info) vs content
  6. Append to .remember/now.md + save JSONL line position
  7. NDC compression (hourly): now.md -> today-YYYY-MM-DD.md via Haiku
  |
  v
session-start-hook.sh (fires on every new session)
  1. Inject identity.md + all memory files into context via stdout
  2. Recover last missed session (if save didn't fire before session ended)
  3. Trigger consolidation of past-day staging files in background
  |
  v
run-consolidation.sh
  - Find today-*.md files older than today
  - Build consolidation prompt with current recent.md + archive.md
  - Call Haiku to merge into updated recent.md (7-day) + archive.md (older)
  - Rename processed staging files to .done.md
```

### 1.3 Hook Configuration (`.claude/settings.local.json`)

Add this to your project's `.claude/settings.local.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/remember/scripts/session-start-hook.sh 2>> .remember/logs/hook-errors.log"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/remember/scripts/user-prompt-hook.sh 2>> .remember/logs/hook-errors.log"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/remember/scripts/post-tool-hook.sh 2>> .remember/logs/hook-errors.log"
          }
        ]
      }
    ]
  }
}
```

### 1.4 Memory File Hierarchy (`.remember/`)

Created automatically. Gitignored by default (`.remember/.gitignore` = `*`).

| File | Scope | Lifecycle |
|------|-------|-----------|
| `now.md` | Current session buffer | Appended every ~50 tool calls, cleared hourly by NDC |
| `today-YYYY-MM-DD.md` | Daily staging | Created by NDC, consumed by consolidation |
| `recent.md` | Last ~7 days | Updated by consolidation, entries rotated to archive |
| `archive.md` | All older history | Compressed weekly summaries |
| `core-memories.md` | Permanent | Key moments, manually curated by user |
| `remember.md` | One-shot handoff | Read once on session start, then cleared |

### 1.5 Config Reference (`config.json`)

```json
{
  "data_dir": ".remember",
  "cooldowns": {
    "save_seconds": 120,
    "ndc_seconds": 3600
  },
  "thresholds": {
    "min_human_messages": 3,
    "delta_lines_trigger": 50
  },
  "features": {
    "ndc_compression": true,
    "recovery": true
  },
  "timezone": "America/New_York"
}
```

- `save_seconds`: minimum seconds between save attempts (prevents spam)
- `ndc_seconds`: minimum seconds between NDC compressions (hourly default)
- `min_human_messages`: skip save if user sent fewer than N messages
- `delta_lines_trigger`: JSONL lines needed before triggering save
- `recovery`: auto-recover last session if save was missed
- `ndc_compression`: enable now.md -> today-*.md compression

### 1.6 Identity File (`identity.md`)

**Customize this per project.** Template:

```markdown
# Identity

## Who I Am
I'm the engineering partner on [PROJECT NAME] — [one-line description].
I write code, [list key responsibilities].

## Values
- [Value 1 — e.g., "Statistical rigor over narrative"]
- [Value 2 — e.g., "Minimal changes — don't over-engineer"]
- [Value 3]

## How I Work
- Direct and concise. Lead with the answer, not the reasoning.
- Read the code before suggesting changes.
- [Project-specific protocol]

## Project Context
- [Key reference files]
- CLAUDE.md + MEMORY.md are my orientation files — read on every session start
- Git repo at [repo URL]
```

### 1.7 Prompt Templates

**save-session.prompt.txt** — Summarization prompt:
- Prioritizes: decisions, findings, state changes, bugs fixed
- Drops: routine debugging, file reads, conversation flow
- Format: `## HH:MM | branch` header + 1-3 compressed sentences
- Returns `SKIP` if no new meaningful progress since last entry

**compress-ndc.prompt.txt** — Now-Day Compression:
- Maximum non-destructive compression
- Groups entries by subject, merges related work
- Developer shorthand: `conf`, `env`, `impl`, `pctile`, `MR`
- Preserves all facts, refs, verbs, relationships

**consolidate-staging.prompt.txt** — Multi-day consolidation:
- Step 1: Compress each staging day into one `## YYYY-MM-DD` entry (2-4 sentences)
- Step 2: Rotate entries older than 3 days into weekly archive blocks
- Step 3: Flag identity-defining moments as candidates
- Token limits: recent < 600 tokens, archive < 400 tokens

### 1.8 Windows Compatibility Notes

If deploying on Windows (Git Bash):
- `detect-tools.sh` validates `python3`/`python` against MS Store stub
- `detect-tools.sh` probes winget jq install path, falls back to Python `_jq_fallback`
- `safe_eval()` strips `\r` from Python output (CRLF issue)
- `session_dir_slug()` handles `/c/Users/...` vs `C:\Users\...` path mismatch

---

## 2. Claude Code Built-in Memory (`~/.claude/projects/.../memory/`)

This is Claude Code's **native** memory system — separate from the Remember
pipeline. Both run simultaneously and serve different purposes.

| System | Purpose | Persistence |
|--------|---------|-------------|
| **Remember** | Session-level diary (what happened, when) | `.remember/` in project |
| **Claude Memory** | Durable knowledge (who the user is, how to work) | `~/.claude/projects/` |

### 2.1 How It Works

- `MEMORY.md` is the index — loaded into every conversation automatically
- Individual memory files are `.md` with frontmatter (`name`, `description`, `type`)
- MEMORY.md links to memory files with brief descriptions
- Keep MEMORY.md under 200 lines (truncated beyond that)

### 2.2 Memory Types

| Type | What to Store | When to Save |
|------|--------------|--------------|
| **user** | Role, preferences, knowledge level | When you learn about the user |
| **feedback** | Corrections to your behavior | When user says "don't do X" |
| **project** | Ongoing work, goals, deadlines | When learning who/what/why/when |
| **reference** | Pointers to external systems | When told about tools, dashboards, URLs |

### 2.3 Memory File Template

```markdown
---
name: Memory Name
description: One-line description used for relevance matching
type: user | feedback | project | reference
---

Content here.
```

### 2.4 What NOT to Store in Memory

- Code patterns, architecture (derivable from reading code)
- Git history (use `git log`)
- Debugging solutions (fix is in the code)
- Anything in CLAUDE.md already
- Ephemeral task details (use tasks instead)

---

## 3. Obsidian Knowledge Graph (Optional)

Turn your project into a navigable knowledge base using Obsidian as a viewer
on top of the same git repo.

### 3.1 Recommended Plugins

| Plugin | Purpose | Install From |
|--------|---------|-------------|
| **Dataview** | Query frontmatter with SQL-like syntax | Community plugins |
| **NotEMD** | LLM-powered wiki-link generation + concept extraction | Community plugins |
| **3D Graph** | Three.js 3D force-directed graph view | Community plugins |
| **Obsidian Git** | Auto-commit/push from within Obsidian | Community plugins |
| **Templater** | Template system for consistent note creation | Community plugins |

### 3.2 `.obsidianignore`

Create this file at vault root to exclude non-markdown noise from the graph.
Adapt the extensions and directories to your project:

```
# Code
*.py
*.pyc
*.js
*.ts
__pycache__/

# Data
*.csv
*.parquet
*.pkl
*.h5
*.tsv

# Generated
*.html
*.log
*.txt

# Config
*.json
*.env
.cache/
.git/
.claude/
.remember/
```

### 3.3 Graph View Settings (`.obsidian/graph.json`)

Recommended physics for large vaults (500+ nodes):

```json
{
  "repelStrength": 10,
  "linkDistance": 80,
  "centerStrength": 0.52,
  "showTags": false,
  "showAttachments": false,
  "hideUnresolved": true,
  "showOrphans": false,
  "showArrow": true
}
```

Note: Obsidian overwrites this file when you change settings in the UI.

Color groups use `"query": "path:dirname/"` with `"color": {"a": 1, "rgb": NUMBER}`.

### 3.4 MOC (Map of Content) Pattern

Create navigation hubs in a `knowledge/` directory:

- **MOC - Home.md** — top-level entry point with Dataview queries
- **MOC - [Domain].md** — one per major subsystem

Dataview query examples:

```
TABLE type, lift, tags FROM "concepts" WHERE lift SORT lift DESC
```

```
TABLE type, consumers FROM "concepts" WHERE consumers SORT consumers DESC
```

### 3.6 Concept Note Frontmatter Schema

```yaml
---
type: model | signal | input | metric | module | redirect
status: live | rejected | deprecated
tags:
  - domain-tag
lift: 2.8        # likelihood ratio (signals only)
consumers: 6     # downstream module count
---
```

### 3.7 NotEMD Configuration

- Model: Anthropic Haiku (cheapest, fast enough for linking)
- Temperature: 0.3 (low creativity, high precision)
- Duplicate detection: enabled
- Output directory: `concepts/`
- Batch process module docs to auto-generate wiki-links and concept notes

---

## 4. System Interaction Diagram

```
Claude Code Session
  |
  |-- [SessionStart hook] --> inject identity + memory files from .remember/
  |-- [UserPromptSubmit hook] --> inject timestamp + context %
  |-- [PostToolUse hook] --> count JSONL delta, fire save-session.sh
  |
  |-- Read CLAUDE.md (project instructions, checked into repo)
  |-- Read MEMORY.md (cross-session knowledge, in ~/.claude/projects/)
  |
  |-- Write code / docs / concepts
  |-- Push to git (when asked)
  |
  v
Obsidian (optional, views same directory)
  |-- NotEMD batch-processes docs -> wiki-links + concept notes
  |-- Dataview renders queries in MOC files
  |-- Graph view + 3D Graph visualize connections
  |-- .obsidianignore filters noise from graph
```

---

## 5. Bootstrapping Checklist

For a new project:

- [ ] Copy `.claude/remember/` directory from reference project
- [ ] Edit `identity.md` with new project persona
- [ ] Edit `config.json` timezone
- [ ] Add hooks to `.claude/settings.local.json` (Section 1.3)
- [ ] Create `.remember/` dir (or let first session auto-create it)
- [ ] Verify: `python3 --version` or `python --version` works
- [ ] Verify: `claude` CLI is on PATH (for Haiku calls)
- [ ] Verify: `ANTHROPIC_API_KEY` is set in environment
- [ ] Write project `CLAUDE.md` with architecture, conventions, key files
- [ ] (Optional) Open project dir as Obsidian vault
- [ ] (Optional) Install Obsidian plugins: Dataview, NotEMD, 3D Graph
- [ ] (Optional) Create `.obsidianignore` for your file types
- [ ] (Optional) Create MOC files for navigation

---

## 6. Advanced Setup — Second Brain Practices

Beyond basic setup, these practices turn the stack into a true second brain.

### 6.1 Structured Knowledge Hierarchy

Create a `knowledge/` directory with subdirectories:

```
knowledge/
  index.md              # Entry point
  models/               # Model inventory with status, metrics
  patterns/             # Cross-model insights
  dependencies/         # Data flow, failure clusters
  audits/               # Formal audit docs (lookahead, data integrity)
  investigations/       # Research docs with phase results
  architecture/         # System design docs (like this file)
```

### 6.2 Maps of Content (MOCs)

Create 5 navigation hubs in `knowledge/`:

| MOC | Purpose |
|-----|---------|
| MOC - Home | Top-level entry, Dataview queries, links to all MOCs |
| MOC - Signal Chain | Data flow from input → output |
| MOC - Rejected Ideas | Dead ends with reasons (prevents re-work) |
| MOC - [Domain 1] | Domain-specific navigation |
| MOC - [Domain 2] | Domain-specific navigation |

**MOC - Rejected Ideas is critical.** Without it, you'll re-investigate killed ideas.

### 6.3 Dataview Queries in MOC - Home

Add live queries to MOC - Home:

```markdown
### Recently Modified
\`\`\`dataview
TABLE file.mtime AS "Modified"
FROM "research_log"
SORT file.mtime DESC
LIMIT 10
\`\`\`

### Concept Coverage
\`\`\`dataview
TABLE length(file.inlinks) AS "Backlinks"
FROM "concepts"
SORT length(file.inlinks) DESC
LIMIT 15
\`\`\`
```

### 6.4 NotEMD Configuration

Settings for optimal wiki-link generation:

| Setting | Value | Why |
|---------|-------|-----|
| Model | claude-3-haiku | Fast, cheap |
| Temperature | 0.3 | Low creativity, high precision |
| Duplicate detection | ON | Prevents redundant concepts |
| Output directory | `concepts/` | Atomic knowledge units |
| Linked form | Backlinks | Shows "Linked From" in concept notes |

**Batch processing order:**
1. `research_log/` — dated findings (most valuable)
2. `knowledge/` — decisions, audits
3. Domain-specific folders

### 6.5 Graph Color Groups

Configure in Obsidian Settings → Graph → Groups:

| Query | Color | RGB | Domain |
|-------|-------|-----|--------|
| `path:concepts/` | White | 16777215 | Atomic concepts |
| `path:knowledge/` | Cyan | 64511 | Research docs |
| `path:research_log/` | Yellow | 16776960 | Dated findings |
| `path:ml/` | Green | 65356 | ML/code docs |
| `path:pinescript/` | Pink | 16711914 | Indicators |

### 6.6 Graph Physics

Recommended settings for 500+ node vaults:

| Setting | Value | Why |
|---------|-------|-----|
| repelStrength | 10 | Prevents clumping |
| linkDistance | 80 | Readable spacing |
| centerStrength | 0.52 | Moderate pull to center |
| nodeSizeMultiplier | 0.51 | Smaller nodes for density |
| lineSizeMultiplier | 0.41 | Thinner lines, less noise |
| hideUnresolved | true | No broken link clutter |
| showOrphans | false | Unlinked notes hidden |
| showArrow | true | Directional links visible |

### 6.7 Git Integration

Initialize and push:

```bash
cd /path/to/project
git init
# Create .gitignore (exclude .remember/, *.parquet, .env, etc.)
git add -A
git commit -m "Initial commit"
git remote add origin https://github.com/USER/REPO.git
git branch -M main
git push -u origin main
```

Configure Obsidian Git plugin:
- Vault backup interval: `0` (manual) or `30` (auto)
- Push on backup: ON
- Pull on startup: ON

---

## 7. Net Effect

| Without Stack | With Stack |
|---------------|------------|
| "Did we test X?" → re-research | Check MOC - Rejected Ideas |
| "What uses Y?" → grep codebase | Follow [[Y]] backlinks |
| "What broke last time?" → memory | Check knowledge/audits/ |
| Context compaction → lost state | Knowledge exists outside context |

The remember pipeline captures session-level what-happened. The knowledge graph captures why-decisions and how-things-work. Together, they let Claude pick up mid-conversation with full context.
