# compose-bluegreen

Compose + Nginx 蓝绿发布：启动空闲颜色，健康后改 upstream 并 `reload` 切流，等待后停旧颜色。

完整项目示例见 [example/README.md](example/README.md)。

## 使用

在 Compose 项目目录执行，`app` 为服务名前缀，`v2` 为新标签：

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:$PWD" -w "$PWD" \
  qvgz/compose-bluegreen:latest app v2
```

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `ENV_FILE` | `.env.prod` | 标签所在的环境文件 |
| `UPSTREAM_FILE` | `conf.d/upstream/<NAME>.conf` | 切流时改写的文件 |
| `PROXY_SERVICE` | `nginx` | 入口的 Compose 服务名 |
| `PROXY_CMD` | `nginx` | 入口容器内执行 `-t` 和 `-s reload` 的命令 |
| `WAIT_TIMEOUT` | `60` | 等待健康的秒数 |
| `DRAIN_SECONDS` | `30` | 切流后停旧颜色前的等待秒数 |
| `TZ` | `Asia/Shanghai` | 日志时区 |

用 `docker run -e` 传入。

## 回滚

已切流后发现逻辑错误时，把 `v2` 换成 `--rollback`：

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:$PWD" -w "$PWD" \
  qvgz/compose-bluegreen:latest app --rollback
```

以当前为 blue 为例：

1. 从 upstream 文件确定当前颜色，从环境文件读取 `APP_TAG_GREEN`。
2. 启动 green 并等待健康，然后改 upstream 并 `reload`。
3. 等待 `DRAIN_SECONDS` 后停止 blue，日志保存到 `$PWD/logs`，再删除 blue。

- 回滚不改环境文件，`APP_TAG_BLUE` 仍是有问题的版本，下次发布时会被覆盖。
- 不要连续回滚两次，第二次会按该标签重建有问题的版本。
- green 启动或健康检查失败时不切流，blue 继续服务。
- blue 日志保存失败时，不删除已停止的 blue，退出码 1。

## 项目约定

以 `NAME=app` 为例：

- 服务名为 `app-blue`、`app-green`，都配置 healthcheck。
- 环境文件中有 `APP_TAG_BLUE`、`APP_TAG_GREEN`。
- `conf.d/upstream/app.conf` 中只出现当前颜色的服务名。
- 标签必须不可变，每个版本用唯一标签。回滚只认标签名，`latest`、`prod` 这类标签重新推送后回滚不到旧版本，命令仍会返回 0。

## 失败行为

| 失败环节 | 结果 |
|---|---|
| 拉取镜像 | 容器和流量不变 |
| 启动或健康检查 | 容器日志保存到 `$PWD/logs/<服务>-<标签>-<时间>.log`（目录不存在时自动创建），停空闲颜色，流量不变，标签不写回 |
| 改写 upstream | 停空闲颜色，流量不变，标签不写回 |
| 配置检查或 `reload` | 恢复 upstream，停空闲颜色，流量不变，标签不写回 |
| 写回标签 | 退出码 1，流量已切到新颜色，旧颜色不停止 |
| 停旧颜色 | 退出码 1，流量已切到新颜色 |
| 另一个发布或回滚正在修改状态 | 退出码 1，容器和流量不变，稍后重试 |

## 注意事项

- 容器内外路径必须一致（`-v "$PWD:$PWD"`），否则相对挂载路径和项目名会出错。
- 容器拥有宿主机 Docker 的完整权限。
- 拉取私有镜像需加 `-v ~/.docker/config.json:/root/.docker/config.json:ro`。
- 服务没有 healthcheck 时，启动后才崩溃的情况发现不了。
- 新旧版本会短暂并存，并共用数据库等依赖，变更要兼容两个版本。
- `DRAIN_SECONDS` 等待期间不持锁，可以回滚；等待结束时流量已不在本次的新颜色上，就不停止旧颜色，退出码 0。
- 锁文件为 `$PWD/.compose-bluegreen-<NAME>.lock`，不要删除，只对同一台主机上的同一目录有效。
- 切流后不做验证。

## 测试

```bash
docker build -t qvgz/compose-bluegreen:latest .
tests/e2e.sh
```
