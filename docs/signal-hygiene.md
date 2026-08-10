# Signal hygiene

How to know that a step actually happened. Read this before writing any check, script, or "done" claim — it applies to every project in the workspace and is loaded into every session.

## The rule

- **A command's own exit code and output are the verification. Read them; never suppress them.** Scripts run under `set -euo pipefail`. Do not silence a fallible command with `-q`, and do not pipe one through `tail`/`head` — that discards the very output explaining the failure. `2>/dev/null` is fine only when the failure is *handled* (a deliberate fallback), never to hide it.

  **Backgrounding moves where that verdict has to land.** In the foreground the `echo` prints where you are already looking, so `<cmd> > out.txt 2>&1; echo "EXIT=$?"` is enough — the form [`definition-of-done.md`](definition-of-done.md) gives for running a gate. Backgrounded it is not enough: the harness reports the *whole pipeline's* status and swallows that trailing `echo`, so a red run announces `exit code 0`. Write the verdict *into* the artifact you are going to read — `{ cmd; echo "EXIT=$?"; } > out.txt 2>&1` — then read the file. The braces are load-bearing: without them the redirect binds to `cmd` alone and the verdict goes somewhere nobody looks (observed 2026-07-22).
- **If you never executed it, it is a draft, not a deliverable.** Say so. Authoring a script, config, or status line in an environment that cannot run it means the first real run is part of authoring, not validation afterwards.
- **A check that reports "nothing found" has to be looking where you think it is.** The Bash tool's working directory persists between calls, so a bare `cd` in one command silently rebases every relative path in the ones after it. Use absolute paths, or confine the change to a subshell — `(cd dir && ...)`. An empty directory and a wrong directory print the same nothing.
- **Before trusting a check you wrote, ask what it prints if the step did nothing at all.** If that matches success, the check is decorative — delete it and read the real signal instead.

That last question is the whole pattern. A check whose pass state is reachable by the very failure it exists to detect does not merely fail to catch the bug: it *reports success*, which ends the investigation. Prefer asserting a positive property of the artifact you meant to produce over an equality that a no-op also satisfies.

Reaching for a secondary check is usually the tell that you discarded the primary one. Git is loud and reliable: `git push` exits non-zero and prints the error on failure, and prints the ref update on success. Reading that line *is* the verification — no gate required.

## The one Git fact worth memorizing

`origin/main` is **a cached snapshot from your last fetch, not the remote.** Any decision sized off it without fetching first — how many commits are unpushed, how far behind you are, whether a rebase is needed — is sized off possibly-stale data. Fetch first, or report the number as unknown; never quietly report a stale count as fact.

And "my `HEAD` equals `origin/main`" is **not** the same claim as "my commit is on the remote." Equality is true when your commit landed *and* true when your commit was destroyed — a dropped rebase commit makes `HEAD` match `origin/main` precisely because the work vanished. That is a real incident, not a hypothetical (2026-07-14).

So: never verify a push by comparing SHAs. Read the push's exit code and output. Where you genuinely need to ask whether a remote contains a commit — for instance, before recording a submodule pointer that must not dangle for anyone who clones — the question is **containment, after a fetch**:

```bash
git -C "$repo" fetch origin
git -C "$repo" merge-base --is-ancestor "$sha" origin/main   # exit 0 = the remote contains it
```

## See also

- [`kaizen-guide.md`](kaizen-guide.md) — the continuous-improvement practice these rules graduated out of. A ninth incident of this pattern *despite* preserved exit codes and unsuppressed output is the trigger to escalate from convention to mechanical enforcement.
- The sibling failure mode is authoring a *claim* rather than designing a *check*: when a claim changes what someone spends or configures, demand a source — "it makes the pieces fit" is not one.
