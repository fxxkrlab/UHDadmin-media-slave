# Token 反查 + PlaySession 追踪 + 并发流控制 开发规格

> 创建时间: 2026-02-01
> 状态: 待开发
> 关联版本: UHDadmin-media-slave v0.3.0

---

## 1. 背景

当前 Slave 的 `client_detect.lua` 已能从 Emby 请求头提取 `user_id`，但很多第三方客户端（Infuse、SenPlayer 等）在 `X-Emby-Authorization` 头里只带 `Token`，不带 `UserId`。导致：

- 用户维度的限流/配额形同虚设（`user_id` 经常为 nil）
- 无法准确追踪"谁在看什么"
- 并发流限制无法实现

### 现有提取能力

| 字段 | 提取函数 | 在用？ | 可靠性 |
|------|---------|--------|--------|
| client_ip | ngx.var.remote_addr | 是 | 100% |
| client_name | get_client_name() | 是 | 高 |
| client_version | get_client_version() | 是 | 高 |
| device_id | get_device_id() | 是 | 中（偶尔 nil） |
| user_id | get_user_id() | 是 | **低（经常 nil）** |
| token | get_token() | **否（死代码）** | 高（几乎每个请求都有） |
| device_name | 未提取 | 否 | 头里有但没解析 |
| PlaySessionId | 未提取 | 否 | 串流URL里有 |

---

## 2. Emby 请求流程参考

```
用户登录:
  POST /Users/AuthenticateByName
  请求头: X-Emby-Authorization: MediaBrowser Client="xxx", Device="xxx", DeviceId="xxx", Version="xxx"
  请求体: { "Username": "john", "Pw": "password" }
  响应体: {
    "User": { "Id": "用户GUID", "Name": "john", ... },
    "AccessToken": "64位hex字符串",
    "SessionInfo": { "Id": "session-id", "UserId": "GUID", ... }
  }

后续所有请求都带:
  X-Emby-Authorization: MediaBrowser Client="xxx", Device="xxx", DeviceId="xxx", Version="xxx", Token="64位hex"
  或 X-Emby-Token: 64位hex
  或 ?api_key=64位hex (串流URL)

请求播放:
  POST /Items/{ItemId}/PlaybackInfo?UserId=GUID
  响应: { "MediaSources": [...], "PlaySessionId": "abc123" }

实际串流:
  GET /Videos/{ItemId}/stream.mkv?MediaSourceId=X&PlaySessionId=abc123&api_key=token
  (一次播放会产生大量分片请求，全部带相同 PlaySessionId)

播放上报:
  POST /Sessions/Playing           ← 开始
  POST /Sessions/Playing/Progress  ← 每10秒
  POST /Sessions/Playing/Stopped   ← 停止

监控活跃会话:
  GET /emby/Sessions?api_key=管理token
  返回所有活跃 session，含 UserId、DeviceId、NowPlayingItem 等
```

### Emby vs Jellyfin 差异

| 特性 | Emby | Jellyfin |
|------|------|----------|
| 头前缀 | `Emby` 或 `MediaBrowser` | `MediaBrowser`（两者通常都兼容） |
| Token 头 | `X-Emby-Token` | `X-Emby-Token`（也接受 `Authorization: MediaBrowser Token="..."`) |
| /Users/Me | 不存在 | 存在，可从 Token 直接获取当前用户 |
| 密码字段 | `Pw`（明文） | `Pw`（明文） |

---

## 3. Token → User 映射

### 3.1 方案 A：拦截登录响应（被动，主要来源）

OpenResty 作为反向代理，在 `header_filter_by_lua` + `body_filter_by_lua` 阶段拦截 `POST /Users/AuthenticateByName` 的响应。

```
请求经过 Slave → 转发到 Emby 后端 → Emby 返回响应
                                         ↓
                              body_filter 阶段拦截响应体
                                         ↓
                              解析 JSON: AccessToken + User.Id + User.Name
                                         ↓
                              存入 Redis 缓存 + 标记待上报 UHDadmin
```

**实现要点：**
- 在 `body_filter` 阶段收集响应体 chunks（可能分多次到达）
- 只拦截 status=200 的成功登录
- 解析 JSON 提取 `AccessToken`、`User.Id`、`User.Name`
- 同时提取 `DeviceId`、`Device`（设备名）从请求头中获取
- 写入 Redis: `token_map:{token} → {user_id, username, device_id, device_name, client_name, login_time}`
- TTL: 7 天（Emby Token 默认不过期，但保留合理 TTL 防止无效数据堆积）
- 标记到待上报队列: `token_report:{timestamp}:{random} → {同上数据}`

**需要新建的文件：**
- `lua/filters/auth_capture.lua` — body_filter 逻辑
- 在 `conf/server.conf` 的对应 location 中加入 filter 指令

### 3.2 方案 B：主动查 Emby API（主动，补充来源）

遇到 Token 在 Redis 中查不到映射时，用 Slave 配置的管理 API Key 主动查询。

```
access 阶段:
  token = get_token()
  user_id = redis:get("token_map:" .. token)
  if not user_id then
    -- 标记为待反查，先放行（不阻塞请求）
    -- 或者如果是新 PlaySession 首次请求，同步查
  end

init_worker 后台定时器（新增）:
  每 30 秒扫描待反查 Token 列表
  调 GET /emby/Sessions?api_key=<slave管理token>
  返回所有活跃 session:
  [
    {
      "UserId": "GUID",
      "UserName": "john",
      "Client": "Infuse",
      "DeviceId": "abc",
      "DeviceName": "iPhone",
      "NowPlayingItem": { ... },
      "PlayState": { ... }
    },
    ...
  ]
  批量建立 token → user 映射
```

**注意：**
- 需要 Slave 配置一个 Emby 管理员 API Key（在 .env 中配置）
- `GET /emby/Sessions` 不返回 Token 本身，需要通过 DeviceId 关联
- 对于 Jellyfin，可以用 `GET /Users/Me?api_key=<token>` 直接反查
- 方案 B 主要用于：Slave 重启后缓存丢失、Token 缓存 miss 的情况

### 3.3 数据存储

**Slave 端 Redis：**
```
Key: token_map:{token_hash}    (token 做 SHA256 取前16位作为 key，避免存明文)
Value: JSON {
  "token": "完整token",       (加密存储或明文，取决于安全要求)
  "user_id": "emby-user-guid",
  "username": "john",
  "device_id": "device-guid",
  "device_name": "iPhone 15",
  "client_name": "Infuse",
  "client_version": "7.8.1",
  "login_time": 1738368000,
  "last_seen": 1738368000
}
TTL: 604800 (7天)
```

**UHDadmin PostgreSQL（已有模型可复用）：**
- `SlaveLoginEvent` — 记录登录事件（event_type=login）
- `SlaveDeviceInfo` — 设备注册表（去重）
- 可能需要新增: `SlaveTokenMap` 表，或者复用 `SlaveLoginEvent` + `SlaveDeviceInfo` 的组合

### 3.4 access.lua 中的使用

修改 `access.lua` 的 Step 3（客户端检测）：

```lua
-- 现有代码
local client_name = client_detect.get_client_name()
local client_version = client_detect.get_client_version()
local device_id = client_detect.get_device_id()
local user_id = client_detect.get_user_id()

-- 新增: Token 反查补全 user_id
local token = client_detect.get_token()
if token and not user_id then
    local token_info = redis_store.get_token_map(token)
    if token_info then
        user_id = token_info.user_id
        -- 同时补全可能缺失的 device_id
        if not device_id and token_info.device_id then
            device_id = token_info.device_id
        end
    end
end

-- 存入 ngx.ctx 供 log 阶段使用
ngx.ctx.token = token
ngx.ctx.user_id = user_id
```

---

## 4. PlaySessionId 提取

### 4.1 提取位置

PlaySessionId 出现在两个地方：

1. **串流 URL query 参数**: `GET /Videos/{id}/stream?PlaySessionId=abc123`
2. **PlaybackInfo 响应体**: `POST /Items/{id}/PlaybackInfo` 返回 `{ "PlaySessionId": "abc123" }`

在 `client_detect.lua` 中新增：

```lua
function _M.get_play_session_id()
    local args = ngx.req.get_uri_args()
    return args["PlaySessionId"] or args["playSessionId"]
end
```

同时在 `access.lua` 中提取并存入 `ngx.ctx.play_session_id`。

### 4.2 Session 生命周期

```
1个视频播放 = 1个 PlaySessionId
  - 用户点播 → POST PlaybackInfo → 获得 PlaySessionId
  - 后续所有串流请求 → 同一个 PlaySessionId (几百个分片)
  - 用户暂停/继续 → 同一个 PlaySessionId
  - 用户停止 → PlaySessionId 结束
  - 用户重新播放 → 新的 PlaySessionId

1个用户 N台设备 = N个 PlaySessionId（并发流数 = 活跃 PlaySessionId 数）
```

### 4.3 活跃 Session 追踪（Slave Redis）

```
Key: active_session:{user_id}:{play_session_id}
Value: JSON {
  "slave_id": "slave-001",
  "device_id": "device-guid",
  "device_name": "iPhone",
  "client_name": "Infuse",
  "item_id": "video-item-guid",
  "media_type": "video",
  "started_at": 1738368000,
  "last_seen": 1738368900,
  "bytes_sent": 1234567890
}
TTL: 90 秒（无新请求则自动过期 = session 结束）

每个串流请求到达时:
  1. 刷新 TTL（续命）
  2. 累加 bytes_sent
```

用 Redis SCAN 扫 `active_session:{user_id}:*` 即可获得该用户当前活跃流数。

---

## 5. 并发流控制

### 5.1 单 Slave 场景

```lua
-- access.lua 中，检测到新 PlaySessionId 时
local session_key = "active_session:" .. user_id .. ":" .. play_session_id
local exists = redis:get(session_key)

if not exists then
    -- 新 session，检查并发数
    local pattern = "active_session:" .. user_id .. ":*"
    local active_count = redis_store.count_keys(pattern)
    local max_streams = config.get_max_concurrent_streams(user_id)

    if active_count >= max_streams then
        ngx.status = 429
        ngx.say('{"error": "concurrent stream limit reached"}')
        return ngx.exit(429)
    end
end

-- 注册/刷新 session
redis:setex(session_key, 90, session_data_json)
```

### 5.2 多 Slave 场景（需要 UHDadmin 协调）

```
问题: 用户 A 在 Slave-1 有 1 个流，在 Slave-2 有 1 个流。
      单个 Slave 只看到 1 个，但实际是 2 个。

解决: 新 session 首次出现时，checkin 到 UHDadmin 确认。

流程:
  Slave 检测到新 PlaySessionId
    ↓
  POST /api/v1/slave/sessions/checkin
  Body: {
    "play_session_id": "abc123",
    "user_id": "user-guid",
    "device_id": "device-guid",
    "item_id": "video-guid",
    "client_name": "Infuse"
  }
    ↓
  UHDadmin 查询 slave_realtime_sessions 表:
    SELECT COUNT(*) FROM slave_realtime_sessions
    WHERE emby_user_id = ? AND is_playing = true
    ↓
  返回: {
    "allowed": true/false,
    "active_count": 2,
    "max_allowed": 3,
    "active_sessions": [
      { "session_id": "xxx", "slave_id": "slave-1", "item_name": "电影A" },
      { "session_id": "yyy", "slave_id": "slave-2", "item_name": "电影B" }
    ]
  }
    ↓
  Slave 根据 allowed 决定放行或拒绝
```

**性能保证：**
- 只有新 PlaySessionId 首次出现才 checkin（不是每个分片请求都查）
- checkin 成功后，后续同一 PlaySessionId 的请求直接放行（Redis TTL 续命即可）
- 如果 checkin 网络超时，降级为本地判断（单 Slave 计数）
- 定时心跳（每 30 秒）上报当前活跃 session 列表给 UHDadmin，保持同步

### 5.3 UHDadmin 端 API

```python
# 新增端点

# 1. Session checkin（Slave 调用）
POST /api/v1/slave/sessions/checkin
  → 检查并发数，注册 session，返回 allowed/denied

# 2. Session heartbeat（Slave 定时调用）
POST /api/v1/slave/sessions/heartbeat
  Body: {
    "active_sessions": [
      { "session_id": "abc", "user_id": "guid", "device_id": "guid", ... },
      ...
    ]
  }
  → 批量刷新 last_heartbeat，清理过期 session

# 3. Session 查询（Admin 后台调用）
GET /api/v1/admin/sessions/realtime
  → 返回所有活跃 session（已有 SlaveRealtimeSession 模型）

GET /api/v1/admin/sessions/realtime?user_id=xxx
  → 返回某用户的活跃 session
```

### 5.4 数据模型

**已有模型（可直接使用）：**
- `SlaveRealtimeSession` — 活跃 session 表，字段齐全
- `SlavePlaybackSession` — 完整 session 记录（历史）
- `SlavePlaybackEvent` — session 内事件

**可能需要新增/修改：**

```python
# 在 MediaRateLimitRule 中增加并发流规则类型
# 或者新增独立模型:

class MediaConcurrentStreamRule(Model):
    """并发流限制规则"""
    id = fields.IntField(pk=True)
    service_type = fields.CharField(max_length=20)  # emby / jellyfin
    dimension = fields.CharField(max_length=20)      # user / device / ip
    max_streams = fields.IntField(default=3)
    action_on_exceed = fields.CharField(max_length=20, default="reject")  # reject / queue / kick_oldest
    is_active = fields.BooleanField(default=True)
    priority = fields.IntField(default=0)
    note = fields.TextField(null=True)
    created_at = fields.DatetimeField(auto_now_add=True)

    class Meta:
        table = "media_concurrent_stream_rules"
```

---

## 6. 数据回流到 UHDadmin

### 6.1 Token 映射上报

```
Slave init_worker 定时器 (复用 telemetry flush 时机，每 60 秒):
  扫描 Redis 中新增的 token_map 记录
  POST /api/v1/slave/telemetry/login-events
  Body: {
    "events": [
      {
        "event_type": "login",
        "emby_user_id": "guid",
        "username": "john",
        "device_id": "device-guid",
        "device_name": "iPhone",
        "client_name": "Infuse",
        "client_version": "7.8.1",
        "client_ip": "1.2.3.4",
        "timestamp": "2026-02-01T12:00:00Z"
      }
    ]
  }
  → UHDadmin 写入 SlaveLoginEvent + 更新 SlaveDeviceInfo
```

### 6.2 Session 数据上报

```
Slave init_worker 定时器 (每 30 秒):
  POST /api/v1/slave/sessions/heartbeat
  Body: {
    "active_sessions": [
      {
        "session_id": "PlaySessionId",
        "user_id": "guid",
        "username": "john",
        "device_id": "device-guid",
        "device_name": "iPhone",
        "client_name": "Infuse",
        "item_id": "video-guid",
        "media_name": "电影名称",          // 如果能从请求中获取
        "play_method": "DirectStream",
        "position_ms": 123456,
        "bytes_sent": 1234567890,
        "started_at": "2026-02-01T12:00:00Z"
      }
    ]
  }
  → UHDadmin 更新 SlaveRealtimeSession
  → Session 结束（不再出现在心跳中）时，UHDadmin 写入 SlavePlaybackSession（历史记录）
```

### 6.3 UHDadmin 后台能看到的数据

| 页面 | 数据来源 | 内容 |
|------|---------|------|
| 实时会话 | SlaveRealtimeSession | 谁在看什么，哪台设备，哪个 Slave，进度 |
| 用户活动 | SlaveUserActivity | 每日观看统计 |
| 播放历史 | SlavePlaybackSession | 完整播放记录 |
| 设备管理 | SlaveDeviceInfo | 用户关联的设备列表 |
| 登录记录 | SlaveLoginEvent | 登录/登出事件 |
| 访问日志 | SlaveAccessLog | 逐条请求记录（含 user_id、token） |
| 封禁管理 | MediaQuotaEnforcement | 基于 user/device/ip 的封禁 |

---

## 7. 需要修改的文件清单

### Slave 端（UHDadmin-media-slave）

| 文件 | 操作 | 说明 |
|------|------|------|
| `lua/lib/client_detect.lua` | 修改 | 新增 `get_play_session_id()`、`get_device_name()` |
| `lua/lib/redis_store.lua` | 修改 | 新增 token_map 和 active_session 相关操作 |
| `lua/access.lua` | 修改 | Token 反查补全 user_id、PlaySessionId 提取、并发流检查 |
| `lua/log_handler.lua` | 修改 | 记录 token、play_session_id、刷新 session TTL |
| `lua/init_worker.lua` | 修改 | 新增 Token 反查定时器、session 心跳定时器 |
| `lua/filters/auth_capture.lua` | **新建** | body_filter 拦截登录响应 |
| `conf/server.conf` | 修改 | 登录 location 加 body_filter 指令 |
| `.env.example` | 修改 | 新增 `EMBY_API_KEY`（管理员 token，用于方案 B） |
| `Dockerfile` | 修改 | 新增 `ENV EMBY_API_KEY` |
| `conf/nginx.conf` | 修改 | 新增 `env EMBY_API_KEY;` |

### UHDadmin 端

| 文件 | 操作 | 说明 |
|------|------|------|
| `app/routers/slave/telemetry.py` | 修改 | 新增 login-events 上报端点 |
| `app/routers/slave/sessions.py` | **新建** | session checkin + heartbeat 端点 |
| `app/routers/admin/slave_telemetry.py` | 修改 | 新增实时 session 查询接口 |
| `app/models/media_access.py` | 修改 | 新增 MediaConcurrentStreamRule |
| `migrations/xxx.sql` | **新建** | concurrent_stream_rules 表 |

### 前端（后续 Round）

| 文件 | 操作 | 说明 |
|------|------|------|
| 限流与配额页面 | 修改 | 增加并发流限制规则管理 |
| 实时会话面板 | 修改 | 显示 PlaySessionId、设备名等新字段 |
| 用户详情页 | 修改 | 显示 Token 映射、设备列表 |

---

## 8. 开发顺序

### Phase 1: Token 反查（基础能力）
1. `client_detect.lua` — 新增 `get_play_session_id()`、`get_device_name()`
2. `redis_store.lua` — 新增 `set_token_map()`、`get_token_map()`
3. `lua/filters/auth_capture.lua` — 拦截登录响应（方案 A）
4. `access.lua` — Token 反查补全 user_id
5. `log_handler.lua` — 记录 token
6. `init_worker.lua` — 方案 B 定时反查 + token 上报
7. 配置文件更新（nginx.conf、server.conf、.env、Dockerfile）

### Phase 2: PlaySession 追踪
1. `redis_store.lua` — 新增 active_session 操作
2. `access.lua` — PlaySessionId 提取 + session 注册
3. `log_handler.lua` — session TTL 刷新 + bytes 累加
4. `init_worker.lua` — session 心跳上报

### Phase 3: 并发流控制
1. UHDadmin: `app/routers/slave/sessions.py` — checkin + heartbeat API
2. UHDadmin: `app/models/media_access.py` — MediaConcurrentStreamRule
3. UHDadmin: migration
4. Slave: `access.lua` — 并发流检查逻辑
5. Slave: `init_worker.lua` — session 心跳 + checkin

### Phase 4: 数据上报 + 后台展示
1. UHDadmin: login-events 上报端点
2. UHDadmin: 实时 session 查询增强
3. 前端: 并发流规则管理 UI
4. 前端: 实时 session 面板增强

---

## 9. 配置项

### Slave .env 新增

```bash
# Emby/Jellyfin 管理员 API Key（用于方案 B 主动反查）
# 在 Emby 后台 -> 高级 -> 安全 -> API Key 中生成
EMBY_API_KEY=

# Emby/Jellyfin 服务器内网地址（Slave 直接访问，不走自身代理）
EMBY_SERVER_URL=http://emby:8096

# 并发流检查模式: local（单Slave本地）/ central（通过UHDadmin协调）
CONCURRENT_CHECK_MODE=central

# Token 反查间隔（秒）
TOKEN_RESOLVE_INTERVAL=30

# Session 心跳间隔（秒）
SESSION_HEARTBEAT_INTERVAL=30
```

### UHDadmin 侧配置

并发流规则通过 Admin 后台管理，存 PostgreSQL，Slave 通过 config pull 获取。

---

## 10. 限流/配额 UI 位置决策

### 结论：从媒体访问控制顶部 Tab 移出，放到左侧菜单

**原因：**
- 限流/配额规则存在 PostgreSQL，Slave 通过 `GET /media-slave/config` 的 `rate_limit_config` 拉取
- 不参与 lua/nginx 配置生成（不走 配置向导 → 快照 流程）
- 是运行时规则，改了下次 Slave 拉取时立即生效
- 与配置向导是不同的心智模型

**新菜单结构：**
```
左侧菜单:
媒体服务/
├── 访问控制配置    ← Tabs: [基础数据] [配置向导] [已保存配置]
├── 限流与配额      ← 单独页面: 速率限制 + 带宽配额 + 并发流规则
└── Slave 管理      ← Slave 列表、状态、配置分发
```
