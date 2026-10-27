# Lakebase Branch 能力总结与 Neon 服务化对接设计

**日期**：2026-10-24  
**输入**：Lakebase 实测报告、Databricks 官方文档、当前 Neon 代码库  
**目标**：回答两个问题：Lakebase 管控为 Branch 提供了什么；如果自建 Neon 服务，管控如何与存储内核、WAL 和 Compute 对接。

> 先给结论：不应该让页存储内核直接承担 Lakebase 对外的 Branch 资源模型。Neon 内核的原语是 `Tenant + Timeline + LSN`；服务化管控层的原语是 `Project + Branch + Endpoint + Operation`。管控将 Branch 的逻辑身份映射到一个可更换的 Timeline，将 Endpoint 映射到指向该 Timeline 的 Compute。

## 1. Lakebase 管控对 Branch 做了什么

### 1.1 用户可见资源模型

```text
Project
 ├─ Branch: production
 │   ├─ Endpoint: primary (READ_WRITE)
 │   ├─ Endpoint: read-replica-* (READ_ONLY)
 │   └─ Child Branches
 └─ Operations: create/update/delete/reset...
```

- Project、Branch、Endpoint 各有稳定资源路径和独立 UID。
- Branch 的资源归属 `parent=Project` 与数据来源 `source_branch` 是两个不同概念。
- Endpoint 不是 Branch 内核对象，而是 Branch 下独立管理的计算资源；Primary 和 Read Replica 也是不同 Endpoint。
- 写操作返回长任务 Operation；提交成功不等于资源 READY。

### 1.2 已实测的 Branch 功能

| 能力组 | Lakebase 行为 | 测试结论 |
|---|---|---|
| 创建 | 选择显式源 Branch，从最新状态创建 | 返回独立 UID、源 Branch、源 LSN/时间；数据和 Schema 是创建时快照 |
| 多级分支 | Branch 可再创建子 Branch | `production → dev → dev-child` 通过，保留父子关系 |
| 数据隔离 | 子 Branch 上 DML 不影响父 Branch | UPDATE/DELETE/INSERT 隔离通过 |
| Schema 隔离 | 子 Branch 上 DDL 不影响父 Branch | 列、索引变更隔离通过 |
| PITR | 根据 `source_branch_time` 在保留窗口内创建历史 Branch | cutoff 前数据可见，cutoff 后数据不可见 |
| 显式 LSN | 使用 `source_branch_lsn` 精确指定分叉点 | 提交后 LSN 只包含该点之前已提交事务；提交前 LSN 不暴露部分事务 |
| LSN 参数约束 | 拒绝过旧 LSN，LSN 与 timestamp 互斥 | `0/1` 和 LSN+timestamp 错误路径均实测，返回 TraceId |
| Schema Diff | UI 展示父子 Schema 的列、索引等差异 | 已实测通过 |
| Reset from parent | 用父 Branch 当前数据/角色覆盖子 Branch | 数据恢复一致，连接会中断，连接地址保持不变 |
| TTL | 创建/更新过期时间，可切换为永不过期 | `1d → no_expiry → 2d` 通过，Branch UID 不变 |
| Protection | 保护的 Branch 不允许删除、Reset、自动归档；与 TTL 互斥 | TTL 冲突拒绝已验证；因套餐仅允许一个 protected Branch，新保护成功路径未完整实测 |
| 父子删除约束 | 有子 Branch 的父 Branch 不能直接删除 | 已实测拒绝 |
| Soft Delete/Purge | 软删除后 GET 不可见，名称暂时保留；Purge 后可同名重建 | 已实测；重建后 UID 变化 |
| 并发/幂等 | 同名并发创建仅一个成功 | 一成一败，未产生重复资源 |
| 超时恢复 | 客户端超时后任务可能仍在服务端执行 | 1s 超时后资源最终 READY，必须按 Operation/资源调和 |
| 错误可运维性 | 错误返回明确约束信息和 TraceId | 同名、TTL/保护、Update Mask 错误均可定位 |

### 1.3 已实测的 Compute/Endpoint 功能

- Branch 可拥有独立 Primary Endpoint，具备独立 UID、Host、直连/连接池地址、CU 范围和休眠时间。
- Endpoint 规格可独立更新；更新 CU 和休眠时间不改变 UID/Host。
- 可在同一 Branch 上创建 Read Replica；它处于 PostgreSQL recovery/read-only 状态，对写入返回 SQLSTATE `25006`，并异步追上 Primary WAL。
- Replica 可独立删除，不影响 Primary 或 Branch。
- Endpoint 可缩容到 IDLE，首次连接自动唤醒；本次实测恢复查询约 4.19s。

### 1.4 核心判断：哪些是管控，哪些是内核

| 能力 | 应归属的组件 |
|---|---|
| Branch 名称、UID、权限、配额、TTL、保护、默认 Branch | 管控元数据和策略层 |
| 长任务、幂等键、TraceId、审计、超时后调和 | 管控工作流/调和器 |
| 父子业务约束、软删除、名称保留、Purge | 管控生命周期层；内核只执行最终物理操作 |
| Timeline 在指定 LSN 处分叉、CoW 读父 Timeline | Pageserver 内核 |
| WAL 持久化、Primary/Replica 追 WAL | Safekeeper + Compute |
| 时间转 LSN、GC 窗口校验、LSN Lease | Pageserver，由管控编排 |
| Endpoint 创建、规格、休眠、路由、Host、证书 | Compute 管控/调度层 |
| Schema Diff | 管控连接两个 Compute 查 `pg_catalog`，不是 Pageserver 能力 |
| Reset from parent | 管控的跨组件工作流，不是 Timeline 原地修改 |

### 1.5 Timeline/LSN 验证完整性审计

| 验证点 | 状态 | 证据/边界 |
|---|---|---|
| latest 分叉点 | 已实测 | 服务端返回最终 `source_branch_lsn`，已包含创建前两条已提交写入 |
| 显式 `source_branch_lsn` | 已实测 | 回显精确 LSN，只包含该点前数据 |
| `source_branch_time` → 历史快照 | 已实测 | cutoff 前 `before` 可见，后 `after` 不可见 |
| PostgreSQL 事务原子性 | 已实测 | 提交前 LSN 不暴露建表/写入事务的部分状态 |
| 过旧 LSN 拒绝 | 已实测 | `0/1` 被拒绝为早于 Branch 首次活动 |
| LSN/time 互斥 | 已实测 | 同时传入被拒绝并返回 TraceId |
| 父子/多级 lineage | 已实测 | `production → dev → dev-child`，API/UI 来源 Branch 一致 |
| Reset 后用户资源稳定性 | 已实测 | 数据被父 Branch 替换、会话中断、连接地址不变 |
| Reset 前后物理 TimelineId/generation | 外部不可验 | Lakebase 公开 Branch API 不暴露内核 TimelineId；只能在自建 Neon 管控中验证 |
| 精确 restore-window/GC cutoff 临界点 | 未完整实测 | 现有测试 Branch 的寿命短于 7 天窗口，无法构造“刚好在 cutoff 内/外”的同一历史数据 |
| LSN lease 与 GC 并发竞态 | Lakebase 黑盒不可验 | 公开管控 API 不暴露 lease/GC 触发器；应在自建 Neon 内部集成测试覆盖 |
| 多 shard 是否使用同一 LSN | Lakebase 黑盒不可验 | Neon Storage Controller 代码已明确先由 shard 0 选 LSN 再传播给其他 shards |

因此，对“用户可见的 Timeline/LSN 语义”已覆盖主要正向和反向路径；剩余缺口都属内核 GC/sharding 竞态或 Lakebase 未暴露的物理 Timeline 身份，应转到自建 Neon 的集成测试中验证。

## 2. Neon 代码已提供的内核原语

### 2.1 资源映射

| 服务化概念 | Neon 对应物 | 说明 |
|---|---|---|
| Project | `TenantId` | 存储隔离和调度单元；项目名、权限等仍属管控 |
| Branch | `TimelineId` | Timeline 元数据保存 ancestor Timeline 和 ancestor LSN |
| Branch 名称 | 无内核对应 | 本地 `neon_local` 也只是用 `BranchMappings` 另存 name → TimelineId 映射 |
| Endpoint | Compute 实例 | Compute 配置持有 `tenant_id + timeline_id + mode` |
| Read Replica | `ComputeMode::Replica` | 同 Timeline 上的另一个 Compute，从 Safekeeper 追 WAL |
| Operation | 无内核对应 | 需自建持久化工作流 |

代码依据：

- `libs/pageserver_api/src/models.rs:314` 定义 `TimelineCreateRequest { new_timeline_id, mode }`。
- `libs/pageserver_api/src/models.rs:395` 的 Branch 模式只接收 `ancestor_timeline_id` 和可选 `ancestor_start_lsn`；没有 Branch 名、TTL 或 protection。
- `control_plane/src/branch_mappings.rs:15` 明确将人类可读 Branch 名称定义为“convenience”映射。这个本地 TOML 实现不能直接当生产管控库。
- `control_plane/src/endpoint.rs:196` 创建 Endpoint 时传入 `tenant_id` 和 `timeline_id`；`control_plane/src/endpoint.rs:539` 为 Replica 配置到 Safekeeper 的 replication 连接。

### 2.2 创建 Timeline/Branch

已有内部 API：

```http
POST /v1/tenant/{tenant_id}/timeline
Content-Type: application/json

{
  "new_timeline_id": "<generated TimelineId>",
  "ancestor_timeline_id": "<source TimelineId>",
  "ancestor_start_lsn": "<optional LSN>",
  "read_only": false,
  "pg_version": null
}
```

调用链：

```text
Public Control Plane worker
  → Storage Controller POST /v1/tenant/{tenant}/timeline
  → shard 0 Pageserver 先创建并确定统一 branch LSN
  → 将相同 LSN 传播到其他 shards/旧 attached locations
  → Pageserver 检查 ancestor 状态、WAL 到达和 GC 窗口
  → 创建只含 ancestor metadata 的 Timeline
  → 上传 Timeline metadata/index 到 remote storage
  → 需要时在 Safekeeper 建 Timeline
  → 返回 TimelineInfo + Safekeeper 信息
```

关键实现：

- `storage_controller/src/http.rs:448` 接收 Timeline 创建请求。
- `storage_controller/src/service.rs:3838` 先在 shard 0 创建；如果调用者没指定 LSN，使用 shard 0 选出的 `ancestor_lsn` 去创建其他 shards，避免各 shard 分叉点不一致。
- `pageserver/src/tenant.rs:2694` 校验 ancestor Timeline active/未归档，并等待指定 LSN 的 WAL 已处理。
- `pageserver/src/tenant.rs:4985` 持有 GC 临界区，校验分叉点未被 GC，然后写入 ancestor ID/LSN 元数据。新 Timeline 刚创建时无数据层，读路径回落到 ancestor，这正是 Neon 的 CoW 分支基础。
- `pageserver/src/tenant.rs:5149` 对“同 new TimelineId + 同 ancestor + 同 LSN”实现内核幂等；不同参数返回 conflict，正在创建时要求调用者重试。
- `pageserver/src/tenant.rs:2750` 之后的逻辑要等远程上传完成才向创建 API 返回成功。仅“Timeline 已能 GET”不代表创建已持久化。

### 2.3 查询 Branch 底层信息

`TimelineInfo` 已能提供：

- `timeline_id`、`ancestor_timeline_id`、`ancestor_lsn`。
- `last_record_lsn`、`disk_consistent_lsn`、`remote_consistent_lsn`。
- `min_readable_lsn`、`applied_gc_cutoff_lsn`，用于判断 PITR 可读边界。
- 逻辑/物理大小、PITR 历史大小、PG 版本、Timeline 状态、是否归档。

代码位置：`libs/pageserver_api/src/models.rs:1546`。Pageserver 有 list/detail 处理器（`pageserver/src/http/routes.rs:720` 和 `:985`）；当前 Storage Controller fork 还有聚合多 shard 的 describe 接口（`storage_controller/src/service.rs:5595`）。

但 UI/API 上的 Branch 不能只由 `TimelineInfo` 拼出。内核并不知道 name、UID、TTL、protected、default、soft-delete、权限、Operation、Endpoint 或当初的壁钟 source time。

### 2.4 时间点分支

Pageserver 已有：

```http
GET /v1/tenant/{tenant_shard_zero}/timeline/{timeline_id}/get_lsn_by_timestamp
    ?timestamp=<RFC3339>&with_lease=true
```

`pageserver/src/http/routes.rs:1036` 只允许 shard 0 执行时间 → LSN 查找，返回 `present/future/past/nodata` 以及可选 LSN lease。内核创建接口本身只接受 LSN，因此 `source_branch_time` 是对外管控 API，不是内核创建参数。

当前 Storage Controller 没有对外暴露同等的时间转 LSN 路由，建议增加一个 shard-aware 代理，由它定位 shard 0，不要让业务管控直接维护 Pageserver 拓扑。

本次补充实测还确认了一个对实现很重要的边界：

- 从已提交事务后的 `0/1D5D6E0` 创建 Branch，仅该点之前的 `before-commit` 可见，之后的 `after-commit` 不可见。
- 从同一 SQL 事务中读取到的提交前 LSN `0/1D5BB78` 创建，该事务中新建的表整体不可见，证明没有暴露部分事务状态。
- latest 创建由服务端选出 `0/1D5D8B8`，两条已提交数据都可见。
- Lakebase 拒绝早于 Branch 首次活动的 LSN，并拒绝同时传入 LSN 和 timestamp。

所以，普通最新分支应让存储内核选择 `last_record_lsn`；按时间分支应使用 Pageserver 的 timestamp → LSN 解析与 lease。如果向用户开放原始 LSN，API 必须明确要求“已提交的安全 LSN”，不能将事务内随手查得的 LSN 当成 commit boundary。

### 2.5 删除、归档、GC 与父子关系

- `storage_controller/src/service.rs:5265` 跨 shards 删除 Timeline，先删非 0 shard，最后删 shard 0；返回 202/409/404 表达异步进度。
- Pageserver 拒绝删除仍有子 Timeline 的 Timeline（`pageserver/src/tenant/timeline/delete.rs:499`）。管控应先行拒绝并给用户可读错误，内核校验作为最后防线。
- Storage Controller 已有 archival config、ancestor detach、block/unblock GC 和 LSN lease 路由（`storage_controller/src/http.rs:2550` 附近）。
- Detach ancestor 可将子 Timeline 对父层的依赖实体化，但不等于用户层的 Reset；是存储生命周期/成本优化工具。

## 3. 推荐的总体架构

```text
UI / CLI / SDK
      |
Public Branch API  ---- AuthN/AuthZ / Quota / Audit / Trace
      |
PostgreSQL metadata DB
  Project / Branch / BranchGeneration / Endpoint / Operation
      |
Durable workflow + reconciler
      |---------------------------|
      |                           |
Storage adapter              Compute adapter
      |                           |
Storage Controller          Scheduler / compute_ctl / Proxy
      |                           |
Pageserver + Safekeeper      PostgreSQL Compute
      |
Remote object storage
```

原则：

1. **公网 API 不直接访问 Pageserver**。它只调用 Storage Controller 适配层，避免泄露 shard、node、generation 等底层细节。
2. **管控数据库是用户资源的权威源**。Timeline API 是调和与健康检查来源，不是 Branch 名称/策略的权威源。
3. **写 API 只产生 desired state + Operation**。Worker 执行工作流，reconciler 持续将实际状态收敛到 desired state。
4. **逻辑 Branch 身份与物理 Timeline 分离**。这是实现 Reset 但保持 Branch UID/Host 稳定的关键。
5. **Endpoint 与 Branch 分层**。Branch 可存在而无运行中 Compute；同 Branch 上 Primary/Replica 独立缩放、休眠和删除。

## 4. 管控数据模型

### 4.1 核心表

```sql
projects(
  uid, name, tenant_id, pg_version, history_retention,
  default_branch_uid, spec_version, created_at, deleted_at
)

branches(
  uid, project_uid, branch_name,
  parent_branch_uid,
  current_generation,
  state,                         -- CREATING/READY/RESETTING/DELETING/DELETED/ERROR
  protected, is_default,
  ttl_seconds, expire_at,
  delete_mode, deleted_at, purge_after,
  created_at, updated_at,
  UNIQUE(project_uid, branch_name) WHERE purged_at IS NULL
)

branch_generations(
  branch_uid, generation,
  timeline_id,
  source_branch_uid, source_timeline_id,
  source_lsn, requested_source_time, resolved_source_time,
  state, created_at, retired_at,
  PRIMARY KEY(branch_uid, generation)
)

endpoints(
  uid, branch_uid, endpoint_name, endpoint_type,
  bound_generation, bound_timeline_id,
  min_cu, max_cu, suspend_timeout,
  hostname, pooler_hostname,
  desired_state, observed_state, spec_version,
  created_at, deleted_at
)

operations(
  uid, resource_uid, kind,
  idempotency_key, request_hash,
  state, current_step, retry_count, next_retry_at,
  error_code, error_message, trace_id,
  response_snapshot, created_at, finished_at,
  UNIQUE(scope, idempotency_key)
)
```

`branch_generations` 不建议省略。它允许 Reset 时为同一 Branch UID 创建新 Timeline，原子切换 Endpoint，同时保留旧 Timeline 一段回滚窗口。

### 4.2 用户读取 Branch 信息的正确方式

`GET /projects/{project}/branches/{branch}` 不要在前台请求里同步 fan-out 所有 Pageserver。建议：

1. 从管控 DB 读出名称、UID、父 Branch、TTL、保护、Operation 和 Endpoint 摘要。
2. 返回 reconciler 最近持久化的 observed state，包括 Timeline state、LSN、大小、Endpoint 状态。
3. 对内的 strong-read/debug API 才即时调用 Storage Controller `timeline describe`。
4. 如 observed state 超时，明确标注 `stale=true/observed_at`，而不是把 Branch 错误地判为不存在。

## 5. 关键工作流

### 5.1 点击“Create branch”后发生什么

```mermaid
sequenceDiagram
  actor U as UI/User
  participant A as Public Branch API
  participant D as Control DB
  participant W as Workflow Worker
  participant S as Storage Controller
  participant P as Pageserver
  participant C as Compute Controller

  U->>A: POST branch(source, time/LSN, ttl)
  A->>A: AuthZ, quota, name/policy validation
  A->>D: reserve name + Branch UID + Operation
  A-->>U: 202 Operation
  W->>D: load source Branch current generation
  opt source time supplied
    W->>S: resolve timestamp on shard 0 + LSN lease
    S->>P: get_lsn_by_timestamp
    P-->>S: LSN, kind, lease
  end
  W->>D: persist generated TimelineId and resolved LSN
  W->>S: create Timeline(new ID, ancestor ID, LSN)
  S->>P: create on shard 0 then remaining shards
  P-->>S: durable TimelineInfo
  S-->>W: TimelineInfo + Safekeepers
  opt product policy creates primary automatically
    W->>C: create Primary(tenant_id, timeline_id)
    C-->>W: Endpoint observed state/host
  end
  W->>D: Branch READY; Operation DONE
  U->>A: GET operation / GET branch
  A-->>U: READY resource
```

实现要点：

- API 事务中先预留 `project + branch_name`，解决同名并发。
- 生成 TimelineId 后必须在调内核前持久化；超时重试始终重用该 ID 及完全相同的 ancestor/LSN，才能利用 Pageserver 幂等语义。
- 创建返回 429/AlreadyCreating 或连接超时时，不要立即创建新 TimelineId；指数退避重试原请求，并用 describe 调和。
- Pageserver 创建 API 返回成功才代表 timeline metadata 已持久化到 remote storage。
- Timeline 已成功但 Compute 创建失败时，建议 Branch 保留为 `READY_WITHOUT_COMPUTE`/Endpoint `ERROR`，让 Endpoint 工作流单独重试，不要回滚已持久化的 Branch。

### 5.2 PITR 创建

1. 验证请求时间不早于项目保留窗口，不晚于当前时间。
2. 调 Storage Controller 新增的 `resolve_lsn(tenant, timeline, timestamp, with_lease=true)`。
3. `kind=present` 可正常创建；`past/nodata` 报“超出恢复窗口/无 WAL 时间映射”；`future` 按产品规则拒绝或折算为 latest，不可静默处理。
4. 持久化用户请求的 timestamp 和内核解析的 LSN；其后创建只传 LSN。
5. 借助 lease 防止在“解析 LSN → 创建 Timeline”窗口内被 GC；工作流超过 lease 时间时要续租/重新解析并记录变化。

### 5.3 Reset from parent

Neon 没有“把已有 Timeline 原地改成父 Timeline 现状”的 Branch API。Pageserver 中的 `tenant_reset_handler` 是重载整个 tenant 的运维操作，不是 Lakebase Branch Reset。

推荐把 Reset 实现为 Timeline generation switch：

1. 校验 Branch 不是 root/protected，并获取 Branch 级互斥锁。
2. 将 Branch 设为 `RESETTING`，阻止新 Endpoint 更改，停止或 drain 现有 Primary/Replica。
3. 从 parent 当前 Timeline 的 latest LSN 创建一个全新 TimelineId，写入 `branch_generations(generation+1)`。
4. 将所有 Endpoint 的 `bound_timeline_id` 切到新 Timeline，保留 Endpoint UID/Host，重启 Compute。
5. 健康检查通过后原子更新 Branch `current_generation`，恢复 READY。
6. 旧 Timeline 先标记 retired，保留短时回滚窗口，然后异步删除。

这样会中断现有数据库会话，但符合 Lakebase 实测的“数据/角色被替换，连接地址不变”语义。

### 5.4 Schema Diff

Pageserver 存储的是 PostgreSQL page versions，不应在它上实现 Schema Diff。管控应：

1. 确保 source/target Branch 各有一个可连接 Compute；对休眠 Endpoint 可唤醒，对无 Endpoint Branch 可启动短命静态 Compute。
2. 用受限的系统角色分别查询 `pg_catalog`/`information_schema`。
3. 对对象做 canonical normalization，然后比较 database/schema/table/column/index/constraint/function/role/privilege。
4. 对大型项目异步执行并缓存 diff，标记两侧 LSN/catalog snapshot 时间，避免把不同时刻的 schema 当成同一快照。

### 5.5 TTL、Protection、Soft Delete 和 Purge

**TTL**：管控 DB 保存 `ttl_seconds + expire_at`；扫描器生成普通 Delete Operation。创建子 Branch 时先校验父 Branch 是否允许过期子孙关系。Reset 后如要对齐 Lakebase，用原 `ttl_seconds` 重置 `expire_at`。

**Protection**：完全是管控策略。所有 delete/reset/archive/project-delete/endpoint-delete 路径必须在同一权限与策略层校验，不能只靠 UI 隐藏按钮。内核 API 还要放在仅管控服务可访问的网络/服务身份后面，否则可绕过 protection。

**Soft Delete**：

- 立即将 Branch 对普通 GET/LIST 隐藏，保留名称唯一占位和 tombstone。
- 停止/删除 Endpoints，将 Timeline 设为待删除，但在 retention 窗口内允许管理员恢复。
- 普通用户不能同名创建，直到 tombstone purge。

**Purge**：立即发起 Endpoint、Safekeeper Timeline、Pageserver Timeline 和相关密钥/路由的最终删除；内核物理对象存储回收是异步的，API 的 purge done 应定义为“不可恢复且已进入最终清理”，不应谎称“所有对象字节已立即回收”。

### 5.6 Endpoint/Replica

管控创建 Endpoint 时将 Branch 的 `current TimelineId` 和 Project `TenantId` 写入 Compute spec。

- Primary：`ComputeMode::Primary`，通过 WAL proposer 向 Safekeeper 写 WAL，Pageserver 消费 WAL 并提供 pages。
- Replica：`ComputeMode::Replica`，指向同一 `tenant_id/timeline_id`，从 Safekeeper 追 WAL，开启 hot standby/read-only。
- 不要为 Lakebase 意义的 Read Replica 再建一个 Branch Timeline；它是同 Timeline 上的计算副本。
- Primary 唯一性要在数据库约束/分布式锁上保证；`control_plane/src/endpoint.rs:283` 的本地内存检查自己也承认并发不完整，不适合生产。

## 6. 对外 API 建议

```text
POST   /v1/projects/{project}/branches
GET    /v1/projects/{project}/branches
GET    /v1/projects/{project}/branches/{branch}
PATCH  /v1/projects/{project}/branches/{branch}
DELETE /v1/projects/{project}/branches/{branch}?purge=false
POST   /v1/projects/{project}/branches/{branch}:reset
POST   /v1/projects/{project}/branches/{branch}:protect
POST   /v1/projects/{project}/branches/{branch}:unprotect
GET    /v1/projects/{project}/branches/{branch}:schemaDiff?base=...

POST   /v1/projects/{project}/branches/{branch}/endpoints
GET    /v1/projects/{project}/branches/{branch}/endpoints
PATCH  /v1/projects/{project}/branches/{branch}/endpoints/{endpoint}
DELETE /v1/projects/{project}/branches/{branch}/endpoints/{endpoint}

GET    /v1/operations/{operation}
```

创建请求三选一：

```json
{
  "branch_id": "feature-x",
  "source_branch": "production",
  "source": { "latest": true },
  "expiration": { "ttl_seconds": 86400 },
  "create_primary_endpoint": true
}
```

`source` 也可为 `{ "timestamp": "RFC3339" }` 或 `{ "lsn": "0/16B6..." }`。Lakebase 公开 API 确实接受 `source_branch_lsn`，本次也已实测；自建产品仍建议先只向高权限/内部 API 开放原始 LSN，普通用户使用 latest 或 timestamp，以免误用未提交或即将被 GC 的 LSN。

所有写请求支持：

- `Idempotency-Key`：同 key + 同 body 返回原 Operation；同 key + 不同 body 返回 409。
- `If-Match/spec_version`：用于 TTL、protection、Endpoint 规格的乐观并发控制。
- `X-Request-Id/TraceId`：贯穿 API、worker、Storage Controller、Pageserver、Compute Controller。
- 稳定错误码：`BRANCH_ALREADY_EXISTS`、`BRANCH_HAS_CHILDREN`、`BRANCH_PROTECTED`、`PITR_OUT_OF_RANGE`、`TIMELINE_CREATE_IN_PROGRESS`、`QUOTA_EXCEEDED`等。

## 7. 需补齐的 Neon 内部接口

| 优先级 | 接口/能力 | 现状与改造 |
|---|---|---|
| P0 | Storage Controller `create_timeline` | 已有；封装为内部稳定 API，保留 Pageserver 幂等语义 |
| P0 | `describe_timeline` | 当前 fork 已有多 shard 聚合；明确聚合规则和 stale/partial 状态 |
| P0 | `delete_timeline` | 已有；对 202/409/404 定义稳定、可重试的 Operation 语义 |
| P0 | `resolve_lsn_by_timestamp` | Pageserver 已有；需在 Storage Controller 新增 shard-0-aware 代理，支持 lease |
| P0 | Endpoint create/update/stop/delete/status | 将当前本地 Control Plane 行为产品化，接入调度、路由、密钥和 Proxy |
| P1 | Timeline event/outbox | 避免只靠轮询；发布 create/delete/archive/state/LSN 事件供 reconciler 消费 |
| P1 | LSN lease renew/release | 已有 create lease；对长工作流补续租和可观测性 |
| P1 | Timeline generation switch 支持 | 主要在 Compute/Proxy 管控实现，用于 Reset |
| P2 | Archive/detach automation | 已有存储原语；与 Branch 休眠、成本策略结合 |

## 8. 实施分期

### Phase 1：最小可用 Branch 服务

- Project ↔ Tenant、Branch ↔ Timeline 元数据库。
- Create/List/Get/Delete Branch，latest 和指定 LSN 分支。
- Operation、幂等键、同名唯一性、reconciler、TraceId。
- Primary Endpoint 创建/启停，连接信息与 Proxy 路由。
- 先不做 Reset 和 Soft Delete；删除为明确的不可恢复操作，降低首期复杂度。

### Phase 2：对齐 Lakebase 核心管控

- timestamp → LSN + lease 的 PITR Branch。
- TTL 扫描器、protection/default/parent-child 策略、配额。
- Endpoint 规格、缩容到 0、自动唤醒、Read Replica。
- Schema Diff 异步任务。
- Reset generation switch。

### Phase 3：完整生命周期和运营

- Soft Delete/Purge/恢复、密钥销毁、对象存储清理调和。
- Archive/detach ancestor/成本策略。
- HA Endpoint Group、跨 AZ 调度、更完整的审计和计量。
- 故障注入、大库、高并发、跨 shard 部分失败测试。

## 9. 验收清单

1. 同一幂等键重放 100 次，只有一个 Branch UID/TimelineId。
2. 同名并发创建，只有一个成功，其余返回稳定 409 错误码。
3. 在 API 超时、worker 崩溃、Storage Controller 超时的每个故障点重启，资源最终只有一个且状态收敛。
4. PITR 实测 cutoff 前可见、cutoff 后不可见；显式 LSN 要同时验证提交前/提交后边界、过旧 LSN 拒绝以及 GC/lease 竞态。
5. DML/DDL/角色/数据库的父子隔离，以及父 Branch 后续写入不会自动出现在子 Branch。
6. Reset 后 Branch UID、Endpoint UID/Host 不变，Timeline generation 变化，旧会话中断且新会话看到父 Branch 当前状态。
7. 父 Branch 有子 Branch、Branch protected、TTL/protection 互斥等约束同时在 API 层和内核最后防线生效。
8. Soft Delete 后普通 GET 不可见但名称不可重用；Purge 后可同名新建且 UID 变化。
9. Replica 写入返回 read-only 错误，Primary 新数据最终可见，删 Replica 不影响 Primary。
10. List/Get 在单 Pageserver/shard 故障时仍返回管控资源，并明确标注 observed state stale/degraded。

## 10. 参考

- 完整实测证据：`lakebase-branch-test.md`
- Databricks Branch 概念：<https://docs.databricks.com/aws/en/oltp/projects/branches>
- Databricks Branch 管理：<https://docs.databricks.com/aws/en/oltp/projects/manage-branches>
- Databricks PITR Branch：<https://docs.databricks.com/aws/en/oltp/projects/point-in-time-branching>
- Databricks Lakebase API：<https://docs.databricks.com/aws/en/oltp/projects/api-usage>
- Databricks Branch API 对象（包含 `source_branch_lsn/time`）：<https://docs.databricks.com/api/postgres/v1/get-branch>

## 11. 仍需注意的证据边界

- Lakebase 的 CoW 是官方公开语义；本次小数据测试只证明分支快照与隔离，不能独立量化其物理存储放大或大库创建耗时。
- Lakebase protection 成功后的 API 删除/Reset 拒绝路径，本轮因套餐唯一 protected Branch 配额被 `production` 占用而未完整实测。
- Neon 代码库中带 `BEGIN_HADRON` 的 Storage Controller timeline describe 是当前 fork 扩展；产品化前应将其纳入稳定内部 API 和兼容性测试。
