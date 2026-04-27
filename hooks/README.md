# Git hooks

Repo-shipped git hooks. Opt-in per clone — git doesn't auto-run hooks
that aren't under `.git/hooks/`. Install with symlinks so future
updates flow through:

```bash
cd ~/milvus-onprem
ln -sf ../../hooks/pre-commit  .git/hooks/pre-commit
ln -sf ../../hooks/commit-msg  .git/hooks/commit-msg
```

Or use `git config core.hooksPath hooks` to point git at this dir
directly (works on git ≥ 2.9).

## What's here

### `pre-commit` — refuses staged content with AI-assistant references

Scans the staged diff for case-insensitive matches on `claude`,
`anthropic`, `co-authored-by`, `agent`, `AI`, `assistant`, `LLM`. If
any line being **added** matches, the commit is refused with the
exact lines printed. Word-bounded so common substrings (`main`,
`tail`, `wait`, `fail`, `available`) don't trip it.

The hook files themselves are pathspec-excluded so that committing
them doesn't self-reject.

### `commit-msg` — same check, on the commit message

`pre-commit` can't see the message; `commit-msg` runs after the
message is composed and applies the same patterns. Comment lines
(starting with `#`) are skipped because git uses them for the
message template.

## Bypassing (rare)

Both hooks honour `git commit --no-verify`. Use for the rare case
where you genuinely need to write one of these words (e.g. updating
this README, citing an external paper). Don't make a habit of it.
