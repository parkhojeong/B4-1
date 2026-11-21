#!/bin/bash
#
# monitor.sh - Agent 앱 상태 점검 및 시스템 자원 로깅
#
# 종료 코드
#   0: 정상 (방화벽 비활성, 임계값 초과는 경고만 출력)
#   1: 프로세스 또는 포트 비정상, 로그 기록 실패
#
# cron은 로그인 환경을 불러오지 않으므로 PATH와 기본값을 스크립트에 고정한다.

set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

# 체크리스트 4-1 · 웹 서버로 바꿀 때는 프로세스 이름, 수신 포트, 로그 경로와 자원 임계값을 맞춘다.
AGENT_PORT="${AGENT_PORT:-15034}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"

# 리눅스의 프로세스 이름(comm)은 15바이트로 잘리므로 잘린 이름으로 정확히 비교한다.
# pgrep -f는 실행 명령 문자열에 앱 이름이 들어간 셸까지 잡을 수 있어 쓰지 않는다.
APP_PROCESS="${APP_PROCESS:-agent-app-linux}"

LOG_FILE="$AGENT_LOG_DIR/monitor.log"

CPU_LIMIT=20
MEM_LIMIT=10
DISK_LIMIT=80

MAX_LOG_SIZE=$((10 * 1024 * 1024)) # 10 MiB = 10,485,760바이트
MAX_ROTATED=9                      # monitor.log + 백업 9개 = 총 10개

# 파일 맨 아래의 main 호출이 실행을 시작한다.
main() {
    local app_pid cpu mem disk

    echo "====== SYSTEM MONITOR RESULT ======"
    echo
    echo "[HEALTH CHECK]"
    app_pid="$(find_app_pid)" || fail "Process '$APP_PROCESS' is not running"
    echo "Checking process '$APP_PROCESS'... [OK] (PID: $app_pid)"
    check_port
    show_firewall_status

    cpu="$(get_cpu_usage)"
    mem="$(get_mem_usage)"
    disk="$(get_disk_usage)"
    show_resources "$cpu" "$mem" "$disk"
    append_log "$app_pid" "$cpu" "$mem" "$disk"
}

fail() {
    echo "[ERROR] $1"
    exit 1
}

# 체크리스트 3-3 · 방화벽 비활성이나 임계값 초과는 경고하고 그때의 측정값을 계속 기록한다.
warn() {
    echo "[WARNING] $1"
}

# 체크리스트 2-1 · 프로세스는 이름과 상태로, 포트는 check_port()에서 TCP LISTEN 여부로 확인한다.
# 앱은 부모와 실제 작업 프로세스로 실행되므로 이름이 일치하는 PID 중 가장 큰 값부터 확인한다.
# 종료 후 회수되지 않은 좀비 프로세스는 실행 중이 아니므로 제외한다.
find_app_pid() {
    local pid state
    for pid in $(pgrep -x "$APP_PROCESS" | sort -rn); do
        state="$(ps -o stat= -p "$pid" 2>/dev/null)"
        state="${state// /}"
        if [[ -n "$state" && "$state" != Z* ]]; then
            echo "$pid"
            return 0
        fi
    done
    return 1
}

check_port() {
    local listener
    listener="$(ss -H -ltn "sport = :$AGENT_PORT")"
    if [[ -z "$listener" ]]; then
        fail "Port $AGENT_PORT is not listening"
    fi
    echo "Checking port $AGENT_PORT... [OK]"
}

# ufw status는 root 권한이 필요하므로 sudoers에 허용된 명령만 호출하고,
# 사용할 수 없으면 설정 파일의 활성화 값으로 판단한다.
firewall_active() {
    local status
    if command -v ufw >/dev/null 2>&1; then
        status="$(sudo -n /usr/sbin/ufw status 2>/dev/null)"
        if [[ -n "$status" ]]; then
            [[ "$status" == *"Status: active"* ]]
            return
        fi
        grep -qsE '^ENABLED=yes' /etc/ufw/ufw.conf
        return
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        [[ "$(firewall-cmd --state 2>/dev/null)" == "running" ]]
        return
    fi
    return 1
}

show_firewall_status() {
    echo
    echo "[FIREWALL]"
    if firewall_active; then
        echo "Firewall status... [OK] (active)"
    else
        warn "Firewall is not active"
    fi
}

# 체크리스트 2-2 · 아래 세 함수가 수집한 사용률을 append_log()가 고정된 필드 순서로 기록한다.
# /proc/stat의 누적 CPU 시간을 "전체 유휴" 형태로 출력한다.
read_cpu_times() {
    local _label user nice system idle iowait irq softirq steal _rest
    read -r _label user nice system idle iowait irq softirq steal _rest </proc/stat
    echo "$((user + nice + system + idle + iowait + irq + softirq + steal)) $((idle + iowait))"
}

# 부팅 후 누적값이 아닌 현재 사용률을 얻기 위해 1초 간격 두 표본의 차이를 계산한다.
get_cpu_usage() {
    local total1 idle1 total2 idle2
    read -r total1 idle1 <<<"$(read_cpu_times)"
    sleep 1
    read -r total2 idle2 <<<"$(read_cpu_times)"
    awk -v total=$((total2 - total1)) -v idle=$((idle2 - idle1)) \
        'BEGIN { if (total <= 0) print "0.0"; else printf "%.1f", (total - idle) * 100 / total }'
}

# 새 작업에 쓸 수 있는 메모리의 추정치(MemAvailable)를 기준으로 계산한다.
get_mem_usage() {
    awk '/^MemTotal:/ { total = $2 } /^MemAvailable:/ { available = $2 }
        END { if (total > 0) printf "%.1f", (total - available) * 100 / total; else print "0.0" }' /proc/meminfo
}

# -P는 긴 장치 이름에서도 한 줄 출력을 보장한다.
get_disk_usage() {
    df -P / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }'
}

warn_if_above() {
    local name="$1" value="$2" limit="$3"
    # awk는 소수 비교 결과가 참이면 종료 코드 0을 돌려주도록 한다.
    if awk -v value="$value" -v limit="$limit" 'BEGIN { exit !(value > limit) }'; then
        warn "$name threshold exceeded (${value}% > ${limit}%)"
    fi
}

show_resources() {
    local cpu="$1" mem="$2" disk="$3"
    echo
    echo "[RESOURCE MONITORING]"
    echo "CPU Usage : ${cpu}%"
    echo "MEM Usage : ${mem}%"
    echo "DISK Used : ${disk}%"
    echo
    warn_if_above CPU "$cpu" "$CPU_LIMIT"
    warn_if_above MEM "$mem" "$MEM_LIMIT"
    warn_if_above DISK "$disk" "$DISK_LIMIT"
}

# 체크리스트 2-4 · 로그 교체는 매번 기록 직전에 이 함수에서 처리한다.
# 다음 줄을 쓰면 10MB를 넘는 경우 백업 번호를 하나씩 밀고 가장 오래된 파일을 지운다.
rotate_log() {
    local next_line_size="$1" size i
    size="$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)"
    ((size + next_line_size <= MAX_LOG_SIZE)) && return 0

    rm -f "$LOG_FILE.$MAX_ROTATED" || return 1
    for ((i = MAX_ROTATED - 1; i >= 1; i--)); do
        if [[ -f "$LOG_FILE.$i" ]]; then
            mv -fT "$LOG_FILE.$i" "$LOG_FILE.$((i + 1))" || return 1
        fi
    done
    mv -fT "$LOG_FILE" "$LOG_FILE.1"
}

append_log() {
    local pid="$1" cpu="$2" mem="$3" disk="$4"
    local timestamp line
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    line="[$timestamp] PID:$pid CPU:${cpu}% MEM:${mem}% DISK_USED:${disk}%"

    # 줄 끝의 개행도 1바이트를 차지한다.
    rotate_log "$((${#line} + 1))" || fail "Log rotation failed: $LOG_FILE"
    # 체크리스트 3-4 · >>는 이전 줄을 보존한다. >를 쓰면 매번 마지막 측정값만 남는다.
    echo "$line" >>"$LOG_FILE" || fail "Cannot write log: $LOG_FILE"
    echo
    echo "[INFO] Log appended: $LOG_FILE"
}

main
