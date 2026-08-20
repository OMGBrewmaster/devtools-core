# Definition of done

The public gates for Workshop apply to every hand-authored change after the
source-of-truth cutover. They run from a standalone clone and do not require
the private upstream, HQ, or any other fleet repository.

| Gate | Command | Pass condition | Applies to |
|---|---|---|---|
| Public checks | `make check` | Exit 0 after public regression tests, agent-surface conformance, Markdown links, JSON validation, and the shellcheck allow-list. | Every change |

The generated transition currently prevents direct contributions, but the
workflow already runs this contract on every push, pull request, and tag.
