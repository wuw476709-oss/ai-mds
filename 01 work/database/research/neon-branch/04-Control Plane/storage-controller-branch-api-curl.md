---
title: Storage Controller Branch API 与 curl 命令总表
aliases:
  - Storage Controller Branch API
  - Neon Timeline curl 速查表
tags:
  - 数据库
  - Neon
  - Storage-Controller
  - Branch
  - API
created: 2026-10-27
updated: 2026-10-27
---

# Storage Controller Branch API 与 curl 命令总表

本文基于 Neon 开源代码提交 `34a417c`，整理 Storage Controller 与 Branch/Timeline 相关的常用 HTTP 接口，并标记哪些能力必须由产品 Control Plane 或 Compute Orchestrator 实现。

> [!important]
> Storage Controller 不认识 `project_name`、`branch_name`、保护分支和 Compute Endpoint。它管理的是 `tenant_id`、`timeline_id`、Tenant shard、Pageserver 与 Safekeeper。产品管控必须保存 `project_id → tenant_id` 和 `(project_id, branch_name) → timeline_id` 映射。

## 1. 功能总表

状态说明：

- **直接支持**：Storage Controller 有直接 REST API。
- **透传支持**：Storage Controller 将请求路由到正确的 Pageserver。
- **组合支持**：需要多个 Storage Controller 调用和产品数据库事务。
- **不支持**：必须由产品 Control Plane 或 Compute Orchestrator 实现。

| 分类 | 产品功能 | Storage Controller 能力 | 支持状态 | 产品管控还需负责 |
|---|---|---|---|---|
| Project | 创建 Project | 创建 Tenant，再创建根 Timeline | 组合支持 | Project 名称、产品 UID、账号、`project_id → tenant_id`、`main → timeline_id` |
| Project | 查询 Project | 查询 Tenant、shard 和配置 | 部分支持 | 名称、账号、套餐、状态聚合 |
| Project | 删除 Project | 删除 Tenant | 直接支持 | 停止 Compute、禁止新操作、产品元数据软删除 |
| Branch | 创建根分支 `main` | 创建 Bootstrap Timeline | 直接支持 | 保存 `main → timeline_id` |
| Branch | 从父分支创建 Branch | 创建带 `ancestor_timeline_id` 的 Timeline | 直接支持 | 解析父 Branch 名称、生成产品 Branch UID、保存名称映射 |
| Branch | 创建子分支 | 与普通 Branch 相同 | 直接支持 | 保存多层名称映射 |
| Branch | 按 LSN 创建 Branch | 设置 `ancestor_start_lsn` | 直接支持 | 校验用户权限与请求幂等 |
| Branch | 按时间创建 PITR Branch | 时间转 LSN，再创建 Timeline | 组合支持 | 保存 Branch 元数据和操作状态 |
| Branch | 列出 Branch | 列出 Timeline | 透传支持 | 用 `timeline_id` 补充 Branch 名称、保护状态和默认状态 |
| Branch | 查询 Branch 详情 | 查询 TimelineInfo | 透传支持 | Branch 名称和产品属性 |
| Branch | 查询父 Timeline/分叉 LSN | 返回 `ancestor_timeline_id`、`ancestor_lsn` | 透传支持 | 可不落库，按需查询 |
| Branch | 删除 Branch | 删除 Timeline | 直接支持 | 保护检查、默认分支检查、子分支检查、Compute 清理、删除名称映射 |
| Branch | Rename | 无底层变更 | 不支持 | 只修改 Branch 名称映射 |
| Branch | 设置默认分支 | 无底层概念 | 不支持 | 保存 `is_default` |
| Branch | 设置保护分支 | 无底层概念 | 不支持 | 保存并强制执行保护策略 |
| Branch | Reset | 没有产品级 Reset API | 组合支持 | 创建替代 Timeline、原子切换映射、重配 Compute、回收旧 Timeline |
| Branch | TTL/自动过期 | 无产品级 TTL | 不支持 | 定时任务、保护检查和删除 Workflow |
| Timeline | 查询可读 LSN 范围 | 返回 `min_readable_lsn`、`last_record_lsn` | 透传支持 | 选择和校验分叉点 |
| Timeline | LSN Lease | 对所有 shard 建立 Lease | 直接支持 | Lease 使用策略 |
| Timeline | Archive/Unarchive | 修改 Timeline archival 状态 | 直接支持 | 产品 UI 和权限控制 |
| Timeline | Detach Ancestor | 断开实际祖先依赖 | 直接支持 | 高风险操作审批和审计 |
| Timeline | Block/Unblock GC | 控制 Timeline GC | 直接支持 | 仅限内部运维，不应直接暴露给普通用户 |
| Compute | 查询 Pageserver 路由 | Tenant locate | 直接支持（内部接口） | 封装 `/debug` API、缓存与鉴权 |
| Compute | 查询 Safekeeper 集合 | Timeline locate | 直接支持（内部接口） | 结合 Safekeeper 地址生成 Compute spec |
| Compute | Branch 绑定 Compute | 只提供存储路由信息 | 不支持 | 保存 `endpoint_id → branch_id`，启动时解析 `tenant_id/timeline_id` |
| Compute | 创建、启停、删除 Endpoint | 无 Compute 生命周期 API | 不支持 | K8s/VM/ECS 调度、`compute_ctl` 生命周期 |
| Compute | 自动休眠/唤醒 | 无 | 不支持 | Proxy、Compute Orchestrator、状态机 |
| Compute | Read Replica | 无产品级 Replica API | 不支持 | 以同一 Branch/Timeline 创建不同模式的 Compute |

## 2. 命令运行环境

本地标准 `neon_local` 环境通常使用：

```bash
export SC_URL="http://127.0.0.1:1234"

export TENANT_ID="$(openssl rand -hex 16)"
export ROOT_TIMELINE_ID="$(openssl rand -hex 16)"
export DEV_TIMELINE_ID="$(openssl rand -hex 16)"

# 按具体操作赋值或重新生成
export PARENT_TIMELINE_ID="${ROOT_TIMELINE_ID}"
export NEW_TIMELINE_ID="$(openssl rand -hex 16)"
export PITR_TIMELINE_ID="$(openssl rand -hex 16)"
export TARGET_TIMESTAMP="2026-10-27T10:00:00+08:00"
export TARGET_LSN="0/1680000"
export SAFEKEEPER_ID="1"
```

如果启用了 JWT，在命令中增加：

```bash
-H "Authorization: Bearer ${STORCON_JWT}"
```

生产环境不要向用户暴露 `/debug/v1` 和 `/control/v1`；应由内部 Storage Adapter 调用。

## 3. Project/Tenant 命令表

| 功能 | 方法与路径 | `curl` 命令 | 说明 |
|---|---|---|---|
| 健康检查 | `GET /ready` | `curl --fail-with-body -sS "${SC_URL}/ready"` | 只表示 Storage Controller 已准备接收请求 |
| 创建 Tenant | `POST /v1/tenant` | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant" -H "Content-Type: application/json" -d "{\"new_tenant_id\":\"${TENANT_ID}\"}"` | 对应 Project 的底层存储对象，不会创建产品 Project |
| 查询 Tenant | `GET /control/v1/tenant/{tenant_id}` | `curl --fail-with-body -sS "${SC_URL}/control/v1/tenant/${TENANT_ID}"` | 返回 shard、策略和 Tenant 配置，通常需要 Admin Token |
| 列出 Tenant | `GET /control/v1/tenant` | `curl --fail-with-body -sS "${SC_URL}/control/v1/tenant"` | 不包含 Project 名称 |
| 查询 Tenant 配置 | `GET /v1/tenant/{tenant_id}/config` | `curl --fail-with-body -sS "${SC_URL}/v1/tenant/${TENANT_ID}/config"` | 查询 Pageserver Tenant 配置 |
| 删除 Tenant | `DELETE /v1/tenant/{tenant_id}` | `curl --fail-with-body -sS -X DELETE "${SC_URL}/v1/tenant/${TENANT_ID}"` | 删除 Project 前应先停止 Compute 并禁止新操作 |

创建产品 Project 的完整顺序是：创建 Tenant → 创建根 Timeline → 在产品库保存 Project 与 `main` Branch 映射。

## 4. Branch/Timeline 命令表

### 4.1 创建与查询

| 功能 | 方法与路径 | `curl` 命令 | 返回/注意事项 |
|---|---|---|---|
| 创建根 Timeline | `POST /v1/tenant/{tenant_id}/timeline` | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" -H "Content-Type: application/json" -d "{\"new_timeline_id\":\"${ROOT_TIMELINE_ID}\",\"pg_version\":16}"` | `ancestor_timeline_id` 和 `ancestor_lsn` 为 `null`；产品管控把它注册为 `main` |
| 从 `main` 创建 `dev` | `POST /v1/tenant/{tenant_id}/timeline` | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" -H "Content-Type: application/json" -d "{\"new_timeline_id\":\"${DEV_TIMELINE_ID}\",\"ancestor_timeline_id\":\"${ROOT_TIMELINE_ID}\",\"read_only\":false}"` | 不传 `ancestor_start_lsn` 时，由 Pageserver 选择当前分叉点 |
| 从 `dev` 创建子分支 | 同上 | `export CHILD_TIMELINE_ID="$(openssl rand -hex 16)"; curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" -H "Content-Type: application/json" -d "{\"new_timeline_id\":\"${CHILD_TIMELINE_ID}\",\"ancestor_timeline_id\":\"${DEV_TIMELINE_ID}\",\"read_only\":false}"` | 产品管控自行保存子分支名称 |
| 指定 LSN 创建 Branch | 同上 | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" -H "Content-Type: application/json" -d "{\"new_timeline_id\":\"${NEW_TIMELINE_ID}\",\"ancestor_timeline_id\":\"${PARENT_TIMELINE_ID}\",\"ancestor_start_lsn\":\"${TARGET_LSN}\",\"read_only\":false}"` | 应先确认 `min_readable_lsn <= TARGET_LSN <= last_record_lsn` |
| 列出 Timeline | `GET /v1/tenant/{tenant_id}/timeline` | `curl --fail-with-body -sS "${SC_URL}/v1/tenant/${TENANT_ID}/timeline"` | 通过 Storage Controller 透传至 shard 0 Pageserver；不包含 Branch 名称 |
| 查询 Timeline 详情 | `GET /v1/tenant/{tenant_id}/timeline/{timeline_id}` | `curl --fail-with-body -sS "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}"` | 返回祖先、LSN、大小、PG 版本和状态 |
| 查询所有 shard 的 Timeline | `GET /control/v1/tenant/{tenant_id}/timeline/{timeline_id}` | `curl --fail-with-body -sS "${SC_URL}/control/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}"` | 返回 `shards[]`，通常需要高权限 Token |

Timeline 详情中最常用的字段：

```json
{
  "timeline_id": "e936bf1a0dde77cd584ed8516a096805",
  "ancestor_timeline_id": "8a1073677c60f7bf37ab2b49185f2802",
  "ancestor_lsn": "0/16944C0",
  "last_record_lsn": "0/1710028",
  "min_readable_lsn": "0/1500000",
  "pg_version": 16,
  "state": "Active"
}
```

### 4.2 PITR 与 LSN

| 功能 | 方法与路径 | `curl` 命令 | 返回/注意事项 |
|---|---|---|---|
| 时间转换为 LSN | `GET .../get_lsn_by_timestamp` | `curl --fail-with-body -sS -G "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${PARENT_TIMELINE_ID}/get_lsn_by_timestamp" --data-urlencode "timestamp=${TARGET_TIMESTAMP}" --data-urlencode "with_lease=true"` | `TARGET_TIMESTAMP` 使用 RFC3339；返回 `lsn`、`kind` 和可选 Lease |
| 建立 LSN Lease | `POST .../lsn_lease` | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${PARENT_TIMELINE_ID}/lsn_lease" -H "Content-Type: application/json" -d "{\"lsn\":\"${TARGET_LSN}\"}"` | 在 PITR 或静态只读 Compute 使用指定 LSN 前保护该点 |
| 创建 PITR Branch | `POST /v1/tenant/{tenant_id}/timeline` | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" -H "Content-Type: application/json" -d "{\"new_timeline_id\":\"${PITR_TIMELINE_ID}\",\"ancestor_timeline_id\":\"${PARENT_TIMELINE_ID}\",\"ancestor_start_lsn\":\"${TARGET_LSN}\",\"read_only\":false}"` | 产品管控保存新的 Branch 名称映射 |

推荐获取 LSN：

```bash
export TARGET_TIMESTAMP="2026-10-27T10:00:00+08:00"

export TARGET_LSN="$(
  curl --fail-with-body -sS -G \
    "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${PARENT_TIMELINE_ID}/get_lsn_by_timestamp" \
    --data-urlencode "timestamp=${TARGET_TIMESTAMP}" \
    --data-urlencode "with_lease=true" |
  jq -r '.lsn'
)"
```

### 4.3 删除与高级操作

| 功能 | 方法与路径 | `curl` 命令 | 返回/注意事项 |
|---|---|---|---|
| 删除 Timeline | `DELETE /v1/tenant/{tenant_id}/timeline/{timeline_id}` | `curl --fail-with-body -i -X DELETE "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}"` | 完成返回 `200`；超过内部等待时间可能返回 `409`，调用方应重试 |
| Archive | `PUT .../archival_config` | `curl --fail-with-body -sS -X PUT "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}/archival_config" -H "Content-Type: application/json" -d '{"state":"Archived"}'` | Archive 不等于产品保护分支 |
| Unarchive | 同上 | `curl --fail-with-body -sS -X PUT "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}/archival_config" -H "Content-Type: application/json" -d '{"state":"Unarchived"}'` | 恢复 Timeline |
| Detach Ancestor（重挂子节点） | `PUT .../detach_ancestor` | `curl --fail-with-body -sS -X PUT "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}/detach_ancestor?detach_behavior=no_ancestor_and_reparent"` | 高风险、不可简单撤销 |
| Detach 多层祖先 | 同上 | `curl --fail-with-body -sS -X PUT "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}/detach_ancestor?detach_behavior=multi_level_and_no_reparent"` | 不重挂子 Timeline |
| Block GC | `POST .../block_gc` | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}/block_gc"` | 内部运维操作 |
| Unblock GC | `POST .../unblock_gc` | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}/unblock_gc"` | 恢复 GC |

删除 Branch 的产品级顺序：检查保护/默认/子分支 → 停止或迁移 Compute → 标记 `deleting` → 删除 Timeline → 确认成功 → 删除名称映射。

## 5. Compute 绑定所需命令

Storage Controller 不创建 Compute，但可以提供启动 Compute 所需的存储路由。

| 功能 | 方法与路径 | `curl` 命令 | 用途 |
|---|---|---|---|
| 查询 Tenant 的 Pageserver 路由 | `GET /debug/v1/tenant/{tenant_id}/locate` | `curl --fail-with-body -sS "${SC_URL}/debug/v1/tenant/${TENANT_ID}/locate"` | 返回所有 shard 的 Pageserver PG/gRPC/HTTP 地址和 stripe size |
| 查询 Timeline 的 Safekeeper 集合 | `GET /debug/v1/tenant/{tenant_id}/timeline/{timeline_id}/locate` | `curl --fail-with-body -sS "${SC_URL}/debug/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}/locate"` | 返回 `generation`、`sk_set` 和 `new_sk_set` |
| 列出 Safekeeper 节点 | `GET /control/v1/safekeeper` | `curl --fail-with-body -sS "${SC_URL}/control/v1/safekeeper"` | 用 Safekeeper ID 补全地址 |
| 查询单个 Safekeeper | `GET /control/v1/safekeeper/{id}` | `curl --fail-with-body -sS "${SC_URL}/control/v1/safekeeper/${SAFEKEEPER_ID}"` | 查询指定 Safekeeper 地址和调度状态 |

产品级绑定流程：

```text
endpoint_id → branch_id
              │
              ├── branches.timeline_id
              └── projects.tenant_id
                       │
                       ▼
              Storage Controller locate
                       │
              ┌────────┴────────┐
              │                 │
         Pageserver 路由    Safekeeper 集合
              │                 │
              └────────┬────────┘
                       ▼
              Compute Orchestrator
                       ▼
               compute_ctl/Postgres
```

本地 `neon_local` 绑定命令不是 Storage Controller REST API：

| 功能 | 本地命令 | 说明 |
|---|---|---|
| 创建并绑定 Endpoint | `./target/debug/neon_local endpoint create dev-compute --tenant-id "${TENANT_ID}" --branch-name dev --pg-version 16` | 从 `.neon/config` 解析 `dev → timeline_id` |
| 启动 Endpoint | `./target/debug/neon_local endpoint start dev-compute` | 内部查询 Tenant locate 并启动 `compute_ctl` |
| 列出 Endpoint | `./target/debug/neon_local endpoint list --tenant-id "${TENANT_ID}"` | 本地目录状态，不是 Storage Controller 状态 |
| 停止 Endpoint | `./target/debug/neon_local endpoint stop dev-compute` | 保留 Endpoint 配置和 PGDATA |
| 销毁本地 Endpoint | `./target/debug/neon_local endpoint stop dev-compute --destroy` | 只删除本地 Compute 数据，不删除 Timeline 或 Branch 映射 |

## 6. Neon/Lakebase 已测试、但 Storage Controller 不包含的能力

以下功能不能通过向 Storage Controller 发送一个 `curl` 直接完成，应由产品管控或 Compute Orchestrator 实现。

| 已测试的产品能力 | Storage Controller 为什么不包含 | 建议实现位置 | 最小实现 |
|---|---|---|---|
| 创建、查询和删除 Project | Storage Controller 只有 Tenant，没有产品 Project | Control Plane | `projects` 表保存 Project 名称、账号和 `tenant_id` |
| Branch 名称及 UID | 内核只识别 TimelineId | Control Plane | `branches` 表保存 `branch_uid/name/timeline_id` |
| Rename Branch | Timeline ID 和数据都不需要变化 | Control Plane | 只更新 `branches.name` |
| 默认 Branch | 内核没有 `main` 概念 | Control Plane | `branches.is_default`，每个 Project 唯一 |
| 保护 Branch | 内核不理解删除/Reset 权限策略 | Control Plane | `branches.protected` 或策略 JSON；所有写操作统一校验 |
| Branch Reset | 内核只有创建和删除 Timeline | Control Plane Workflow | 创建替代 Timeline → 原子切换映射 → 重配 Compute → 回收旧 Timeline |
| Branch TTL/临时分支自动清理 | Storage Controller 不保存产品过期时间 | Control Plane Scheduler | `expires_at` + 定时删除 Workflow |
| Endpoint 创建与 Branch 绑定 | Storage Controller 不管理 Compute | Control Plane + Compute Orchestrator | `compute_endpoints.branch_id`；启动时解析 Tenant/Timeline |
| Endpoint 启停、删除和规格调整 | 属于 Pod/VM/ECS 生命周期 | Compute Orchestrator | desired/observed state 状态机 |
| 自动休眠与唤醒 | 依赖连接流量、Proxy 和 Compute 状态 | Proxy + Compute Orchestrator | 空闲检测、停止 Compute、连接触发唤醒 |
| Read Replica | 本质是同一 Timeline 上的 Compute 模式 | Compute Orchestrator | Endpoint spec 保存 primary/replica 模式 |
| Branch 独立连接串和密码 | 属于接入、身份和密钥管理 | Proxy/Auth/Secret Manager | Endpoint hostname、角色、密码或短期 Token |
| 权限、配额、计费和审计 | 不属于存储内核 | Control Plane | IAM、quota、operations、audit log |
| 产品 API 幂等和异步进度 | Storage 调用可能超时、部分成功 | Control Plane Workflow | `operations` 表、idempotency key、重试与对账 |

## 7. 源码依据

- Storage Controller 路由：`storage_controller/src/http.rs`
- Timeline 创建请求和 TimelineInfo：`libs/pageserver_api/src/models.rs`
- Tenant create/locate 模型：`libs/pageserver_api/src/controller_api.rs`
- Storage Controller 本地客户端：`control_plane/src/storage_controller.rs`
- Branch 创建编排：`control_plane/src/bin/neon_local.rs`
- Compute Endpoint 本地实现：`control_plane/src/endpoint.rs`
- Storage Controller Compute Hook：`storage_controller/src/compute_hook.rs`
