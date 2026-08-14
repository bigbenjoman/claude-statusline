# claude-statusline

A clean, two-line [status line](https://docs.claude.com/en/docs/claude-code/statusline) for Claude Code.

```
Opus 4.8 (1M) high │ studia-portal │ my-session
ctx ██▒▒▒▒▒▒▒▒▒▒ 6% 69k/1M │ 5h 25% 14:27 │ 7d 12% Jul 4 12:00 │ extra: £0.00
```

…and in a linked git worktree, where the parent repo dims and the worktree takes the bright half:

```
Opus 4.8 (1M) high │ studia-portal/hotfix │ my-session
ctx ██▒▒▒▒▒▒▒▒▒▒ 6% 69k/1M │ 5h 25% 14:27 │ 7d 12% Jul 4 12:00 │ extra: £0.00
```

Two lines, grouped by the question you're actually asking at a glance:

- **Line 1 — identity:** model + reasoning effort · repo name, worktree (+ PR status) · session name
- **Line 2 — gauges:** context-window usage · 5-hour rate limit · 7-day rate limit (each with reset time) · extra-usage credits (used/limit)

Percentages stay muted until they matter, then turn **amber at ≥60%** and **coral at ≥85%** — so an idle bar is calm and a stressed one grabs your eye.

## Install

Hand the script to Claude Code:

> run `install-statusline.sh` to set up my status line

Or from a terminal:

```bash
bash install-statusline.sh
```

Then restart Claude Code (or open a new session).

## What it does

1. Writes the status line to `~/.claude/statusline-command.sh`.
2. Adds a `statusLine` entry to `~/.claude/settings.json`, **merging** into whatever is already there (a timestamped `.bak` is made first).

Safe to re-run — it just refreshes the files. Existing settings keys are preserved.

## Design notes

- **Grouped by question, not by field.** "Where am I working?" lives on line 1; "how much budget is left?" lives on line 2.
- **Dividers (`│`) separate groups only** — items within a group are separated by spacing, keeping the bar narrow and quiet.
- **Graceful degradation.** Any segment with no data is omitted; if line 2 has nothing, the bar collapses to a single line.
- **The bright half is what you're editing.** In a linked worktree the location reads `repo/worktree`, with the parent repo demoted to a desaturated blue and the worktree taking the brighter one. The worktree is a qualifier of "where am I?", not a separate question, so it stays inside the location group rather than earning its own divider. Outside a worktree nothing changes — the segment simply isn't there. Worktree names longer than 24 characters are truncated with `…`; the repo name never is, since it's the stable anchor.

## Extra-usage credits

The `extra:` segment (pay-as-you-go credit spend, `used/limit`) is **not** in the status line's stdin, so it is fetched from Anthropic's OAuth usage endpoint using your existing Claude Code credentials (env var → macOS Keychain → `~/.claude/.credentials.json` → GNOME Keyring, in that order). The result is cached for ~2 minutes and refreshed in the background, so it never blocks a render. If no token is found or the endpoint is unavailable, the segment is silently omitted. The currency symbol follows your account (`£`/`$`/`€`/`¥`); the `/limit` half appears only once a monthly limit is set.

## Requirements

- Claude Code (a build that feeds `context_window` and `rate_limits` into the status line for those segments to appear).
- `node`, `bash`, and `curl` on `PATH`.
- macOS or Linux. Reset-time formatting handles both BSD (`date -r`) and GNU (`date -d`) `date`.

## Fields consumed

From the status line's stdin JSON: `model.display_name`, `effort.level`, `context_window.*`, `workspace.repo.name`, `workspace.git_worktree`, `workspace.project_dir`, `cwd`, `session_name`, `pr.*`, `rate_limits.five_hour.*`, `rate_limits.seven_day.*`.
