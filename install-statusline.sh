#!/usr/bin/env bash
#
# Claude Code status line installer (macOS / Linux).
#
# WHAT THIS DOES:
#   1. Writes the status line script to ~/.claude/statusline-command.sh
#   2. Adds the "statusLine" setting to ~/.claude/settings.json,
#      MERGING into any existing settings (a timestamped .bak backup is made first).
#
# THE STATUS LINE (two lines, grouped by the question you're asking):
#   line 1 — identity:  model + effort  │  repo[/worktree] ⎇ branch  │  session
#   line 2 — gauges:    context bar  │  5h · 7d limits  │  extra credits
#   Percentages stay muted until elevated, then turn amber / coral — rate limits
#   at >=60/85%, the context window later (>=75/90%) since it self-heals.
#   Segments with no data are omitted; if line 2 is empty it collapses to one line.
#   Both lines fit themselves to $COLUMNS, dropping the cheapest information
#   first, so nothing is silently truncated off the right edge.
#
# NOTE: the worktree half of the location is also absent from stdin — it is
#   derived by asking git whether cwd sits in a linked worktree.
#
# NOTE: "extra:" (pay-as-you-go credits) is NOT in the status-line stdin, so it
#   is fetched from Anthropic's OAuth usage endpoint using your Claude Code
#   credentials and cached (~2 min, refreshed in the background). If no token is
#   found or the endpoint is unavailable, that segment is simply omitted.
#
# HOW TO RUN IT:
#   Hand this file to Claude Code and say: "run this file to set up my status line".
#   (Or in a terminal:  bash install-statusline.sh )
#
# Safe to run more than once — it just refreshes the files.

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SCRIPT_PATH="$CLAUDE_DIR/statusline-command.sh"
SETTINGS_PATH="$CLAUDE_DIR/settings.json"

mkdir -p "$CLAUDE_DIR"

# ── 1. Write the status line script ───────────────────────────────────────────
cat > "$SCRIPT_PATH" <<'STATUSLINE_EOF'
#!/usr/bin/env bash
# Claude Code Status Line

# ── Diagnostics (bash statusline-command.sh --debug) ─────────────────────────
# The extra-usage segment fails silently by design, which makes "no token",
# "endpoint down" and "credits disabled" indistinguishable on the bar. Rather
# than spend bar space on that, the failure is inspectable on demand. This runs
# before stdin is read, so it works from a normal shell with no JSON piped in.
STATUSLINE_DEBUG=""
[ "${1:-}" = "--debug" ] && STATUSLINE_DEBUG=1

[ -z "$STATUSLINE_DEBUG" ] && input=$(cat)

# ── Colour palette ────────────────────────────────────────────────────────────
# Contrast is measured against a dark charcoal terminal (#1e2127). Text tokens
# clear WCAG AA (4.5:1); bar cells and dividers are non-text UI components, so
# they only owe 3:1 — which is why the divider stays at 244 (4.08) and only the
# empty cells, which failed even that at 2.27, moved.
RESET="\033[0m"
DIM="\033[2m"

C_MODEL="\033[38;5;183m"      # soft lavender   — model name              (8.8:1)
C_EFFORT="\033[38;5;139m"     # dusty mauve     — effort suffix           (5.3:1)
C_BAR_NEUT="\033[38;5;248m"   # light gray      — bar fill, low usage      (6.8:1)
C_BAR_WARN="\033[38;5;221m"   # golden yellow   — bar fill, mid usage     (11.6:1)
C_BAR_CRIT="\033[38;5;210m"   # soft coral      — bar fill, high usage     (7.0:1)
C_BAR_EMPTY="\033[38;5;243m"  # dark gray       — empty bar cells          (3.6:1)
C_VALUE="\033[97m"             # bright white    — primary values          (16:1)
C_MUTED="\033[38;5;245m"      # dim gray        — secondary / token counts (4.7:1)
C_LOCATION="\033[38;5;110m"   # muted sky blue  — repo / dir name (or worktree) (7.0:1)
C_LOC_PARENT="\033[38;5;103m" # dusty periwinkle— parent repo + branch     (4.7:1)
C_SESSION="\033[38;5;252m"    # near-white      — session name            (10.5:1)
C_WARN="\033[38;5;221m"       # golden yellow   — mid rate limit
C_CRIT="\033[38;5;210m"       # soft coral      — high rate limit, spent credits

# Separator grammar, escalating only as far as it needs to:
#   sigil (⎇ #)  items that already carry their own mark
#   ·            items inside one group
#   │            between groups
SEP=" \033[38;5;244m│\033[0m "
ITEM_SEP=" \033[38;5;245m·\033[0m "

# ── Read every field in ONE parse ────────────────────────────────────────────
# This used to be a json_get() helper called once per field, which spawned a
# node process per field — 13 interpreter starts (~20ms each) to read 13 values
# out of a single object. Claude Code debounces the status line at 300ms and
# CANCELS an in-flight script when a new update arrives, so a slow render is not
# merely slow: it is a render that never paints while you are working.
#
# The protocol is newline-delimited values in a fixed order. Absent and null
# fields come back as empty lines, so the "was it present?" checks downstream
# are unchanged. Any newline inside a value is flattened first — one stray \n
# would shift every field after it onto the wrong variable.
read_fields() {
    echo "$input" | node -e "
let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{
  let o={};try{o=JSON.parse(d)}catch(e){}
  const g=p=>{let v=o;
    for(const k of p.split('.')){if(v&&typeof v==='object')v=v[k];else return ''}
    return (v==null)?'':String(v).replace(/[\r\n]+/g,' ')};
  process.stdout.write([
    'model.display_name','effort.level',
    'context_window.used_percentage','context_window.total_input_tokens',
    'context_window.context_window_size',
    'workspace.repo.name','workspace.project_dir','cwd','session_name',
    'rate_limits.five_hour.used_percentage','rate_limits.five_hour.resets_at',
    'rate_limits.seven_day.used_percentage','rate_limits.seven_day.resets_at',
  ].map(g).join('\n'));
});
" 2>/dev/null
}

# Order here must match the list above. The herestring supplies the trailing
# newline the final field lacks, so every read succeeds.
{ read -r model_name  ; read -r effort_level
  read -r used_pct    ; read -r total_input   ; read -r ctx_size
  read -r repo_name   ; read -r project_dir   ; read -r cwd
  read -r session_name
  read -r five_pct    ; read -r five_resets
  read -r week_pct    ; read -r week_resets
} <<< "$(read_fields)"

# ── Severity thresholds ───────────────────────────────────────────────────────
# Rate limits are the scarce resource: hitting 100% locks you out for hours or
# days and starts spending real money. Context is not — it self-heals through
# compaction — so its ramp starts later, keeping the loudest thing on the bar
# the thing you can least afford to run out of.
WARN_AT=60 ; CRIT_AT=85          # rate limits + credits
CTX_WARN_AT=75 ; CTX_CRIT_AT=90  # context window

# ── Progress bar (fills left-to-right as value increases) ────────────────────
# The fill GLYPH changes at critical as well as the colour, so severity survives
# a mono terminal, a screenshot, and red-green colour blindness — amber and
# coral differ by only 1.67:1 in luminance, which is not a signal on its own.
make_bar() {
    local pct=$1 width=$2 warn=${3:-$WARN_AT} crit=${4:-$CRIT_AT}
    # Clamp before the arithmetic: a pct outside 0..100 would otherwise produce a
    # bar wider than the width l2_width() budgeted for it, overflowing the line
    # the fit pass exists to protect.
    [ "$pct" -lt 0 ]   && pct=0
    [ "$pct" -gt 100 ] && pct=100
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local color glyph="█"
    if   [ "$pct" -ge "$crit" ]; then color="$C_BAR_CRIT" glyph="▓"
    elif [ "$pct" -ge "$warn" ]; then color="$C_BAR_WARN"
    else                              color="$C_BAR_NEUT"
    fi
    # NOT `seq 1 $n`: BSD seq counts DOWN when first > last, so `seq 1 0` prints
    # "1 0" and a zero-length run of cells rendered as TWO cells — showing usage
    # at 0% and headroom at 100%, the wrong signal at both ends of the scale.
    # Arithmetic-for is correct for 0 and negative counts, and costs no fork.
    local bar="${color}" i
    for (( i = 0; i < filled; i++ )); do bar="${bar}${glyph}"; done
    bar="${bar}${C_BAR_EMPTY}"
    for (( i = 0; i < empty;  i++ )); do bar="${bar}▒"; done
    bar="${bar}${RESET}"
    printf "%b" "$bar"
}

# ── Colour for a percentage value (only highlights when elevated) ─────────────
pct_color() {
    local pct=$1 warn=${2:-$WARN_AT} crit=${3:-$CRIT_AT}
    if   [ "$pct" -ge "$crit" ]; then printf "%b" "$C_CRIT"
    elif [ "$pct" -ge "$warn" ]; then printf "%b" "$C_WARN"
    else                              printf "%b" "\033[38;5;73m"
    fi
}

# Severity deliberately carries NO text marker on the percentages: "100%" is
# already unambiguous, and "100%!" reads as shouting at someone who can see the
# number. The non-colour signal lives where the number can't carry it — the
# bar's fill glyph (█ → ▓), and credits turn coral when a limit is spent.

# ── 1. MODEL + EFFORT ─────────────────────────────────────────────────────────
# model_name / effort_level arrive from the single parse above. Values stay
# plain until the FIT pass below has decided what survives; the coloured strings
# are built once, at assembly, from whatever is left.

# ── 2. CONTEXT BAR (shows how much context has been USED) ────────────────────
used_int=""
used_k=""
ctx_bar_w=10
if [ -n "$used_pct" ]; then
    used_int=$(printf "%.0f" "$used_pct")
    if [ -n "$total_input" ] && [ -n "$ctx_size" ]; then
        used_k=$(echo "$total_input $ctx_size" | awk 'function fmt(n){ if(n>=1000000){v=n/1000000; if(v==int(v)) return sprintf("%dM",v); return sprintf("%.1fM",v)} return sprintf("%dk",n/1000)}
{printf "%s/%s", fmt($1), fmt($2)}')
    fi
fi

# ── 3. LOCATION (repo name only — no owner prefix) ───────────────────────────
# Rendered as repo/worktree when cwd is in a linked worktree. The BRIGHT half is
# always the thing you're actually editing: in a worktree the parent repo demotes
# itself, so a glance answers "am I in my real checkout or a disposable copy?".
# repo_name / project_dir / cwd arrive from the single parse above.

# The status-line stdin has no worktree field, so ask git directly. A linked
# worktree is exactly the case where --git-dir differs from --git-common-dir;
# --path-format=absolute is required, or a plain subdirectory of the MAIN
# checkout reports "../.git" vs "/repo/.git" and false-positives as a worktree.
worktree=""
worktree_parent=""
branch=""
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
    # One process answers both questions. In a repo with no commits this exits
    # 128 after printing the first three lines, so parse by line and let the
    # branch simply come back empty rather than losing the location too.
    git_info=$(cd "$cwd" 2>/dev/null && git rev-parse --path-format=absolute \
        --git-dir --git-common-dir --show-toplevel --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$git_info" ]; then
        git_dir=$(printf '%s\n' "$git_info" | awk 'NR==1')
        git_common=$(printf '%s\n' "$git_info" | awk 'NR==2')
        git_top=$(printf '%s\n' "$git_info" | awk 'NR==3')
        branch=$(printf '%s\n' "$git_info" | awk 'NR==4')
        if [ -n "$git_dir" ] && [ "$git_dir" != "$git_common" ]; then
            worktree=$(basename "$git_top")
            worktree_parent=$(basename "$(dirname "$git_common")")
        fi
        # --abbrev-ref is sticky, so a detached HEAD reports the literal
        # "HEAD" and the sha costs one extra call — only in that rare case.
        if [ "$branch" = "HEAD" ]; then
            branch=$(cd "$cwd" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null)
            # "@" (not colour) is what marks a detached head, so it still reads
            # on a mono terminal. Deliberately NOT amber: agent worktrees are
            # detached by default, and an alarm that fires every time is noise.
            [ -n "$branch" ] && branch="@${branch}"
        fi
        [ "${#branch}" -gt 22 ] && branch="${branch:0:21}…"
    fi
fi

# Base name: repo if the remote is known, else the directory we're rooted in.
# In a worktree, project_dir/cwd point at the worktree itself, so the main
# checkout's directory name is the only honest local fallback for the parent.
base_name=""
if   [ -n "$repo_name" ];        then base_name="$repo_name"
elif [ -n "$worktree_parent" ];  then base_name="$worktree_parent"
elif [ -n "$project_dir" ];      then base_name=$(basename "$project_dir")
elif [ -n "$cwd" ];              then base_name=$(basename "$cwd")
fi

# Worktree dirs are usually named "<repo>-<branchish>"; that repeated prefix
# buys nothing once the repo is already shown to its left, so drop it.
if [ -n "$worktree" ]; then
    for prefix in "$base_name" "$worktree_parent"; do
        [ -z "$prefix" ] && continue
        case "$worktree" in
            "$prefix"-?*) worktree="${worktree#"$prefix"-}"; break ;;
        esac
    done
fi

# Truncate the worktree, never the repo — the repo is the stable anchor.
[ "${#worktree}" -gt 24 ] && worktree="${worktree:0:23}…"

# ── 4. SESSION ────────────────────────────────────────────────────────────────
# session_name arrives from the single parse above.

# ── 5. RATE LIMITS (only shown/coloured when elevated) ───────────────────────
# five_pct / five_resets / week_pct / week_resets likewise. Each window is
# independently absent for non-subscribers, which reads here as an empty string.
five_int=""; five_time=""
week_int=""; week_time=""
now=$(date +%s)
if [ -n "$five_pct" ]; then
    five_int=$(printf "%.0f" "$five_pct")
    if [ -n "$five_resets" ] && [ $(( (five_resets - now + 59) / 60 )) -gt 0 ]; then
        five_time=$(date -d "@${five_resets}" +"%H:%M" 2>/dev/null)
        [ -z "$five_time" ] && five_time=$(date -r "${five_resets}" +"%H:%M" 2>/dev/null)
    fi
fi
if [ -n "$week_pct" ]; then
    week_int=$(printf "%.0f" "$week_pct")
    if [ -n "$week_resets" ] && [ $(( (week_resets - now + 59) / 60 )) -gt 0 ]; then
        # 24-hour, matching the 5h segment. %-d (no day padding) works on both
        # GNU and BSD date, so one format serves both branches.
        week_time=$(date -d "@${week_resets}" +"%b %-d %H:%M" 2>/dev/null)
        [ -z "$week_time" ] && week_time=$(date -r "${week_resets}" +"%b %-d %H:%M" 2>/dev/null)
    fi
fi

# A limit at 100% is not just "very high" — it is the moment work starts costing
# real money, which is exactly what the credits segment below is reporting. The
# two facts are causally linked, so the consequence inherits the alarm.
limits_maxed=0
[ -n "${five_int:-}" ] && [ "$five_int" -ge 100 ] && limits_maxed=1
[ -n "${week_int:-}" ] && [ "$week_int" -ge 100 ] && limits_maxed=1

# ── 6. EXTRA USAGE / CREDITS (pay-as-you-go) ─────────────────────────────────
# This is NOT in the status-line stdin, so we fetch it from the OAuth usage
# endpoint (same one Claude Code uses) and cache it with a background refresh.
# Silently shows nothing if there's no token or the endpoint is unavailable.
extra_part=""
xu_str=""
xu_reset=""
XU_CACHE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cache"
XU_CACHE="$XU_CACHE_DIR/statusline-extra-usage.json"
XU_TTL=120
mkdir -p "$XU_CACHE_DIR" 2>/dev/null

xu_token() {
    [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && { printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN"; return; }
    local r=""
    command -v security >/dev/null 2>&1 && \
        r=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    if [ -z "$r" ]; then
        local cf="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
        [ -f "$cf" ] && r=$(cat "$cf" 2>/dev/null)
    fi
    [ -z "$r" ] && command -v secret-tool >/dev/null 2>&1 && \
        r=$(secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
    printf '%s' "$r" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const o=JSON.parse(d);process.stdout.write(String((o.claudeAiOauth&&o.claudeAiOauth.accessToken)||o.accessToken||""))}catch(e){}})' 2>/dev/null
}
xu_fetch() {
    local t; t=$(xu_token); [ -z "$t" ] && return 1
    curl -s --max-time 5 \
        -H "Accept: application/json" -H "Authorization: Bearer $t" \
        -H "anthropic-beta: oauth-2025-04-20" -H "User-Agent: claude-code/statusline" \
        "https://api.anthropic.com/api/oauth/usage"
}

if [ -n "$STATUSLINE_DEBUG" ]; then
    echo "── statusline diagnostics ─────────────────────────────────"
    echo "terminal width : ${COLUMNS:-unset} (COLUMNS) / $(tput cols 2>/dev/null || echo n-a) (tput)"
    echo "cwd            : $PWD"
    gi=$(git rev-parse --path-format=absolute --git-dir --git-common-dir --show-toplevel --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$gi" ]; then
        echo "git dir        : $(printf '%s\n' "$gi" | awk 'NR==1')"
        echo "git common dir : $(printf '%s\n' "$gi" | awk 'NR==2')"
        echo "worktree?      : $([ "$(printf '%s\n' "$gi" | awk 'NR==1')" != "$(printf '%s\n' "$gi" | awk 'NR==2')" ] && echo yes || echo "no (main checkout)")"
        echo "branch         : $(printf '%s\n' "$gi" | awk 'NR==4')"
    else
        echo "git            : not a repository"
    fi
    tok=$(xu_token)
    if [ -n "$tok" ]; then
        src="unknown"
        [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && src="CLAUDE_CODE_OAUTH_TOKEN env"
        [ "$src" = "unknown" ] && command -v security >/dev/null 2>&1 && \
            security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1 && src="macOS Keychain"
        [ "$src" = "unknown" ] && [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ] && src="~/.claude/.credentials.json"
        echo "oauth token    : found (${#tok} chars) via $src"
    else
        echo "oauth token    : NOT FOUND — the extra segment will be omitted"
    fi
    echo "cache file     : $XU_CACHE"
    if [ -f "$XU_CACHE" ]; then
        m=$(stat -f %m "$XU_CACHE" 2>/dev/null || stat -c %Y "$XU_CACHE" 2>/dev/null || echo 0)
        echo "cache age      : $(( $(date +%s) - m ))s (ttl ${XU_TTL}s)"
    else
        echo "cache age      : no cache yet"
    fi
    if [ -n "$tok" ]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            -H "Accept: application/json" -H "Authorization: Bearer $tok" \
            -H "anthropic-beta: oauth-2025-04-20" -H "User-Agent: claude-code/statusline" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        echo "live fetch     : HTTP ${code:-no response}"
    fi
    [ -s "$XU_CACHE" ] && node -e '
      const fs=require("fs");
      const o=(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).extra_usage)||{};
      const dp=(o.decimal_places!=null)?o.decimal_places:2;
      console.log("is_enabled     : "+o.is_enabled);
      console.log("currency       : "+o.currency+"  decimal_places: "+dp);
      console.log("used_credits   : "+o.used_credits+" (minor units) -> "+(Number(o.used_credits)/Math.pow(10,dp)).toFixed(dp));
      console.log("monthly_limit  : "+(o.monthly_limit==null?"none (unlimited)":o.monthly_limit));
    ' "$XU_CACHE" 2>/dev/null
    echo "───────────────────────────────────────────────────────────"
    exit 0
fi

xu_age=999999
if [ -f "$XU_CACHE" ]; then
    xu_mtime=$(stat -f %m "$XU_CACHE" 2>/dev/null || stat -c %Y "$XU_CACHE" 2>/dev/null || echo 0)
    xu_age=$(( $(date +%s) - xu_mtime ))
fi
if [ "$xu_age" -ge "$XU_TTL" ]; then
    # Claim the slot BEFORE forking. The status line can re-run every 300ms, and
    # an in-flight fetch is invisible to the next render — without a claim, a
    # cold cache makes every render start its own curl. An empty file reads as
    # fresh (age 0) and as "nothing to show" (the reader tests -s), so the
    # stampede collapses to one fetch and the segment stays absent until it lands.
    [ -f "$XU_CACHE" ] || : > "$XU_CACHE"
    # One path for warm and cold alike: background, unique tmp, atomic mv.
    # The cold path used to fetch SYNCHRONOUSLY straight into $XU_CACHE — the
    # branch that blocked the first render for up to curl's 5s --max-time, which
    # made it the branch most likely to be cancelled by Claude Code mid-write,
    # and the only one without tmp+rename to survive being cancelled. A killed
    # fetch now costs a stray $XU_CACHE.$$ that nothing reads, not a truncated
    # cache that silently hides the credits segment until the TTL expires.
    ( o=$(xu_fetch 2>/dev/null)
      [ -n "$o" ] && printf '%s' "$o" > "$XU_CACHE.$$" && mv "$XU_CACHE.$$" "$XU_CACHE"
    ) >/dev/null 2>&1 &
fi

if [ -s "$XU_CACHE" ]; then
    xu_str=$(node -e '
      const fs=require("fs");
      try{
        const o=(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).extra_usage)||{};
        if(!o.is_enabled) process.exit(0);
        const sym={USD:"$",EUR:"€",GBP:"£",JPY:"¥"}[o.currency]||((o.currency||"")+" ");
        const dp=(o.decimal_places!=null)?o.decimal_places:2;
        // used_credits / monthly_limit are MINOR units — decimal_places says how
        // many digits to shift, so 668 with dp=2 is £6.68, not £668.00. (The same
        // payload spells this out under spend.used: {amount_minor, exponent}.)
        const money=v=>(Number(v)/Math.pow(10,dp)).toFixed(dp);
        const used=(o.used_credits!=null)?money(o.used_credits):null;
        const lim=(o.monthly_limit!=null)?money(o.monthly_limit):null;
        if(used==null && lim==null) process.exit(0);
        let s=sym+(used!=null?used:money(0));
        if(lim!=null) s+="/"+sym+lim;
        process.stdout.write(s);
      }catch(e){}
    ' "$XU_CACHE" 2>/dev/null)
    if [ -n "$xu_str" ]; then
        # Credits reset monthly on the 1st (as the Usage page states); the API
        # returns no reset field, so the date is derived, not fetched. Without a
        # horizon a running total has no denominator — every other gauge on this
        # line tells you when it resets.
        xu_reset=$(date -v1d -v+1m +"%b %-d" 2>/dev/null)
        [ -z "$xu_reset" ] && xu_reset=$(date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null)
    fi
fi

# ── ASSEMBLE (two lines: identity on top, resource gauges below) ─────────────
# Group by the question the user is asking, not by field. Line 1 answers
# "where/what am I working in?"; line 2 answers "how much budget is left?".
# Dividers (│) separate GROUPS only; spacing separates items within a group.
join_sep() {                       # join non-empty args with the divider
    local out="" p
    for p in "$@"; do
        [ -z "$p" ] && continue
        [ -n "$out" ] && out="${out}${SEP}${p}" || out="$p"
    done
    printf '%s' "$out"             # raw (keep literal escapes for final %b)
}

# ── FIT LINE 1 TO THE TERMINAL ───────────────────────────────────────────────
# Claude Code truncates an over-long status line at the right edge, so the tail
# silently loses whatever sat there — always the session name. Fitting first
# means the bar CHOOSES what to give up, cheapest information first, instead of
# letting position decide. Width comes from the plain values, before any colour
# codes exist, so nothing has to be un-escaped to be measured.
term_cols="${COLUMNS:-}"
[ -z "$term_cols" ] && term_cols=$(tput cols 2>/dev/null)
case "$term_cols" in ''|*[!0-9]*) term_cols=100 ;; esac
budget=$(( term_cols - 1 ))        # leave the last cell; some terminals wrap on it

trunc() {                          # $1 string, $2 max — ellipsis is the mark
    local s=$1 m=$2
    [ "${#s}" -le "$m" ] && { printf '%s' "$s"; return; }
    printf '%s…' "${s:0:$((m - 1))}"
}

l1_width() {
    local w=0 groups=0
    if [ -n "$model_name" ]; then
        w=$(( w + ${#model_name} ))
        [ -n "$effort_level" ] && w=$(( w + 1 + ${#effort_level} ))
        groups=$(( groups + 1 ))
    fi
    local loc=0
    if [ -n "$worktree" ] && [ -n "$base_name" ]; then loc=$(( ${#base_name} + 1 + ${#worktree} ))
    elif [ -n "$worktree" ];                      then loc=${#worktree}
    elif [ -n "$base_name" ];                     then loc=${#base_name}
    fi
    [ -n "$branch" ] && [ "$loc" -gt 0 ] && loc=$(( loc + 3 + ${#branch} ))   # " ⎇ "
    [ "$loc" -gt 0 ] && { w=$(( w + loc )); groups=$(( groups + 1 )); }
    [ -n "$session_name" ] && { w=$(( w + ${#session_name} )); groups=$(( groups + 1 )); }
    [ "$groups" -gt 1 ] && w=$(( w + 3 * (groups - 1) ))   # " │ " per divider
    printf '%s' "$w"
}

# Sacrifice ladder, cheapest first. The location is never dropped: it is the one
# thing a glance is FOR when several sessions are open on one repo.
if [ "$(l1_width)" -gt "$budget" ] && [ "${#session_name}" -gt 28 ]; then
    session_name=$(trunc "$session_name" 28)
fi
if [ "$(l1_width)" -gt "$budget" ] && [ "${#session_name}" -gt 20 ]; then
    session_name=$(trunc "$session_name" 20)
fi
[ "$(l1_width)" -gt "$budget" ] && branch=""
[ "$(l1_width)" -gt "$budget" ] && effort_level=""
[ "$(l1_width)" -gt "$budget" ] && session_name=""
if [ "$(l1_width)" -gt "$budget" ] && [ -n "$worktree" ]; then
    worktree=$(trunc "$worktree" 12)
fi
# Last resorts: the model's parenthetical qualifier ("(1M context)") is the only
# part of it you already know, so it goes before the name itself is cut.
if [ "$(l1_width)" -gt "$budget" ]; then
    case "$model_name" in *\ \(*) model_name="${model_name%% (*}" ;; esac
fi
[ "$(l1_width)" -gt "$budget" ] && model_name=$(trunc "$model_name" 12)

# ── Build line 1 from what survived ──────────────────────────────────────────
model_part=""
if [ -n "$model_name" ]; then
    model_part="${C_MODEL}${model_name}${RESET}"
    [ -n "$effort_level" ] && model_part="${model_part} ${C_EFFORT}${effort_level}${RESET}"
fi

location_part=""
if [ -n "$worktree" ]; then
    if [ -n "$base_name" ]; then
        location_part="${C_LOC_PARENT}${base_name}/${C_LOCATION}${worktree}${RESET}"
    else
        location_part="${C_LOCATION}${worktree}${RESET}"
    fi
elif [ -n "$base_name" ]; then
    location_part="${C_LOCATION}${base_name}${RESET}"
fi

# Branch qualifies the location, so it joins that group rather than earning its
# own divider. Three tiers keep the hierarchy readable: the thing you edit is
# brightest, its context is desaturated, the glyph is chrome. Override the glyph
# with STATUSLINE_BRANCH_GLYPH if your font renders ⎇ oddly.
if [ -n "$branch" ] && [ -n "$location_part" ]; then
    location_part="${location_part} ${C_MUTED}${STATUSLINE_BRANCH_GLYPH:-⎇}${RESET} ${C_LOC_PARENT}${branch}${RESET}"
fi

session_part=""
[ -n "$session_name" ] && session_part="${C_SESSION}${session_name}${RESET}"

# Line 1 — identity: model/effort · repo/worktree + branch · session
location_group="$location_part"
line1=$(join_sep "$model_part" "$location_group" "$session_part")

# ── FIT LINE 2 ───────────────────────────────────────────────────────────────
# Same ladder, different priorities. Credits are never dropped and never lose
# their alarm: being truncated off the right edge is exactly how a segment that
# reports money quietly stops being read.
l2_width() {
    local w=0 groups=0
    if [ -n "$used_int" ]; then
        w=$(( w + 4 + ${#used_int} + 1 ))                          # "ctx " "NN%"
        # The bar and the space that separates it from the percentage both
        # disappear together at the ctx_bar_w=0 rung, so they are budgeted
        # together — counting the separator for a bar that isn't there is how
        # you get "ctx  50%" with a hole in it.
        [ "$ctx_bar_w" -gt 0 ] && w=$(( w + ctx_bar_w + 1 ))
        [ -n "$used_k" ] && w=$(( w + 1 + ${#used_k} ))
        groups=$(( groups + 1 ))
    fi
    local rate=0
    if [ -n "$five_int" ]; then
        rate=$(( rate + 3 + ${#five_int} + 1 ))                     # "5h NN%"
        [ -n "$five_time" ] && rate=$(( rate + 1 + ${#five_time} ))
    fi
    if [ -n "$week_int" ]; then
        [ "$rate" -gt 0 ] && rate=$(( rate + 3 ))                   # " · "
        rate=$(( rate + 3 + ${#week_int} + 1 ))
        [ -n "$week_time" ] && rate=$(( rate + 1 + ${#week_time} ))
    fi
    [ "$rate" -gt 0 ] && { w=$(( w + rate )); groups=$(( groups + 1 )); }
    if [ -n "$xu_str" ]; then
        w=$(( w + 7 + ${#xu_str} ))                                 # "extra: " amount
        [ -n "$xu_reset" ] && w=$(( w + 8 + ${#xu_reset} ))         # " resets X"
        groups=$(( groups + 1 ))
    fi
    [ "$groups" -gt 1 ] && w=$(( w + 3 * (groups - 1) ))
    printf '%s' "$w"
}

# Cheapest information first: raw token counts duplicate the percentage beside
# them; the credits reset is derived rather than reported; then the reset times;
# then the bar narrows. The numbers themselves are the last thing to go.
[ "$(l2_width)" -gt "$budget" ] && used_k=""
[ "$(l2_width)" -gt "$budget" ] && xu_reset=""
[ "$(l2_width)" -gt "$budget" ] && week_time=""
[ "$(l2_width)" -gt "$budget" ] && five_time=""
[ "$(l2_width)" -gt "$budget" ] && ctx_bar_w=5
# Below this the context group goes entirely, before the credits are allowed to
# fall off the right edge: context self-heals, money does not.
[ "$(l2_width)" -gt "$budget" ] && ctx_bar_w=0
[ "$(l2_width)" -gt "$budget" ] && { used_int=""; used_k=""; }

# ── Build line 2 from what survived ──────────────────────────────────────────
ctx_part=""
if [ -n "$used_int" ]; then
    pct_c=$(pct_color "$used_int" "$CTX_WARN_AT" "$CTX_CRIT_AT")
    ctx_part="${C_MUTED}ctx ${RESET}"
    # At the narrowest rung the bar is dropped entirely; it takes its trailing
    # separator with it, so the label sits straight against the percentage.
    if [ "$ctx_bar_w" -gt 0 ]; then
        ctx_bar=$(make_bar "$used_int" "$ctx_bar_w" "$CTX_WARN_AT" "$CTX_CRIT_AT")
        ctx_part="${ctx_part}${ctx_bar} "
    fi
    ctx_part="${ctx_part}${pct_c}${used_int}%${RESET}"
    [ -n "$used_k" ] && ctx_part="${ctx_part} ${C_MUTED}${used_k}${RESET}"
fi

rate_part=""
if [ -n "$five_int" ]; then
    rate_part="${C_MUTED}5h ${RESET}$(pct_color "$five_int")${five_int}%${RESET}"
    [ -n "$five_time" ] && rate_part="${rate_part} ${C_MUTED}${five_time}${RESET}"
fi
if [ -n "$week_int" ]; then
    [ -n "$rate_part" ] && rate_part="${rate_part}${ITEM_SEP}"
    rate_part="${rate_part}${C_MUTED}7d ${RESET}$(pct_color "$week_int")${week_int}%${RESET}"
    [ -n "$week_time" ] && rate_part="${rate_part} ${C_MUTED}${week_time}${RESET}"
fi

extra_part=""
if [ -n "$xu_str" ]; then
    # Coral when a limit is spent: the amount is live and climbing at that
    # moment, and colour says so without spending a character on it.
    if [ "$limits_maxed" = 1 ]; then
        extra_part="${C_MUTED}extra: ${RESET}${C_CRIT}${xu_str}${RESET}"
    else
        extra_part="${C_MUTED}extra: ${RESET}${C_VALUE}${xu_str}${RESET}"
    fi
    [ -n "$xu_reset" ] && extra_part="${extra_part} ${C_MUTED}resets ${xu_reset}${RESET}"
fi

# Line 2 — gauges: context window · rate limits · extra usage (far right)
line2=$(join_sep "$ctx_part" "$rate_part" "$extra_part")

if [ -n "$line2" ]; then
    printf "%b\n%b\n" "$line1" "$line2"
else
    printf "%b\n" "$line1"
fi
STATUSLINE_EOF

chmod +x "$SCRIPT_PATH"
echo "✓ Wrote status line script → $SCRIPT_PATH"

# ── 2. Merge the statusLine setting into settings.json (non-destructive) ──────
# Back up any existing settings first.
if [ -f "$SETTINGS_PATH" ]; then
    BACKUP_PATH="$SETTINGS_PATH.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS_PATH" "$BACKUP_PATH"
    echo "✓ Backed up existing settings → $BACKUP_PATH"
fi

node -e '
const fs = require("fs");
const p = process.argv[1];
let obj = {};
if (fs.existsSync(p)) {
  const raw = fs.readFileSync(p, "utf8");
  if (raw.trim()) {
    try { obj = JSON.parse(raw); }
    catch (e) {
      console.error("✗ Existing settings.json is not valid JSON — aborting so nothing is lost.");
      console.error("  Fix or remove " + p + " and re-run.");
      process.exit(3);
    }
  }
}
obj.statusLine = { type: "command", command: "bash ~/.claude/statusline-command.sh" };
fs.writeFileSync(p, JSON.stringify(obj, null, 2) + "\n");
' "$SETTINGS_PATH"

echo "✓ Added statusLine to → $SETTINGS_PATH"
echo ""
echo "Done. Restart Claude Code (or open a new session) to see the status line."
