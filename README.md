# UHDadmin Media Slave

[![Release](https://img.shields.io/github/v/release/fxxkrlab/UHDadmin-media-slave?style=flat-square)](https://github.com/fxxkrlab/UHDadmin-media-slave/releases)
[![License](https://img.shields.io/badge/license-Proprietary-red.svg?style=flat-square)](LICENSE)

[English](#english-version)

**UHDadmin Media Slave** 是 [UHDadmin](https://github.com/fxxkrlab/UHDadmin) 的媒体代理网关组件，基于 **OpenResty (Nginx + Lua)** 构建，为 Emby/Jellyfin 媒体服务器提供访问控制、限流、遥测和并发流管理。

> **版权声明**：本软件为专有商业软件，版权归 Sakakibara 所有。未经授权，禁止用于商业用途。详见 [LICENSE](LICENSE)。

---

## 功能概览

| 功能 | 说明 |
|------|------|
| **访问控制** | 播放器白名单、URI 封禁/跳过、客户端检测 |
| **三层限流** | L1 内存 (shared_dict) + L2 Redis (配额) + L3 PostgreSQL (全局聚合) |
| **Token→User 映射** | 登录拦截 (Plan A) + Sessions API 轮询 (Plan B) |
| **并发流控制** | 跨 Slave 并发流检测、checkin/heartbeat 协调 |
| **遥测上报** | 访问日志、播放会话、设备信息、带宽、拦截日志 → UHDadmin |
| **配置热加载** | 从 UHDadmin 拉取 Lua + Nginx 配置，自动 reload |
| **多服务器代理** | 一个 Slave Docker 代理同主机多个 Emby/Jellyfin 实例 |
| **Fake Counts** | 伪造在线人数拦截 |

---

## 架构图

### Master / Slave 通信

```
┌─────────────────────────────────────────────────────────┐
│                    Emby/Jellyfin 客户端                   │
└──────────────────────────┬──────────────────────────────┘
                           │ 所有请求
                           ▼
┌──────────────────────────────────────────────────────────┐
│              Slave (OpenResty + Lua + Redis)              │
│                                                          │
│  ┌─ Nginx ─────────────────────────────────────────────┐ │
│  │  access_by_lua    → 8 步访问检查链                   │ │
│  │  log_by_lua       → 遥测数据收集                     │ │
│  │  header_filter    → Token 捕获                       │ │
│  │  proxy_pass       → Emby/Jellyfin upstream           │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌─ Lua Agent (init_worker) ───────────────────────────┐ │
│  │  [30s]  拉取配置 → 写 conf → reload nginx            │ │
│  │  [60s]  遥测上报 → 访问日志 + 拦截日志 + Token 报告  │ │
│  │  [300s] 配额同步 → Redis 计数 ↔ UHDadmin             │ │
│  │  [30s]  Token 解析 → Sessions API → Redis 映射       │ │
│  │  [30s]  会话心跳 → PlaySession → UHDadmin             │ │
│  │  [60s]  Agent 心跳 → 状态 + 版本                     │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌─ Redis ─────────────────────────────────────────────┐ │
│  │  配额计数 │ Token→User 映射 │ Enforcement 指令缓存  │ │
│  │  活跃会话 │ 速率限制状态                             │ │
│  └─────────────────────────────────────────────────────┘ │
└──────────────┬───────────────────────────────────────────┘
               │ API 通信 (HTTPS)
               ▼
┌──────────────────────────────────────────────────────────┐
│               UHDadmin Master (FastAPI + PostgreSQL)       │
│                                                          │
│  配置管理 │ 遥测存储 │ 配额聚合 │ 并发流协调 │ 监控面板  │
└──────────────────────────────────────────────────────────┘
```

### 8 步访问检查链

```
请求到达
  │
  ├─ 1. URI 跳过列表 ──────→ 命中 → 直接放行（流媒体等）
  │
  ├─ 2. URI 封禁列表 ──────→ 命中 → 403 拒绝
  │
  ├─ 3. 客户端检测 ────────→ Token→User 映射
  │
  ├─ 4. Redis Enforcement ─→ 封禁/限速指令 → 403/429
  │
  ├─ 5. L1 速率限制 ──────→ shared_dict 令牌桶 → 429
  │
  ├─ 6. L2 Redis 配额 ────→ 请求数/带宽配额 → 403
  │     └─ 6b. 并发流检查 → checkin → 超限 → 403
  │
  ├─ 7. 播放器白名单 ─────→ 未授权客户端 → 403
  │
  └─ 8. Fake Counts ──────→ 拦截人数统计请求
  │
  ▼
放行 → proxy_pass → Emby/Jellyfin
```

### 多服务器配置合并 (v0.2.0+)

```
┌─ UHDadmin Master ───────────────────────────────────────┐
│  Token → Slave(ID=1) → host=192.168.1.100               │
│  → 查同 host 的 Slave [1, 2, 3]                         │
│  → generate_multi_server_config()                        │
│  → rendered_nginx (3 upstream + maps + 3 server block)   │
└──────────────────────────┬──────────────────────────────┘
                           │
                           ▼
┌─ Slave Agent ────────────────────────────────────────────┐
│  收到 rendered_nginx:                                     │
│  1. 写入 server.conf (全部内容)                           │
│  2. 清空 upstream.conf + maps.conf (防重复)               │
│  3. openresty -t && openresty -s reload                  │
└──────────────────────────────────────────────────────────┘
```

---

## 快速开始

### 前置条件

- 已部署 [UHDadmin](https://github.com/fxxkrlab/UHDadmin) 并创建了 Slave Token
- Docker & Docker Compose
- Emby/Jellyfin 媒体服务器运行中

### 1. 获取镜像

```bash
docker pull ghcr.io/fxxkrlab/uhdadmin-media-slave:latest
```

### 2. 配置环境变量

```bash
# 复制示例配置
cp .env.example .env

# 编辑 .env，填入必填项
vim .env
```

**必填项：**

| 变量 | 说明 | 示例 |
|------|------|------|
| `UHDADMIN_URL` | UHDadmin API 地址 | `https://admin.example.com` |
| `APP_TOKEN` | Slave Token（在 UHDadmin 管理面板创建） | `slv_xxxxxxxx` |

### 3. 启动服务

```bash
# Named Volume 模式（推荐，配置由 Agent 自动管理）
docker compose up -d

# 或 Bind Mount 模式（配置文件映射到宿主机）
docker compose -f docker-compose.bind.yml up -d
```

### 4. 验证

```bash
# 检查健康状态
curl http://localhost:8080/health

# 查看日志
docker logs uhd-slave -f
```

---

## Docker Compose 模式

### Named Volume 模式 (`docker-compose.yml`)

配置由 Slave Agent 从 UHDadmin 自动拉取并管理，适合生产部署。

```bash
docker compose up -d
```

### Bind Mount 模式 (`docker-compose.bind.yml`)

所有配置文件（conf/ + lua/）映射到宿主机目录，便于调试和手动修改。

```bash
docker compose -f docker-compose.bind.yml up -d
```

| 特性 | Named Volume | Bind Mount |
|------|:---:|:---:|
| 配置文件可直接编辑 | ❌ | ✅ |
| Agent 自动管理配置 | ✅ | ✅ |
| 适合生产 | ✅ | ⚠️ |
| 适合调试 | ❌ | ✅ |

---

## 环境变量

### 必填

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `UHDADMIN_URL` | UHDadmin API 地址 | `http://localhost:8000` |
| `APP_TOKEN` | Slave 认证 Token | *无* |

### 网络

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `LISTEN_PORT` | HTTPS 监听端口（宿主机映射） | `8443` |
| `LISTEN_HTTP_PORT` | HTTP 监听端口（宿主机映射） | `8080` |

### SSL

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `SSL_CERT_PATH` | SSL 证书路径（宿主机） | `./certs/cert.pem` |
| `SSL_KEY_PATH` | SSL 私钥路径（宿主机） | `./certs/key.pem` |

### Redis

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `REDIS_HOST` | Redis 地址 | `redis`（Docker 内部） |
| `REDIS_PORT` | Redis 端口 | `6379` |
| `REDIS_DB` | Redis 数据库编号 | `0` |
| `REDIS_PASSWORD` | Redis 密码 | *空* |

### Emby/Jellyfin（Token 反向映射 Plan B）

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `EMBY_API_KEY` | Emby/Jellyfin API Key | *空* |
| `EMBY_SERVER_URL` | Emby/Jellyfin 地址 | *空* |

### 定时器间隔（秒）

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `CONFIG_PULL_INTERVAL` | 配置拉取间隔 | `30` |
| `TELEMETRY_FLUSH_INTERVAL` | 遥测上报间隔 | `60` |
| `QUOTA_SYNC_INTERVAL` | 配额同步间隔 | `300` |
| `HEARTBEAT_INTERVAL` | Agent 心跳间隔 | `60` |
| `TOKEN_RESOLVE_INTERVAL` | Token 解析间隔 (Plan B) | `30` |
| `SESSION_HEARTBEAT_INTERVAL` | 会话心跳间隔 | `30` |

---

## 目录结构

```
UHDadmin-media-slave/
├── conf/                           # Nginx 配置
│   ├── nginx.conf                  # 主配置（shared_dict + include）
│   ├── upstream.conf               # Upstream 定义（Agent 自动覆写）
│   ├── maps.conf                   # Nginx Map 变量（Agent 自动覆写）
│   └── server.conf                 # Server Block（Agent 自动覆写）
│
├── lua/                            # Lua 脚本
│   ├── init_worker.lua             # 后台定时器（配置拉取/遥测/配额/心跳）
│   ├── access.lua                  # access_by_lua：8 步访问检查链
│   ├── log_handler.lua             # log_by_lua：遥测数据收集
│   ├── filters/                    # 响应过滤器
│   │   ├── auth_capture_header.lua # header_filter：Token 捕获
│   │   └── auth_capture_body.lua   # body_filter：登录响应提取
│   └── lib/                        # 工具库
│       ├── client_detect.lua       # 客户端检测（UA 解析 + Token 映射）
│       ├── config.lua              # 配置管理（环境变量 + shared_dict）
│       ├── rate_limiter.lua        # L1 限流（令牌桶）
│       ├── redis_store.lua         # Redis 操作封装
│       └── telemetry.lua           # 遥测数据缓冲与上报
│
├── docker-compose.yml              # Named Volume 模式
├── docker-compose.bind.yml         # Bind Mount 模式
├── Dockerfile                      # 镜像构建
├── .env.example                    # 环境变量模板
├── VERSION                         # 版本号
├── CHANGELOG.md                    # 更新日志
└── README.md                       # 本文档
```

---

## GHCR 镜像

### 镜像地址

```
ghcr.io/fxxkrlab/uhdadmin-media-slave
```

### Tag 规范

| Tag | 说明 |
|-----|------|
| `latest` | 最新稳定版本 |
| `stable` | 稳定版本（同 latest） |
| `0.3.0` | 语义化版本号 |

### 拉取命令

```bash
# 最新版本
docker pull ghcr.io/fxxkrlab/uhdadmin-media-slave:latest

# 指定版本
docker pull ghcr.io/fxxkrlab/uhdadmin-media-slave:0.3.0
```

---

## 许可证

**专有商业软件** — 版权归 Sakakibara 所有。未经授权，禁止用于商业用途。详见 [LICENSE](LICENSE)。

---

# English Version

**UHDadmin Media Slave** is the media proxy gateway component of [UHDadmin](https://github.com/fxxkrlab/UHDadmin), built on **OpenResty (Nginx + Lua)**, providing access control, rate limiting, telemetry, and concurrent stream management for Emby/Jellyfin media servers.

For detailed documentation, please refer to the Chinese version above or visit the [GitHub Releases](https://github.com/fxxkrlab/UHDadmin-media-slave/releases) page.

### Quick Start

```bash
# 1. Pull image
docker pull ghcr.io/fxxkrlab/uhdadmin-media-slave:latest

# 2. Configure
cp .env.example .env
# Edit .env: set UHDADMIN_URL and APP_TOKEN

# 3. Start
docker compose up -d

# 4. Verify
curl http://localhost:8080/health
```
