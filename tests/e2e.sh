#!/usr/bin/env bash
# 端到端测试：依赖本地已构建的 qvgz/compose-bluegreen:latest，运行时会拉取 alpine 和 nginx 镜像
set -u

work=$(mktemp -d "${TMPDIR:-/tmp}/cbg-e2e.XXXXXX") || exit 1
cd "$work" || exit 1
fail=0

# shellcheck disable=SC2329 # 由 EXIT trap 调用。
cleanup() {
    docker compose --env-file .env.prod --profile '*' down -t 0 >/dev/null 2>&1
    cd / && [ -n "$work" ] && rm -rf -- "$work"
}
trap cleanup EXIT

mkdir -p conf.d/upstream
cat >compose.yaml <<'E'
x-app: &app
  command:
    - sh
    - -c
    - 'echo app-started; while :; do { printf "HTTP/1.0 200 OK\r\n\r\n"; cat /etc/alpine-release; } | nc -l -p 8080 >/dev/null; done'
  healthcheck:
    # 3.19 视为不健康的版本
    test: ["CMD-SHELL", "! grep -q ^3.19 /etc/alpine-release"]
    interval: 1s
    retries: 2
    timeout: 1s
    start_period: 0s
services:
  nginx:
    image: nginx:alpine
    volumes:
      - ./conf.d:/etc/nginx/conf.d
  app-blue:
    <<: *app
    image: alpine:${APP_TAG_BLUE}
    profiles: [blue]
  app-green:
    <<: *app
    image: alpine:${APP_TAG_GREEN}
    profiles: [green]
E
printf 'APP_TAG_BLUE=3.20\nAPP_TAG_GREEN=3.20\n' >.env.prod
cat >conf.d/default.conf <<'E'
resolver 127.0.0.11 valid=10s ipv6=off;
include /etc/nginx/conf.d/upstream/*.conf;
server {
    listen 80;
    location / {
        proxy_pass http://app_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }
}
E
cat >conf.d/upstream/app.conf <<'E'
upstream app_backend {
    zone app_backend 64k;
    server app-blue:8080 resolve;
    keepalive 32;
}
E

compose() { docker compose --env-file .env.prod "$@"; }
deploy() {
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$work:$work" -w "$work" -e DRAIN_SECONDS="${DRAIN:-1}" -e WAIT_TIMEOUT=15 \
        qvgz/compose-bluegreen:latest "$@" >"$work/${LOG:-deploy.log}" 2>&1
}
wait_log() {
    local _
    for _ in $(seq 1 100); do
        grep -q "$2" "$work/$1" 2>/dev/null && return 0
        sleep 0.3
    done
    return 1
}
body() {
    local _ out
    for _ in 1 2 3 4 5; do
        out=$(compose exec -T nginx wget -qO- http://127.0.0.1/ 2>/dev/null) && [ -n "$out" ] && {
            printf '%s\n' "$out" | cut -d. -f1-2
            return
        }
        sleep 1
    done
    echo none
}
state() {
    local cid
    cid=$(compose ps -aq "$1" 2>/dev/null)
    if [ -n "$cid" ]; then docker inspect -f '{{.State.Status}}' "$cid"; else echo none; fi
}
check() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1 = $3"
    else
        echo "FAIL $1：期望 $2，实际 $3"
        tail -20 "$work/deploy.log" 2>/dev/null
        fail=1
    fi
}
color() { grep -oE 'app-(blue|green)' conf.d/upstream/app.conf; }

compose up -d >/dev/null 2>&1
compose up -d --wait --wait-timeout 30 --no-deps app-blue >/dev/null 2>&1
compose exec -T nginx nginx -s reload >/dev/null 2>&1
check 初始流量 3.20 "$(body)"

echo "--- 正常发布：blue -> green"
deploy app 3.21
check 退出码 0 "$?"
check 当前颜色 app-green "$(color)"
check 流量 3.21 "$(body)"
check 旧颜色 exited "$(state app-blue)"
check 环境文件 APP_TAG_GREEN=3.21 "$(grep GREEN .env.prod)"

echo "--- 镜像不存在：不切流"
deploy app no-such-tag
check 退出码 1 "$?"
check 当前颜色 app-green "$(color)"
check 流量 3.21 "$(body)"

echo "--- 健康检查失败：不切流，停掉空闲颜色"
deploy app 3.19
check 退出码 1 "$?"
check 当前颜色 app-green "$(color)"
check 流量 3.21 "$(body)"
check 空闲颜色 exited "$(state app-blue)"
check 环境文件未写 APP_TAG_BLUE=3.20 "$(grep BLUE .env.prod)"
check 容器日志 app-started "$(cat logs/app-blue-3.19-*.log 2>/dev/null)"

echo "--- 配置检查失败：恢复 upstream"
echo 'invalid_directive;' >conf.d/broken.conf
deploy app 3.22
check 退出码 1 "$?"
check 当前颜色 app-green "$(color)"
check 空闲颜色 exited "$(state app-blue)"
check 环境文件未写 APP_TAG_BLUE=3.20 "$(grep BLUE .env.prod)"
rm -f conf.d/broken.conf
check 流量 3.21 "$(body)"

echo "--- 再次发布：green -> blue"
deploy app 3.22
check 退出码 0 "$?"
check 当前颜色 app-blue "$(color)"
check 流量 3.22 "$(body)"
check 旧颜色 exited "$(state app-green)"

echo "--- 回滚：blue(3.22) -> green(3.21)，保存日志后删除 blue"
deploy app --rollback
check 退出码 0 "$?"
check 当前颜色 app-green "$(color)"
check 流量 3.21 "$(body)"
check 新颜色容器 running "$(state app-green)"
check 旧颜色容器已删除 none "$(state app-blue)"
check 旧颜色日志 app-started "$(grep -hm1 app-started logs/app-blue-3.22-*.log 2>/dev/null)"
check 环境文件未改 "APP_TAG_BLUE=3.22,APP_TAG_GREEN=3.21" "$(paste -sd, .env.prod)"

echo "--- 回滚目标不健康：不切流，当前颜色不动"
sed -i 's/^APP_TAG_BLUE=.*/APP_TAG_BLUE=3.19/' .env.prod
deploy app --rollback
check 退出码 1 "$?"
check 当前颜色 app-green "$(color)"
check 流量 3.21 "$(body)"
check 当前颜色容器 running "$(state app-green)"
check 回滚目标容器 exited "$(state app-blue)"

echo "--- 回滚后继续发布：green -> blue"
deploy app 3.22
check 退出码 0 "$?"
check 当前颜色 app-blue "$(color)"
check 流量 3.22 "$(body)"

echo "--- 排空窗口内回滚：发布不停止正在服务的颜色"
LOG=drain-deploy.log DRAIN=6 deploy app 3.21 &
deploy_pid=$!
wait_log drain-deploy.log 切流
LOG=drain-rollback.log DRAIN=9 deploy app --rollback &
rollback_pid=$!
wait "$deploy_pid"
check 发布退出码 0 "$?"
check 回滚后流量 3.22 "$(body)"
check 发布未停止当前颜色 running "$(state app-blue)"
wait "$rollback_pid"
check 回滚退出码 0 "$?"
check 当前颜色 app-blue "$(color)"
check 流量 3.22 "$(body)"
check 当前颜色容器 running "$(state app-blue)"
check 旧颜色容器已删除 none "$(state app-green)"

echo "--- 锁冲突：立即失败"
docker run --rm -v "$work:$work" -w "$work" --entrypoint sh qvgz/compose-bluegreen:latest \
    -c 'exec 9>.compose-bluegreen-app.lock; flock 9; touch locked; sleep 5' &
lock_pid=$!
until [ -f locked ]; do sleep 0.2; done
deploy app 3.21
check 退出码 1 "$?"
check 当前颜色 app-blue "$(color)"
check 环境文件未写 APP_TAG_GREEN=3.21 "$(grep GREEN .env.prod)"
wait "$lock_pid"

echo "--- 输入校验：不改变状态"
deploy app $'3.21\nb@d tag'
check 多行标签退出码 1 "$?"
check 多行标签提示 1 "$(grep -c 'TAG 不合法' deploy.log)"
DRAIN=abc deploy app 3.21
check 非法排空时间退出码 1 "$?"
check 非法排空时间提示 1 "$(grep -c 'DRAIN_SECONDS 不合法' deploy.log)"
check 当前颜色 app-blue "$(color)"
check 流量 3.22 "$(body)"

echo "--- 环境文件标签带引号：可以回滚"
sed -i 's/^APP_TAG_GREEN=.*/APP_TAG_GREEN="3.21"/' .env.prod
deploy app --rollback
check 退出码 0 "$?"
check 当前颜色 app-green "$(color)"
check 流量 3.21 "$(body)"

[ "$fail" -eq 0 ] && echo 全部通过 || echo 存在失败
exit "$fail"
