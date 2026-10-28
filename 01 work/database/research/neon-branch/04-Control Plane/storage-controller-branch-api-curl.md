---
title: Storage Controller Branch API 与 curl 命令总表
aliases:
  - Storage Controller Branch API
  - Neon Timeline curl 速查表
tags: [数据库, Neon, Storage-Controller, Branch, API]
created: 2026-10-27
updated: 2026-10-27
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

## 3. Branch 创建命令表

| 功能 | 方法与路径 | `curl` 命令 | 说明 |
|---|---|---|---|
| 创建根 Branch 对应的 Timeline | `POST /v1/tenant/{tenant_id}/timeline` | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" -H "Content-Type: application/json" -d "{\"new_timeline_id\":\"${ROOT_TIMELINE_ID}\",\"pg_version\":16}"` | 祖先字段为 `null`；上层将它命名为 `main` |
| 从父 Branch 当前状态创建 | 同上 | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" -H "Content-Type: application/json" -d "{\"new_timeline_id\":\"${DEV_TIMELINE_ID}\",\"ancestor_timeline_id\":\"${PARENT_TIMELINE_ID}\",\"read_only\":false}"` | 不传 `ancestor_start_lsn`，Pageserver 选择分叉点 |
| 从 `dev` 创建子 Branch | 同上 | `export CHILD_TIMELINE_ID="$(openssl rand -hex 16)"; curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" -H "Content-Type: application/json" -d "{\"new_timeline_id\":\"${CHILD_TIMELINE_ID}\",\"ancestor_timeline_id\":\"${DEV_TIMELINE_ID}\",\"read_only\":false}"` | 支持多层祖先关系 |
| 指定 LSN 创建 Branch | 同上 | `curl --fail-with-body -sS -X POST "${SC_URL}/v1/tenant/${TENANT_ID}/timeline" -H "Content-Type: application/json" -d "{\"new_timeline_id\":\"${NEW_TIMELINE_ID}\",\"ancestor_timeline_id\":\"${PARENT_TIMELINE_ID}\",\"ancestor_start_lsn\":\"${TARGET_LSN}\",\"read_only\":false}"` | 应先校验父 Timeline 的可读范围 |

创建响应直接包含：`timeline_id`、`ancestor_timeline_id`、`ancestor_lsn` 和 `last_record_lsn`。

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

Storage Controller 只负责创建替代 Timeline和删除旧 Timeline。

## 8. Branch 绑定 Compute

| 功能 | 方法与路径 | `curl` 命令 | 用途 |
|---|---|---|---|
| 查询 Pageserver 路由 | `GET /debug/v1/tenant/{tenant_id}/locate` | `curl --fail-with-body -sS "${SC_URL}/debug/v1/tenant/${TENANT_ID}/locate"` | 返回 shard 的 PG/gRPC/HTTP 地址和 stripe size |
| 查询 Timeline 的 Safekeeper 集合 | `GET /debug/v1/tenant/{tenant_id}/timeline/{timeline_id}/locate` | `curl --fail-with-body -sS "${SC_URL}/debug/v1/tenant/${TENANT_ID}/timeline/${DEV_TIMELINE_ID}/locate"` | 返回 `generation`、`sk_set`、`new_sk_set` |
| 列出 Safekeeper | `GET /control/v1/safekeeper` | `curl --fail-with-body -sS "${SC_URL}/control/v1/safekeeper"` | 用 ID 补全 Safekeeper 地址 |
| 查询单个 Safekeeper | `GET /control/v1/safekeeper/{id}` | `curl --fail-with-body -sS "${SC_URL}/control/v1/safekeeper/${SAFEKEEPER_ID}"` | 返回地址和调度状态 |

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

- `storage_controller/src/http.rs`
- `libs/pageserver_api/src/models.rs`
- `libs/pageserver_api/src/controller_api.rs`
- `control_plane/src/bin/neon_local.rs`
- `control_plane/src/endpoint.rs`
- `storage_controller/src/compute_hook.rs`
