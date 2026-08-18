---
name: docs-audit
description: Audit documentation for style compliance, navigation, and accuracy
---

# Audit Docs

Audit all documentation in `docs/` against the shared style guide — checking style compliance, navigation integrity, and content accuracy — then apply safe fixes and report findings.

This command checks documentation **quality and discoverability** — not content correctness or feature completeness.

**Arguments**: optional `[all|style|navigation|accuracy]`, naming which phase
to run. Default is `all`. (The token `$ARGUMENTS` later in the body is Claude Code's
substitution for the invocation's arguments — read it as whatever your harness passed.)

Execute the following phases in order.

## Repo conventions (resolve first)

- **Tasks root**: `docs/work/tasks/` — written as `<tasks>/` below. Task documents are exempt from several checks, so a wrong answer here silently audits them under the wrong rules — resolve it once, before Phase 1. If none exists the repo simply has no task documents; audit everything and let the exemptions below never fire. Do not stop — unlike the `task-*` skills, this one has work to do either way.
- **Style guide**: `<this skill's physical directory>/../../../docs/documentation-style-quickstart.md` if it exists — resolve the symlink first, so the path lands in the tree the skill actually lives in, not the consumer's own `docs/` ([`skill-path-resolution.md`](../../../docs/skill-path-resolution.md)) — else `docs/style-guides/documentation-style-quickstart.md`, else `docs/documentation-style-quickstart.md` (auditing the devtools repo itself, where there is no nested `devtools/`). First hit wins.

---

## Phase 1 — Gather Context

1. Read the documentation style quickstart from the path resolved above. This is the reference standard for all checks.

2. Enumerate all `.md` files under `docs/` recursively (with a file-glob lookup). This includes `docs/README.md` and every directory `README.md` — index files are audited like any other document. **Exclude `_TEMPLATE.md`** files — they are templates, not auditable documents.

3. Parse the scope argument from `$ARGUMENTS` (defaults to `all` if empty or not provided). Valid scopes:
   - `all` — Run style, navigation, and accuracy checks
   - `style` — Only style compliance checks
   - `navigation` — Only navigation and link checks
   - `accuracy` — Only content accuracy checks

4. Print a summary: "Found N documents to audit. Scope: [scope]."

---

## Phase 2 — Analyze Documents

Launch **up to 3 parallel analysis agents**, each analyzing a batch of documents. Divide documents roughly evenly across agents. If there are 3 or fewer documents, use a single analysis agent.

Each analysis agent receives:
- The full text of the documentation style quickstart (from Phase 1)
- The list of documents to analyze (file paths)
- The scope filter (which check categories to run)
- The analysis protocol below

### Per-document analysis protocol

For each document, the subagent must read the file and perform the applicable checks:

### Style checks (scope: `all` or `style`)

1. **Scope statement** — Check that 1-3 sentences appear immediately after the H1 title, answering what the document covers and who should read it. A scope statement should NOT be a history note ("This was created in...") or a table of contents.

2. **Single H1** — Verify exactly one `#` heading exists in the file, at the top.

3. **No skipped heading levels** — Verify heading levels are not skipped (e.g., `#` followed by `###` without an intervening `##`). Walk the heading sequence and flag any gaps.

4. **Sentence case headings** — Check that headings use sentence case ("Getting started with the API") not Title Case ("Getting Started With The API"). Proper nouns, acronyms, and code references in backticks are exempt.

5. **Code block language identifiers** — Check that every fenced code block (` ``` `) has a language identifier. Flag bare ` ``` ` fences.

6. **See Also section** — For documents longer than 50 lines, check that a `## See also` section exists near the end of the file. Short documents and task documents are exempt.

7. **No date fields** — Check that the document does not contain `Last Updated`, `Updated`, or `Date` metadata fields. **There is no exception, task documents included**: the `Created` field was removed from the task format fleet-wide in the 2026-07-26 convergence, and creation dates are derived from git (`git log --diff-filter=A --follow`) rather than stored. Flag a `**Created**:` field on a task document as a leftover of the old format.

8. **kebab-case filename** — Check that the filename uses `kebab-case.md`. Flag any `SCREAMING_SNAKE_CASE.md` filenames. `README.md` and `_TEMPLATE.md` are exempt.

### Navigation checks (scope: `all` or `navigation`)

1. **Relative links resolve** — Extract all relative markdown links (`[text](path)`) from the document and verify each target file exists by globbing from the document's directory. Ignore external URLs (`http://`, `https://`) and anchor-only links (`#section`). Run this over every enumerated document — `docs/README.md` and directory `README.md`s included — so a broken index link surfaces here like any other broken link.

2. **See Also links resolve** — If a `## See also` section exists, verify each link in it resolves to an existing file.

### Accuracy checks (scope: `all` or `accuracy`)

1. **File path references** — Find file paths in backticks (patterns like `path/to/file.ext` or `directory/name/`) and verify they exist on disk with a file lookup. Only check paths that look like project-relative file or directory references (contain `/` and end with a file extension or `/`). This is best-effort — skip ambiguous references.

2. **Code block path references** — Within code blocks, look for file paths and verify they exist. This is best-effort and should not flag paths that are clearly example/template values.

Each analysis agent returns structured per-document findings with:
- File path
- Issue category (style, navigation, or accuracy)
- Issue type (e.g., `missing-scope-statement`, `broken-link`, `skipped-heading-level`)
- Severity (the issue type name is sufficient)
- Details (specific description, e.g., which link is broken and where it was expected)

---

## Phase 3 — Apply Safe Fixes

Using a text-editing tool, apply the following **safe, non-destructive** auto-fixes to documents:

### Auto-apply

- **Add language identifiers to bare code blocks** — Guess the language from the content:
  - Lines starting with `$`, `#!`, `cd`, `npm`, `git`, `docker`, `bash`, `source`, `export`, `mkdir`, `cp`, `mv`, `rm`, `ls`, `cat`, `grep`, `curl`, `wget`, `sudo` → `bash`
  - Lines containing `{`, `}`, `function`, `const`, `let`, `var`, `=>`, `import` with TypeScript-like syntax → `typescript`
  - Lines containing `def `, `class `, `import `, `from `, `print(` with Python-like syntax → `python`
  - Lines containing `"key":` or starting with `{`/`[` with JSON structure → `json`
  - Lines starting with `- ` or containing `##` with markdown-like content → `markdown`
  - Lines containing YAML-like `key: value` patterns → `yaml`
  - If uncertain, use `text` as a safe fallback
  - Change the opening fence from ` ``` ` to ` ```language `

- **Add missing See Also stub** — For documents longer than 50 lines that lack a `## See also` section, append:
  ```
  \n## See also\n
  ```
  This creates an empty stub for humans to populate. Do NOT add this to task documents (files under `<tasks>/`).

### Do NOT auto-apply

- Missing scope statements (requires understanding the document's purpose)
- Heading hierarchy fixes (may require restructuring)
- Heading case changes (proper nouns and acronyms need human judgment)
- Broken link fixes (requires knowing the intended target)
- Filename changes (requires renaming files and updating all references)
- Index additions (requires choosing the right section in README.md)

Print a summary of auto-fixes applied:
```
### Auto-fixes Applied
- [file]: added language identifier to N code blocks
- [file]: added See Also stub
```

If no auto-fixes were needed, print "No auto-fixes needed — all documents passed auto-fixable checks."

---

## Phase 4 — Present Findings Interactively

Compile all findings from Phase 2 (excluding issues already auto-fixed in Phase 3) and group them by category. Present the categories in this order:

### Finding categories

1. **Missing scope statements** — List each file that lacks a scope statement after its H1.

2. **Broken links** — List each broken link with the source file, the link text, and the expected target path. Index files (`docs/README.md`, directory `README.md`s) are covered by the same check as every other document.

3. **Heading issues** — List files with skipped heading levels or incorrect heading case, noting the specific headings.

4. **Filename convention violations** — List files using SCREAMING_SNAKE_CASE or other non-kebab-case names.

5. **Missing See Also** — List substantial documents (>50 lines) that lack a See Also section (where a stub was NOT auto-added because the document is a task or other exempt type, or the auto-fix was not applied for another reason).

6. **Date fields present** — List documents with date metadata that should be removed. Task documents are not exempt; a `Created` field there is a leftover of the pre-2026-07-26 task format.

Omit any category that has no findings.

After presenting the grouped findings, ask the user which categories to address with a multi-select prompt (each option a category name with a count — label format: `Category name (N issues)`, description a one-line summary).

For each category the user selects, present the specific issues and proposed fixes. Confirm each fix with the user before applying it with the editing tool.

If the user selects no categories (or there are no findings), skip ahead to Phase 5.

---

## Phase 5 — Summary Report

Print a structured report with these sections:

### Documents Scanned
Total count of documents audited.

### Issues by Category

| Category | Found | Auto-fixed | Manually Fixed | Remaining |
|----------|-------|------------|----------------|-----------|
| Missing scope statements | N | — | N | N |
| Broken links | N | — | N | N |
| Heading issues | N | — | N | N |
| Filename violations | N | — | N | N |
| Code block languages | N | N | — | 0 |
| Missing See Also | N | N | N | N |
| Date fields | N | — | N | N |

Omit rows with zero findings.

### Auto-fixes Applied
List each auto-fix with file path and description.

### Manual Fixes Applied
List each user-approved fix with file path and description.

### Remaining Issues
List issues that were found but not addressed (user declined or skipped).

Omit any section that has no entries.

End the report with:

> Do **NOT** auto-commit. Review the changes and commit when satisfied.
