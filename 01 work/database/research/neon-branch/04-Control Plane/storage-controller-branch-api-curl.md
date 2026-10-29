---
title: Storage Controller Branch API 与 curl 命令总表
aliases:
  - Storage Controller Branch API
  - Neon Timeline curl 速查表
tags: [数据库, Neon, Storage-Controller, Branch, API]
created: 2026-10-27
updated: 2026-10-29
---

# Storage Controller Branch API 与 curl 命令总表

本文只讨论 Branch：创建、PITR、查询、删除、Reset，以及 Branch 绑定 Compute。假定 `tenant_id` 已存在，不展开 Project、Tenant 或产品表结构。

> [!important]
> Storage Controller 和存储内核只识别 `tenant_id`、`timeline_id`、`ancestor_timeline_id` 和 LSN，不识别 `branch_name`。上层管控负责把 `main`、`dev` 等名称解析成 `timeline_id`。

## 1. Branch 功能总表

| Branch 功能 | Storage Controller 能力 | 支持状态 | 上层还需负责 |
|---|---|---|---|
| 创建根 Branch | 创建 Bootstrap Timeline | 直接支持 | 给 Timeline 注册 `main` 等名称 |
| 从父 Branch 当前状态创建 | 创建带 `ancestor_timeline_id` 的 Timeline | 直接支持 | 解析父 Branch 名、保存新名称映射 |
| 创建多层子 Branch | Timeline 可继续作为其他 Timeline 的祖先 | 直接支持 | 维护名称映射 |
| 按指定 LSN 创建 | 设置 `ancestor_start_lsn` | 直接支持 | 选择、校验并保护目标 LSN |
| 按时间创建 PITR Branch | 时间转 LSN，再创建 Timeline | 组合支持 | 编排两次调用并注册 Branch 名称 |
| 列出 Branch | 列出 Timeline | 透传支持 | 将 TimelineId 转回 Branch 名称 |
| 查询 Branch 详情 | 查询 TimelineInfo | 透传支持 | 补充名称、默认和保护属性 |
| 查询父节点与分叉点 | 返回 `ancestor_timeline_id`、`ancestor_lsn` | 透传支持 | 可实时查询，无需重复保存 |
| 删除 Branch | 删除 Timeline | 直接支持 | 检查保护、默认、子分支和 Compute，再清理名称映射 |
| Rename Branch | 无底层变化 | 不支持 | 只修改名称映射 |
| 设置默认 Branch | 无底层概念 | 不支持 | 上层保存默认分支 |
| 设置保护 Branch | 无底层概念 | 不支持 | 上层拦截删除、Reset、Rename |
| Reset Branch | 没有产品级 Reset API | 组合支持 | 创建替代 Timeline、切换映射、重配 Compute、回收旧 Timeline |
| Branch TTL/自动过期 | 无产品级 TTL | 不支持 | 上层定时触发删除 Workflow |
| Archive/Unarchive | 修改 Timeline archival 状态 | 直接支持 | 产品权限和状态展示 |
| Detach Ancestor | 断开真实 Timeline 祖先依赖 | 直接支持 | 高风险操作审批与审计 |
| Block/Unblock GC | 控制 Timeline GC | 直接支持 | 只作为内部运维能力 |
| Branch 绑定 Compute | 提供 Pageserver/Safekeeper 路由 | 部分支持 | 保存绑定并创建 Compute |
| Primary/Read Replica Compute | 无 Compute 生命周期 API | 不支持 | Compute Orchestrator |
| Compute 自动休眠/唤醒 | 无 | 不支持 | Proxy + Compute Orchestrator |

支持状态含义：**直接支持**是明确 REST API；**透传支持**是 Storage Controller 路由到 Pageserver；**组合支持**需要上层编排；**不支持**表示必须由上层实现。

## 2. 命令环境

```bash
export SC_URL="http://127.0.0.1:1234"
export TENANT_ID="你的tenant_id"

export ROOT_TIMELINE_ID="$(openssl rand -hex 16)"
export DEV_TIMELINE_ID="$(openssl rand -hex 16)"
export PARENT_TIMELINE_ID="${ROOT_TIMELINE_ID}"
export NEW_TIMELINE_ID="$(openssl rand -hex 16)"
export PITR_TIMELINE_ID="$(openssl rand -hex 16)"

export TARGET_TIMESTAMP="2026-10-27T10:00:00+08:00"
export TARGET_LSN="0/1680000"
export SAFEKEEPER_ID="1"
```

启用 JWT 时，在命令中增加：`-H "Authorization: Bearer ${STORCON_JWT}"`。

### 2.1 通用入参与响应约定

| 项目 | 格式 | 说明 |
|---|---|---|
| `tenant_id` | 32 位十六进制字符串 | 产品层通常把 Project 映射到 Tenant；Storage Controller 接口只接收 ID，不接收 Project 名称 |
| `timeline_id` | 32 位十六进制字符串 | Branch 对应的底层 ID；不能把 `dev`、`main` 等 Branch 名直接传给这些接口 |
| `ancestor_timeline_id` | 32 位十六进制字符串 | 创建子 Branch 时指定父 Timeline |
| LSN | PostgreSQL LSN，例如 `0/1680000` | 表示 WAL/数据库历史中的位置 |
| 时间 | RFC 3339，例如 `2026-10-27T10:00:00+08:00` | PITR 的时间输入；建议始终携带时区 |
| JSON 请求 | `Content-Type: application/json` | 有 Body 的 `POST`/`PUT` 请求必须设置 |
| 鉴权 | `Authorization: Bearer ...` | 是否需要以及 Token scope 取决于部署配置 |
| 空成功响应 | HTTP `200`，Body 为 `null` | Rust 的单位值 `()` 经 JSON 序列化后的结果；不要把 `null` 当成失败 |
| 错误响应 | 以 HTTP 状态码为准 | `curl --fail-with-body` 会返回非零退出码，同时保留服务端错误 Body |

下面的“出参”按当前仓库源码定义整理。可选字段以及新版本追加的字段，应按向前兼容方式解析，不要因为出现未知字段就失败。

常见失败状态码：`400` 表示参数或状态不合法，`401/403` 表示 Token 或 scope 不满足，`404` 表示 Tenant/Timeline/节点不存在，`406` 可能表示祖先归档等创建前置条件不满足，`409` 表示操作冲突或异步删除仍在进行，`503` 通常表示调度迁移期间暂不可用。调用方应记录响应 Body，并只对 `409`、`503` 等可重试错误采用有上限的退避重试。

## 3. Branch 创建命令表

| 功能 | 方法与路径 | `curl` 命令 | 说明 |
|---|---|---|---|
| 创建根 Branch 对应的 Timeline | `POST /v1/tenant/{tenant_id}/timeline` | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" -H "Content-Type: application/json" -d "{\"new_timeline_id\":\"${ROOT_TIMELINE_ID}\",\"pg_version\":16}"` | 祖先字段为 `null`；上层将它命名为 `main` |
| 从父 Branch 当前状态创建 | 同上 | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" -H "Content-Type: application/json" -d "{\"new_timeline_id\":\"${DEV_TIMELINE_ID}\",\"ancestor_timeline_id\":\"${PARENT_TIMELINE_ID}\",\"read_only\":false}"` | 不传 `ancestor_start_lsn`，Pageserver 选择分叉点 |
| 从 `dev` 创建子 Branch | 同上 | `export CHILD_TIMELINE_ID="$(openssl rand -hex 16)"; curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" -H "Content-Type: application/json" -d "{\"new_timeline_id\":\"${CHILD_TIMELINE_ID}\",\"ancestor_timeline_id\":\"${DEV_TIMELINE_ID}\",\"read_only\":false}"` | 支持多层祖先关系 |
| 指定 LSN 创建 Branch | 同上 | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" -H "Content-Type: application/json" -d "{\"new_timeline_id\":\"${NEW_TIMELINE_ID}\",\"ancestor_timeline_id\":\"${PARENT_TIMELINE_ID}\",\"ancestor_start_lsn\":\"${TARGET_LSN}\",\"read_only\":false}"` | 应先校验父 Timeline 的可读范围 |

### 3.1 创建接口入参

四条创建命令调用的是同一个接口，差别只在 JSON Body：

| 参数位置 | 字段 | 必填 | 类型/示例 | 含义 |
|---|---|---:|---|---|
| Path | `tenant_id` | 是 | `${TENANT_ID}` | 新 Timeline 所属 Tenant |
| Body | `new_timeline_id` | 是 | `${DEV_TIMELINE_ID}` | 调用方生成的新 Timeline ID；Storage Controller 不会替该请求自动生成 |
| Body | `ancestor_timeline_id` | 子 Branch 必填 | `${PARENT_TIMELINE_ID}` | 父 Branch 对应的 Timeline ID；根 Timeline 不传 |
| Body | `ancestor_start_lsn` | 否 | `0/1680000` | 指定分叉点；省略时由 Pageserver 在父 Timeline 上选择分叉位置 |
| Body | `pg_version` | 根 Timeline 建议显式传 | `16` | 根 Timeline 的 PostgreSQL 主版本；子 Timeline 继承父 Timeline，兼容性上仍允许携带该字段 |
| Body | `read_only` | 否 | `false` | Branch 模式字段，默认 `false`；不是“保护 Branch”，也不代表产品层只读权限 |

Body 的模式由字段组合决定：只有 `new_timeline_id` 加可选 `pg_version` 是 **Bootstrap 根 Timeline**；出现 `ancestor_timeline_id` 是 **Branch 子 Timeline**。

### 3.2 创建接口出参

- 状态码：`201 Created`。
- Body：`TimelineCreateResponseStorcon`，即一份 `TimelineInfo`，外加可选的 `safekeepers`。下面是响应节选，实际还会带有 5.2 节列出的其他字段。

```json
{
  "tenant_id": "<tenant-shard-id>",
  "timeline_id": "<new-timeline-id>",
  "ancestor_timeline_id": "<parent-timeline-id-or-null>",
  "ancestor_lsn": "0/1680000",
  "last_record_lsn": "0/1680000",
  "pg_version": 16,
  "state": "Active",
  "safekeepers": {
    "tenant_id": "<tenant-id>",
    "timeline_id": "<new-timeline-id>",
    "generation": 1,
    "safekeepers": [{"id": 1, "hostname": "host:port"}]
  }
}
```

`safekeepers` 可以是 `null`，取决于 Storage Controller 是否启用了将 Timeline 放置到 Safekeeper，以及该创建模式。其余 Timeline 字段见 5.2 节。

## 4. PITR Branch 命令表

| 功能 | 方法与路径 | `curl` 命令 | 说明 |
|---|---|---|---|
| 时间转 LSN | `GET .../get_lsn_by_timestamp` | `curl --fail-with-body -sS -G "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${PARENT_TIMELINE_ID}/get_lsn_by_timestamp" --data-urlencode "timestamp=${TARGET_TIMESTAMP}" --data-urlencode "with_lease=true"` | 时间使用 RFC3339；返回 `lsn`、`kind` 和可选 Lease |
| 建立 LSN Lease | `POST .../lsn_lease` | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${PARENT_TIMELINE_ID}/lsn_lease" -H "Content-Type: application/json" -d "{\"lsn\":\"${TARGET_LSN}\"}"` | 在 PITR 或静态 Compute 使用该点前保护 LSN |
| 创建 PITR Branch | `POST /v1/tenant/{tenant_id}/timeline` | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" -H "Content-Type: application/json" -d "{\"new_timeline_id\":\"${PITR_TIMELINE_ID}\",\"ancestor_timeline_id\":\"${PARENT_TIMELINE_ID}\",\"ancestor_start_lsn\":\"${TARGET_LSN}\",\"read_only\":false}"` | 成功后上层注册 Branch 名称 |

组合执行：

```bash
export TARGET_LSN="$(
  curl --fail-with-body -sS -G \
    "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${PARENT_TIMELINE_ID}/get_lsn_by_timestamp" \
    --data-urlencode "timestamp=${TARGET_TIMESTAMP}" \
    --data-urlencode "with_lease=true" |
  jq -r '.lsn'
)"
```

然后使用表中的“创建 PITR Branch”命令。

### 4.1 时间转 LSN：入参与出参

`GET .../get_lsn_by_timestamp` 是 Storage Controller 的通用 GET 透传接口：它把请求路由到 Tenant 的 shard 0 Pageserver。

| 参数位置 | 字段 | 必填 | 类型/取值 | 含义 |
|---|---|---:|---|---|
| Path | `tenant_id` | 是 | Tenant ID | 所属 Tenant |
| Path | `timeline_id` | 是 | 父 Timeline ID | 在哪条 Timeline 上查找时间点 |
| Query | `timestamp` | 是 | RFC 3339 | 目标时间，必须 URL 编码 |
| Query | `with_lease` | 否 | `true`/`false`，默认 `false` | 是否顺便尝试为结果 LSN 建立临时 Lease |

成功返回 `200`：

```json
{
  "lsn": "0/1680000",
  "kind": "present",
  "valid_until": "2026-10-29T09:31:00.000Z"
}
```

| 返回字段 | 含义 |
|---|---|
| `lsn` | Pageserver 根据时间找到的 LSN |
| `kind` | `present`、`future`、`past` 或 `nodata`；分别表示时间点位于现有历史中、晚于现有历史、早于现有历史，或缺少足够数据完成精确匹配 |
| `valid_until` | 仅在 `with_lease=true` 且 Lease 建立成功时出现；RFC 3339 到期时间。请求了 Lease 也可能不返回此字段，因此调用方必须按可选字段处理 |

不要只检查 `lsn`：创建 PITR Branch 前还应检查 `kind` 是否符合产品语义，并确认 LSN 不早于可读边界。

### 4.2 显式 LSN Lease：入参与出参

| 参数位置 | 字段 | 必填 | 类型/示例 | 含义 |
|---|---|---:|---|---|
| Path | `tenant_id` | 是 | Tenant ID | 所属 Tenant |
| Path | `timeline_id` | 是 | Timeline ID | 要保护哪条 Timeline 的历史 |
| Body | `lsn` | 是 | `0/1680000` | 暂时阻止 GC 使该 LSN 失效 |

当前 Storage Controller 会在所有 shard 上申请 Lease，并在内部计算最早到期时间；但 HTTP handler 没有把这个 `valid_until` 返回给调用方。成功响应是：

```http
HTTP/1.1 200 OK
Content-Type: application/json

null
```

如果上层必须拿到 `valid_until`，可优先使用 `get_lsn_by_timestamp?with_lease=true` 的返回值，或者在自建管控中补充 Storage Controller handler 的返回结构。Lease 是临时的，默认时长取决于 Pageserver 配置，不能当作永久保留策略。

### 4.3 创建 PITR Branch 的入参与出参

它仍是第 3 节的创建 Timeline 接口：把时间转换得到的 `lsn` 放入 `ancestor_start_lsn`。成功返回 `201` 和 `TimelineCreateResponseStorcon`；上层随后保存 `branch_name → new_timeline_id` 映射。

## 5. Branch 查询命令表

| 功能 | 方法与路径 | `curl` 命令 | 说明 |
|---|---|---|---|
| 列出所有 Timeline | `GET /v1/tenant/{tenant_id}/timeline` | `curl --fail-with-body -sS "${SC_URL}/v1/tenant/${TENANT_ID}/timeline"` | 不返回 Branch 名称，上层按 TimelineId 补充 |
| 查询单个 Branch 对应的 Timeline | `GET /v1/tenant/{tenant_id}/timeline/{timeline_id}` | `curl --fail-with-body -sS "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}"` | 返回父节点、分叉 LSN、当前 LSN、大小、版本和状态 |
| 查询所有 shard | `GET /control/v1/tenant/{tenant_id}/timeline/{timeline_id}` | `curl --fail-with-body -sS "${SC_URL}/control/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}"` | 返回 `shards[]`，通常要求高权限 Token |

常用字段过滤：

```bash
curl --fail-with-body -sS \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}" |
jq '{timeline_id, ancestor_timeline_id, ancestor_lsn,
     min_readable_lsn, last_record_lsn, pg_version, state}'
```

### 5.1 三个查询接口的入参与出参

| 接口 | 入参 | 成功出参 | 路由行为 |
|---|---|---|---|
| `GET /v1/tenant/{tenant_id}/timeline` | Path：`tenant_id`；可选 Query：`include-non-incremental-logical-size`、`force-await-initial-logical-size`、`include-image-consistent-lsn`，均为布尔值 | `200`，`TimelineInfo[]` | 通用 GET 透传到 shard 0；不是跨 shard 聚合 |
| `GET /v1/tenant/{tenant_id}/timeline/{timeline_id}` | Path：`tenant_id`、`timeline_id`；可选 Query 同上 | `200`，单个 `TimelineInfo` | 通用 GET 透传到 shard 0 |
| `GET /control/v1/tenant/{tenant_id}/timeline/{timeline_id}` | Path：`tenant_id`、`timeline_id`；无 Query/Body | `200`，`{"shards":[TimelineInfo...],"image_consistent_lsn":"..."}` | Storage Controller 并发查询所有 shard 后聚合；需要 `Scrubber` scope |

三个可选 Query 的含义：

| Query 参数 | 默认值 | 作用与代价 |
|---|---:|---|
| `include-non-incremental-logical-size` | `false` | 计算并返回非增量逻辑大小，可能增加查询成本 |
| `force-await-initial-logical-size` | `false` | 等待初始逻辑大小计算完成，可能显著增加响应时间 |
| `include-image-consistent-lsn` | `false` | 请求返回 `image_consistent_lsn`；属于当前代码中的扩展字段 |

### 5.2 `TimelineInfo` 返回字段

创建、列表和详情接口都复用该结构。常用字段如下：

| 字段 | 类型 | 含义 |
|---|---|---|
| `tenant_id` | TenantShardId | Pageserver 上的 Tenant shard 标识；未分片环境看起来接近 Tenant ID |
| `timeline_id` | TimelineId | 当前 Branch 的底层 Timeline ID |
| `ancestor_timeline_id` | TimelineId 或 `null` | 父 Timeline；根 Timeline 为 `null` |
| `ancestor_lsn` | LSN 或 `null` | 从父 Timeline 分叉的位置；根 Timeline 为 `null` |
| `last_record_lsn` | LSN | 当前已处理到的最新 WAL 位置 |
| `prev_record_lsn` | LSN 或 `null` | 前一条 WAL record 的位置 |
| `min_readable_lsn` | LSN | 当前允许创建 Branch、静态 Compute 或读取历史的最早常规边界；选 PITR 点优先看它 |
| `applied_gc_cutoff_lsn` | LSN | GC 已应用的 cutoff；不建议用它代替 `min_readable_lsn` 做 Branch 合法性判断 |
| `disk_consistent_lsn` | LSN | 本地磁盘一致性位置 |
| `remote_consistent_lsn` | LSN | 已成功上传到远端存储的位置 |
| `remote_consistent_lsn_visible` | LSN | 对 Safekeeper 公布的远端一致性位置 |
| `initdb_lsn` | LSN | 根 Timeline 的初始化位置 |
| `current_logical_size` | 字节数 | 当前逻辑数据量 |
| `current_logical_size_is_accurate` | bool | 上述逻辑大小是否准确 |
| `current_physical_size` | 字节数或 `null` | Layer 文件物理大小；Timeline 未加载时可能是 `null` |
| `current_logical_size_non_incremental` | 字节数或 `null` | 请求非增量计算时返回的逻辑大小 |
| `pitr_history_size` | 字节数 | 当前 Timeline 的 PITR 窗口所覆盖的 WAL 历史量 |
| `within_ancestor_pitr` | bool | 分叉点是否仍在祖先自己的 PITR 窗口内；`false` 可能意味着该 Branch 迫使祖先额外保留 Layer |
| `pg_version` | 整数 | PostgreSQL 主版本 |
| `state` | `Loading`/`Active`/`Stopping`/`Broken` | Pageserver 内存中的 Timeline 状态；`Broken` 还包含原因和 backtrace |
| `is_archived` | bool 或 `null` | 是否已归档；兼容旧版本所以是可选字段 |
| `is_invisible` | bool 或 `null` | 是否在 synthetic size 计算中隐藏 |
| `image_consistent_lsn` | LSN 或缺省 | 已被 image layer 覆盖的一致性位置；只有支持且请求时才可能出现 |
| `wal_source_connstr`、`walreceiver_status`、`last_received_msg_lsn`、`last_received_msg_ts` | 多种 | WAL receiver 的来源及接收状态 |
| `directory_entries_counts`、`timeline_dir_layer_file_size_sum` | 多种 | Timeline 目录和 Layer 文件统计 |

`GET /control/...` 的 `shards[]` 中每项都是一份 `TimelineInfo`。`image_consistent_lsn` 是 Storage Controller 对各 shard 结果计算出的聚合值；如果不可用会省略。

## 6. Branch 删除与高级命令表

| 功能 | 人话解释与使用场景 | `curl` 命令 | 关键影响与注意事项 |
|---|---|---|---|
| 删除 Timeline | **把这个 Branch 对应的底层 Timeline 数据真正删掉**，不是只删 Branch 名称。用于确定不再需要该 Branch 时。 | `curl --fail-with-body -i -X DELETE "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}"` | 应先停掉或迁走 Compute，并检查默认分支、保护策略和子分支。完成返回 `200`；处理未完成可能返回 `409`，稍后重试。删除通常不可恢复。 |
| Archive（归档） | **把长期不用、但暂时不想删除的 Branch 标为冷数据。** Pageserver 不再把它当作正常活跃 Timeline 管理，后续可将数据 offload 到远端存储并释放本地缓存。 | `curl --fail-with-body -sS -X PUT "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}/archival_config" -H "Content-Type: application/json" -d '{"state":"Archived"}'` | 归档只是改变生命周期状态，不等于删除、保护分支或制作一份完整备份。一般不能直接供活跃 Compute 使用；存在活跃后代 Timeline 时还会受到祖先/后代状态约束。 |
| Unarchive（取消归档） | **把冷藏的 Branch 重新激活**，让 Timeline 回到可以正常加载和使用的状态。用于重新启用历史 Branch。 | `curl --fail-with-body -sS -X PUT "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}/archival_config" -H "Content-Type: application/json" -d '{"state":"Unarchived"}'` | 如果数据已经 offload，重新启用时可能要从远端下载，首次访问会比较慢。它不是 PITR 恢复；归档祖先与后代之间还要满足状态约束。 |
| Detach 并重挂子 Timeline | **让目标 Timeline 不再依赖原祖先，同时自动调整相关子 Timeline 的祖先关系。** 常见目的，是保留后代 Branch，但为删除或清理旧祖先创造条件。 | `curl --fail-with-body -sS -X PUT "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}/detach_ancestor?detach_behavior=no_ancestor_and_reparent"` | 会物化目标 Timeline 所依赖的历史并改写存储层祖先关系，可能耗时、占空间，而且不能简单撤销；该模式只适用于接口要求的祖先拓扑。不是 Branch reset。 |
| Detach 多层祖先且不重挂 | **一次切断目标 Timeline 对多层祖先的依赖，但不替其他子 Timeline 自动改父关系。** 主要用于特殊迁移或存储拓扑修复。 | `curl --fail-with-body -sS -X PUT "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}/detach_ancestor?detach_behavior=multi_level_and_no_reparent"` | 比普通 Detach 更容易影响既有分支树，应只由理解 Timeline 拓扑的运维程序使用。它改变的是底层祖先依赖，不是修改产品层 Branch 名称。 |
| Block GC（暂停历史回收） | **临时告诉 Pageserver：先别回收这条 Timeline 的旧历史数据。** 可在维护、迁移或必须保留某段历史依赖时使用。 | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}/block_gc"` | 只阻止 GC 清理历史，不阻止删除 Timeline，也不是“保护分支”。长期阻塞会使存储持续增长，操作完成后应及时解除。 |
| Unblock GC（恢复历史回收） | **撤销上面的暂停，让 Pageserver 继续正常清理过旧历史。** 在维护或迁移完成后使用。 | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}/unblock_gc"` | 解除后，一旦 GC 推进，被清理的旧历史通常无法再读回；执行前要确认已没有 PITR、分支创建或祖先依赖需要这些历史。 |

最容易混淆的几个概念可以这样记：

| 概念 | 一句话区分 |
|---|---|
| Branch protection | 产品管控层的删除策略：**不允许用户误删这个 Branch**。Storage Controller 本身不保存这个产品策略。 |
| Archive | Timeline 生命周期管理：**数据先留着，但按长期不用的冷数据处理**。 |
| Block GC | 历史保留开关：**Timeline 还正常存在，只是暂时不回收它的旧历史**。 |
| Detach ancestor | 存储依赖改造：**把 Timeline 对祖先历史的依赖切断或改写**。 |
| Delete | 物理删除：**真正移除 Branch 对应的 Timeline 数据**。 |

### 6.1 删除与高级接口的精确入参与出参

| 功能/接口 | Path 入参 | Query 或 Body 入参 | 成功出参 | 重要状态码/行为 |
|---|---|---|---|---|
| 删除 Timeline | `tenant_id`、`timeline_id` | 无 | `200` + `null` | Storage Controller 轮询 Pageserver/Safekeeper 的异步删除；约 25 秒仍未完成时返回 `409`，调用方应稍后重试 |
| Archive/Unarchive | `tenant_id`、`timeline_id` | JSON Body：`state` 只能是精确大小写的 `Archived` 或 `Unarchived` | `200` + `null` | 非法状态为 `400`；祖先/后代归档约束不满足时请求会失败 |
| Detach ancestor | `tenant_id`、`timeline_id` | Query：`detach_behavior` 可省略，默认 `no_ancestor_and_reparent`；也可传 `multi_level_and_no_reparent` | `200` + `{"reparented_timelines":["..."]}` | 数组列出这次被自动重挂的 Timeline ID；第二种模式通常返回空数组，因为它不执行重挂 |
| Block GC | `tenant_id`、`timeline_id` | 无 | `200` + `null` | 作用于该 Tenant 的全部 shard；不是删除保护 |
| Unblock GC | `tenant_id`、`timeline_id` | 无 | `200` + `null` | 作用于该 Tenant 的全部 shard；解除后 GC 可以继续推进 |

Detach 的兼容别名 `v1`、`v2` 在当前源码中分别对应上述两种模式，但新程序应使用完整名称，避免语义不清。

删除前，上层至少检查保护状态、默认分支、子分支和绑定 Compute；删除成功后再清理名称映射。

## 7. Branch Reset

Storage Controller 没有单独 Reset 接口。正确流程：

```text
解析 Reset 目标 Timeline/LSN
  → 创建替代 Timeline
  → 将原 Branch 名切换到替代 timeline_id
  → 重建或重配绑定 Compute
  → 无引用后删除旧 Timeline
```

Storage Controller 只负责创建替代 Timeline 和删除旧 Timeline。

## 8. Branch 绑定 Compute

| 功能 | 方法与路径 | `curl` 命令 | 用途 |
|---|---|---|---|
| 查询 Pageserver 路由 | `GET /debug/v1/tenant/{tenant_id}/locate` | `curl --fail-with-body -sS "${SC_URL}/debug/v1/tenant/${TENANT_ID}/locate"` | 返回 shard 的 PG/gRPC/HTTP 地址和 stripe size |
| 查询 Timeline 的 Safekeeper 集合 | `GET /debug/v1/tenant/{tenant_id}/timeline/{timeline_id}/locate` | `curl --fail-with-body -sS "${SC_URL}/debug/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}/locate"` | 返回 `generation`、`sk_set`、`new_sk_set` |
| 列出 Safekeeper | `GET /control/v1/safekeeper` | `curl --fail-with-body -sS "${SC_URL}/control/v1/safekeeper"` | 用 ID 补全 Safekeeper 地址 |
| 查询单个 Safekeeper | `GET /control/v1/safekeeper/{id}` | `curl --fail-with-body -sS "${SC_URL}/control/v1/safekeeper/${SAFEKEEPER_ID}"` | 返回地址和调度状态 |

### 8.1 路由查询接口的入参与出参

| 接口 | 入参 | 成功出参 | 权限与用途 |
|---|---|---|---|
| Tenant locate | Path：`tenant_id` | `{"shards":[...],"shard_params":{"count":N,"stripe_size":N}}` | `Admin` scope；Compute Orchestrator 用它确定每个 shard 所在 Pageserver |
| Timeline locate | Path：`tenant_id`、`timeline_id` | `{"generation":N,"sk_set":[1,2,3],"new_sk_set":null}` | `Admin` scope；确定 Timeline 当前 Safekeeper membership；迁移中 `new_sk_set` 可能非空 |
| Safekeeper list | 无 Path/Query/Body | `SafekeeperDescribeResponse[]` | `Infra` scope；列出所有已注册 Safekeeper |
| Safekeeper detail | Path：整数 `id` | 单个 `SafekeeperDescribeResponse` | `Infra` scope；未知 ID 返回 `404` |

Tenant locate 的 `shards[]` 每项字段：

| 字段 | 含义 |
|---|---|
| `shard_id` | TenantShardId |
| `node_id` | 承载该 shard 的 Pageserver 节点 ID |
| `listen_pg_addr`、`listen_pg_port` | Compute 连接 Pageserver page service 的地址与端口 |
| `listen_grpc_addr`、`listen_grpc_port` | 可选 gRPC 地址与端口 |
| `listen_http_addr`、`listen_http_port`、`listen_https_port` | Pageserver 管理接口地址与端口 |
| `shard_params.count` | Tenant shard 数 |
| `shard_params.stripe_size` | 数据 striping 参数，不是 Compute 规格 |

Safekeeper list/detail 的返回字段：

| 字段 | 含义 |
|---|---|
| `id` | Safekeeper 节点 ID，与 `sk_set` 中的值对应 |
| `region_id`、`availability_zone_id` | 区域和可用区标识 |
| `version` | 节点上报的发布版本数字 |
| `host`、`port` | Safekeeper WAL 服务地址 |
| `http_port`、`https_port` | 管理接口端口；HTTPS 可能为 `null` |
| `scheduling_policy` | `Active`、`Activating`、`Pause` 或 `Decomissioned` |

例如，管控可以先从 Timeline locate 得到 `sk_set: [1,2,3]`，再用 Safekeeper list 按 `id` 找出这三个节点的 `host:port`。

```text
Branch 名 → timeline_id
             ├── tenant locate → Pageserver 路由
             └── timeline locate → Safekeeper generation/sk_set
                                      ↓
                              Compute Orchestrator
                                      ↓
                              compute_ctl/Postgres
```

本地 Compute 命令不是 Storage Controller REST API：

| 功能 | 本地命令 | 说明 |
|---|---|---|
| Endpoint 绑定到 `dev` | `./target/debug/neon_local endpoint create dev-compute --tenant-id "${TENANT_ID}" --branch-name dev --pg-version 16` | 从本地 Branch 映射解析 TimelineId |
| 启动 Endpoint | `./target/debug/neon_local endpoint start dev-compute` | 查询存储路由并启动 `compute_ctl` |
| 列出 Endpoint | `./target/debug/neon_local endpoint list --tenant-id "${TENANT_ID}"` | 本地 Endpoint 状态 |
| 停止 Endpoint | `./target/debug/neon_local endpoint stop dev-compute` | 不删除 Timeline 或 Branch 映射 |
| 销毁 Endpoint | `./target/debug/neon_local endpoint stop dev-compute --destroy` | 只删除本地 Compute 数据 |

## 9. Neon/Lakebase 已测试、但 Storage Controller 不包含的 Branch 能力

| 已测试能力 | 不包含原因 | 应由谁实现 |
|---|---|---|
| Branch 名称和独立 Branch UID | 内核只识别 TimelineId | Control Plane |
| Rename Branch | 不改变 Timeline 数据 | Control Plane |
| 默认 Branch | 内核没有 `main` 语义 | Control Plane |
| 保护 Branch | 属于产品操作策略 | Control Plane |
| Branch Reset | 是创建、切换、重配、删除的组合流程 | Control Plane Workflow |
| Branch TTL/临时分支清理 | Storage Controller 不保存过期时间 | Control Plane Scheduler |
| Endpoint 与 Branch 的产品绑定 | Storage Controller 不管理 Compute | Control Plane |
| Endpoint 创建、启停、删除、规格调整 | 属于 Pod/VM/ECS 生命周期 | Compute Orchestrator |
| 自动休眠和连接唤醒 | 依赖连接流量与运行状态 | Proxy + Compute Orchestrator |
| Read Replica | 是同一 Timeline 上的另一种 Compute 模式 | Compute Orchestrator |
| Branch 独立连接串和密码 | 属于接入、认证和密钥管理 | Proxy/Auth/Secret Manager |
| Branch 权限、配额、审计和幂等 | 不属于存储内核 | Control Plane |

## 10. 源码依据

- `storage_controller/src/http.rs`：路由、Path/Query 解析、权限 scope、HTTP 状态码及空响应
- `storage_controller/src/service.rs`：Timeline 创建/删除、跨 shard 调用、LSN Lease 聚合
- `storage_controller/src/service/safekeeper_service.rs`：Safekeeper membership 与 Timeline 删除
- `pageserver/src/http/routes.rs`：GET 透传接口、时间转 LSN、`TimelineInfo` 查询的实际行为
- `libs/pageserver_api/src/models.rs`：`TimelineCreateRequest`、`TimelineInfo`、`LsnLease`、Archive 和 Detach 数据结构
- `libs/pageserver_api/src/models/detach_ancestor.rs`：Detach 响应 `AncestorDetached`
- `libs/pageserver_api/src/controller_api.rs`：Tenant locate、全 shard describe、Safekeeper 返回结构
- `libs/safekeeper_api/src/models.rs`：Timeline locate 返回结构
- `control_plane/src/bin/neon_local.rs`
- `control_plane/src/endpoint.rs`
- `storage_controller/src/compute_hook.rs`
