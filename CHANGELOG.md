# 更新日志 / Changelog

[English Version](#english-version)

---

## v0.3.0 (2026-02-03)

### 📦 发布基础设施 + 文档完善

#### GHCR 镜像发布
- 新增 GitHub Actions release 工作流 — tag 推送自动构建并推送 GHCR 镜像
- 镜像标签：`latest`、`stable`、语义版本号（如 `0.3.0`）
- 镜像地址：`ghcr.io/fxxkrlab/uhdadmin-media-slave`

#### Docker Compose 双模式
- **Named Volume 模式** (`docker-compose.yml`)：使用 GHCR 镜像，配置内置容器，适合生产部署
- **Bind Mount 模式** (`docker-compose.bind.yml`)：所有配置文件映射到宿主机目录，适合调试和自定义

#### 文档
- 新增 `README.md` — 项目介绍、架构图、安装教程、环境变量说明
- 新增 `CHANGELOG.md` — 版本更新日志
- 新增 `VERSION` 文件 — 语义化版本号

---

## v0.2.1 (2026-02-03)

### 🐛 Nginx 配置文件冲突修复

- **问题**：`nginx.conf` 分别 include `upstream.conf`、`maps.conf`、`server.conf`，但 Agent 将合并的 `rendered_nginx`（包含 upstream + maps + server blocks）全部写入 `server.conf`，导致 upstream/map 重复定义，Nginx reload 失败
- **修复**：Agent 写入 `server.conf` 时同时清空 `upstream.conf` 和 `maps.conf`

---

## v0.2.0 (2026-02-03)

### 🌐 多服务器配置拉取 + 自动 Reload

- Agent (`init_worker.lua`) 支持从 UHDadmin 拉取 `rendered_nginx`（多服务器合并配置）
- 拉到新配置后自动写入 `server.conf` 并执行 `openresty -t && openresty -s reload`
- 仅在配置内容变化时写入文件和 reload，避免无意义重启

---

## v0.1.0 (2026-02-02)

### 🚀 Token→User 反向映射 + PlaySession 追踪 + 并发流控制

- **Plan A: 登录拦截** — `auth_capture_body.lua` 拦截 Emby/Jellyfin 登录响应，提取 Token + UserId + DeviceId
- **Plan B: Sessions API** — 定时轮询 `/Sessions` API 建立 DeviceId → UserId 映射
- **PlaySession 追踪** — 从 URL 提取 PlaySessionId，Redis 维护活跃会话（TTL=90s 心跳）
- **并发流控制** — `POST /sessions/checkin` + `POST /sessions/heartbeat` 跨 Slave 协调
- **L2 Redis 配额** — 持久化配额计数（请求数 + 带宽），Enforcement 指令缓存

---

## v0.0.1 (2026-02-01)

### 🎉 初始版本

- OpenResty + Lua 媒体代理网关
- 8 步访问检查链：URI 跳过 → URI 封禁 → 客户端检测 → Redis Enforcement → L1 限流 → L2 配额 → 白名单 → Fake Counts
- 配置从 UHDadmin API 拉取（30s 间隔）
- 遥测批量上报（访问日志、拦截日志、Token 报告）
- L1 速率限制（Nginx shared_dict，令牌桶 + burst）
- Redis 存储层（配额、Enforcement、Token 映射）
- 健康检查端点 `/health`

---

# English Version

> For English documentation, please refer to the [GitHub Releases](https://github.com/fxxkrlab/UHDadmin-media-slave/releases) page.
