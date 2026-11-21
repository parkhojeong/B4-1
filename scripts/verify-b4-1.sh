#!/bin/bash
#
# verify-b4-1.sh - 평가 체크리스트의 구현 항목을 컨테이너에서 자동 점검한다.
#
# 사용법: ./scripts/verify-b4-1.sh
# 앱을 종료하지 않으며, 시험용 로그는 임시 디렉토리에 기록하고 삭제한다.

DOCKER_CONTEXT_NAME="${B4_DOCKER_CONTEXT:-orbstack}"
CONTAINER="${B4_CONTAINER:-b4-1}"

docker --context "$DOCKER_CONTEXT_NAME" exec -i "$CONTAINER" bash -s <<'EOF'
H=/home/agent-admin/agent-app
M=$H/bin/monitor.sh
L=/var/log/agent-app/monitor.log
PASS=0
FAIL=0

section() { printf '\n[%s]\n' "$1"; }

c() {
    if eval "$2" >/dev/null 2>&1; then
        PASS=$((PASS + 1)); echo "PASS  $1"
    else
        FAIL=$((FAIL + 1)); echo "FAIL  $1"
    fi
}

in_group() { id -nG "$1" | tr ' ' '\n' | grep -qx "$2"; }
can() { su - "$1" -c "$2"; }
mode_is() { [ "$(stat -c '%U:%G:%a' "$1")" = "$2" ]; }
env_is() { [ "$(su - agent-admin -c "printenv $1")" = "$2" ]; }

# 앱에 영향을 주지 않도록 쓰기 가능한 임시 로그 디렉토리에서 실행한다.
TMP_LOG=$(mktemp -d /tmp/verify-log.XXXXXX)
chown agent-admin "$TMP_LOG"
run_monitor() { su - agent-admin -c "AGENT_LOG_DIR=$TMP_LOG $1 $M"; }

rotation_works() {
    local t rc
    t=$(mktemp -d /tmp/verify-rot.XXXXXX)
    chown agent-admin "$t"
    su - agent-admin -c "
        cd $t
        for i in 1 2 3 4 5 6 7 8 9; do echo backup-\$i > monitor.log.\$i; done
        head -c 10485750 /dev/zero | tr '\0' x > monitor.log
        AGENT_LOG_DIR=$t $M >/dev/null
        [ \$(ls monitor.log monitor.log.[0-9] | wc -l) -eq 10 ] &&
        [ \$(stat -c %s monitor.log) -lt 1024 ] &&
        [ \$(stat -c %s monitor.log.1) -eq 10485750 ] &&
        [ \"\$(cat monitor.log.9)\" = backup-8 ]
    "
    rc=$?
    rm -rf "$t"
    return $rc
}

app_runs_as_admin() {
    ps -C agent-app-linux -o uid= | awk -v admin="$(id -u agent-admin)" '
        $1 != admin { invalid = 1 }
        END { exit !(NR > 0 && !invalid) }
    '
}

boot_steps_ok() {
    local step
    for step in 1 2 3 4 5; do
        grep -qE "^\[$step/5\].*\[OK\]$" "$H/app.out" || return 1
    done
}

cron_appends() {
    local initial deadline
    initial=$(tail -n 1 "$L") || return 1
    deadline=$((SECONDS + 80))
    while (( SECONDS < deadline )); do
        sleep 2
        [[ -s "$L" && "$(tail -n 1 "$L")" != "$initial" ]] && return 0
    done
    return 1
}

# 체크리스트 1-1 · SSH 포트 변경과 root 원격 로그인 차단
section "SSH"
c "sshd 포트가 20022이다" 'sshd -T | grep -qx "port 20022"'
c "Root 원격 로그인이 차단되어 있다" 'sshd -T | grep -qx "permitrootlogin no"'
c "20022 포트가 LISTEN 상태이다" '[ -n "$(ss -H -ltn "sport = :20022")" ]'
c "기존 22 포트는 LISTEN 상태가 아니다" '[ -z "$(ss -H -ltn "sport = :22")" ]'

# 체크리스트 1-2 · UFW 활성 상태와 허용 포트
section "방화벽"
c "UFW가 활성화되어 있다" 'ufw status | grep -qx "Status: active"'
c "기본 인바운드 정책이 deny이다" 'ufw status verbose | grep -q "deny (incoming)"'
c "허용 규칙이 20022/tcp, 15034/tcp뿐이다" '[ "$(ufw status | awk "/ALLOW/{print \$1}" | sort -u | tr "\n" " ")" = "15034/tcp 20022/tcp " ]'

# 체크리스트 1-3 · 계정별 agent-common·agent-core 소속
section "계정과 그룹"
for u in agent-admin agent-dev agent-test; do
    c "$u 계정이 있다" "id $u"
    c "$u 는 agent-common 그룹이다" "in_group $u agent-common"
done
c "agent-admin은 agent-core 그룹이다" 'in_group agent-admin agent-core'
c "agent-dev는 agent-core 그룹이다" 'in_group agent-dev agent-core'
c "agent-test는 agent-core 그룹이 아니다" '! in_group agent-test agent-core'

section "디렉토리와 권한"
c "upload_files 그룹은 agent-common이다" "mode_is $H/upload_files agent-admin:agent-common:2770"
c "api_keys 그룹은 agent-core이다" "mode_is $H/api_keys agent-admin:agent-core:2770"
c "로그 디렉토리 그룹은 agent-core이다" 'mode_is /var/log/agent-app agent-admin:agent-core:2770'
for u in agent-admin agent-dev agent-test; do
    c "$u 는 upload_files에 쓸 수 있다" "can $u 'touch $H/upload_files/.v_$u && rm $H/upload_files/.v_$u'"
done
for u in agent-admin agent-dev; do
    c "$u 는 api_keys를 읽고 쓸 수 있다" "can $u 'cat $H/api_keys/t_secret.key && touch $H/api_keys/.v_$u && rm $H/api_keys/.v_$u'"
    c "$u 는 로그 디렉토리에 쓸 수 있다" "can $u 'touch /var/log/agent-app/.v_$u && rm /var/log/agent-app/.v_$u'"
done
c "agent-test는 api_keys를 읽을 수 없다" "! can agent-test 'cat $H/api_keys/t_secret.key'"
c "agent-test는 로그 디렉토리를 읽을 수 없다" "! can agent-test 'ls /var/log/agent-app'"
c "agent-test는 앱 출력 파일을 읽을 수 없다" "! can agent-test 'cat $H/app.out'"

for dir in "$H/upload_files" "$H/api_keys" /var/log/agent-app; do
    group=agent-core
    [[ "$dir" == "$H/upload_files" ]] && group=agent-common
    c "$dir 에 $group 접근 ACL과 기본 ACL이 있다" "getfacl -cp '$dir' | grep -qx 'group:$group:rwx' && getfacl -cp '$dir' | grep -qx 'default:group:$group:rwx'"
done

section "앱 실행 환경"
c "AGENT_HOME 값이 맞다" "env_is AGENT_HOME $H"
c "AGENT_PORT 값이 맞다" 'env_is AGENT_PORT 15034'
c "AGENT_UPLOAD_DIR 값이 맞다" "env_is AGENT_UPLOAD_DIR $H/upload_files"
c "로그인 환경의 AGENT_KEY_PATH가 명세의 키 파일이다" "env_is AGENT_KEY_PATH $H/api_keys/t_secret.key"
c "앱이 읽는 secret.key가 명세의 키 파일을 가리킨다" '[ "$H/api_keys/secret.key" -ef "$H/api_keys/t_secret.key" ]'
c "AGENT_LOG_DIR 값이 맞다" 'env_is AGENT_LOG_DIR /var/log/agent-app'
c "키 파일 내용이 1줄로 맞다" "[ \"\$(cat $H/api_keys/t_secret.key)\" = agent_api_key_test ] && [ \"\$(wc -l < $H/api_keys/t_secret.key)\" -eq 1 ]"
c "앱 프로세스의 실행 계정이 agent-admin이다" 'app_runs_as_admin'
# 체크리스트 1-4 · 부팅 5단계와 실제 완료 메시지 Agent READY
c "Boot Sequence 5단계가 모두 [OK]이다" 'boot_steps_ok'
c "Agent READY가 출력되었다" "grep -qx 'Agent READY' $H/app.out"
c "앱이 0.0.0.0:15034에서 LISTEN 중이다" 'runuser -u agent-admin -- ss -H -ltnp "sport = :15034" | grep -F "0.0.0.0:15034" | grep -qF "(\"agent-app-linux\","'

section "monitor.sh"
c "위치, 소유자, 그룹, 권한이 맞다" "mode_is $M agent-dev:agent-core:750"
c "Bash 스크립트이다" "[ \"\$(head -n 1 $M)\" = '#!/bin/bash' ]"
# 체크리스트 1-5 · 정상 실행과 프로세스·포트 오류의 종료 코드 비교
c "agent-admin이 정상 실행하면 exit 0이다" 'run_monitor ""'
c "포트가 비정상이면 exit 1이다" '[ "$(run_monitor "AGENT_PORT=15999" >/dev/null 2>&1; echo $?)" = 1 ]'
c "프로세스가 비정상이면 exit 1이다" '[ "$(run_monitor "APP_PROCESS=no-such-proc" >/dev/null 2>&1; echo $?)" = 1 ]'
c "cron과 같은 빈 환경에서도 실행된다" "su agent-admin -s /bin/bash -c 'cd / && env -i AGENT_LOG_DIR=$TMP_LOG $M'"
c "자원 수치를 출력한다" 'run_monitor "" | grep -q "CPU Usage" && run_monitor "" | grep -q "MEM Usage" && run_monitor "" | grep -q "DISK Used"'

resource_warnings() {
    runuser -u agent-admin -- bash -s -- "$TMP_LOG" "$M" <<'WARNINGS'
set -eu
export AGENT_LOG_DIR=$1
cd "$AGENT_LOG_DIR"
# 측정 입력만 고정한다. 제출 스크립트의 임계값, 비교, 경고, 로그 기록 코드를 실행한다.
sed -e "s|/proc/meminfo|$AGENT_LOG_DIR/meminfo|" -e "s|df -P / |cat '$AGENT_LOG_DIR/df.out' |" "$2" > monitor-fixture.sh
printf 'MemTotal: 1000 kB\nMemAvailable: 900 kB\n' > meminfo
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/test 100 80 20 80%% /\n' > df.out
bash monitor-fixture.sh > output
if grep -Eq '^\[WARNING\] (MEM|DISK)' output; then exit 1; fi
sed -i s/900/899/ meminfo
sed -i s/80%/81%/ df.out
bash monitor-fixture.sh > output
grep -Fxq '[WARNING] MEM threshold exceeded (10.1% > 10%)' output
grep -Fxq '[WARNING] DISK threshold exceeded (81% > 80%)' output
tail -1 monitor.log | grep -Eq ' MEM:10[.]1% DISK_USED:81%$'
WARNINGS
}
c "MEM 10%·DISK 80% 경계와 초과 경고 후 로그 기록이 맞다" 'resource_warnings'

section "로그와 cron"
# 체크리스트 1-6 · 로그 파일과 각 줄의 필드 형식
c "monitor.log가 있다" "[ -s $L ]"
c "모든 줄이 지정 포맷이다" "! grep -vE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] PID:[0-9]+ CPU:[0-9.]+% MEM:[0-9.]+% DISK_USED:[0-9]+%\$' $L"
c "agent-admin crontab에 매분 실행이 등록되어 있다" "crontab -u agent-admin -l | grep -qxF '* * * * * $M >/dev/null 2>&1'"
c "cron 서비스가 실행 중이다" 'service cron status'
c "최근 90초 안에 로그가 기록되었다" "[ \$(( \$(date +%s) - \$(date -d \"\$(tail -n 1 $L | cut -c2-20)\" +%s) )) -le 90 ]"
# 체크리스트 1-8 · 임시 로그로 교체 시점과 백업 9개 보존 확인
c "10MB 초과 시 교체하고 10개 파일을 유지한다" 'rotation_works'

# 체크리스트 1-7 · 매분 cron 등록 확인 후 다음 자동 기록 관찰
c "수동 기록 없이 80초 안에 monitor.log에 새 줄이 생긴다" 'cron_appends'

section "선택 과제"
c "아카이브 작업이 agent-admin의 일일 cron에 등록되어 있다" "crontab -u agent-admin -l | grep -qxF '15 0 * * * $H/bin/archive-logs.sh'"
c "agent-admin이 운영 로그로 통계 리포트를 실행할 수 있다" 'runuser -u agent-admin -- "$H/bin/report.sh" | grep -Eq "^Data Points: [1-9][0-9]*$"'

report_works() {
    runuser -u agent-admin -- env AGENT_LOG_DIR="$TMP_LOG" bash -s -- "$H/bin/report.sh" <<'REPORT'
set -eu
cd "$AGENT_LOG_DIR"
cat > monitor.log <<'SAMPLES'
[2026-11-01 10:00:00] PID:1 CPU:99.0% MEM:99.0% DISK_USED:99%
[2026-11-01 10:01:00] PID:2 CPU:10.0% MEM:5.0% DISK_USED:30%
[2026-11-01 10:02:00] PID:3 CPU:20.0% MEM:3.0% DISK_USED:40%
SAMPLES
"$1" '2026-11-01 10:01:00' '2026-11-01 10:02:00' > result
diff - result <<'EXPECTED'
====== STATISTICS REPORT ======
[CPU]
Average: 15.0%
Maximum: 20.0% at 2026-11-01 10:02:00
Minimum: 10.0% at 2026-11-01 10:01:00
[MEM]
Average: 4.0%
Maximum: 5.0% at 2026-11-01 10:01:00
Minimum: 3.0% at 2026-11-01 10:02:00
[DISK_USED]
Average: 35.0%
Maximum: 40.0% at 2026-11-01 10:02:00
Minimum: 30.0% at 2026-11-01 10:01:00
Data Points: 2
EXPECTED
"$1" '2026-11-02 00:00:00' | grep -qx 'Data Points: 0'
REPORT
}
archive_works() {
    runuser -u agent-admin -- env AGENT_LOG_DIR="$TMP_LOG" AGENT_ARCHIVE_DIR="$TMP_LOG/archive" bash -s -- "$H/bin/archive-logs.sh" <<'ARCHIVE'
set -eu
cd "$AGENT_LOG_DIR"
mkdir "$AGENT_ARCHIVE_DIR"
echo old > old.log
touch -d '7 days ago' old.log
touch recent.log
touch -d '6 days ago' recent.log
touch -d '8 days ago' open.log
exec 8>>open.log
touch -d '30 days ago' archive/expired.gz
touch -d '29 days ago' archive/keep.gz
"$1"
"$1"
[[ ! -e old.log && -f recent.log && -f open.log && ! -e archive/expired.gz && -f archive/keep.gz ]]
copies=(archive/old.log.*.gz)
(( ${#copies[@]} == 1 ))
[[ "$(gzip -cd -- "${copies[0]}")" == old ]]
if AGENT_ARCHIVE_DIR="$AGENT_LOG_DIR/missing" "$1"; then exit 1; fi
chmod 500 archive
if "$1"; then exit 1; fi
ARCHIVE
}
c "선택 구간의 평균·최댓값·최솟값·시각·샘플 수가 정확하다" 'report_works'
c "7일 된 로그를 압축하고 30일 된 아카이브만 만료시킨다" 'archive_works'

rm -rf "$TMP_LOG"

printf '\n결과: PASS %d / FAIL %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
EOF
