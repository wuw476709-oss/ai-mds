---
title: Storage Controller Branch 命令开发手册
aliases:
  - Storage Controller Branch API 命令
  - SC Timeline curl 手册
tags: [数据库, Neon, Storage-Controller, Branch, Timeline, API]
created: 2026-10-29
updated: 2026-10-29
---

# Storage Controller Branch 命令开发手册

本文只整理**直接发送给 Neon Storage Controller 的命令**，供管控开发人员调用和调试。

本文不讨论：

- Project 与 `tenant_id` 的对应关系；
- Branch UID、Branch 名称与 `timeline_id` 的对应关系；
- 管控数据库表结构；
- Compute endpoint 的创建、绑定和生命周期。

在 Storage Controller/Pageserver 中，产品层 Branch 对应底层 Timeline。所以下文用“创建 Branch”描述产品意图，但实际接口参数只包含 `tenant_id`、`timeline_id`、`ancestor_timeline_id`、时间和 LSN。

> [!important]
> Storage Controller 不接受 Project 名、Branch 名或 Branch UID。调用本文命令前，调用方必须已经拿到 `tenant_id` 和相关 `timeline_id`。

## 0. 环境变量与通用约定

```bash
export SC_URL="http://127.0.0.1:1234"
export STORCON_JWT="<storage-controller-jwt>"

export TENANT_ID="<32位十六进制tenant-id>"
export TIMELINE_ID="<32位十六进制timeline-id>"
export PARENT_TIMELINE_ID="<32位十六进制parent-timeline-id>"

export TARGET_TIMESTAMP="2026-10-29T09:30:00+08:00"
```

生成新的 Timeline ID：

```bash
export NEW_TIMELINE_ID="$(openssl rand -hex 16)"
```

启用 JWT 的部署，在请求中增加：

```bash
-H "Authorization: Bearer ${STORCON_JWT}"
```

如果本地 `neon_local` 没有启用 JWT，可以删除该 Header。

### 通用参数

| 参数 | 格式 | 说明 |
|---|---|---|
| `tenant_id` | 32 位十六进制字符串 | Storage Controller 的 Tenant ID |
| `timeline_id` | 32 位十六进制字符串 | Timeline ID；创建时由调用方生成，SC 不自动生成 |
| `ancestor_timeline_id` | 32 位十六进制字符串 | 父 Timeline ID |
| LSN | PostgreSQL LSN，例如 `0/1680000` | Timeline 历史中的 WAL 位置 |
| timestamp | RFC 3339 | 必须包含 `Z` 或明确时区，例如 `+08:00` |

### 通用响应规则

| 情况 | 行为 |
|---|---|
| 成功但无返回对象 | HTTP `200`，JSON Body 通常为 `null` |
| 参数不合法 | 通常为 `400` |
| Tenant/Timeline 不存在 | 通常为 `404` |
| 状态冲突或删除仍在进行 | 通常为 `409` |
| 调度迁移或节点暂不可用 | 通常为 `503`，调用方应退避重试 |

所有示例使用 `--fail-with-body`：非 2xx 时 `curl` 返回非零退出码，但仍打印服务端错误 Body。

## 功能总表

| 功能 | Storage Controller 支持情况 | SC 实现方式 |
|---|---|---|
| 1.1 创建根 Branch | 支持 | 创建 Bootstrap Timeline |
| 1.2 不指定 LSN 创建 Branch | 支持 | 创建子 Timeline，不传 `ancestor_start_lsn` |
| 1.3 按指定时间创建 Branch | 组合支持 | 时间转 LSN + Lease + 创建子 Timeline |
| 2. 删除 Branch | 支持 | 删除 Timeline，并协调 Pageserver/Safekeeper |
| 3. 查询 Branch | 支持 | 查询 Timeline 列表、详情或所有 shard |
| 4. Reset Branch | 无单接口，组合支持 | 创建替代 Timeline；旧 Timeline 是否删除由调用方判断 |
| 5. 设置保护 Branch | 不支持 | SC 没有产品级保护属性 |
| 6. 设置默认 Branch | 不支持 | SC 没有默认 Timeline 概念 |

---

## 1. 创建 Branch

三个创建场景最终都使用：

```http
POST /v1/tenant/{tenant_id}/timeline
```

区别在 JSON Body，以及按时间创建前是否需要先查询 LSN。

### 1.1 创建根 Branch

根 Branch 在底层是没有祖先的 Bootstrap Timeline。

#### 完整 `curl`

```bash
export ROOT_TIMELINE_ID="$(openssl rand -hex 16)"

curl --fail-with-body -sS -X POST \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" \
  -H "Authorization: Bearer ${STORCON_JWT}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg new_timeline_id "${ROOT_TIMELINE_ID}" \
    '{new_timeline_id:$new_timeline_id, pg_version:16}')"
```

#### 入参

| 位置 | 字段 | 必填 | 类型/示例 | 说明 |
|---|---|---:|---|---|
| Path | `tenant_id` | 是 | `${TENANT_ID}` | Timeline 所属 Tenant |
| Body | `new_timeline_id` | 是 | 32 位十六进制 | 调用方生成的新 Timeline ID |
| Body | `pg_version` | 建议必填 | `16` | PostgreSQL 主版本 |
| Body | `ancestor_timeline_id` | 否 | 不传 | 根 Timeline 没有祖先 |
| Body | `ancestor_start_lsn` | 否 | 不传 | 根 Timeline 没有分叉点 |

#### 成功出参

状态码：`201 Created`。

响应是 `TimelineCreateResponseStorcon`：完整 `TimelineInfo` 加可选 `safekeepers`。响应节选：

```json
{
  "tenant_id": "<tenant-shard-id>",
  "timeline_id": "<root-timeline-id>",
  "ancestor_timeline_id": null,
  "ancestor_lsn": null,
  "last_record_lsn": "0/1680000",
  "min_readable_lsn": "0/1680000",
  "pg_version": 16,
  "state": "Active",
  "is_archived": false,
  "safekeepers": null
}
```

调用方至少校验：

- `timeline_id == ROOT_TIMELINE_ID`；
- `ancestor_timeline_id == null`；
- `ancestor_lsn == null`；
- `pg_version` 符合预期；
- `state == Active`。

`safekeepers` 是否为 `null` 取决于 Storage Controller 配置和部署模式。

---

### 1.2 不指定 LSN 创建 Branch

该场景表达“从父 Timeline 当前可用位置创建子 Timeline”。调用方不传 `ancestor_start_lsn`，Pageserver 选择实际分叉点。

#### 完整 `curl`

```bash
export NEW_TIMELINE_ID="$(openssl rand -hex 16)"

curl --fail-with-body -sS -X POST \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" \
  -H "Authorization: Bearer ${STORCON_JWT}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg new_timeline_id "${NEW_TIMELINE_ID}" \
    --arg ancestor_timeline_id "${PARENT_TIMELINE_ID}" \
    '{new_timeline_id:$new_timeline_id,
      ancestor_timeline_id:$ancestor_timeline_id,
      read_only:false}')"
```

#### 入参

| 位置 | 字段 | 必填 | 类型/示例 | 说明 |
|---|---|---:|---|---|
| Path | `tenant_id` | 是 | Tenant ID | 新旧 Timeline 必须属于该 Tenant |
| Body | `new_timeline_id` | 是 | 32 位十六进制 | 新 Timeline ID |
| Body | `ancestor_timeline_id` | 是 | 32 位十六进制 | 父 Timeline ID |
| Body | `ancestor_start_lsn` | 否 | 此场景不传 | 由 Pageserver 选择实际分叉位置 |
| Body | `read_only` | 否 | `false` | 默认 `false`；不是产品层“保护分支” |
| Body | `pg_version` | 否 | `16` | 子 Timeline 继承父 Timeline 版本；兼容性上允许携带 |

#### 成功出参

状态码：`201 Created`。

```json
{
  "tenant_id": "<tenant-shard-id>",
  "timeline_id": "<new-timeline-id>",
  "ancestor_timeline_id": "<parent-timeline-id>",
  "ancestor_lsn": "0/1700000",
  "last_record_lsn": "0/1700000",
  "min_readable_lsn": "0/1680000",
  "pg_version": 16,
  "state": "Active",
  "is_archived": false,
  "safekeepers": {
    "tenant_id": "<tenant-id>",
    "timeline_id": "<new-timeline-id>",
    "generation": 1,
    "safekeepers": [
      {"id": 1, "hostname": "safekeeper-1"}
    ]
  }
}
```

调用方应从返回值读取实际 `ancestor_lsn`，不要在调用前自行猜测。

---

### 1.3 基于指定时间创建 Branch

Storage Controller 的 Timeline 创建接口最终仍需要 LSN，但调用方可以先使用 Pageserver 的时间查询接口把客户时间转换为 LSN。因此，上层客户只需要提交时间，不需要理解 LSN。

完整流程：

```text
timestamp
  → get_lsn_by_timestamp(with_lease=true)
  → 校验 kind
  → 取得 LSN
  → 创建带 ancestor_start_lsn 的 Timeline
```

#### 第一步：时间转换为 LSN

```bash
export LSN_RESPONSE="$(
  curl --fail-with-body -sS -G \
    "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${PARENT_TIMELINE_ID}/get_lsn_by_timestamp" \
    -H "Authorization: Bearer ${STORCON_JWT}" \
    --data-urlencode "timestamp=${TARGET_TIMESTAMP}" \
    --data-urlencode "with_lease=true"
)"

echo "${LSN_RESPONSE}" | jq .
```

##### 入参

| 位置 | 字段 | 必填 | 类型/取值 | 说明 |
|---|---|---:|---|---|
| Path | `tenant_id` | 是 | Tenant ID | 父 Timeline 所属 Tenant |
| Path | `timeline_id` | 是 | `${PARENT_TIMELINE_ID}` | 在哪条 Timeline 上查时间 |
| Query | `timestamp` | 是 | RFC 3339 | 目标时间；使用 `--data-urlencode` |
| Query | `with_lease` | 否 | `true`/`false` | 建议传 `true`，顺便保护返回的 LSN |

##### 成功出参

状态码：`200 OK`。

```json
{
  "lsn": "0/1680000",
  "kind": "present",
  "valid_until": "2026-10-29T01:31:00.000Z"
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `lsn` | LSN | 根据时间找到的 WAL 位置 |
| `kind` | string | `present`、`future`、`past` 或 `nodata` |
| `valid_until` | RFC 3339，可缺省 | 仅在 Lease 成功时返回；到该时间前 LSN 受 Lease 保护 |

建议的调用方行为：

| `kind` | 含义 | 建议行为 |
|---|---|---|
| `present` | 时间位于现有可解析历史中 | 继续创建 |
| `future` | 目标时间晚于现有历史 | 拒绝或让调用方明确选择“最新”，不要静默创建 |
| `past` | 目标时间早于现有历史 | 拒绝，提示已超出保留窗口 |
| `nodata` | 缺少足够数据确定时间点 | 拒绝或稍后重试 |

提取字段：

```bash
export TARGET_LSN="$(echo "${LSN_RESPONSE}" | jq -r '.lsn')"
export LSN_KIND="$(echo "${LSN_RESPONSE}" | jq -r '.kind')"
export LEASE_VALID_UNTIL="$(echo "${LSN_RESPONSE}" | jq -r '.valid_until // empty')"

test "${LSN_KIND}" = "present"
```

#### 可选：显式建立 LSN Lease

如果时间查询没有返回 `valid_until`，或者调用方已经有一个经过校验的 LSN，可以显式申请 Lease：

```bash
curl --fail-with-body -sS -X POST \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${PARENT_TIMELINE_ID}/lsn_lease" \
  -H "Authorization: Bearer ${STORCON_JWT}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg lsn "${TARGET_LSN}" '{lsn:$lsn}')"
```

入参：

| 位置 | 字段 | 必填 | 说明 |
|---|---|---:|---|
| Path | `tenant_id` | 是 | Tenant ID |
| Path | `timeline_id` | 是 | 要保护历史的父 Timeline |
| Body | `lsn` | 是 | 要临时保护的 LSN |

当前 Storage Controller handler 成功返回：

```http
HTTP/1.1 200 OK
Content-Type: application/json

null
```

SC 内部会在全部 shard 上建立 Lease 并计算最早到期时间，但当前 HTTP handler 不返回 `valid_until`。因此显式 Lease 只能通过 HTTP 是否成功判断，不能从该响应获取到期时间。

#### 第二步：在目标 LSN 创建 Timeline

```bash
export NEW_TIMELINE_ID="$(openssl rand -hex 16)"

curl --fail-with-body -sS -X POST \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" \
  -H "Authorization: Bearer ${STORCON_JWT}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg new_timeline_id "${NEW_TIMELINE_ID}" \
    --arg ancestor_timeline_id "${PARENT_TIMELINE_ID}" \
    --arg ancestor_start_lsn "${TARGET_LSN}" \
    '{new_timeline_id:$new_timeline_id,
      ancestor_timeline_id:$ancestor_timeline_id,
      ancestor_start_lsn:$ancestor_start_lsn,
      read_only:false}')"
```

##### 入参

| 位置 | 字段 | 必填 | 说明 |
|---|---|---:|---|
| Path | `tenant_id` | 是 | Tenant ID |
| Body | `new_timeline_id` | 是 | 新 Timeline ID |
| Body | `ancestor_timeline_id` | 是 | 父 Timeline ID |
| Body | `ancestor_start_lsn` | 是 | 时间转换得到的 `TARGET_LSN` |
| Body | `read_only` | 否 | 默认 `false` |

##### 成功出参

状态码：`201 Created`。

```json
{
  "timeline_id": "<new-timeline-id>",
  "ancestor_timeline_id": "<parent-timeline-id>",
  "ancestor_lsn": "0/1680000",
  "last_record_lsn": "0/1680000",
  "min_readable_lsn": "0/1680000",
  "pg_version": 16,
  "state": "Active",
  "safekeepers": null
}
```

调用方应校验：

- `timeline_id == NEW_TIMELINE_ID`；
- `ancestor_timeline_id == PARENT_TIMELINE_ID`；
- `ancestor_lsn == TARGET_LSN`；
- `state == Active`。

---

## 2. 删除 Branch

SC 侧删除 Branch 等价于删除 Timeline：

```http
DELETE /v1/tenant/{tenant_id}/timeline/{timeline_id}
```

#### 完整 `curl`

```bash
curl --fail-with-body -sS -i -X DELETE \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${TIMELINE_ID}" \
  -H "Authorization: Bearer ${STORCON_JWT}"
```

### 入参

| 位置 | 字段 | 必填 | 说明 |
|---|---|---:|---|
| Path | `tenant_id` | 是 | Timeline 所属 Tenant |
| Path | `timeline_id` | 是 | 要删除的 Timeline |
| Query | 无 | — | 无 Query 参数 |
| Body | 无 | — | 无 JSON Body |

### 成功出参

```http
HTTP/1.1 200 OK
Content-Type: application/json

null
```

Storage Controller 会协调删除所有 Pageserver shard 上的 Timeline，并调用 Safekeeper Timeline 删除。Pageserver 的内部删除语义是先返回 `202/409`、完成后返回 `404`；Storage Controller 在外层最多等待约 25 秒，并向调用方暴露更简单的结果。

### 状态码处理

| 状态码 | 含义 | 调用方处理 |
|---:|---|---|
| `200` | 删除完成 | 操作成功 |
| `409` | 约 25 秒内仍未完成，或删除已在进行 | 退避后使用相同 Tenant/Timeline 重试 |
| `404` | Tenant/Timeline 路由或映射不存在 | 核对输入；不要无条件当作成功 |
| `503` | Tenant 正在迁移或节点暂不可用 | 退避重试 |

### 删除前应先检查

Storage Controller 不知道默认 Branch、保护 Branch 或 Compute 绑定，但会受到真实 Timeline 祖先关系约束。调用删除前至少应：

1. 查询 Timeline 列表，确认没有其他 Timeline 的 `ancestor_timeline_id` 指向目标；
2. 查询目标 Timeline 当前状态；
3. 确认外部没有继续使用该 Timeline；
4. 对 `409/503` 做有上限的指数退避重试。

不要为了删除父 Timeline 自动调用 Detach Ancestor。Detach 会改变真实存储依赖，应作为单独的高风险运维流程。

---

## 3. 查询 Branch

SC 侧查询 Branch 就是查询 Timeline。普通 GET 透传到 Tenant 的 shard 0；`/control/v1/...` 接口会查询所有 shard。

### 3.1 查询 Timeline 列表

```bash
curl --fail-with-body -sS \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" \
  -H "Authorization: Bearer ${STORCON_JWT}"
```

#### 入参

| 位置 | 字段 | 必填 | 说明 |
|---|---|---:|---|
| Path | `tenant_id` | 是 | Tenant ID |
| Query | `include-non-incremental-logical-size` | 否 | 默认 `false`；计算非增量逻辑大小，成本较高 |
| Query | `force-await-initial-logical-size` | 否 | 默认 `false`；等待初始逻辑大小计算 |
| Query | `include-image-consistent-lsn` | 否 | 默认 `false`；请求扩展字段 |

带可选参数的命令：

```bash
curl --fail-with-body -sS -G \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" \
  -H "Authorization: Bearer ${STORCON_JWT}" \
  --data-urlencode "include-non-incremental-logical-size=false" \
  --data-urlencode "force-await-initial-logical-size=false" \
  --data-urlencode "include-image-consistent-lsn=true"
```

#### 成功出参

状态码：`200 OK`。Body 是 `TimelineInfo[]`：

```json
[
  {
    "tenant_id": "<tenant-shard-id>",
    "timeline_id": "<timeline-id>",
    "ancestor_timeline_id": "<parent-or-null>",
    "ancestor_lsn": "0/1680000",
    "last_record_lsn": "0/1700000",
    "min_readable_lsn": "0/1600000",
    "pg_version": 16,
    "state": "Active",
    "is_archived": false
  }
]
```

该接口由 Storage Controller 通用 GET 路由透传到 shard 0，不是所有 shard 的聚合结果。

查找目标 Timeline：

```bash
curl --fail-with-body -sS \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" \
  -H "Authorization: Bearer ${STORCON_JWT}" |
jq --arg timeline_id "${TIMELINE_ID}" \
  '.[] | select(.timeline_id == $timeline_id)'
```

查找直接子 Timeline：

```bash
curl --fail-with-body -sS \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" \
  -H "Authorization: Bearer ${STORCON_JWT}" |
jq --arg parent_timeline_id "${TIMELINE_ID}" \
  '[.[] | select(.ancestor_timeline_id == $parent_timeline_id)]'
```

### 3.2 查询单个 Timeline

```bash
curl --fail-with-body -sS \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${TIMELINE_ID}" \
  -H "Authorization: Bearer ${STORCON_JWT}"
```

#### 入参

| 位置 | 字段 | 必填 | 说明 |
|---|---|---:|---|
| Path | `tenant_id` | 是 | Tenant ID |
| Path | `timeline_id` | 是 | 目标 Timeline ID |
| Query | 三个逻辑大小/镜像参数 | 否 | 与列表接口相同 |

#### 成功出参

状态码：`200 OK`。Body 是单个完整 `TimelineInfo`。

常用字段过滤：

```bash
curl --fail-with-body -sS \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${TIMELINE_ID}" \
  -H "Authorization: Bearer ${STORCON_JWT}" |
jq '{
  tenant_id,
  timeline_id,
  ancestor_timeline_id,
  ancestor_lsn,
  min_readable_lsn,
  applied_gc_cutoff_lsn,
  last_record_lsn,
  disk_consistent_lsn,
  remote_consistent_lsn,
  current_logical_size,
  current_physical_size,
  pg_version,
  state,
  is_archived
}'
```

### 3.3 查询所有 shard 的 Timeline

```bash
curl --fail-with-body -sS \
  "${SC_URL}/control/v1/tenant/${TENANT_ID}/timeline/${TIMELINE_ID}" \
  -H "Authorization: Bearer ${STORCON_JWT}"
```

#### 入参

| 位置 | 字段 | 必填 | 说明 |
|---|---|---:|---|
| Path | `tenant_id` | 是 | Tenant ID |
| Path | `timeline_id` | 是 | Timeline ID |
| Query/Body | 无 | — | 无 |

该接口需要 `Scrubber` scope，而普通 Timeline GET 使用 `PageServerApi` scope。

#### 成功出参

```json
{
  "shards": [
    {
      "tenant_id": "<tenant-shard-id>",
      "timeline_id": "<timeline-id>",
      "ancestor_timeline_id": "<parent-or-null>",
      "ancestor_lsn": "0/1680000",
      "last_record_lsn": "0/1700000",
      "state": "Active",
      "is_archived": false
    }
  ],
  "image_consistent_lsn": "0/1680000"
}
```

`shards[]` 中每一项都是完整 `TimelineInfo`。`image_consistent_lsn` 不可用时可能省略。

### 3.4 `TimelineInfo` 主要出参字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `tenant_id` | TenantShardId | 返回数据所属 Tenant shard |
| `timeline_id` | TimelineId | 当前 Timeline |
| `ancestor_timeline_id` | TimelineId/null | 父 Timeline；根 Timeline 为 `null` |
| `ancestor_lsn` | LSN/null | 分叉点；根 Timeline 为 `null` |
| `last_record_lsn` | LSN | 最新已处理 WAL 位置 |
| `prev_record_lsn` | LSN/null | 前一 WAL record 位置 |
| `min_readable_lsn` | LSN | 当前常规允许创建子 Timeline 或读取历史的最早边界 |
| `applied_gc_cutoff_lsn` | LSN | GC 已应用的 cutoff；创建历史分支优先判断 `min_readable_lsn` |
| `disk_consistent_lsn` | LSN | 本地磁盘一致性位置 |
| `remote_consistent_lsn` | LSN | 已上传远端存储的位置 |
| `remote_consistent_lsn_visible` | LSN | 对 Safekeeper 公布的位置 |
| `initdb_lsn` | LSN | 根 Timeline 初始化位置 |
| `current_logical_size` | u64 | 逻辑大小，单位字节 |
| `current_physical_size` | u64/null | Layer 物理大小；未加载时可为 `null` |
| `pitr_history_size` | u64 | PITR 窗口覆盖的历史量 |
| `within_ancestor_pitr` | bool | 分叉点是否仍在祖先自己的 PITR 窗口中 |
| `pg_version` | integer | PostgreSQL 主版本 |
| `state` | enum | `Loading`、`Active`、`Stopping` 或 `Broken` |
| `is_archived` | bool/null | 是否归档 |
| `walreceiver_status` | string | WAL receiver 状态 |
| `image_consistent_lsn` | LSN/缺省 | image layer 一致性位置，按版本和 Query 决定是否返回 |

---

## 4. 重置 Branch

Storage Controller **没有 Reset Timeline API**，也不能让一个已有 `timeline_id` 改为指向另一段历史。

SC 侧能提供的 Reset 组合能力只有：

1. 在源 Timeline 上按指定时间查询 LSN；
2. 以新 `timeline_id` 创建替代 Timeline；
3. 等待调用方把消费者切换到新 Timeline；
4. 在确认旧 Timeline 无依赖后删除旧 Timeline。

本文只列 SC 命令，不讨论消费者如何切换。

### 第一步：时间转 LSN

```bash
export SOURCE_TIMELINE_ID="${TIMELINE_ID}"
export RESET_TIMESTAMP="2026-10-29T08:45:00+08:00"

export RESET_LSN_RESPONSE="$(
  curl --fail-with-body -sS -G \
    "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${SOURCE_TIMELINE_ID}/get_lsn_by_timestamp" \
    -H "Authorization: Bearer ${STORCON_JWT}" \
    --data-urlencode "timestamp=${RESET_TIMESTAMP}" \
    --data-urlencode "with_lease=true"
)"

echo "${RESET_LSN_RESPONSE}" | jq .
export RESET_LSN="$(echo "${RESET_LSN_RESPONSE}" | jq -r '.lsn')"
test "$(echo "${RESET_LSN_RESPONSE}" | jq -r '.kind')" = "present"
```

入参和出参与 1.3 节的时间转 LSN 完全相同。

### 第二步：创建替代 Timeline

```bash
export OLD_TIMELINE_ID="${TIMELINE_ID}"
export REPLACEMENT_TIMELINE_ID="$(openssl rand -hex 16)"

curl --fail-with-body -sS -X POST \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" \
  -H "Authorization: Bearer ${STORCON_JWT}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg new_timeline_id "${REPLACEMENT_TIMELINE_ID}" \
    --arg ancestor_timeline_id "${SOURCE_TIMELINE_ID}" \
    --arg ancestor_start_lsn "${RESET_LSN}" \
    '{new_timeline_id:$new_timeline_id,
      ancestor_timeline_id:$ancestor_timeline_id,
      ancestor_start_lsn:$ancestor_start_lsn,
      read_only:false}')"
```

成功返回 `201 Created` 和新的 `TimelineCreateResponseStorcon`。调用方必须验证 `ancestor_lsn == RESET_LSN`、`state == Active`。

### 第三步：查询替代 Timeline

```bash
curl --fail-with-body -sS \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${REPLACEMENT_TIMELINE_ID}" \
  -H "Authorization: Bearer ${STORCON_JWT}" |
jq '{timeline_id, ancestor_timeline_id, ancestor_lsn, last_record_lsn, state}'
```

### 第四步：按条件删除旧 Timeline

只有在调用方已经完成切换，并确认旧 Timeline 没有子 Timeline 或其他使用者后，才执行：

```bash
curl --fail-with-body -sS -i -X DELETE \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${OLD_TIMELINE_ID}" \
  -H "Authorization: Bearer ${STORCON_JWT}"
```

> [!warning]
> 如果替代 Timeline 本身就是从 `OLD_TIMELINE_ID` 创建的，它会依赖旧 Timeline。此时不能直接删除旧 Timeline。需要选择另一个源 Timeline、继续保留旧 Timeline，或者通过单独审批的 Detach Ancestor 流程切断依赖。Reset 不能简单等同于“创建子 Timeline 后立刻删除父 Timeline”。

---

## 5. 设置保护 Branch

### 结论

Storage Controller **没有设置保护 Branch/Timeline 的 API**，因此没有对应 `curl`。

保护 Branch 的语义通常是：禁止删除、Reset、Rename、Archive 等高风险产品操作。这是调用 Storage Controller **之前**的操作策略，不是存储状态。

以下 SC 能力都不能替代保护 Branch：

| SC 能力 | 为什么不是保护 Branch |
|---|---|
| Archive | 只是把 Timeline 标记为冷数据生命周期状态，不阻止删除 |
| Block GC | 只阻止历史 GC 推进，不阻止删除 Timeline |
| LSN Lease | 临时保护一个 LSN 可读，不阻止删除整个 Timeline |
| Detach Ancestor | 改变存储祖先依赖，与防误删无关 |

如果调用方没有自己的保护策略，下面的删除命令仍可直接删除 Timeline：

```bash
curl --fail-with-body -sS -X DELETE \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${TIMELINE_ID}" \
  -H "Authorization: Bearer ${STORCON_JWT}"
```

因此，保护校验必须发生在向 SC 发送删除、Reset 组合流程、Archive 等命令之前。

---

## 6. 设置默认 Branch

### 结论

Storage Controller **没有设置默认 Branch/Timeline 的 API**，因此没有对应 `curl`。

SC 不识别 `main`，也不会在多个 Timeline 中选择“默认 Timeline”。所有 SC Timeline API 都要求调用方显式提供 `timeline_id`，例如：

```bash
curl --fail-with-body -sS \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${TIMELINE_ID}" \
  -H "Authorization: Bearer ${STORCON_JWT}"
```

默认选择必须在 SC 之外完成。设置默认值本身不应调用 Storage Controller。

---

## 调用顺序速查

### 创建根 Timeline

```text
生成 timeline_id
  → POST /v1/tenant/{tenant_id}/timeline
  → 校验 ancestor_timeline_id=null、state=Active
```

### 从最新位置创建子 Timeline

```text
取得 parent_timeline_id
  → 生成 new_timeline_id
  → POST timeline，不传 ancestor_start_lsn
  → 读取响应中的实际 ancestor_lsn
```

### 按时间创建子 Timeline

```text
timestamp
  → GET get_lsn_by_timestamp?with_lease=true
  → 校验 kind=present
  → POST timeline，传 ancestor_start_lsn
  → 校验 ancestor_lsn 与目标 LSN 一致
```

### 删除 Timeline

```text
查询列表/详情与直接子 Timeline
  → DELETE timeline
  → 200 完成；409/503 退避重试
```

### Reset

```text
时间转 LSN
  → 创建 replacement_timeline_id
  → 查询确认新 Timeline Active
  → SC 之外完成消费者切换
  → 无依赖时才考虑删除旧 Timeline
```

## 源码依据

- `storage_controller/src/http.rs`：SC 路由、Path/Query/Body 解析、状态码与权限 scope
- `storage_controller/src/service.rs`：Timeline 创建、删除、跨 shard 调用与 Lease 聚合
- `storage_controller/src/service/safekeeper_service.rs`：Safekeeper Timeline 删除
- `pageserver/src/http/routes.rs`：Timeline 查询、时间转 LSN、显式 Lease 的实际响应
- `libs/pageserver_api/src/models.rs`：`TimelineCreateRequest`、`TimelineCreateResponseStorcon`、`TimelineInfo`、`LsnLease`
- `libs/pageserver_api/src/controller_api.rs`：全 shard Timeline 查询响应

## 关联文档

- [[storage-controller-branch-api-curl]]
