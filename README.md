# claude-statusline

A clean, two-line [status line](https://docs.claude.com/en/docs/claude-code/statusline) for Claude Code.

```
Opus 5 (1M) high │ studia-portal │ my-session
ctx ██▒▒▒▒▒▒▒▒▒▒ 6% 69k/1M │ 5h 25% 14:27 │ 7d 12% Jul 4 12:00 │ extra: £0.00
```

…and in a linked git worktree, where the parent repo dims and the worktree takes the bright half:

```
Opus 5 (1M) high │ studia-portal/hotfix │ my-session
ctx ██▒▒▒▒▒▒▒▒▒▒ 6% 69k/1M │ 5h 25% 14:27 │ 7d 12% Jul 4 12:00 │ extra: £0.00
```

Two lines, grouped by the question you're actually asking at a glance:

- **Line 1 — identity:** model + reasoning effort · location, as `repo` or `repo/worktree` (+ PR status) · session name
- **Line 2 — gauges:** context-window usage · 5-hour rate limit · 7-day rate limit (each with reset time) · extra-usage credits (used/limit)

Percentages stay muted until they matter, then turn **amber at ≥60%** and **coral at ≥85%** — so an idle bar is calm and a stressed one grabs your eye. All times are 24-hour.

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

Both live in `~/.claude`, so this installs **globally** — it applies to every project, not just the one you ran it from. A `statusLine` in a project's own `.claude/settings.json` takes precedence, so check there if a repo doesn't pick it up.

Safe to re-run — it just refreshes the files. Existing settings keys are preserved.

To remove it, delete the `statusLine` key from `~/.claude/settings.json` (or restore the `.bak` the installer made) and delete `~/.claude/statusline-command.sh`.

## Design notes

- **Grouped by question, not by field.** "Where am I working?" lives on line 1; "how much budget is left?" lives on line 2.
- **Dividers (`│`) separate groups only** — items within a group are separated by spacing, keeping the bar narrow and quiet.
- **Graceful degradation.** Any segment with no data is omitted; if line 2 has nothing, the bar collapses to a single line.
- **The bright half is what you're editing.** In a linked worktree the location reads `repo/worktree`: the parent repo drops to a desaturated blue and the worktree takes the brighter one. A glance answers "am I in my real checkout, or a disposable copy?" — the question that actually matters with several sessions open against one repo.
- **The worktree qualifies the location, it isn't a peer of it.** It sits inside the location group rather than earning its own `│`, which keeps line 1 at three groups even when a PR badge is showing. Outside a worktree the segment simply isn't there.

## Worktrees

Claude Code sets `workspace.git_worktree` to the worktree **name** (a single flat segment, from `.claude/worktrees/<name>`) whenever the working directory sits in a linked worktree. It's absent otherwise, so nothing changes in a normal checkout.

Names longer than 24 characters are truncated with `…`. The repo name is never truncated — it's the stable anchor you scan for first. If the repo has no origin remote, the parent falls back to the project directory's name, so the worktree still shows.

## Extra-usage credits

The `extra:` segment (pay-as-you-go credit spend, `used/limit`) is **not** in the status line's stdin, so it is fetched from Anthropic's OAuth usage endpoint using your existing Claude Code credentials (env var → macOS Keychain → `~/.claude/.credentials.json` → GNOME Keyring, in that order). The result is cached for ~2 minutes and refreshed in the background, so it never blocks a render. If no token is found or the endpoint is unavailable, the segment is silently omitted. The currency symbol follows your account (`£`/`$`/`€`/`¥`); the `/limit` half appears only once a monthly limit is set.

## Requirements

- Claude Code (a build that feeds `context_window` and `rate_limits` into the status line for those segments to appear).
- `node`, `bash`, and `curl` on `PATH`.
- macOS or Linux. Reset-time formatting handles both BSD (`date -r`) and GNU (`date -d`) `date`.

## Fields consumed

From the status line's stdin JSON:

| Field | Used for |
| --- | --- |
| `model.display_name`, `effort.level` | model + effort |
| `workspace.repo.name` | location (preferred) |
| `workspace.git_worktree` | worktree name, when in a linked worktree |
| `workspace.project_dir`, `cwd` | location fallbacks, in that order |
| `pr.number`, `pr.review_state` | PR badge |
| `session_name` | session |
| `context_window.*` | context bar |
| `rate_limits.five_hour.*`, `rate_limits.seven_day.*` | rate-limit gauges + reset times |

Every field is optional — any segment with no data is dropped.
