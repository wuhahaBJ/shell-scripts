if ! command -v jq &> /dev/null; then
  echo "需要 jq (brew install jq)"
  exit 1
fi

input=$(cat)

# --- 外部配额监控配置 ---
GLM_MONITOR_URL="${GLM_MONITOR_URL:-https://open.bigmodel.cn/api/monitor/usage/quota/limit}"
GLM_QUOTA_CACHE_TTL="${GLM_QUOTA_CACHE_TTL:-300}"
GLM_QUOTA_STALE_MAX_AGE="${GLM_QUOTA_STALE_MAX_AGE:-1800}"
GLM_MONITOR_TIMEOUT_MS="${GLM_MONITOR_TIMEOUT_MS:-1500}"
GLM_QUOTA_DISABLE="${GLM_QUOTA_DISABLE:-0}"
FIELD_SEP=$'\x1f'
QUOTA_CACHE_KEY="default"
if command -v shasum >/dev/null 2>&1; then
  QUOTA_CACHE_KEY="$(
    printf '%s' "${ANTHROPIC_AUTH_TOKEN:-anonymous}|${GLM_MONITOR_URL}" \
      | shasum -a 256 \
      | awk '{print substr($1,1,12)}'
  )"
fi
QUOTA_CACHE_FILE="/tmp/.claude-statusline-quota-cache-${QUOTA_CACHE_KEY}.json"

# 单次 jq 调用提取所有字段，用 @sh 安全输出
eval "$(echo "$input" | jq -r '
  "model=" + (.model.display_name // "Claude" | @sh),
  "used_pct=" + (.context_window.used_percentage // 0 | tostring),
  "remain_pct=" + (.context_window.remaining_percentage // 0 | tostring),
  "ctx_size=" + (.context_window.context_window_size // 0 | tostring),
  "input_tokens=" + (.context_window.total_input_tokens // 0 | tostring),
  "output_tokens=" + (.context_window.total_output_tokens // 0 | tostring),
  "cache_read=" + (.context_window.current_usage.cache_read_input_tokens // 0 | tostring),
  "cache_create=" + (.context_window.current_usage.cache_creation_input_tokens // 0 | tostring),
  "cur_input=" + (.context_window.current_usage.input_tokens // 0 | tostring),
  "cur_output=" + (.context_window.current_usage.output_tokens // 0 | tostring),
  "cost=" + (.cost.total_cost_usd // 0 | tostring),
  "duration=" + (.cost.total_duration_ms // 0 | tostring),
  "api_duration=" + (.cost.total_api_duration_ms // 0 | tostring),
  "lines_add=" + (.cost.total_lines_added // 0 | tostring),
  "lines_rm=" + (.cost.total_lines_removed // 0 | tostring),
  "rate_5h=" + ((.rate_limits.five_hour.used_percentage // null) // "" | tostring),
  "rate_7d=" + ((.rate_limits.seven_day.used_percentage // null) // "" | tostring),
  "reset_5h=" + ((.rate_limits.five_hour.resets_at // null) // 0 | tostring),
  "reset_7d=" + ((.rate_limits.seven_day.resets_at // null) // 0 | tostring)
')"

# --- ANSI 颜色 ---
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
CYAN='\033[36m'
RESET='\033[0m'

# --- 工具函数：数值判断 ---
is_number() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

clamp_pct() {
  local v="$1"
  is_number "$v" || { echo ""; return; }
  local p="${v%%.*}"
  [ "$p" -lt 0 ] 2>/dev/null && p=0
  [ "$p" -gt 100 ] 2>/dev/null && p=100
  echo "$p"
}

# --- 工具函数：根据百分比返回颜色 ---
pct_color() {
  local pct="${1%%.*}"
  [ "${pct:-0}" -ge 80 ] 2>/dev/null && printf '%b' "$RED" && return
  [ "${pct:-0}" -ge 50 ] 2>/dev/null && printf '%b' "$YELLOW" && return
  printf '%b' "$GREEN"
}

# --- 工具函数：生成进度条 ---
make_bar() {
  local pct="${1%%.*}"
  local width="${2:-10}"
  pct="${pct:-0}"
  [ "$pct" -lt 0 ] 2>/dev/null && pct=0
  [ "$pct" -gt 100 ] 2>/dev/null && pct=100
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local bar=""
  local i
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done
  echo "$bar"
}

# --- 工具函数：格式化倒计时 ---
format_countdown() {
  local resets_at="$1"
  local now
  now=$(date +%s)
  local diff=$((resets_at - now))
  if [ "$diff" -le 0 ]; then
    echo "now"
    return
  fi
  local hours=$((diff / 3600))
  local mins=$(( (diff % 3600) / 60 ))
  if [ "$hours" -gt 24 ]; then
    echo "$((hours / 24))d$((hours % 24))h"
  elif [ "$hours" -gt 0 ]; then
    echo "${hours}h${mins}m"
  else
    echo "${mins}m"
  fi
}

# --- 工具函数：标准化时间戳（毫秒->秒） ---
normalize_epoch_seconds() {
  local ts="$1"
  if ! is_number "$ts"; then
    echo ""
    return
  fi
  local i="${ts%%.*}"
  if [ "$i" -gt 100000000000 ] 2>/dev/null; then
    i=$(( i / 1000 ))
  fi
  echo "$i"
}

# --- 工具函数：倒计时（自动识别秒/毫秒） ---
format_countdown_auto() {
  local ts
  ts="$(normalize_epoch_seconds "$1")"
  if [ -z "$ts" ]; then
    echo "--"
    return
  fi
  format_countdown "$ts"
}

# --- 工具函数：格式化持续时间 ---
format_duration() {
  local ms="$1"
  local total_sec=$((ms / 1000))
  local mins=$((total_sec / 60))
  local secs=$((total_sec % 60))
  if [ "$mins" -gt 60 ]; then
    echo "$((mins / 60))h$((mins % 60))m"
  elif [ "$mins" -gt 0 ]; then
    echo "${mins}m${secs}s"
  else
    echo "${secs}s"
  fi
}

# --- 工具函数：格式化 token 数量 ---
format_tokens() {
  local n="$1"
  if [ "$n" -ge 1000000 ] 2>/dev/null; then
    printf '%.1fM' "$(echo "scale=1; $n / 1000000" | bc)"
  elif [ "$n" -ge 1000 ] 2>/dev/null; then
    printf '%.1fK' "$(echo "scale=1; $n / 1000" | bc)"
  else
    echo "${n}"
  fi
}

# --- 配额缓存：读取（fresh 或 stale） ---
read_quota_cache() {
  local mode="${1:-fresh}"
  [ -f "$QUOTA_CACHE_FILE" ] || return 1

  local row
  row="$(jq -r '[.saved_at // 0, (.five_hour_used_pct // ""), (.monthly_used_pct // ""), (.next_reset_time // ""), (.raw_level // "")] | map(if . == null then "" else tostring end) | join("\u001f")' "$QUOTA_CACHE_FILE" 2>/dev/null)" || return 1
  [ -n "$row" ] || return 1

  local saved_at fiveh mon reset level
  IFS="$FIELD_SEP" read -r saved_at fiveh mon reset level <<<"$row"
  is_number "$saved_at" || return 1

  local now
  now=$(date +%s)
  local age=$(( now - ${saved_at%%.*} ))

  if [ "$mode" = "fresh" ]; then
    local ttl="${GLM_QUOTA_CACHE_TTL%%.*}"
    is_number "$ttl" || ttl=300
    [ "$ttl" -lt 1 ] 2>/dev/null && ttl=300
    [ "$age" -le "$ttl" ] || return 1
  else
    local stale_max="${GLM_QUOTA_STALE_MAX_AGE%%.*}"
    is_number "$stale_max" || stale_max=1800
    [ "$stale_max" -lt 1 ] 2>/dev/null && stale_max=1800
    [ "$age" -le "$stale_max" ] || return 1
  fi

  printf '%s%s%s%s%s%s%s\n' "$fiveh" "$FIELD_SEP" "$mon" "$FIELD_SEP" "$reset" "$FIELD_SEP" "$level"
}

# --- 配额缓存：写入 ---
write_quota_cache() {
  local fiveh="$1"
  local mon="$2"
  local reset="$3"
  local level="$4"
  local now
  now=$(date +%s)

  jq -n \
    --argjson saved_at "$now" \
    --arg fiveh "$fiveh" \
    --arg mon "$mon" \
    --arg reset "$reset" \
    --arg level "$level" \
    '{
      saved_at: $saved_at,
      five_hour_used_pct: (if $fiveh == "" then null else ($fiveh | tonumber) end),
      monthly_used_pct: (if $mon == "" then null else ($mon | tonumber) end),
      next_reset_time: (if $reset == "" then null else ($reset | tonumber) end),
      raw_level: $level
    }' > "$QUOTA_CACHE_FILE" 2>/dev/null
}

# --- 监控 API：拉取原始配额 JSON ---
get_monitor_quota_raw() {
  [ "$GLM_QUOTA_DISABLE" = "1" ] && return 1
  [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] || return 1
  command -v curl >/dev/null 2>&1 || return 1

  local timeout_ms="${GLM_MONITOR_TIMEOUT_MS%%.*}"
  is_number "$timeout_ms" || timeout_ms=1500
  [ "$timeout_ms" -lt 200 ] 2>/dev/null && timeout_ms=200
  local timeout_sec
  timeout_sec=$(awk "BEGIN { printf \"%.3f\", $timeout_ms/1000 }")

  local resp http_code body
  resp="$(curl -sS --max-time "$timeout_sec" -H "Authorization: ${ANTHROPIC_AUTH_TOKEN}" -H "Accept-Language: en-US,en" -H "Content-Type: application/json" -w $'\n%{http_code}' "$GLM_MONITOR_URL" 2>/dev/null)" || return 1
  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  [ "$http_code" = "200" ] || return 1
  echo "$body"
}

# --- 监控 API：解析 limits，输出 fiveh \t monthly \t reset \t level ---
parse_quota_limits() {
  local raw="$1"
  echo "$raw" | jq -r '
    def n:
      if type == "number" then .
      elif type == "string" then (tonumber?)
      else null end;
    def pct(v):
      if (v | n) == null then null
      elif (v | n) < 0 then 0
      elif (v | n) > 100 then 100
      else (v | n) end;
    def score:
      if (.usage | n) != null then (.usage | n)
      elif ((.remaining | n) != null and (.currentValue | n) != null) then ((.remaining | n) + (.currentValue | n))
      elif (.unit | n) != null then (.unit | n)
      else 0 end;

    ((.data.limits // .limits // []) | map(select(type == "object"))) as $limits
    | ($limits | map(select(.type == "TOKENS_LIMIT" and ((.number | n) == 5))) | .[0]) as $five_primary
    | ($limits | map(select(.type == "TIME_LIMIT" and ((.unit | n) == 5))) | .[0]) as $five_fallback
    | (if $five_primary != null then $five_primary else $five_fallback end) as $five
    | ($limits | map(select(.type == "TIME_LIMIT" and ((.unit | n) != 5)))) as $mon_candidates
    | (if ($mon_candidates | length) > 0 then ($mon_candidates | max_by(score)) else null end) as $mon
    | [($five | pct(.percentage)), ($mon | pct(.percentage)), ($five.nextResetTime // $mon.nextResetTime // ""), (.data.level // .level // "")]
    | map(if . == null then "" else tostring end)
    | join("\u001f")
  ' 2>/dev/null
}

# --- 配额聚合：优先 fresh cache -> API -> stale cache ---
load_monitor_quota() {
  if [ "$GLM_QUOTA_DISABLE" = "1" ] || [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    echo $'\t\t\t'
    return 0
  fi

  local row

  row="$(read_quota_cache fresh)"
  if [ -n "$row" ]; then
    echo "$row"
    return 0
  fi

  local raw parsed
  raw="$(get_monitor_quota_raw)"
  if [ -n "$raw" ]; then
    parsed="$(parse_quota_limits "$raw")"
    if [ -n "$parsed" ]; then
      local q5 qm qr ql
      IFS="$FIELD_SEP" read -r q5 qm qr ql <<<"$parsed"
      write_quota_cache "$q5" "$qm" "$qr" "$ql"
      printf '%s%s%s%s%s%s%s\n' "$q5" "$FIELD_SEP" "$qm" "$FIELD_SEP" "$qr" "$FIELD_SEP" "$ql"
      return 0
    fi
  fi

  row="$(read_quota_cache stale)"
  if [ -n "$row" ]; then
    echo "$row"
    return 0
  fi

  echo $'\t\t\t'
}

# =============================================================================
# 第一行：模型 | 上下文进度条 | Token 统计 | 费用 | 持续时间
# =============================================================================

ctx_bar=$(make_bar "$used_pct" 10)
ctx_color=$(pct_color "$used_pct")
duration_str=$(format_duration "$duration")
input_str=$(format_tokens "$input_tokens")
output_str=$(format_tokens "$output_tokens")

line1="${BOLD}${model}${RESET} "
line1+="${ctx_color}${ctx_bar}${RESET} "
line1+="${ctx_color}${used_pct%%.*}%${RESET} "
line1+="${DIM}↑${input_str} ↓${output_str}${RESET} "
line1+="${DIM}\$$(printf '%.2f' "$cost")${RESET} "
line1+="${DIM}${duration_str}${RESET}"

# =============================================================================
# 第二行：速率限制 | 缓存统计 | 代码变更
# =============================================================================

line2=""
sep=""

# 外部配额（固定前两项）
monitor_row="$(load_monitor_quota)"
monitor_5h=""
monitor_mon=""
monitor_reset=""
monitor_level=""
IFS="$FIELD_SEP" read -r monitor_5h monitor_mon monitor_reset monitor_level <<<"$monitor_row"

if is_number "$monitor_5h"; then
  monitor_5h_pct="$(clamp_pct "$monitor_5h")"
  m5_color=$(pct_color "$monitor_5h_pct")
  m5_bar=$(make_bar "$monitor_5h_pct" 8)
  m5_reset=$(format_countdown_auto "$monitor_reset")
  line2+="${sep}${BOLD}5H${RESET} ${m5_color}${m5_bar}${RESET} ${m5_color}${monitor_5h_pct}%${RESET} ${DIM}↻${m5_reset}${RESET}"
else
  line2+="${sep}${BOLD}5H${RESET} ${DIM}--${RESET}"
fi
sep=" ${DIM}|${RESET} "

if is_number "$monitor_mon"; then
  monitor_mon_pct="$(clamp_pct "$monitor_mon")"
  mmon_color=$(pct_color "$monitor_mon_pct")
  mmon_bar=$(make_bar "$monitor_mon_pct" 8)
  line2+="${sep}${BOLD}MON${RESET} ${mmon_color}${mmon_bar}${RESET} ${mmon_color}${monitor_mon_pct}%${RESET}"
else
  line2+="${sep}${BOLD}MON${RESET} ${DIM}--${RESET}"
fi
sep=" ${DIM}|${RESET} "

# 速率限制（仅在有数据时显示）
if [ -n "$rate_5h" ] && [ "$rate_5h" != "null" ]; then
  color_5h=$(pct_color "$rate_5h")
  countdown_5h=$(format_countdown "$reset_5h")
  line2+="${sep}${BOLD}5h:${RESET}${color_5h}${rate_5h%%.*}% ↻${countdown_5h}${RESET}"
  sep=" ${DIM}|${RESET} "
fi

if [ -n "$rate_7d" ] && [ "$rate_7d" != "null" ]; then
  color_7d=$(pct_color "$rate_7d")
  countdown_7d=$(format_countdown "$reset_7d")
  line2+="${sep}${BOLD}7d:${RESET}${color_7d}${rate_7d%%.*}% ↻${countdown_7d}${RESET}"
  sep=" ${DIM}|${RESET} "
fi

# 缓存统计（仅在有缓存命中时显示）
if [ "${cache_read:-0}" -gt 0 ] 2>/dev/null; then
  total_ctx=$(( cur_input + cache_read + cache_create ))
  if [ "$total_ctx" -gt 0 ] 2>/dev/null; then
    cache_pct=$(( cache_read * 100 / total_ctx ))
    line2+="${sep}${CYAN}cache:${cache_pct}%${RESET}"
    sep=" ${DIM}|${RESET} "
  fi
fi

# 代码变更
if [ "${lines_add:-0}" -gt 0 ] 2>/dev/null || [ "${lines_rm:-0}" -gt 0 ] 2>/dev/null; then
  line2+="${sep}${GREEN}+${lines_add}${RESET} ${RED}-${lines_rm}${RESET}"
fi

# --- 输出 ---
printf '%b\n' "$line1"
if [ -n "$line2" ]; then
  printf '%b\n' "$line2"
fi
