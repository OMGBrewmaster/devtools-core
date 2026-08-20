# Definition of done

The public gates for Workshop apply to every change. They run from a standalone
clone and do not require a private upstream, HQ, or any other fleet repository.

| Gate | Command | Pass condition | Applies to |
|---|---|---|---|
| Public checks | `make check` | Exit 0 after public regression tests, agent-surface conformance, Markdown links, JSON validation, and the shellcheck allow-list. | Every change |

The workflow runs this contract on every push, pull request, and tag.
