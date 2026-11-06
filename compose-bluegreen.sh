#!/bin/sh
# Compose 蓝绿发布：新版本健康后，改 upstream 并 reload 切流
set -eu

[ "$#" -eq 2 ] || {
    echo "用法：compose-bluegreen <NAME> <TAG>|--rollback" >&2
    exit 2
}
name=$1
tag=$2
rollback=0
[ "$tag" != --rollback ] || rollback=1
env_file=${ENV_FILE:-.env.prod}
upstream_file=${UPSTREAM_FILE:-conf.d/upstream/$name.conf}
proxy=${PROXY_SERVICE:-nginx}
proxy_cmd=${PROXY_CMD:-nginx}
wait_timeout=${WAIT_TIMEOUT:-60}
drain_seconds=${DRAIN_SECONDS:-30}

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $*"; }
die() {
    log "失败 $*" >&2
    exit 1
}
compose() { docker compose --env-file "$env_file" "$@"; }

# 写回原文件，保留 inode、属主和权限。
rewrite() {
    sed "$2" "$1" >"$1.tmp" && cat "$1.tmp" >"$1" && rm -f "$1.tmp"
}

# 读取环境文件中的变量，重复定义取最后一个。
env_value() {
    sed -n "s/^$1=//p" "$env_file" | tail -n 1 | tr -d "\"'\r"
}

# 把容器日志保存到项目目录：save_logs <服务> <标签>
save_logs() {
    saved_log=$PWD/logs/$1-$2-$(date +%Y%m%d%H%M%S).log
    cid=$(compose ps -aq "$1" || :)
    if [ -n "$cid" ] && mkdir -p "$PWD/logs" && docker logs "$cid" >"$saved_log" 2>&1; then
        log "容器日志 $saved_log"
    else
        log "容器日志保存失败 $1" >&2
        return 1
    fi
}

case "$name" in
    '' | *[!a-z0-9-]* | [!a-z]*) die "NAME 不合法：$name" ;;
esac
case "$drain_seconds" in
    '' | *[!0-9]*) die "DRAIN_SECONDS 不合法：$drain_seconds" ;;
esac
[ -f "$env_file" ] || die "环境文件不存在：$env_file"
[ -f "$upstream_file" ] || die "upstream 文件不存在：$upstream_file"

# 同一项目同时只允许一个发布或回滚修改状态，冲突立即失败。
exec 9>"$PWD/.compose-bluegreen-$name.lock"
flock -n 9 || die "另一个发布或回滚正在修改状态，请稍后重试"

# 当前颜色只以 upstream 文件为准。
blue=$(grep -c "$name-blue" "$upstream_file" || :)
green=$(grep -c "$name-green" "$upstream_file" || :)
if [ "$blue" -gt 0 ] && [ "$green" -eq 0 ]; then
    active=blue idle=green
elif [ "$green" -gt 0 ] && [ "$blue" -eq 0 ]; then
    active=green idle=blue
else
    die "无法从 $upstream_file 判断当前颜色"
fi

idle_service=$name-$idle
active_service=$name-$active
tag_var=$(echo "${name}_TAG_$idle" | tr 'a-z-' 'A-Z_')
grep -q "^$tag_var=" "$env_file" || die "$env_file 中不存在变量：$tag_var"

# 回滚目标是环境文件中记录的空闲颜色标签。
[ "$rollback" -eq 0 ] || tag=$(env_value "$tag_var")
case "$tag" in
    '' | *[!A-Za-z0-9_.-]* | [.-]*) die "TAG 不合法：$tag" ;;
esac
[ "${#tag}" -le 128 ] || die "TAG 不合法：$tag"

log "开始 $active_service -> $idle_service:$tag"

# 拉取失败时容器和流量都未变化。回滚优先用本地镜像，缺失时由 up 拉取。
if [ "$rollback" -eq 0 ]; then
    env "$tag_var=$tag" docker compose --env-file "$env_file" pull "$idle_service" ||
        die "$idle_service:$tag 拉取失败"
fi

if ! env "$tag_var=$tag" docker compose --env-file "$env_file" \
    up -d --wait --wait-timeout "$wait_timeout" --no-deps "$idle_service"; then
    # 下次发布会重建容器，先保存日志。
    save_logs "$idle_service" "$tag" || :
    compose stop "$idle_service" || :
    die "$idle_service:$tag 启动或健康检查失败，流量未切换"
fi

if ! rewrite "$upstream_file" "s/$active_service/$idle_service/g"; then
    compose stop "$idle_service" || :
    die "$upstream_file 改写失败，流量未切换"
fi
if ! compose exec -T "$proxy" "$proxy_cmd" -t ||
    ! compose exec -T "$proxy" "$proxy_cmd" -s reload; then
    rewrite "$upstream_file" "s/$idle_service/$active_service/g" || :
    compose stop "$idle_service" || :
    die "$proxy 配置检查或 reload 失败，流量未切换"
fi
log "切流 $active_service -> $idle_service:$tag"

# 切流成功后才保存标签，回滚读取的始终是正式上线过的版本。
if [ "$rollback" -eq 0 ]; then
    rewrite "$env_file" "s/^$tag_var=.*/$tag_var=$tag/" ||
        die "$env_file 保存失败，流量已切到 $idle_service，$active_service 未停止"
fi

# 等旧 worker 处理完请求，再停旧颜色。等待期间不持锁，允许回滚。
flock -u 9
sleep "$drain_seconds"
flock 9

# 等待期间流量可能已被回滚或新发布改变，此时旧颜色可能正在服务，不能停止。
if ! grep -q "$idle_service" "$upstream_file"; then
    log "流量已不在 $idle_service，不停止 $active_service"
    exit 0
fi
compose stop "$active_service" || die "$active_service 停止失败，流量已切到 $idle_service"

if [ "$rollback" -eq 1 ]; then
    # 日志保存失败时保留容器，避免丢失排查依据。
    active_var=$(echo "${name}_TAG_$active" | tr 'a-z-' 'A-Z_')
    save_logs "$active_service" "$(env_value "$active_var")" ||
        die "$active_service 未删除，流量已切到 $idle_service"
    compose rm -f "$active_service" || die "$active_service 删除失败，流量已切到 $idle_service"
fi
log "成功 $idle_service:$tag"
