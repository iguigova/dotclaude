#!/usr/bin/env bash
# memory_schedule.sh — run `memory_check.sh --all` every night, and catch up on a
# night the machine missed.
#
# It installs a systemd user timer, memory-check.timer, at 04:30 local time with
# Persistent=true: a night the machine was off or the user logged out runs the
# check as soon as the timer is active again. Cron has no such catch-up, so
# install also removes any crontab line naming memory_check.sh, leaving one
# schedule. The run appends to ~/.claude/memory_check.log, as before.
#
# Without lingering (`loginctl enable-linger`), a user timer is active only
# while the user is logged in, so a missed night runs at the next login.
#
# Usage:
#   memory_schedule.sh install    # write and enable the units; drop the cron line
#   memory_schedule.sh status     # when the timer last ran and next runs
#   memory_schedule.sh --self-test
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

UNIT=memory-check
unit_dir() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"; }

service_text() {
  cat <<EOF
[Unit]
Description=Re-check every stored memory fact (memory_check.sh --all)

[Service]
Type=oneshot
ExecStart=%h/.claude/scripts/memory_check.sh --all
StandardOutput=append:%h/.claude/memory_check.log
StandardError=append:%h/.claude/memory_check.log
EOF
}

timer_text() {
  cat <<EOF
[Unit]
Description=Nightly memory_check.sh --all, caught up after a missed night

[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

install_units() {
  local d; d=$(unit_dir)
  mkdir -p "$d" || return 1
  service_text > "$d/$UNIT.service" && timer_text > "$d/$UNIT.timer" || return 1
  systemctl --user daemon-reload && systemctl --user enable --now "$UNIT.timer" || return 1
  local cur
  if cur=$(crontab -l 2>/dev/null) && grep -q 'memory_check\.sh' <<<"$cur"; then
    grep -v 'memory_check\.sh' <<<"$cur" | crontab - || return 1
    echo "removed the crontab line naming memory_check.sh"
  fi
  echo "installed $d/$UNIT.timer"
}

self_test() {
  local st=0 out
  FX=$(mktemp -d); trap 'rm -rf "$FX"' EXIT
  local fx=$FX
  fail() { echo "  FAIL $*" >&2; st=1; }
  ok()   { echo "  ok   $*"; }
  mkdir -p "$fx/bin"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/systemctl.log"\n' "$fx" > "$fx/bin/systemctl"
  printf '#!/usr/bin/env bash\nif [[ "$1" == -l ]]; then cat "%s/crontab" 2>/dev/null; else cat > "%s/crontab"; fi\n' "$fx" "$fx" > "$fx/bin/crontab"
  chmod +x "$fx/bin/systemctl" "$fx/bin/crontab"
  printf 'SHELL=/bin/bash\n30 4 * * * /h/.claude/scripts/memory_check.sh --all >> /h/log 2>&1\n0 1 * * * other.sh\n' > "$fx/crontab"

  out=$(PATH="$fx/bin:$PATH" XDG_CONFIG_HOME="$fx/cfg" install_units 2>&1) || fail "install failed: $out"
  local d="$fx/cfg/systemd/user"
  grep -q '^Persistent=true$' "$d/$UNIT.timer" && grep -q '^OnCalendar=\*-\*-\* 04:30:00$' "$d/$UNIT.timer" \
    && ok "the timer runs at 04:30 and catches up" || fail "timer text"
  grep -q '^ExecStart=%h/.claude/scripts/memory_check.sh --all$' "$d/$UNIT.service" && ok "the service runs --all" || fail "service text"
  grep -q "enable --now $UNIT.timer" "$fx/systemctl.log" && ok "the timer is enabled and started" || fail "not enabled"
  if ! grep -q memory_check "$fx/crontab" && grep -q other.sh "$fx/crontab" && grep -q SHELL "$fx/crontab"; then
    ok "the cron line goes and every other line stays"
  else
    fail "crontab: $(cat "$fx/crontab")"
  fi
  out=$(PATH="$fx/bin:$PATH" XDG_CONFIG_HOME="$fx/cfg" install_units 2>&1) || fail "second install failed"
  grep -q 'removed the crontab' <<<"$out" && fail "a second install touched cron" || ok "a second install leaves cron alone"

  [[ $st -eq 0 ]] && echo "memory_schedule self-test: PASS" || echo "memory_schedule self-test: FAIL"
  return "$st"
}

case "${1:-}" in
  install)     install_units ;;
  status)      systemctl --user list-timers "$UNIT.timer" --all --no-pager ;;
  --self-test) self_test ;;
  *)           echo "usage: memory_schedule.sh install|status|--self-test" >&2; exit 2 ;;
esac
