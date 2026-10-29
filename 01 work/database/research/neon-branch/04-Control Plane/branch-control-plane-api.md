---
title: Neon Branch Control Plane API 开发文档
aliases:
  - Branch 产品接口
  - Branch Control Plane API
tags: [数据库, Neon, Control-Plane, Branch, API]
created: 2026-10-29
updated: 2026-10-29
---

# Neon Branch Control Plane API 开发文档

本文是给 Control Plane 开发人员使用的 Branch 接口手册，定义管控对外 API、完整 `curl`、入参与出参，以及每个功能在管控内部对应的 Storage Controller 调用。覆盖：

1. 创建 Branch
2. 删除 Branch
3. 查询 Branch
4. 重置 Branch
5. 设置保护 Branch
6. 设置默认 Branch

底层实现基于 Neon Storage Controller/Pageserver Timeline API。管控对外 API **不暴露** `tenant_id`、`timeline_id`、LSN 等内核概念；Control Plane 实现内部则必须维护这些映射，并按本文给出的 Storage Controller `curl` 完成编排。

> [!important]
> 客户按时间创建 Branch 时，只提交 RFC 3339 时间。Control Plane 内部负责“时间 → LSN → Lease → 创建 Timeline”，不要求客户理解或直接填写 LSN。

> [!warning]
> `/api/v1/projects/...` 是本文为云管控设计的接口契约，需要你在 Control Plane 中实现；它不是 Neon 开源 Storage Controller 已经存在的路由。文中 `/v1/tenant/...`、`/control/v1/...`、`/debug/v1/...` 才是当前 Neon 源码中的 Storage Controller/Pageserver 接口。

## 接口边界与通用约定

### 调试环境变量

以下变量供本文所有 `curl` 直接复用：

```bash
export CP_URL="http://127.0.0.1:8080"
export CP_TOKEN="<control-plane-api-token>"

export SC_URL="http://127.0.0.1:1234"
export STORCON_JWT="<storage-controller-jwt>"

export PROJECT_ID="prj_01JBC6Q8D7P4F2K9M1N5R3T0VX"
export BRANCH_ID="br_01JBC7DEV00000000000000000"
export PARENT_BRANCH_ID="br_01JBC70MAIN000000000000000"

# 以下变量只在 Control Plane 内部调用 Storage Controller 时使用
export TENANT_ID="<32位十六进制tenant-id>"
export TIMELINE_ID="<32位十六进制timeline-id>"
export PARENT_TIMELINE_ID="<32位十六进制parent-timeline-id>"
```

管控对外调用统一使用：

```bash
-H "Authorization: Bearer ${CP_TOKEN}"
```

管控调用 Storage Controller 时，如部署启用了 JWT，则使用：

```bash
-H "Authorization: Bearer ${STORCON_JWT}"
```

### Base URL

```text
/api/v1/projects/{project_id}
```

### 管控对外接口总表

| 功能 | 方法 | 路径 | Storage Controller 实现方式 |
|---|---|---|---|
| 创建根 Branch | `POST` | `/branches`，`source.mode=root` | 创建 Bootstrap Timeline |
| 从最新状态创建 | `POST` | `/branches`，`source.mode=latest` | 创建子 Timeline，不传 `ancestor_start_lsn` |
| 按时间创建 | `POST` | `/branches`，`source.mode=timestamp` | 时间转 LSN + Lease + 创建子 Timeline |
| 删除 Branch | `DELETE` | `/branches/{branch_id}` | 检查管控约束后删除 Timeline |
| 查询 Branch 列表 | `GET` | `/branches` | 以管控数据库为主，后台/按需核对 Timeline |
| 查询 Branch 详情 | `GET` | `/branches/{branch_id}` | 同上 |
| Reset Branch | `POST` | `/branches/{branch_id}/reset` | 创建替代 Timeline + 原子切映射 + 延迟回收旧 Timeline |
| 设置/解除保护 | `PUT` | `/branches/{branch_id}/protection` | 只修改管控元数据，不调用 Storage Controller |
| 设置默认 Branch | `PUT` | `/default-branch` | 只修改 `projects.default_branch_id` |

### 通用请求头

| 请求头 | 是否必填 | 说明 |
|---|---:|---|
| `Authorization: Bearer <token>` | 是 | 客户身份与项目权限 |
| `Content-Type: application/json` | 有 Body 时必填 | JSON 请求 |
| `Idempotency-Key: <uuid>` | 创建、删除、Reset 必填 | 防止网络重试造成重复 Timeline 或重复 Workflow |
| `X-Request-Id` | 否 | 调用链追踪；缺省时由服务端生成 |

### 客户可见的 Branch 对象

```json
{
  "id": "br_01JBC7VZ9X3Q8H6K4M2N1P0R5S",
  "project_id": "prj_01JBC6Q8D7P4F2K9M1N5R3T0VX",
  "name": "dev",
  "parent_branch_id": "br_01JBC70MAIN000000000000000",
  "creation_source": {
    "mode": "timestamp",
    "requested_timestamp": "2026-10-29T09:30:00+08:00"
  },
  "state": "ready",
  "protected": false,
  "default": false,
  "created_at": "2026-10-29T09:31:12.456Z",
  "updated_at": "2026-10-29T09:31:12.456Z"
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 稳定的产品层 Branch UID；不会随 Reset 改变 |
| `project_id` | string | Branch 所属 Project |
| `name` | string | Project 内唯一的 Branch 名称 |
| `parent_branch_id` | string/null | 产品层父 Branch；根 Branch 为 `null` |
| `creation_source` | object | 根、父 Branch 最新状态或指定时间 |
| `state` | string | `creating`、`ready`、`resetting`、`deleting`、`error` |
| `protected` | bool | Control Plane 的操作保护策略，不是 Archive/Block GC |
| `default` | bool | 是否为 Project 默认 Branch |

`timeline_id` 只存在于 Control Plane 内部映射中，不进入普通客户响应。运维接口可以单独展示，但不应允许客户拿它作为 Branch API 入参。

---

## 1. 创建 Branch

统一入口：

```http
POST /api/v1/projects/{project_id}/branches
```

通过 `source.mode` 区分根 Branch、从父 Branch 最新状态创建，以及从指定时间创建。

### 1.1 创建根 Branch

#### 客户场景

根 Branch 没有父 Branch，会创建一个 Bootstrap Timeline。通常它在创建 Project 时由系统自动创建并命名为 `main`，不建议普通客户在同一 Project 中随意创建多个根 Branch。

如果产品允许显式创建根 Branch，建议只开放给内部服务或管理员。

#### 请求

```http
POST /api/v1/projects/{project_id}/branches
Idempotency-Key: 2b4b80ac-7265-4f6d-90d6-3504fe33b90a
Content-Type: application/json
```

```json
{
  "name": "main",
  "source": {
    "mode": "root",
    "pg_version": 16
  },
  "protected": true,
  "set_as_default": true
}
```

#### 完整 `curl`

```bash
curl --fail-with-body -sS -X POST \
  "${CP_URL}/api/v1/projects/${PROJECT_ID}/branches" \
  -H "Authorization: Bearer ${CP_TOKEN}" \
  -H "Idempotency-Key: 2b4b80ac-7265-4f6d-90d6-3504fe33b90a" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "main",
    "source": {"mode": "root", "pg_version": 16},
    "protected": true,
    "set_as_default": true
  }'
```

#### 入参

| 位置 | 参数 | 必填 | 说明 |
|---|---|---:|---|
| Path | `project_id` | 是 | 产品层 Project UID |
| Body | `name` | 是 | Project 内唯一；建议满足 `^[a-zA-Z][a-zA-Z0-9_-]{0,62}$` |
| Body | `source.mode` | 是 | 固定为 `root` |
| Body | `source.pg_version` | 是 | PostgreSQL 主版本，例如 `16` |
| Body | `protected` | 否 | 默认 `false`；是否创建后立即保护 |
| Body | `set_as_default` | 否 | 默认 `false`；Project 第一个 Branch 可以自动设为默认 |

#### 成功响应

```http
201 Created
```

```json
{
  "branch": {
    "id": "br_01JBC70MAIN000000000000000",
    "project_id": "prj_01JBC6Q8D7P4F2K9M1N5R3T0VX",
    "name": "main",
    "parent_branch_id": null,
    "creation_source": {"mode": "root", "pg_version": 16},
    "state": "ready",
    "protected": true,
    "default": true,
    "created_at": "2026-10-29T09:00:00.000Z",
    "updated_at": "2026-10-29T09:00:00.000Z"
  }
}
```

#### Control Plane 内部流程

```text
校验 Project 与 Branch 名
  → 读取 project.tenant_id
  → 生成 branch_id 与 timeline_id
  → POST Storage Controller /v1/tenant/{tenant_id}/timeline
       {new_timeline_id, pg_version}
  → 保存 branch_id/name → timeline_id 映射
  → 在同一产品事务中设置 protected/default
```

#### 内部 Storage Controller `curl`

```bash
export NEW_TIMELINE_ID="$(openssl rand -hex 16)"

curl --fail-with-body -sS -X POST \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" \
  -H "Authorization: Bearer ${STORCON_JWT}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg new_timeline_id "${NEW_TIMELINE_ID}" \
    '{new_timeline_id:$new_timeline_id, pg_version:16}')"
```

成功返回 `201 Created`，Body 是 `TimelineCreateResponseStorcon`。管控至少读取 `timeline_id`、`ancestor_timeline_id`、`ancestor_lsn`、`last_record_lsn`、`state` 和可选 `safekeepers`；随后将 `NEW_TIMELINE_ID` 写入 `branches.timeline_id`。

---

### 1.2 不指定时间创建 Branch

#### 客户场景

客户只表达“从 `main` 当前最新状态创建 `dev`”，不提交时间或 LSN。这是最常见、最简单的 Branch 创建方式。

“不指定 LSN”是客户接口语义；底层仍会由 Pageserver 选择实际分叉 LSN，并在创建响应中记录祖先关系。

#### 请求

```http
POST /api/v1/projects/{project_id}/branches
Idempotency-Key: caa79087-f1b7-49eb-b024-8889b91ce35a
Content-Type: application/json
```

```json
{
  "name": "dev",
  "source": {
    "mode": "latest",
    "parent_branch_id": "br_01JBC70MAIN000000000000000"
  },
  "protected": false
}
```

#### 完整 `curl`

```bash
curl --fail-with-body -sS -X POST \
  "${CP_URL}/api/v1/projects/${PROJECT_ID}/branches" \
  -H "Authorization: Bearer ${CP_TOKEN}" \
  -H "Idempotency-Key: caa79087-f1b7-49eb-b024-8889b91ce35a" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg parent_branch_id "${PARENT_BRANCH_ID}" \
    '{name:"dev", source:{mode:"latest", parent_branch_id:$parent_branch_id}, protected:false}')"
```

#### 入参

| 位置 | 参数 | 必填 | 说明 |
|---|---|---:|---|
| Path | `project_id` | 是 | 目标 Project |
| Body | `name` | 是 | 新 Branch 名称 |
| Body | `source.mode` | 是 | 固定为 `latest` |
| Body | `source.parent_branch_id` | 是 | 父 Branch UID，不能传父 Timeline ID 或名称 |
| Body | `protected` | 否 | 默认 `false` |

#### 成功响应

```http
201 Created
```

```json
{
  "branch": {
    "id": "br_01JBC7DEV00000000000000000",
    "project_id": "prj_01JBC6Q8D7P4F2K9M1N5R3T0VX",
    "name": "dev",
    "parent_branch_id": "br_01JBC70MAIN000000000000000",
    "creation_source": {"mode": "latest"},
    "state": "ready",
    "protected": false,
    "default": false,
    "created_at": "2026-10-29T09:20:00.000Z",
    "updated_at": "2026-10-29T09:20:00.000Z"
  }
}
```

#### Control Plane 内部流程

```text
parent_branch_id
  → 查询父 Branch 的 timeline_id
  → 生成新 timeline_id
  → POST Storage Controller /v1/tenant/{tenant_id}/timeline
       {new_timeline_id, ancestor_timeline_id, read_only:false}
  → 从返回值记录实际 ancestor_lsn（内部字段）
  → 保存新 Branch 映射
```

#### 内部 Storage Controller `curl`

Control Plane 先用 `parent_branch_id` 查询自己的 `branches` 表得到 `PARENT_TIMELINE_ID`，然后调用：

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

成功返回 `201 Created`。未指定 `ancestor_start_lsn` 时，由 Pageserver 选择分叉点；管控应从响应的 `ancestor_lsn` 记录实际分叉位置。

---

### 1.3 基于指定时间创建 Branch

#### 客户场景

客户表达“从 `main` 在 2026-10-29 09:30 的状态创建 `recovery-test`”。客户提供时间，不提供 LSN。

这是产品层 PITR Branch。接口必须明确时间格式与时区，并拒绝无法精确满足的未来时间、过旧时间或缺失历史，而不是悄悄改成最新状态。

#### 请求

```http
POST /api/v1/projects/{project_id}/branches
Idempotency-Key: d350c984-b7c4-4a98-9c10-9c663b9c4c4a
Content-Type: application/json
```

```json
{
  "name": "recovery-test",
  "source": {
    "mode": "timestamp",
    "parent_branch_id": "br_01JBC70MAIN000000000000000",
    "timestamp": "2026-10-29T09:30:00+08:00"
  },
  "protected": false
}
```

#### 完整 `curl`

```bash
export TARGET_TIMESTAMP="2026-10-29T09:30:00+08:00"

curl --fail-with-body -sS -X POST \
  "${CP_URL}/api/v1/projects/${PROJECT_ID}/branches" \
  -H "Authorization: Bearer ${CP_TOKEN}" \
  -H "Idempotency-Key: d350c984-b7c4-4a98-9c10-9c663b9c4c4a" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg parent_branch_id "${PARENT_BRANCH_ID}" \
    --arg timestamp "${TARGET_TIMESTAMP}" \
    '{name:"recovery-test",
      source:{mode:"timestamp", parent_branch_id:$parent_branch_id, timestamp:$timestamp},
      protected:false}')"
```

#### 入参

| 位置 | 参数 | 必填 | 说明 |
|---|---|---:|---|
| Path | `project_id` | 是 | 目标 Project |
| Body | `name` | 是 | 新 Branch 名称 |
| Body | `source.mode` | 是 | 固定为 `timestamp` |
| Body | `source.parent_branch_id` | 是 | 在哪条父 Branch 的历史上查找 |
| Body | `source.timestamp` | 是 | RFC 3339，必须带 `Z` 或明确时区偏移 |
| Body | `protected` | 否 | 默认 `false` |

#### 成功响应

```http
201 Created
```

```json
{
  "branch": {
    "id": "br_01JBC7PITR0000000000000000",
    "project_id": "prj_01JBC6Q8D7P4F2K9M1N5R3T0VX",
    "name": "recovery-test",
    "parent_branch_id": "br_01JBC70MAIN000000000000000",
    "creation_source": {
      "mode": "timestamp",
      "requested_timestamp": "2026-10-29T09:30:00+08:00"
    },
    "state": "ready",
    "protected": false,
    "default": false,
    "created_at": "2026-10-29T09:31:12.456Z",
    "updated_at": "2026-10-29T09:31:12.456Z"
  }
}
```

#### Control Plane 内部流程

```text
timestamp + parent_branch_id
  → 查询父 Branch 的 timeline_id
  → GET Storage Controller
       /v1/tenant/{tenant_id}/timeline/{parent_timeline_id}/get_lsn_by_timestamp
       ?timestamp=<RFC3339>&with_lease=true
  → 校验 kind == present，并取得 lsn 与 valid_until
  → 生成新 timeline_id
  → POST Storage Controller /v1/tenant/{tenant_id}/timeline
       {new_timeline_id, ancestor_timeline_id, ancestor_start_lsn:lsn}
  → 保存 Branch 映射、客户请求时间和内部实际 LSN
```

#### 内部 Storage Controller `curl`：第一步，时间转 LSN

```bash
export LSN_RESPONSE="$(
  curl --fail-with-body -sS -G \
    "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${PARENT_TIMELINE_ID}/get_lsn_by_timestamp" \
    -H "Authorization: Bearer ${STORCON_JWT}" \
    --data-urlencode "timestamp=${TARGET_TIMESTAMP}" \
    --data-urlencode "with_lease=true"
)"

echo "${LSN_RESPONSE}" | jq .
export TARGET_LSN="$(echo "${LSN_RESPONSE}" | jq -r '.lsn')"
export LSN_KIND="$(echo "${LSN_RESPONSE}" | jq -r '.kind')"
export LEASE_VALID_UNTIL="$(echo "${LSN_RESPONSE}" | jq -r '.valid_until // empty')"
```

成功响应：

```json
{
  "lsn": "0/1680000",
  "kind": "present",
  "valid_until": "2026-10-29T01:31:00.000Z"
}
```

只有 `LSN_KIND=present` 才继续。`valid_until` 是可选字段；缺失时管控应执行显式 Lease 或失败重试。

显式 Lease 的 fallback：

```bash
curl --fail-with-body -sS -X POST \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${PARENT_TIMELINE_ID}/lsn_lease" \
  -H "Authorization: Bearer ${STORCON_JWT}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg lsn "${TARGET_LSN}" '{lsn:$lsn}')"
```

当前 Storage Controller handler 成功返回 `200`、Body 为 `null`；虽然内部在所有 shard 上建立 Lease 并计算最早到期时间，但没有把 `valid_until` 透出。管控以 HTTP 成功作为 Lease 已建立的判断，并确保在 Lease 有效期内尽快完成 Timeline 创建。

#### 内部 Storage Controller `curl`：第二步，创建指定分叉点 Timeline

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

成功返回 `201 Created` 和 `TimelineCreateResponseStorcon`。响应的 `ancestor_lsn` 应与本次 `TARGET_LSN` 一致；不一致时不要提交 Branch 映射。

### 1.4 Storage Controller 创建 Timeline 的公共出参

1.1、1.2、1.3 最终都调用同一个 Storage Controller 创建接口。响应为 `201 Created`，Body 是 `TimelineCreateResponseStorcon`：完整 `TimelineInfo` 加可选 `safekeepers`。

```json
{
  "tenant_id": "<tenant-shard-id>",
  "timeline_id": "<new-timeline-id>",
  "ancestor_timeline_id": "<parent-timeline-id-or-null>",
  "ancestor_lsn": "0/1680000",
  "last_record_lsn": "0/1680000",
  "min_readable_lsn": "0/1680000",
  "disk_consistent_lsn": "0/1680000",
  "remote_consistent_lsn": "0/1680000",
  "current_logical_size": 0,
  "current_physical_size": 0,
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

| 返回字段 | 管控如何使用 |
|---|---|
| `timeline_id` | 必须等于本次生成的 `NEW_TIMELINE_ID`，否则视为协议错误 |
| `ancestor_timeline_id` | 根 Timeline 为 `null`；子 Timeline 必须与解析出的父 Timeline 一致 |
| `ancestor_lsn` | 保存为内部实际分叉点；按时间创建时应与 `TARGET_LSN` 一致 |
| `last_record_lsn` | 初始 WAL 位置，可用于诊断，不作为 Branch 名称映射主键 |
| `min_readable_lsn` | 当前最早常规可读历史边界 |
| `pg_version` | 核对 PostgreSQL 主版本 |
| `state` | 正常应为 `Active`；非 Active 时不要把 Branch 标为 `ready` |
| `safekeepers` | 可能为 `null`；非空时包含 generation 和已选 Safekeeper 节点 |

响应还包含其他 `TimelineInfo` 统计字段。管控反序列化时必须允许未知字段，避免 Neon 升级追加字段导致调用失败。

### 1.5 时间异常的产品行为

| Storage 返回 | 产品接口行为 | 建议错误码 |
|---|---|---|
| `kind=present` | 正常创建 | `201` |
| `kind=future` | 拒绝；不能把未来时间悄悄替换为最新状态 | `422 TIMESTAMP_IN_FUTURE` |
| `kind=past` | 拒绝；目标早于可用历史 | `422 TIMESTAMP_BEFORE_RETENTION` |
| `kind=nodata` | 拒绝；无法从现有数据确定时间点 | `422 TIMESTAMP_NOT_RESOLVABLE` |
| 没有返回 `valid_until` | 可重试一次显式 Lease；仍失败则不创建 | `503 LSN_LEASE_UNAVAILABLE` |

### 1.6 为什么不向客户开放“指定 LSN 创建”

- LSN 是存储内核坐标，不是客户业务时间。
- 客户通常知道“事故发生前 5 分钟”，不知道 `0/1680000`。
- LSN 只在某条 Timeline 内有意义，传错父 Timeline 容易产生误解。
- LSN 还受 `min_readable_lsn`、GC 和 Lease 约束。

因此，指定 LSN 可以保留为内部运维 API，但不应成为普通客户 API。

---

## 2. 删除 Branch

```http
DELETE /api/v1/projects/{project_id}/branches/{branch_id}
Idempotency-Key: 7d3bd86d-0180-47a8-ae08-1685674046b5
```

### 完整 `curl`

```bash
curl --fail-with-body -sS -X DELETE \
  "${CP_URL}/api/v1/projects/${PROJECT_ID}/branches/${BRANCH_ID}" \
  -H "Authorization: Bearer ${CP_TOKEN}" \
  -H "Idempotency-Key: 7d3bd86d-0180-47a8-ae08-1685674046b5"
```

### 入参

| 位置 | 参数 | 必填 | 说明 |
|---|---|---:|---|
| Path | `project_id` | 是 | Branch 所属 Project |
| Path | `branch_id` | 是 | 产品层 Branch UID，不接受名称或 Timeline ID |

首版不建议提供 `force=true` 或 `cascade=true`。删除默认 Branch、受保护 Branch、有子 Branch 或仍绑定 Compute 的 Branch 时，应明确返回冲突，让客户先处理依赖。

### 成功响应

```http
202 Accepted
```

```json
{
  "operation": {
    "id": "op_01JBC8DELETE00000000000000",
    "type": "delete_branch",
    "status": "running",
    "branch_id": "br_01JBC7DEV00000000000000000"
  }
}
```

删除可能超过一个 HTTP 请求周期，因此客户接口返回 Operation，后台 Workflow 继续执行。客户可查询：

```http
GET /api/v1/projects/{project_id}/operations/{operation_id}
```

```bash
export OPERATION_ID="op_01JBC8DELETE00000000000000"

curl --fail-with-body -sS \
  "${CP_URL}/api/v1/projects/${PROJECT_ID}/operations/${OPERATION_ID}" \
  -H "Authorization: Bearer ${CP_TOKEN}"
```

完成响应示例：

```json
{
  "operation": {
    "id": "op_01JBC8DELETE00000000000000",
    "type": "delete_branch",
    "status": "succeeded",
    "branch_id": "br_01JBC7DEV00000000000000000",
    "error": null,
    "created_at": "2026-10-29T10:10:00.000Z",
    "updated_at": "2026-10-29T10:10:08.123Z"
  }
}
```

`status` 取值为 `pending`、`running`、`succeeded` 或 `failed`。失败时 `error` 返回统一的 `{code,message,details}` 结构。

### 删除前置校验

| 条件 | 行为 |
|---|---|
| `protected=true` | `409 BRANCH_PROTECTED` |
| `default=true` | `409 DEFAULT_BRANCH_CANNOT_BE_DELETED`；先设置其他默认 Branch |
| 存在直接或间接子 Branch | `409 BRANCH_HAS_CHILDREN`；首版不自动 Detach/Cascade |
| 仍绑定 Compute endpoint | `409 BRANCH_HAS_COMPUTE`；先停用、迁移或删除 Compute |
| Branch 已在删除 | 返回原 Operation，不重复调用底层删除 |
| Branch 已删除 | 对相同幂等键返回原成功结果；其他请求可返回 `404` |

### Control Plane 内部流程

```text
锁定 Branch 并做前置校验
  → state=deleting
  → 停止接收新的 Compute 绑定
  → DELETE Storage Controller /v1/tenant/{tenant_id}/timeline/{timeline_id}
  → 对 409/503 做有上限退避重试
  → 底层完成后软删除/归档 Branch 映射
  → Operation=succeeded
```

### 内部 Storage Controller `curl`

Control Plane 从 `project_id` 和 `branch_id` 分别解析出 `TENANT_ID` 和 `TIMELINE_ID`：

```bash
curl --fail-with-body -sS -i -X DELETE \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${TIMELINE_ID}" \
  -H "Authorization: Bearer ${STORCON_JWT}"
```

| Storage Controller 响应 | 管控处理 |
|---|---|
| `200`，Body `null` | Pageserver 和 Safekeeper Timeline 删除完成，可提交产品层删除状态 |
| `409`，Body `null` | 删除仍在进行，后台 Workflow 退避后重试，不重新创建 Operation |
| `404` | 核对 Tenant/Timeline 映射；若此前已有成功删除证据可按幂等完成，否则记为异常 |
| `503` | 调度迁移或节点暂不可用，退避重试 |

---

## 3. 查询 Branch

查询接口只返回产品层 Branch 信息，不要求客户理解 Timeline。

### 3.1 查询 Branch 列表

```http
GET /api/v1/projects/{project_id}/branches?limit=50&cursor=<cursor>&state=ready
```

#### 完整 `curl`

```bash
curl --fail-with-body -sS -G \
  "${CP_URL}/api/v1/projects/${PROJECT_ID}/branches" \
  -H "Authorization: Bearer ${CP_TOKEN}" \
  --data-urlencode "limit=50" \
  --data-urlencode "state=ready"
```

带下一页游标时增加：

```bash
--data-urlencode "cursor=${NEXT_CURSOR}"
```

#### 入参

| 位置 | 参数 | 必填 | 说明 |
|---|---|---:|---|
| Path | `project_id` | 是 | 目标 Project |
| Query | `limit` | 否 | 默认 `50`，最大 `200` |
| Query | `cursor` | 否 | 服务端返回的不透明游标 |
| Query | `state` | 否 | 按 Branch 状态过滤 |
| Query | `name` | 否 | 按 Branch 名精确查询；名称要 URL 编码 |

#### 成功响应

```json
{
  "branches": [
    {
      "id": "br_01JBC70MAIN000000000000000",
      "project_id": "prj_01JBC6Q8D7P4F2K9M1N5R3T0VX",
      "name": "main",
      "parent_branch_id": null,
      "creation_source": {"mode": "root", "pg_version": 16},
      "state": "ready",
      "protected": true,
      "default": true,
      "created_at": "2026-10-29T09:00:00.000Z",
      "updated_at": "2026-10-29T09:00:00.000Z"
    }
  ],
  "next_cursor": null
}
```

列表以 Control Plane 数据库为准，不能只列 Storage Controller Timeline：底层不保存 Branch 名、保护状态和默认状态。

### 3.2 查询单个 Branch

```http
GET /api/v1/projects/{project_id}/branches/{branch_id}
```

#### 完整 `curl`

```bash
curl --fail-with-body -sS \
  "${CP_URL}/api/v1/projects/${PROJECT_ID}/branches/${BRANCH_ID}" \
  -H "Authorization: Bearer ${CP_TOKEN}"
```

成功返回：

```json
{
  "branch": {
    "id": "br_01JBC7DEV00000000000000000",
    "project_id": "prj_01JBC6Q8D7P4F2K9M1N5R3T0VX",
    "name": "dev",
    "parent_branch_id": "br_01JBC70MAIN000000000000000",
    "creation_source": {"mode": "latest"},
    "state": "ready",
    "protected": false,
    "default": false,
    "created_at": "2026-10-29T09:20:00.000Z",
    "updated_at": "2026-10-29T09:20:00.000Z"
  }
}
```

### 3.3 是否实时查询 Storage Controller

普通列表不应逐条查询底层，否则 Branch 多时会形成 N+1 请求。建议：

- Branch 名、父子关系、保护和默认状态：查 Control Plane 数据库。
- `timeline_id`：Control Plane 内部映射，不返回客户。
- Timeline 健康状态：由后台周期同步或按单 Branch 详情按需查询。
- `ancestor_timeline_id`、`ancestor_lsn`：需要诊断时从 Storage Controller 查询，不必作为客户模型的主字段重复暴露。

### 3.4 管控按需查询 Storage Controller

客户 Branch 列表来自 Control Plane 数据库。需要核对底层 Timeline 时，管控可以使用以下接口。

查询 Tenant 在 shard 0 上可见的 Timeline 列表：

```bash
curl --fail-with-body -sS \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" \
  -H "Authorization: Bearer ${STORCON_JWT}" |
jq '[.[] | {
  timeline_id,
  ancestor_timeline_id,
  ancestor_lsn,
  min_readable_lsn,
  last_record_lsn,
  state,
  is_archived
}]'
```

查询单个 Timeline 的 shard 0 详情：

```bash
curl --fail-with-body -sS \
  "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${TIMELINE_ID}" \
  -H "Authorization: Bearer ${STORCON_JWT}" |
jq '{
  timeline_id,
  ancestor_timeline_id,
  ancestor_lsn,
  min_readable_lsn,
  last_record_lsn,
  pg_version,
  state,
  is_archived
}'
```

查询所有 shard 的 Timeline 详情：

```bash
curl --fail-with-body -sS \
  "${SC_URL}/control/v1/tenant/${TENANT_ID}/timeline/${TIMELINE_ID}" \
  -H "Authorization: Bearer ${STORCON_JWT}"
```

最后一个接口成功返回：

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

`shards[]` 的元素是完整 `TimelineInfo`；上例仅展示管控最常用字段。

---

## 4. 重置 Branch

Branch Reset 的客户语义是：**Branch UID 和名称不变，但它指向的数据库历史被切换到指定时间点的新 Timeline。**

客户仍然只提交时间，不提交 LSN。

```http
POST /api/v1/projects/{project_id}/branches/{branch_id}/reset
Idempotency-Key: af125e32-bce2-40cf-82ba-77a76344bc49
Content-Type: application/json
```

```json
{
  "target": {
    "mode": "timestamp",
    "source_branch_id": "br_01JBC70MAIN000000000000000",
    "timestamp": "2026-10-29T08:45:00+08:00"
  }
}
```

### 完整 `curl`

```bash
export RESET_TIMESTAMP="2026-10-29T08:45:00+08:00"

curl --fail-with-body -sS -X POST \
  "${CP_URL}/api/v1/projects/${PROJECT_ID}/branches/${BRANCH_ID}/reset" \
  -H "Authorization: Bearer ${CP_TOKEN}" \
  -H "Idempotency-Key: af125e32-bce2-40cf-82ba-77a76344bc49" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg source_branch_id "${PARENT_BRANCH_ID}" \
    --arg timestamp "${RESET_TIMESTAMP}" \
    '{target:{mode:"timestamp", source_branch_id:$source_branch_id, timestamp:$timestamp}}')"
```

### 入参

| 位置 | 参数 | 必填 | 说明 |
|---|---|---:|---|
| Path | `project_id` | 是 | 所属 Project |
| Path | `branch_id` | 是 | 要 Reset 的稳定 Branch UID |
| Body | `target.mode` | 是 | 首版固定为 `timestamp` |
| Body | `target.source_branch_id` | 是 | 从哪条 Branch 的历史恢复 |
| Body | `target.timestamp` | 是 | RFC 3339，必须包含时区 |

### 成功响应

```http
202 Accepted
```

```json
{
  "operation": {
    "id": "op_01JBC8RESET000000000000000",
    "type": "reset_branch",
    "status": "running",
    "branch_id": "br_01JBC7DEV00000000000000000"
  }
}
```

### 前置校验

| 条件 | 行为 |
|---|---|
| Branch 受保护 | `409 BRANCH_PROTECTED` |
| Branch 正在创建、删除或 Reset | `409 BRANCH_BUSY` |
| 时间在未来、早于历史或无法解析 | 与 1.3 节相同的 `422` |
| Compute 不能在线重配 | Workflow 中短暂停机并重新绑定；API 文档和控制台必须明确提示 |

### Control Plane 内部流程

```text
锁定 branch_id，state=resetting
  → source_branch_id + timestamp 转换为 LSN，并取得 Lease
  → 创建 replacement_timeline_id
  → 等待新 Timeline ready
  → 原子更新 branch.timeline_id → replacement_timeline_id
  → 重配/重建绑定该 Branch 的 Compute
  → state=ready，Operation=succeeded
  → 旧 Timeline 无引用后异步回收
```

> [!warning]
> 已存在的子 Branch 在底层仍可能依赖 Reset 前的旧 Timeline。Reset 不能立刻无条件删除旧 Timeline；Workflow 必须检查后代依赖，必要时保留内部引用、延迟回收或执行经过审批的 Detach。产品层 `parent_branch_id` 与底层真实祖先关系在 Reset 后也可能暂时不同，必须在数据模型中区分。

Reset 失败时，必须保持原 `branch_id → timeline_id` 映射不变；只有新 Timeline 创建完成后才能原子切换。

### 内部 Storage Controller `curl`

Reset 没有单个 Storage Controller API。管控必须编排以下步骤。

第一步，解析 `source_branch_id → SOURCE_TIMELINE_ID` 并把时间转换为 LSN：

```bash
export SOURCE_TIMELINE_ID="<source-branch对应的timeline-id>"

export RESET_LSN_RESPONSE="$(
  curl --fail-with-body -sS -G \
    "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${SOURCE_TIMELINE_ID}/get_lsn_by_timestamp" \
    -H "Authorization: Bearer ${STORCON_JWT}" \
    --data-urlencode "timestamp=${RESET_TIMESTAMP}" \
    --data-urlencode "with_lease=true"
)"

export RESET_LSN="$(echo "${RESET_LSN_RESPONSE}" | jq -r '.lsn')"
test "$(echo "${RESET_LSN_RESPONSE}" | jq -r '.kind')" = "present"
```

第二步，创建替代 Timeline：

```bash
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

第三步，确认响应为 `201` 且 Timeline `state=Active`，在数据库事务中原子切换 `branches.timeline_id`，随后重配 Compute。只有确认旧 Timeline 不再被子 Branch、Compute 或其他内部引用使用时，才调用第 2 节的 Timeline 删除接口。

---

## 5. 设置保护 Branch

保护是 Control Plane 的产品策略，用于阻止误删除、Reset 等高风险操作。它不是 Timeline Archive，也不是 Block GC。

```http
PUT /api/v1/projects/{project_id}/branches/{branch_id}/protection
Content-Type: application/json
```

```json
{
  "enabled": true
}
```

### 完整 `curl`

设置保护：

```bash
curl --fail-with-body -sS -X PUT \
  "${CP_URL}/api/v1/projects/${PROJECT_ID}/branches/${BRANCH_ID}/protection" \
  -H "Authorization: Bearer ${CP_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"enabled":true}'
```

解除保护：

```bash
curl --fail-with-body -sS -X PUT \
  "${CP_URL}/api/v1/projects/${PROJECT_ID}/branches/${BRANCH_ID}/protection" \
  -H "Authorization: Bearer ${CP_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"enabled":false}'
```

### 入参

| 位置 | 参数 | 必填 | 说明 |
|---|---|---:|---|
| Path | `project_id` | 是 | 所属 Project |
| Path | `branch_id` | 是 | 目标 Branch UID |
| Body | `enabled` | 是 | `true` 为保护，`false` 为解除保护 |

### 成功响应

```json
{
  "branch": {
    "id": "br_01JBC70MAIN000000000000000",
    "name": "main",
    "protected": true,
    "default": true,
    "state": "ready",
    "updated_at": "2026-10-29T10:00:00.000Z"
  }
}
```

### 保护策略建议

| 操作 | 受保护时是否允许 |
|---|---:|
| 查询、连接、创建子 Branch | 允许 |
| 删除 | 禁止 |
| Reset | 禁止 |
| Rename | 建议禁止，或要求更高权限 |
| Archive | 建议禁止，除非管理员显式解除保护 |
| 设置为默认 | 允许 |
| 解除保护 | 需要 Branch 管理权限并写审计日志 |

该接口只更新 Control Plane 数据库和审计日志，不调用 Storage Controller，因此不存在对应的 Storage Controller `curl`。管控必须在删除、Reset、Archive 等入口统一检查 `protected`，不能只依赖前端隐藏按钮。

---

## 6. 设置默认 Branch

默认 Branch 是 Project 级属性，表示控制台、CLI 或未显式指定 Branch 的连接默认选哪条 Branch。Storage Controller 没有 `main` 或默认 Branch 的概念。

```http
PUT /api/v1/projects/{project_id}/default-branch
Content-Type: application/json
```

```json
{
  "branch_id": "br_01JBC70MAIN000000000000000"
}
```

### 完整 `curl`

```bash
curl --fail-with-body -sS -X PUT \
  "${CP_URL}/api/v1/projects/${PROJECT_ID}/default-branch" \
  -H "Authorization: Bearer ${CP_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg branch_id "${BRANCH_ID}" '{branch_id:$branch_id}')"
```

### 入参

| 位置 | 参数 | 必填 | 说明 |
|---|---|---:|---|
| Path | `project_id` | 是 | 目标 Project |
| Body | `branch_id` | 是 | 必须属于该 Project，且状态为 `ready` |

### 成功响应

```json
{
  "project_id": "prj_01JBC6Q8D7P4F2K9M1N5R3T0VX",
  "default_branch_id": "br_01JBC70MAIN000000000000000",
  "updated_at": "2026-10-29T10:05:00.000Z"
}
```

### 行为约束

- 一个 Project 必须至多有一个默认 Branch。
- 通过更新 `projects.default_branch_id` 原子切换，不要分别修改两个 Branch 的布尔字段。
- Branch 列表中的 `default` 应由 `projects.default_branch_id == branch.id` 计算，避免双写不一致。
- 已删除、正在删除或处于错误状态的 Branch 不能设为默认。
- 设置默认 Branch 不调用 Storage Controller，也不自动迁移 Compute。

该接口只在 Control Plane 数据库中原子更新 `projects.default_branch_id` 并记录审计日志，不存在对应的 Storage Controller `curl`。

---

## Control Plane 与 Storage Controller 映射

```text
客户 API
Project(project_id)
└── Branch(branch_id, name, protected)
      │
      ├── projects.tenant_id
      └── branches.timeline_id
              │
              ▼
Storage Controller / Pageserver
Tenant(tenant_id)
└── Timeline(timeline_id)
      ├── ancestor_timeline_id
      └── ancestor_lsn
```

| 客户操作 | Control Plane 行为 | Storage Controller 行为 |
|---|---|---|
| 创建根 Branch | 生成 Branch UID、名称和映射 | 创建 Bootstrap Timeline |
| 从最新状态创建 | 解析父 Branch | 创建带祖先的 Timeline，分叉 LSN 由 Pageserver 选择 |
| 按时间创建 | 时间转 LSN、Lease、保存映射 | 查询 LSN 并创建指定分叉点 Timeline |
| 删除 | 检查保护、默认、子 Branch、Compute | 删除 Pageserver 和 Safekeeper Timeline 数据 |
| 查询 | 返回名称、保护、默认等产品元数据 | 必要时补充 Timeline 健康状态 |
| Reset | 创建替代 Timeline 并原子切映射 | 时间转 LSN、创建新 Timeline、延迟删除旧 Timeline |
| 设置保护 | 更新产品策略与审计 | 不调用 |
| 设置默认 | 更新 `projects.default_branch_id` | 不调用 |

## 最小数据模型

### `projects`

| 字段 | 用途 |
|---|---|
| `id` | 产品层 Project UID |
| `tenant_id` | Storage Controller Tenant ID |
| `default_branch_id` | 默认 Branch；外键指向 `branches.id` |

### `branches`

| 字段 | 用途 |
|---|---|
| `id` | 稳定 Branch UID |
| `project_id` | 所属 Project |
| `name` | Project 内唯一名称 |
| `timeline_id` | 当前映射的底层 Timeline ID |
| `parent_branch_id` | 产品层父 Branch |
| `creation_mode` | `root`、`latest`、`timestamp` |
| `source_timestamp` | 客户请求的时间；非时间创建为 `null` |
| `source_lsn` | 内部解析后的实际 LSN；不向普通客户暴露 |
| `protected` | 保护策略 |
| `state` | Branch Workflow 状态 |
| `version` | 乐观锁版本，防止并发 Reset/Delete |
| `created_at`、`updated_at`、`deleted_at` | 生命周期时间 |

建议唯一约束：

```text
UNIQUE(project_id, name) WHERE deleted_at IS NULL
UNIQUE(project_id, timeline_id) WHERE deleted_at IS NULL
```

### `branch_operations`

| 字段 | 用途 |
|---|---|
| `id` | Operation UID |
| `project_id`、`branch_id` | 操作对象 |
| `type` | `create_branch`、`delete_branch`、`reset_branch` |
| `idempotency_key` | 防止重复执行 |
| `status` | `pending`、`running`、`succeeded`、`failed` |
| `request_payload` | 原始业务请求，用于恢复 Workflow |
| `error_code`、`error_message` | 失败原因 |
| `created_at`、`updated_at` | 操作时间 |

## 通用错误响应

```json
{
  "error": {
    "code": "BRANCH_PROTECTED",
    "message": "Branch 'main' is protected and cannot be deleted.",
    "request_id": "req_01JBC9F0M2P7K4H8N6R3T1V5XQ",
    "details": {}
  }
}
```

| HTTP 状态码 | 典型错误码 | 含义 |
|---:|---|---|
| `400` | `INVALID_ARGUMENT` | JSON、Branch 名或时间格式不合法 |
| `401` | `UNAUTHENTICATED` | Token 缺失或无效 |
| `403` | `PERMISSION_DENIED` | 无 Project/Branch 操作权限 |
| `404` | `PROJECT_NOT_FOUND`、`BRANCH_NOT_FOUND` | 对象不存在或不属于当前租户 |
| `409` | `BRANCH_NAME_EXISTS`、`BRANCH_PROTECTED`、`BRANCH_HAS_CHILDREN`、`BRANCH_BUSY` | 当前产品状态不允许操作 |
| `422` | `TIMESTAMP_IN_FUTURE`、`TIMESTAMP_BEFORE_RETENTION`、`TIMESTAMP_NOT_RESOLVABLE` | 时间语法正确，但无法满足恢复语义 |
| `429` | `RATE_LIMITED` | 超过配额或调用频率 |
| `503` | `STORAGE_TEMPORARILY_UNAVAILABLE`、`LSN_LEASE_UNAVAILABLE` | Storage Controller/Pageserver 临时不可用，可退避重试 |

## 设计结论

1. 客户接口使用 Branch UID 和时间，绝不要求客户组装 Timeline ID 或 LSN。
2. “从最新状态创建”和“按指定时间创建”是两个清晰的客户意图，底层都落为 Timeline 创建。
3. 创建、删除、Reset 必须有幂等键和可恢复 Workflow。
4. 保护和默认 Branch 是 Control Plane 元数据，不应伪装成 Storage Controller 能力。
5. Reset 保持 Branch UID/名称稳定，通过原子切换 `timeline_id` 实现，并妥善处理旧 Timeline 的子孙依赖。
6. Branch 列表来自 Control Plane 数据库；Storage Controller 用于存储事实与健康校验，不能代替产品元数据数据库。

## 参考文档

- [[storage-controller-branch-api-curl]]
- Neon 源码：`storage_controller/src/http.rs`
- Neon 源码：`storage_controller/src/service.rs`
- Neon 源码：`pageserver/src/http/routes.rs`
- Neon 源码：`libs/pageserver_api/src/models.rs`
