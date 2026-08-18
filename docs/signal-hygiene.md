# Signal hygiene

How to know that a step actually happened. Read this before writing any check, script, or "done" claim — it applies to every project in the workspace and is loaded into every session.

## The rule

- **A command's own exit code and output are the verification. Read them; never suppress them.** Scripts run under `set -euo pipefail`. Do not silence a fallible command with `-q`. `2>/dev/null` is fine only when the failure is *handled* (a deliberate fallback), never to hide it.

  **Backgrounding moves where that verdict has to land.** Foreground, `<cmd> > out.txt 2>&1; echo "EXIT=$?"` is enough. Backgrounded it is not: the harness reports the whole pipeline's status and swallows that trailing `echo`, so a red run announces `exit code 0`. Write the verdict *into* the artifact — `{ cmd; echo "EXIT=$?"; } > out.txt 2>&1` — then read the file. The braces are load-bearing: without them the redirect binds to `cmd` alone and the verdict lands where nobody looks (2026-07-22).
- **If you never executed it, it is a draft, not a deliverable.** Say so. Authoring a script, config, or status line in an environment that cannot run it means the first real run is part of authoring, not validation afterwards.
- **A check that reports "nothing found" has to be looking where you think it is.** The Bash tool's working directory persists between calls, so a bare `cd` in one command silently rebases every relative path in the ones after it. Use absolute paths, or confine the change to a subshell — `(cd dir && ...)`. An empty directory and a wrong directory print the same nothing.
- **A recursive search may be scoped to tracked files without telling you.** Many search tools honour ignore files by default — ripgrep, ugrep, some harness-bundled `grep` shims — so a recursive search silently skips whatever `.gitignore` excludes, sibling clones and vendored trees included. A *negative* result ("no other caller", "no third instance") is evidence only once the tool is confirmed to have seen the excluded directories. Pass the paths explicitly; until then a count is a lower bound, not a total.
- **An empty path-scoped `git log`/`git diff` is evidence only if the repo tracks that path.** Git exits 0 and prints nothing for a pathspec that is untracked, gitignored, or in another repository — byte-identical to "nothing changed here". `git ls-files --error-unmatch -- <path>` settles it; its answer is "tracked *now*", so a path deleted since the base commit fails it too. Either way the verdict is *unknown*, not *clean*.
- **Before trusting a check you wrote, ask what it prints if the step did nothing at all.** If that matches success, the check is decorative — delete it and read the real signal instead.

That last question is the whole pattern. A check whose pass state is reachable by the very failure it exists to detect does not merely fail to catch the bug: it *reports success*, which ends the investigation. Prefer asserting a positive property of the artifact you meant to produce over an equality that a no-op also satisfies.

## The one Git fact worth memorizing

`origin/main` is **a cached snapshot from your last fetch, not the remote.** Any decision sized off it without fetching first — how many commits are unpushed, how far behind you are, whether a rebase is needed — is sized off possibly-stale data. Fetch first, or report the number as unknown; never quietly report a stale count as fact.

And "my `HEAD` equals `origin/main`" is **not** the same claim as "my commit is on the remote." Equality is true when your commit landed *and* true when your commit was destroyed — a dropped rebase commit makes `HEAD` match `origin/main` precisely because the work vanished. That is a real incident, not a hypothetical (2026-07-14).

So: never verify a push by comparing SHAs. Read the push's exit code and output — `git push` is loud in both directions, and reaching for a secondary check is usually the tell that you discarded the primary one. Where you genuinely need to ask whether a remote contains a commit — for instance, before recording a submodule pointer that must not dangle for anyone who clones — the question is **containment, after a fetch**:

```bash
git -C "$repo" fetch origin
git -C "$repo" merge-base --is-ancestor "$sha" origin/main   # exit 0 = the remote contains it
```

## See also

- [`kaizen-guide.md`](kaizen-guide.md) — the practice these rules graduated out of, and the graduation contract that stops a lesson losing its content in transit. The escalation trigger they once carried fired in 2026-08 and was replaced by mechanism.
- The sibling failure mode is authoring a *claim* rather than designing a *check*: when a claim changes what someone spends or configures, demand a source — "it makes the pieces fit" is not one.
