# claude-statusline

A clean, two-line [status line](https://docs.claude.com/en/docs/claude-code/statusline) for Claude Code.

```
Opus 5 (1M) high │ studia-portal ⎇ main │ my-session
ctx ██▒▒▒▒▒▒▒▒ 6% 69k/1M │ 5h 25% 14:27 · 7d 12% Jul 4 12:00 │ extra: £0.00 resets Sep 1
```

…and in a linked git worktree, where the parent repo dims and the worktree takes the bright half:

```
Opus 5 (1M) high │ studia-portal/hotfix ⎇ fix/dropped-state │ my-session
ctx ██▒▒▒▒▒▒▒▒ 6% 69k/1M │ 5h 25% 14:27 · 7d 12% Jul 4 12:00 │ extra: £0.00 resets Sep 1
```

Two lines, grouped by the question you're actually asking at a glance:

- **Line 1 — identity:** model + reasoning effort · location, as `repo` or `repo/worktree`, then the branch · session name
- **Line 2 — gauges:** context-window usage · 5-hour and 7-day rate limits with reset times · extra-usage credits

Percentages stay muted until they matter, then turn **amber** and **coral** — so an idle bar is calm and a stressed one grabs your eye. Rate limits ramp at **≥60% / ≥85%**; the context window ramps later (**≥75% / ≥90%**) because it self-heals through compaction, while a spent rate limit locks you out for days. All times are 24-hour.

**Separator grammar**, escalating only as far as it needs to: a sigil (`⎇`) for items carrying their own mark, `·` between items of one group, `│` between groups.

**Severity never rests on colour alone** — amber and coral differ by only 1.67:1 in luminance, which is no signal at all in a screenshot or with red-green colour blindness. The context bar changes its fill glyph (`█` → `▓`) at critical; credits turn coral when a limit is spent. The percentages carry no marker: `100%` is already unambiguous.

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

## Fitting the terminal

Claude Code truncates an over-long status line at the right edge, so whatever sits on the right — the session name on line 1, the credits on line 2 — silently disappears. The bar therefore measures itself against `$COLUMNS` (falling back to `tput cols`, then 100) and **decides what to give up**, cheapest information first, rather than letting position decide. `…` marks anything shortened.

**Line 1** sacrifices in this order: session name to 28 chars → to 20 → branch → effort → session name entirely → worktree to 12 → the model's `(1M context)` qualifier → the model name. The location is never dropped; it is what a glance is *for* when several sessions are open on one repo.

**Line 2**: raw token counts (they duplicate the percentage beside them) → the credits reset date (derived, not reported) → the 7-day reset → the 5-hour reset → the bar narrows to 5 cells → the bar goes → the whole context group goes. Credits are last, because context self-heals and money does not.

## Diagnostics

The `extra` segment is silent when it fails, which makes "no token", "endpoint down" and "credits disabled" indistinguishable. Rather than spend bar space on that:

```bash
bash ~/.claude/statusline-command.sh --debug
```

reports terminal width, worktree/branch detection for the current directory, which credential source the token came from, cache age, a live HTTP status from the usage endpoint, and the raw-vs-formatted credit values.

## Design notes

- **Grouped by question, not by field.** "Where am I working?" lives on line 1; "how much budget is left?" lives on line 2.
- **Dividers (`│`) separate groups only** — items within a group take `·`, or nothing at all when they already carry a sigil, keeping the bar narrow and quiet.
- **Graceful degradation.** Any segment with no data is omitted; if line 2 has nothing, the bar collapses to a single line.
- **The bright half is what you're editing.** In a linked worktree the location reads `repo/worktree`: the parent repo drops to a desaturated blue and the worktree takes the brighter one. A glance answers "am I in my real checkout, or a disposable copy?" — the question that actually matters with several sessions open against one repo.
- **The worktree qualifies the location, it isn't a peer of it.** It sits inside the location group rather than earning its own `│`, which keeps line 1 at three groups. Outside a worktree the segment simply isn't there. The branch follows the same rule.
- **Consequences inherit their cause's alarm.** A rate limit at 100% is the moment work starts spending real money, which is precisely what the credits segment reports. So when any limit is spent, `extra:` turns coral — otherwise the two causally linked facts sit on the same line looking unrelated, and the one denominated in money is the calmer of the pair.
- **Contrast is measured, not eyeballed.** Text tokens clear WCAG AA (4.5:1) against a dark charcoal terminal; bar cells and dividers are non-text UI components and owe 3:1, which is why the divider stays as it is and only the empty bar cells (2.27:1, failing even that) were lightened.

## Worktrees

The status line's stdin carries **no worktree field**, so this is derived by asking git about the working directory:

```bash
git rev-parse --path-format=absolute --git-dir --git-common-dir --show-toplevel
```

A linked worktree is exactly the case where `--git-dir` differs from `--git-common-dir`. `--path-format=absolute` is not optional here: without it a plain subdirectory of the *main* checkout reports `/repo/.git` against `../.git` and false-positives as a worktree. The worktree label is the basename of `--show-toplevel`; the parent repo is the directory holding the common `.git`, so worktrees anywhere on disk resolve — `../repo-hotfix`, `.claude/worktrees/<name>`, `/tmp/…` alike.

Because worktree directories are conventionally named `<repo>-<branchish>`, a repeated repo prefix is dropped: `belmont-state-readers` in the `belmont` repo renders as `belmont/state-readers`. Names longer than 24 characters are truncated with `…`. The repo name is never truncated — it's the stable anchor you scan for first. If the repo has no origin remote, the parent falls back to the main checkout's directory name, so the worktree still shows.

## Extra-usage credits

The `extra:` segment (pay-as-you-go credit spend, `used/limit`) is **not** in the status line's stdin, so it is fetched from Anthropic's OAuth usage endpoint using your existing Claude Code credentials (env var → macOS Keychain → `~/.claude/.credentials.json` → GNOME Keyring, in that order). The result is cached for ~2 minutes and refreshed in the background, so it never blocks a render. If no token is found or the endpoint is unavailable, the segment is silently omitted. The currency symbol follows your account (`£`/`$`/`€`/`¥`); the `/limit` half appears only once a monthly limit is set.

The endpoint reports `used_credits` in **minor units** — `993` with `decimal_places: 2` is £9.93, not £993.00 (the same payload spells this out as `spend.used: {amount_minor, exponent}`). The amount is scaled by `10^decimal_places` before formatting.

## Not shown

**Pull request status.** Claude Code renders its own line beneath this one that already carries the PR, so a badge here would only duplicate it. The stdin fields `pr.number` and `pr.review_state` are deliberately ignored.

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
| `workspace.project_dir`, `cwd` | location fallbacks, in that order; `cwd` is also what git is asked about for worktree detection |
| `session_name` | session |
| `context_window.*` | context bar |
| `rate_limits.five_hour.*`, `rate_limits.seven_day.*` | rate-limit gauges + reset times; either at 100% also raises the credits alarm |

Plus `$COLUMNS` from the environment (falling back to `tput cols`) to fit both lines to the terminal.

Every field is optional — any segment with no data is dropped.
