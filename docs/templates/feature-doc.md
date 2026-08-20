# Feature name

<!-- Replace with the name of the feature being documented. -->

<!-- Scope statement: 1-3 sentences explaining what this feature provides and who
     should read this. Example: "This document describes the achievement system
     that tracks and rewards player progress. Read this when adding new achievements,
     modifying unlock conditions, or debugging award logic." -->

## TL;DR

<!-- Optional but recommended. Bullet-point summary so readers can assess relevance
     in 5 seconds. -->

- **What**: <!-- One-sentence description of the feature -->
- **Where**: <!-- Root directory or key path -->
- **Key file**: <!-- Single most important file -->

## Overview

<!-- User-facing description of the feature: what it does from the player's or user's
     perspective. 1-3 paragraphs. Avoid implementation details here. -->

## How it works

<!-- Technical implementation details. Explain the architecture, algorithms, or
     workflows that power this feature. Use subsections if the feature has distinct
     parts. Include Mermaid diagrams for complex flows. -->

## Key files

<!-- Table of important files. Include paths relative to the project root. -->

| File | Purpose |
|------|---------|
| `path/to/file` | <!-- What this file does --> |
| `path/to/file` | <!-- What this file does --> |

## Design decisions

<!-- Document key decisions and their rationale. This prevents future contributors
     from re-litigating settled questions. Use ### subsections for each decision
     if there are multiple. -->

### Decision title

<!-- Example format:
     **Decision**: Use SQLite for local game data.
     **Context**: Single-player mobile game with read-only content data.
     **Alternatives considered**: PostgreSQL (overkill), PlayerPrefs (no queries).
     **Rationale**: Ships with the app, zero configuration, handles read-heavy workload. -->

## See also

<!-- Links to related documents. Use relative paths. Include a short description
     after the em dash. -->

- `../path/to/doc.md` — Related document description
