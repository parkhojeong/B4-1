#!/bin/bash
# 계정과 디렉터리를 구성한 B4-1 실습 컨테이너에서 스크립트와 cron을 갱신한다.
set -euo pipefail
cd "$(dirname "$0")/.."
docker_cmd=(docker --context "${B4_DOCKER_CONTEXT:-orbstack}" exec -i "${B4_CONTAINER:-b4-1}")
stage=$("${docker_cmd[@]}" mktemp -d)
trap '"${docker_cmd[@]}" rm -rf -- "$stage"' EXIT
for source in required/monitor.sh bonus/report.sh bonus/archive-logs.sh; do
    script=${source##*/}
    "${docker_cmd[@]}" sh -c 'cat > "$1"' sh "$stage/$script" < "$source"
done

"${docker_cmd[@]}" bash -s -- "$stage" <<'INNER'
set -euo pipefail
stage=$1
bin=/home/agent-admin/agent-app/bin
profile=/etc/profile.d/agent-app.sh
# 체크리스트 2-3 · agent-dev 소유, agent-core 읽기·실행. 아래에서 agent-admin의 crontab에 등록한다.
for script in monitor.sh report.sh archive-logs.sh; do
    install -o agent-dev -g agent-core -m 750 "$stage/$script" "$stage/$script.ready"
    mv -fT "$stage/$script.ready" "$bin/$script"
done
sed -i 's|^export AGENT_KEY_PATH=.*$|export AGENT_KEY_PATH=$AGENT_HOME/api_keys/t_secret.key|' "$profile"
install -d -m 2750 -o agent-admin -g agent-core /var/log/monitor/agent-app/archive

if ! crontab -u agent-admin -l > "$stage/cron" 2>"$stage/cron.err"; then
    grep -qx 'no crontab for agent-admin' "$stage/cron.err" || { cat "$stage/cron.err" >&2; exit 1; }
fi
for job in "* * * * * $bin/monitor.sh >/dev/null 2>&1" "15 0 * * * $bin/archive-logs.sh"; do
    grep -qxF "$job" "$stage/cron" || echo "$job" >> "$stage/cron"
done
crontab -u agent-admin "$stage/cron"
INNER
