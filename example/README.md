# 示例项目

用 `compose-bluegreen` 发布的完整 Compose 项目。应用镜像 `qvgz/health-app`：`v1` 健康，`v2` 健康检查失败。

| 文件 | 作用 |
|---|---|
| `compose.yaml` | Nginx 和 `app-blue`、`app-green` 两个服务 |
| `.env.prod` | 两个颜色的标签，发布时写回 |
| `conf.d/default.conf` | 入口配置 |
| `conf.d/upstream/app.conf` | 当前颜色，发布时改写 |

## 首次部署

```bash
docker compose --env-file .env.prod up -d --wait --no-deps app-blue
docker compose --env-file .env.prod up -d
curl -i http://127.0.0.1/health
```

## 发布

```bash
# 成功：切到另一个颜色
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:$PWD" -w "$PWD" \
  qvgz/compose-bluegreen:latest app v1

# 失败：v2 健康检查不通过，退出码 1，流量不变
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:$PWD" -w "$PWD" \
  qvgz/compose-bluegreen:latest app v2
```

## 回滚

健康检查通过、已切流后发现逻辑错误时执行：

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:$PWD" -w "$PWD" \
  qvgz/compose-bluegreen:latest app --rollback
```

## 注意事项

- 先启动当前颜色，再启动 Nginx。顺序反过来时，请求会挂起数秒才恢复（实测 `valid=3s` 约 2 秒，`valid=10s` 约 9 秒）。
- `conf.d` 要挂载目录，不要挂单个文件，否则改写后容器可能读不到新内容。
- 蓝绿服务用 `profiles`，普通 `up -d` 不会拉起已停止的旧颜色。
- 全部下线用 `docker compose --env-file .env.prod --profile '*' down`。普通 `down` 不处理蓝绿服务。
- `server ... resolve` 需要 Nginx 1.27.3 及以上。
- 发布会改动 `.env.prod` 和 `conf.d/upstream/app.conf`，二者在 Git 中会显示为已修改。
