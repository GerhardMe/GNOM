#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/mode/state"
SERVICE="awake.service"

# Colors
SERVER_COLOR="#002199b2"      # blue in server mode
NORMAL_COLOR=$(sed -n 's/.*theme.bg_normal[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$HOME/GNOMS/dotfiles/awesome/theme.lua")
NORMAL_COLOR="${NORMAL_COLOR:-#424242}"
PERFORMANCE_COLOR="#400050b2" # red in performance mode

# Txt colors
RED="\033[91m"     # bright red
GREEN="\033[92m"   # bright green
YELLOW="\033[93m"  # bright yellow
BLUE="\033[94m"    # bright blue
ORANGE="\033[95m"  # bright magenta
RESET="\033[0m"

# Helpers
err() { printf "${RED}ERROR:${RESET} %s\n" "$*" >&2; }
warn() { printf "${YELLOW}⚠ %s${RESET}\n" "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

mode_from_file() {
  if [[ -f "$STATE_FILE" ]]; then
    tr -d ' \t\r\n' < "$STATE_FILE"
  else
    echo normal
  fi
}

unit_exists_user() {
  systemctl --user list-unit-files | awk '{print $1}' | grep -qx "$SERVICE"
}

sleep_status() {
  systemctl --user is-active --quiet "$SERVICE" && echo OFF || echo ON
}

sshd_status() {
  systemctl is-active --quiet sshd 2>/dev/null && echo ON || echo OFF
}

safe_start_sshd() { sudo systemctl start sshd 2>/dev/null || err "failed to start sshd"; }
safe_stop_sshd()  { sudo systemctl stop  sshd 2>/dev/null || err "failed to stop sshd";  }

safe_start_inhibitor() {
  if unit_exists_user; then
    systemctl --user start "$SERVICE" 2>/dev/null || err "failed to start $SERVICE"
  else
    err "user unit $SERVICE not found (define it in Home Manager)"
  fi
}
safe_stop_inhibitor() {
  if unit_exists_user; then
    systemctl --user stop "$SERVICE" 2>/dev/null || err "failed to stop $SERVICE"
  fi
}

set_bar_color() {
  local color="$1"
  command -v awesome-client >/dev/null 2>&1 || { err "awesome-client not found; skipping bar color"; return 0; }
  [[ -z "${DISPLAY:-}" ]] && { err "DISPLAY not set; skipping bar color"; return 0; }
  awesome-client "awesome.emit_signal('mode::bar_bg', '$color')" >/dev/null 2>&1 || err "could not signal AwesomeWM"
}

battery_warning() {
  [[ "$MODE" != "server" ]] && return 0
  local base="/sys/class/power_supply"
  local bat dev
  bat="$(ls "$base" | grep -m1 '^BAT')" || return 0
  dev="$base/$bat"

  local status capacity power_now energy_now time_left=""
  status="$(<"$dev/status")" || return 0
  capacity="$(<"$dev/capacity")" || return 0

  if [[ "$status" == "Discharging" ]]; then
    if [[ -r "$dev/time_to_empty_now" ]]; then
      local secs
      secs="$(<"$dev/time_to_empty_now")"
      if (( secs > 0 )); then
        local h=$(( secs / 3600 ))
        local m=$(( (secs % 3600) / 60 ))
        time_left="${h} hours & ${m} minutes"
      fi
    elif [[ -r "$dev/power_now" && -r "$dev/energy_now" ]]; then
      power_now="$(<"$dev/power_now")"
      energy_now="$(<"$dev/energy_now")"
      if (( power_now > 0 )); then
        local mins=$(( energy_now * 60 / power_now ))
        local h=$(( mins / 60 ))
        local m=$(( mins % 60 ))
        time_left="${h} hours, ${m} minutes"
      fi
    fi

    {
      warn "Server mode on battery!"
      warn "  Battery: $capacity%"
      [[ -n "$time_left" ]] && warn "  Est. time left: $time_left"
    } >&2
  fi
}

# --- apply ---
MODE="$(mode_from_file)"
case "$MODE" in
  server)
    have systemctl || { err "systemctl missing"; exit 1; }
    have sudo || err "sudo missing (needed to control sshd)"
    safe_start_sshd
    safe_start_inhibitor
    set_bar_color "$SERVER_COLOR"
    ;;
  performance)
    have systemctl || { err "systemctl missing"; exit 1; }
    have sudo || err "sudo missing (needed to control sshd)"
    safe_stop_sshd
    safe_stop_inhibitor
    set_bar_color "$PERFORMANCE_COLOR"
    ;;
  normal|*)
    have systemctl || { err "systemctl missing"; exit 1; }
    have sudo || err "sudo missing (needed to control sshd)"
    safe_stop_sshd
    safe_stop_inhibitor
    set_bar_color "$NORMAL_COLOR"
    MODE="normal"
    ;;
esac

# --- concise summary (queried live) ---
if [[ "$MODE" == "server" ]]; then
  echo -e "${BLUE}${MODE} mode activated!${RESET}"
elif [[ "$MODE" == "performance" ]]; then
  echo -e "${ORANGE}${MODE} mode activated!${RESET}"
else
  echo -e "${GREEN}${MODE} mode activated!${RESET}"
fi

echo "sleep: $(sleep_status)"
echo "sshd:  $(sshd_status)"
battery_warning
