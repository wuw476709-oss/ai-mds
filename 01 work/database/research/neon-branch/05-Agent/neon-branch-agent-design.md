---
title: Neon Local Branch 能力抽取与 Agent 数据库设计
aliases:
  - Neon Branch Agent 设计
  - neon_local Branch 抽取
tags: [数据库, Neon, Branch, Agent, Control-Plane, 数据模型]
created: 2026-10-29
updated: 2026-10-29
---

# Neon Local Branch 能力抽取与 Agent 数据库设计

## 结论

Neon 开源 `control_plane` 中没有一个完整的云端 Branch 管控服务。现有 `neon_local` 的 Branch 能力主要是：

1. 在 `.neon/config` 中保存 `branch_name + tenant_id → timeline_id` 映射；
2. 将 Branch 名称解析成 Timeline ID；
3. 调 Storage Controller 创建根 Timeline 或子 Timeline；
4. 查询 Pageserver Timeline 后，用本地映射补充名称并打印树；
5. 创建 Compute endpoint 时，将 Branch 名解析成 Timeline ID；
6. 把 endpoint 与 `tenant_id/timeline_id` 的绑定保存到本地 `endpoint.json`。

它目前没有实现：

- Branch 删除命令；
- Branch Reset；
- 按时间创建 Branch；
- Branch Rename/Unmap；
- 保护 Branch；
- 默认 Branch 元数据；
- TTL/自动清理；
- 幂等操作、失败恢复和跨进程事务。

因此，后续 Agent 不应只是机械复制 `neon_local`，而应抽取它的“解析、执行、持久化”职责，并补上数据库事务、幂等 Workflow 和存储状态对账。

## 1. 源码中的 Branch 相关组件

### 1.1 文件与职责

| 文件 | 当前职责 | Agent 中的对应模块 |
|---|---|---|
| `control_plane/src/bin/neon_local.rs` | CLI 参数、Branch 创建编排、名称解析、列表展示、Endpoint 创建 | Agent API Handler + `BranchService` |
| `control_plane/src/local_env.rs` | 从 `.neon/config` 加载/保存 Branch 映射和默认 Tenant | `BranchRepository` + `TenantRepository` |
| `control_plane/src/storage_controller.rs` | Storage Controller HTTP client | `StorageControllerClient` |
| `control_plane/src/endpoint.rs` | Endpoint 创建、加载、绑定 Tenant/Timeline、启动 Compute | `ComputeService` + `EndpointRepository` |
| `control_plane/src/branch_mappings.rs` | 独立的 `BranchMappings` 文件实现 | 可参考，但当前没有接入 `control_plane/src/lib.rs`，也没有调用点 |

`branch_mappings.rs` 与 `LocalEnv` 中存在近似重复的映射代码。当前真正被 `neon_local` 使用的是 `LocalEnv.branch_name_mappings`，而不是独立 `BranchMappings`。

### 1.2 当前本地数据结构

`.neon/config` 中保存：

```toml
default_tenant_id = "ff5117463416aef7a63e532978974a01"

[branch_name_mappings]
main = [[
  "ff5117463416aef7a63e532978974a01",
  "8a1073677c60f7bf37ab2b49185f2802",
]]
dev = [[
  "ff5117463416aef7a63e532978974a01",
  "e936bf1a0dde77cd584ed8516a096805",
]]
```

Rust 类型是：

```rust
default_tenant_id: Option<TenantId>
branch_name_mappings: HashMap<String, Vec<(TenantId, TimelineId)>>
```

这里使用 `Vec<(TenantId, TimelineId)>`，是因为 TOML 对嵌套泛型 Map 的序列化限制。数据库化后不需要保留这种结构，应直接拆成行。

### 1.3 映射操作

`LocalEnv::register_branch_mapping`：

- Key 是 `branch_name`；
- 在同一 Branch 名下按 `tenant_id` 查找；
- 相同 Tenant、相同 Timeline 重复注册视为成功；
- 相同 Tenant、不同 Timeline 会报错；
- 没有更新映射、删除映射或 Rename 能力。

`LocalEnv::get_branch_timeline_id`：

- 输入 `branch_name + tenant_id`；
- 返回 `timeline_id`；
- 当前 `LocalEnv` 实现不支持把形似 Timeline ID 的 Branch 名直接透传。

`LocalEnv::timeline_name_mappings`：

- 将正向映射反转为 `(tenant_id,timeline_id) → branch_name`；
- 用于 Timeline 列表和 Endpoint 列表补充人类可读名称。

对应源码：

- `control_plane/src/local_env.rs:595`：注册映射；
- `control_plane/src/local_env.rs:624`：名称解析；
- `control_plane/src/local_env.rs:636`：反向映射；
- `control_plane/src/local_env.rs:792`：保存 `.neon/config`。

### 1.4 创建根 Branch

入口：`cargo neon timeline create`。

当前调用链：

```text
TimelineCmd::Create
  → get_tenant_id(--tenant-id 或 default_tenant_id)
  → 生成/读取 new_timeline_id
  → StorageController::tenant_timeline_create(Bootstrap)
  → env.register_branch_mapping(branch_name, tenant_id, timeline_id)
  → 命令结束后 env.persist_config()
```

请求结构：

```rust
TimelineCreateRequest {
    new_timeline_id,
    mode: TimelineCreateRequestMode::Bootstrap {
        existing_initdb_timeline_id: None,
        pg_version: Some(args.pg_version),
    },
}
```

对应源码：`control_plane/src/bin/neon_local.rs:1190` 附近。

### 1.5 创建子 Branch

入口：

```bash
cargo neon timeline branch \
  --branch-name dev \
  --ancestor-branch-name main
```

当前调用链：

```text
TimelineCmd::Branch
  → get_tenant_id()
  → 未显式传 timeline_id 时生成 TimelineId
  → ancestor_branch_name 缺省为 "main"
  → get_branch_timeline_id(name, tenant_id)
  → 组装 TimelineCreateRequestMode::Branch
  → StorageController::tenant_timeline_create()
  → register_branch_mapping(new_name, tenant_id, new_timeline_id)
  → 命令结束后 persist_config()
```

请求结构：

```rust
TimelineCreateRequestMode::Branch {
    ancestor_timeline_id,
    ancestor_start_lsn,
    read_only: false,
    pg_version: None,
}
```

对应源码：`control_plane/src/bin/neon_local.rs:1276-1312`。

当前 CLI 只支持：

- 不传 `ancestor_start_lsn`，从父 Timeline 当前状态创建；
- 直接传 LSN 创建。

它不支持用户提交时间后自动调用 `get_lsn_by_timestamp`。Agent 应补上“时间 → LSN → Lease → 创建 Timeline”的编排，不应要求客户提交 LSN。

### 1.6 创建 Tenant 时自动创建 `main`

`TenantCmd::Create` 会：

1. 创建 Tenant；
2. 创建 Bootstrap Timeline；
3. 把它注册成常量 `DEFAULT_BRANCH_NAME = "main"`；
4. 可选设置 `default_tenant_id`。

这里的 `main` 只是本地 CLI 约定，不是 Storage Controller 的默认 Branch 属性。

### 1.7 导入 Tenant 后生成 Branch 名称

`TenantCmd::Import` 会查询 Timeline：

- 找到第一个没有祖先的 Timeline，命名为 `main`；
- 其余 Timeline 依次命名为 `branch_1`、`branch_2`；
- 保存本地映射。

这是开发环境便利逻辑，不应直接用于生产 Agent。生产系统应由调用方提供稳定名称，或将未映射 Timeline 标记为 orphan/unmapped，不能因遍历顺序变化而重新命名。

### 1.8 Timeline 列表

`TimelineCmd::List` 当前：

1. 直接查询默认 Pageserver 的 Timeline 列表；
2. 结合反向名称映射；
3. 根据 `ancestor_timeline_id` 构造内存树；
4. 打印 `branch_name [timeline_id]` 和 `ancestor_lsn`。

对应源码：

- `control_plane/src/bin/neon_local.rs:1178`：命令入口；
- `control_plane/src/bin/neon_local.rs:810-919`：构造并打印 Timeline 树。

源码中已经有 TODO：分片环境不应该直接使用默认 Pageserver。Agent 应通过 Storage Controller 查询 shard 0 或全 shard 信息。

### 1.9 手动注册映射

入口：

```bash
cargo neon mappings map \
  --tenant-id <tenant_id> \
  --timeline-id <timeline_id> \
  --branch-name dev
```

它只执行 `register_branch_mapping`，不检查 Timeline 是否真实存在，也不支持修改和删除。

对应源码：`control_plane/src/bin/neon_local.rs:1663`。

### 1.10 Endpoint 绑定 Branch

`EndpointCmd::Create` 当前：

```text
branch_name 缺省为 main
  → get_branch_timeline_id(branch_name, tenant_id)
  → 得到 timeline_id
  → 检查同一 Tenant/Timeline 是否已有 Primary
  → 创建 Endpoint
  → 写 .neon/endpoints/<endpoint_id>/endpoint.json
```

`endpoint.json` 的 Branch 相关字段：

```json
{
  "endpoint_id": "dev-compute",
  "tenant_id": "...",
  "timeline_id": "...",
  "mode": "Primary",
  "pg_port": 55436,
  "external_http_port": 3082,
  "internal_http_port": 3083,
  "pg_version": 16
}
```

对应源码：

- `control_plane/src/bin/neon_local.rs:1381-1400`：解析 Branch 并创建 Endpoint；
- `control_plane/src/endpoint.rs:92`：`EndpointConf`；
- `control_plane/src/endpoint.rs:220` 附近：写入 `endpoint.json`。

### 1.11 当前持久化时序

`neon_local` 为本地文件模型加了仓库级文件锁，避免多个命令并发修改简单文件：

```text
加载 .neon/config
  → 执行远程操作/本地操作
  → 比较 LocalEnv 是否变化
  → 命令成功后 persist_config()
```

这个模型存在重要风险：

```text
Storage Controller 创建 Timeline 成功
  → register_branch_mapping 失败
  或 persist_config 失败
  → SC 中已有 Timeline，本地却没有名称映射
```

迁移到 Agent 后必须使用操作记录和可恢复 Workflow 解决，不能只把 `fs::write` 替换成一条普通 `INSERT`。

## 2. 当前能力全集与缺口

| 能力 | neon_local 当前实现 | 适合迁入 Agent | 需要补充 |
|---|---|---|---|
| Branch 名称解析 | 有 | 是 | 数据库 Repository、版本和缓存 |
| 反向 Timeline→名称 | 有 | 是 | 唯一约束和 orphan 标记 |
| 创建根 Timeline | 有 | 是 | 幂等与失败恢复 |
| 从父 Branch 最新位置创建 | 有 | 是 | 分片场景校验 |
| 按 LSN 创建 | 有 | 仅保留内部能力 | 对外改为按时间创建 |
| 按时间创建 | 无 | 是 | 时间转 LSN、Lease、kind 校验 |
| Timeline 列表树 | 有 | 是 | 改为通过 SC 查询，不直连默认 Pageserver |
| 手工 Map | 有 | 是，限管理员/导入 | 校验 Timeline 存在、审计 |
| Unmap/Rename | 无 | 是 | 数据库更新和并发控制 |
| 删除 Branch | 无 | 是 | 前置检查、SC 删除、映射 tombstone |
| Reset Branch | 无 | 是 | 新 Timeline、CAS 切映射、旧 Timeline 回收 |
| 保护 Branch | 无 | 通常留在中央管控 | Agent 可做防御性二次校验 |
| 默认 Branch | 无，只有硬编码 `main` | 通常留在中央管控 | 不要混同 `default_tenant_id` |
| Endpoint 绑定 | 有 | 是 | 数据库化、重绑和版本控制 |
| 幂等操作 | 无 | 必须 | `operation_id`/`idempotency_key` |
| 并发控制 | 仅本地文件锁 | 必须 | DB 唯一约束、行锁、乐观锁 |
| 对账修复 | 无 | 必须 | 映射与 SC Timeline 双向 reconcile |

## 3. 推荐的目标架构

```text
客户
  │
  ▼
中央 Control Plane
  ├── 认证、权限、Project
  ├── 产品 Branch UID、保护、默认、配额
  └── 生成 operation_id / idempotency_key
          │
          ▼
Agent API
  ├── BranchService
  │     ├── 名称/引用 → tenant_id、timeline_id
  │     ├── 调 Storage Controller
  │     ├── Branch Workflow
  │     └── 返回执行结果
  ├── ComputeService
  │     └── Endpoint 与 Timeline 绑定
  ├── Reconciler
  │     └── Agent DB ↔ Storage Controller 对账
  └── Repository
          │
          ▼
Agent Metadata DB
  ├── tenant 默认值
  ├── Branch 名称映射
  ├── Endpoint 绑定
  └── 操作状态/幂等记录
          │
          ▼
Storage Controller
  └── Tenant、Timeline、祖先、LSN、Pageserver/Safekeeper 状态
```

### 3.1 职责边界

| 数据/能力 | 建议权威来源 |
|---|---|
| 客户、Project、权限、保护、默认 Branch | 中央 Control Plane |
| `tenant_id`、`timeline_id`、祖先和 LSN 的真实状态 | Storage Controller/Pageserver |
| Agent 环境中的名称→Timeline 映射 | Agent Metadata DB |
| Endpoint→Tenant/Timeline 绑定 | Agent Metadata DB |
| 操作幂等、重试和失败恢复 | Agent Metadata DB |
| 私钥/JWT/数据库密码 | Secret Manager，不存 Agent Metadata DB 明文 |
| PostgreSQL `pgdata`、日志、临时文件 | 本地磁盘/对象存储，不写元数据表 |

中央管控调用 Agent 时，建议已经完成 Project→Tenant 的产品解析，向 Agent 传入 `tenant_id`。Agent 负责 Branch 名称/引用→Timeline 的本地解析。这样与 `neon_local` 当前本地数据职责最接近，也避免 Agent 再保存一套 Project 模型。

### 3.2 Agent 模块拆分

```text
agent/src/branch/
├── api.rs                   HTTP/gRPC 请求与响应
├── service.rs               创建、删除、Reset、查询 Workflow
├── repository.rs            映射和操作记录数据库访问
├── storage_controller.rs    SC Client
├── models.rs                Agent DTO/状态枚举
└── reconcile.rs             DB 与 SC 对账

agent/src/compute/
├── service.rs               Endpoint 创建、启动、停止、重绑
└── repository.rs            Endpoint 元数据
```

可以复用的逻辑：

- `TimelineCreateRequest` 和 Neon ID/LSN 类型；
- `StorageController::tenant_timeline_create` 的 HTTP client 思路；
- `TimelineInfo` 构造父子树的算法；
- Endpoint 冲突检查。

不应直接复用的逻辑：

- `LocalEnv` 全量克隆后写整个 TOML；
- `RepoLock` 文件锁；
- `branch_1` 等遍历顺序命名；
- 直连默认 Pageserver 查询 Timeline；
- 创建成功后才尝试写映射的非事务时序。

## 4. 数据库选型

### 推荐

- 单机开发 Agent：SQLite 可以作为过渡方案；
- 多 Agent、高可用或远程部署：使用 PostgreSQL；
- 多 Agent 必须访问同一个 Metadata DB，或者确保同一 environment 只有唯一 Agent owner。

下面 DDL 按 PostgreSQL 设计。

## 5. 最小表结构

### 5.1 `agent_environments`

表示一套本地 Neon/Storage Controller 环境，替代“某个 `.neon` 目录”的身份。

```sql
CREATE TABLE agent_environments (
    id                  uuid PRIMARY KEY,
    name                text NOT NULL UNIQUE,
    storage_controller_url text NOT NULL,
    status              text NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'disabled', 'error')),
    version             bigint NOT NULL DEFAULT 0,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
```

不要把 `STORCON_JWT` 明文存这里。只保存 Secret Manager 引用，或由 Agent 启动配置注入。

### 5.2 `agent_tenants`

替代 `.neon/config.default_tenant_id`，同时登记 Agent 当前可操作的 Tenant。

```sql
CREATE TABLE agent_tenants (
    environment_id      uuid NOT NULL REFERENCES agent_environments(id),
    tenant_id           char(32) NOT NULL,
    is_default          boolean NOT NULL DEFAULT false,
    status              text NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'missing', 'error')),
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (environment_id, tenant_id),
    CHECK (tenant_id ~ '^[0-9a-f]{32}$')
);

CREATE UNIQUE INDEX uq_agent_tenants_one_default
    ON agent_tenants(environment_id)
    WHERE is_default;
```

如果生产 Agent 所有请求都显式传 `tenant_id`，可以不支持默认 Tenant；该字段主要用于兼容 `neon_local` 使用习惯。

### 5.3 `agent_branch_mappings`

替代 `.neon/config.branch_name_mappings`。

```sql
CREATE TABLE agent_branch_mappings (
    id                  uuid PRIMARY KEY,
    environment_id      uuid NOT NULL REFERENCES agent_environments(id),
    tenant_id           char(32) NOT NULL,
    branch_name         text NOT NULL,
    timeline_id         char(32) NOT NULL,
    state               text NOT NULL
                        CHECK (state IN (
                            'creating', 'ready', 'resetting',
                            'deleting', 'error', 'deleted'
                        )),
    version             bigint NOT NULL DEFAULT 0,
    last_operation_id   uuid,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    deleted_at          timestamptz,
    FOREIGN KEY (environment_id, tenant_id)
        REFERENCES agent_tenants(environment_id, tenant_id),
    CHECK (tenant_id ~ '^[0-9a-f]{32}$'),
    CHECK (timeline_id ~ '^[0-9a-f]{32}$'),
    CHECK (length(branch_name) BETWEEN 1 AND 63)
);

CREATE UNIQUE INDEX uq_agent_branch_name_active
    ON agent_branch_mappings(environment_id, tenant_id, branch_name)
    WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX uq_agent_branch_timeline_active
    ON agent_branch_mappings(environment_id, tenant_id, timeline_id)
    WHERE deleted_at IS NULL;
```

最小化原则：

- 不把 `ancestor_timeline_id`、`ancestor_lsn`、`last_record_lsn` 作为权威字段重复保存；需要时从 SC 查询；
- 如需列表性能，可以增加 `last_observed_*` 缓存字段，但必须明确它们不是事实来源；
- Reset 通过 CAS 更新 `timeline_id` 和 `version`，不能沿用 `register_branch_mapping` 的“已存在就禁止改变”逻辑；
- 删除使用 tombstone，短期不要物理删行，便于幂等重试和审计。

### 5.4 `agent_endpoint_bindings`

替代 `.neon/endpoints/<endpoint_id>/endpoint.json` 中的元数据部分。`pgdata`、日志和生成的配置文件仍保留在文件系统。

```sql
CREATE TABLE agent_endpoint_bindings (
    id                  uuid PRIMARY KEY,
    environment_id      uuid NOT NULL REFERENCES agent_environments(id),
    endpoint_id         text NOT NULL,
    tenant_id           char(32) NOT NULL,
    timeline_id         char(32) NOT NULL,
    mode                text NOT NULL
                        CHECK (mode IN ('primary', 'replica', 'static')),
    static_lsn          text,
    pg_port             integer NOT NULL,
    external_http_port  integer NOT NULL,
    internal_http_port  integer NOT NULL,
    pg_version          integer NOT NULL,
    grpc                boolean NOT NULL DEFAULT false,
    runtime_state       text NOT NULL DEFAULT 'stopped'
                        CHECK (runtime_state IN (
                            'creating', 'stopped', 'starting',
                            'running', 'stopping', 'error', 'deleted'
                        )),
    config              jsonb NOT NULL DEFAULT '{}'::jsonb,
    version             bigint NOT NULL DEFAULT 0,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    deleted_at          timestamptz,
    FOREIGN KEY (environment_id, tenant_id)
        REFERENCES agent_tenants(environment_id, tenant_id),
    CHECK (tenant_id ~ '^[0-9a-f]{32}$'),
    CHECK (timeline_id ~ '^[0-9a-f]{32}$'),
    CHECK ((mode = 'static' AND static_lsn IS NOT NULL)
        OR (mode <> 'static' AND static_lsn IS NULL))
);

CREATE UNIQUE INDEX uq_agent_endpoint_id_active
    ON agent_endpoint_bindings(environment_id, endpoint_id)
    WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX uq_one_primary_per_timeline
    ON agent_endpoint_bindings(environment_id, tenant_id, timeline_id)
    WHERE mode = 'primary'
      AND runtime_state IN ('creating', 'starting', 'running')
      AND deleted_at IS NULL;
```

数据库存配置元数据和绑定关系，但以下内容继续留在磁盘：

- `pgdata/`；
- `compute.log`；
- 最终生成的 `postgresql.conf`；
- socket、pid 等运行时文件。

### 5.5 `agent_operations`

这是 Agent 化后最关键的新增表，用来解决“SC 成功但本地映射保存失败”的问题。

```sql
CREATE TABLE agent_operations (
    id                  uuid PRIMARY KEY,
    environment_id      uuid NOT NULL REFERENCES agent_environments(id),
    idempotency_key     text NOT NULL,
    operation_type      text NOT NULL
                        CHECK (operation_type IN (
                            'branch_create_root',
                            'branch_create_latest',
                            'branch_create_timestamp',
                            'branch_delete',
                            'branch_reset',
                            'branch_rename',
                            'branch_import_mapping',
                            'endpoint_bind',
                            'endpoint_rebind'
                        )),
    status              text NOT NULL
                        CHECK (status IN (
                            'pending', 'running', 'retrying',
                            'succeeded', 'failed', 'cancelled'
                        )),
    tenant_id           char(32),
    branch_name         text,
    old_timeline_id     char(32),
    new_timeline_id     char(32),
    request_payload     jsonb NOT NULL,
    result_payload      jsonb,
    error_code          text,
    error_message       text,
    attempt_count       integer NOT NULL DEFAULT 0,
    next_retry_at       timestamptz,
    lease_owner         text,
    lease_expires_at    timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    finished_at         timestamptz,
    UNIQUE (environment_id, idempotency_key)
);

CREATE INDEX idx_agent_operations_retry
    ON agent_operations(status, next_retry_at)
    WHERE status IN ('pending', 'retrying');
```

`id` 最好直接采用中央管控下发的 `operation_id`；`idempotency_key` 用于应对同一业务请求的网络重试。

### 5.6 可选：`agent_audit_events`

```sql
CREATE TABLE agent_audit_events (
    id              bigserial PRIMARY KEY,
    environment_id  uuid NOT NULL REFERENCES agent_environments(id),
    operation_id    uuid,
    event_type      text NOT NULL,
    payload         jsonb NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);
```

如果中央管控已经有完整审计，可将 Agent 事件通过消息或回调上报，Agent DB 只保留短期执行日志。

## 6. 核心 Workflow

### 6.1 创建根 Branch

```text
接收 operation_id、tenant_id、branch_name
  → DB 事务：
       插入 agent_operations(pending)
       生成 new_timeline_id
       插入 branch_mappings(state=creating)
       把 new_timeline_id 写入 operation
  → 提交事务
  → 调 SC 创建 Bootstrap Timeline
  → DB 事务：mapping.state=ready，operation=succeeded
  → 返回 tenant_id、branch_name、timeline_id、TimelineInfo
```

关键点：必须在调用 SC 前把生成的 `new_timeline_id` 持久化。Agent 重启后重试时继续使用同一个 ID，不能重新生成。

### 6.2 从最新状态创建子 Branch

```text
接收 parent_branch_name
  → DB 查询 parent timeline_id
  → 预占新名称并持久化 new_timeline_id
  → 调 SC 创建 Branch，不传 ancestor_start_lsn
  → 用 SC 返回的 ancestor_lsn 作为结果返回，但不必当作映射权威字段保存
  → mapping ready，operation succeeded
```

### 6.3 按时间创建 Branch

```text
接收 RFC3339 timestamp
  → 解析 parent timeline_id
  → SC get_lsn_by_timestamp(with_lease=true)
  → 只接受 kind=present
  → 必要时显式建立 LSN Lease
  → 持久化 new_timeline_id
  → SC 创建 ancestor_start_lsn=目标 LSN 的 Timeline
  → mapping ready，operation succeeded
```

客户接口不接受 LSN；Agent 的内部运维 API 可以保留 `create_at_lsn`。

### 6.4 创建失败恢复

需要区分：

| 情况 | 恢复方式 |
|---|---|
| DB 预占成功，SC 调用前 Agent 崩溃 | Operation 重试，使用已持久化的 `new_timeline_id` |
| SC 创建成功，DB 更新前 Agent 崩溃 | 重试时先 GET Timeline；存在且祖先符合预期则补写 `ready` |
| SC 明确不存在 Timeline | 重新调用创建 |
| SC 存在同 ID 但祖先/模式不符合 | 标记 `failed`，禁止覆盖，要求人工处理 |
| 名称已被其他 Operation 占用 | 唯一约束失败，返回冲突 |

### 6.5 查询 Branch

```text
DB 查询 branch_mappings
  → 一次性调用 SC Timeline list
  → 按 timeline_id 合并
  → 返回名称映射 + SC 实时状态
```

对账状态：

| DB | SC | 状态 |
|---|---|---|
| 有 mapping | 有 Timeline | 正常 |
| 有 mapping | 无 Timeline | `missing_in_storage`，禁止启动新 Compute |
| 无 mapping | 有 Timeline | `unmapped_timeline`，可由管理员导入映射 |
| mapping=creating | 有 Timeline | 补偿完成创建 Workflow |
| mapping=deleting | 无 Timeline | 补偿完成删除 Workflow |

### 6.6 删除 Branch

```text
中央管控完成保护/默认等产品校验
  → Agent DB 检查 Endpoint 绑定
  → SC 查询直接子 Timeline
  → DB：mapping.state=deleting，operation=running
  → 调 SC DELETE Timeline
  → 200：mapping tombstone，operation succeeded
  → 409/503：operation retrying
```

不要先删除映射再调用 SC，否则失败后将失去可恢复的 Timeline 定位信息。

### 6.7 Reset Branch

```text
解析当前 old_timeline_id
  → 按时间得到 LSN
  → 持久化 replacement_timeline_id
  → SC 创建 replacement Timeline
  → DB 事务/CAS：
       UPDATE mapping
       SET timeline_id=replacement, version=version+1
       WHERE timeline_id=old AND version=expected
  → Endpoint 绑定按策略重建或重绑
  → 旧 Timeline进入延迟回收
```

Reset 不能使用当前 `register_branch_mapping`，因为它禁止同名映射到新 Timeline。

旧 Timeline 可能仍被子 Timeline 依赖，不能在映射切换后立即删除。Agent 应从 SC 查询后代关系，必要时保留或进入经过审批的 Detach 流程。

### 6.8 Endpoint 绑定

```text
接收 tenant_id + branch_name + endpoint 参数
  → DB 解析 timeline_id，要求 mapping.state=ready
  → 检查唯一 Primary 约束
  → 插入 endpoint_bindings(state=creating)
  → 创建本地目录与配置，启动 compute_ctl
  → 更新 runtime_state=running
```

Endpoint 应保存绑定的 `timeline_id`，而不是每次启动时用可能已变化的 Branch 名重新解析。Reset 时由明确的重绑 Workflow 决定 Endpoint 是否切换。

## 7. Agent API 建议

中央管控请求中应始终携带 `operation_id` 和 `idempotency_key`。

### 创建 Branch

```http
POST /v1/environments/{environment_id}/tenants/{tenant_id}/branches
```

```json
{
  "operation_id": "1f60f4c5-2c90-4aac-bfd5-3e32c646e5ea",
  "idempotency_key": "customer-request-123",
  "branch_name": "dev",
  "source": {
    "mode": "timestamp",
    "parent_branch_name": "main",
    "timestamp": "2026-10-29T09:30:00+08:00"
  }
}
```

`source.mode`：

- `root`；
- `latest`；
- `timestamp`；
- `lsn` 仅限内部运维接口。

### 查询 Branch

```http
GET /v1/environments/{environment_id}/tenants/{tenant_id}/branches
GET /v1/environments/{environment_id}/tenants/{tenant_id}/branches/{branch_name}
```

返回映射信息和从 SC 获取的实时 Timeline 状态。

### 删除 Branch

```http
DELETE /v1/environments/{environment_id}/tenants/{tenant_id}/branches/{branch_name}
```

### Reset Branch

```http
POST /v1/environments/{environment_id}/tenants/{tenant_id}/branches/{branch_name}/reset
```

### 操作查询

```http
GET /v1/operations/{operation_id}
```

异步操作统一返回：

```json
{
  "operation_id": "1f60f4c5-2c90-4aac-bfd5-3e32c646e5ea",
  "status": "running",
  "result": null,
  "error": null
}
```

## 8. 本地文件迁移到数据库

### 8.1 迁移映射

```text
.neon/config.default_tenant_id
  → agent_tenants.is_default

.neon/config.branch_name_mappings.<name>[[tenant_id,timeline_id]]
  → agent_branch_mappings 一行
```

迁移时必须调用 SC 校验 Timeline 是否存在。不存在的记录不要直接标为 `ready`，应标为 `error` 或输出迁移报告。

### 8.2 迁移 Endpoint

```text
.neon/endpoints/<endpoint_id>/endpoint.json
  → agent_endpoint_bindings
```

迁移后仍保留原目录用于 `pgdata`、日志和配置文件。数据库只取代元数据源，不取代数据库文件系统。

### 8.3 双写过渡

不建议长期双写 TOML 和数据库。过渡顺序：

1. 停止 Agent/`neon_local` 写操作；
2. 备份 `.neon/config` 和 `endpoint.json`；
3. 执行一次性导入；
4. 调 SC 对账；
5. 切换 Agent 读写数据库；
6. 将旧文件改为只读备份；
7. 验证后移除旧元数据写路径。

如果必须短期双写，应以数据库为主，文件写失败只告警；不要让两个来源都可独立修改。

## 9. 并发、幂等与安全要求

### 并发

- 同一 `(environment_id,tenant_id,branch_name)` 的变更必须串行；
- 使用唯一索引防重名；
- Reset/Rename 使用 `version` 做 CAS；
- 多 Agent 消费操作时使用 `FOR UPDATE SKIP LOCKED` 或数据库 advisory lock；
- 不再依赖本地 `RepoLock`。

### 幂等

- 中央管控每次操作生成稳定 `operation_id`；
- 网络重试复用相同 `idempotency_key`；
- 生成的 Timeline ID 在第一次执行前写入操作表；
- SC 返回超时不能直接认定失败，先查询 Timeline 是否已创建/删除。

### 安全

- Agent 只接受来自中央管控的双向 TLS/JWT 请求；
- SC Token 从 Secret Manager 或启动环境注入；
- DB 不保存私钥明文；
- 保护/默认策略在中央管控检查，Agent 可根据请求中的策略快照做二次防护；
- 删除、Reset、Detach 必须记录审计事件。

## 10. 推荐实施顺序

### 第一阶段：只替换映射文件

1. 实现 `BranchRepository`；
2. 将 `register/get/reverse mapping` 改为 DB；
3. 保持 SC Client 和 Compute 逻辑不变；
4. 增加 `.neon/config` 导入工具。

### 第二阶段：操作 Workflow

1. 增加 `agent_operations`；
2. 创建 Branch 幂等化；
3. 增加按时间创建；
4. 增加删除和对账。

### 第三阶段：Endpoint 数据库化

1. 导入 `endpoint.json`；
2. Endpoint 创建、启动、停止使用 Repository；
3. 增加 Branch Reset 后的 Endpoint 重绑。

### 第四阶段：高可用

1. 多 Agent 任务租约；
2. Reconciler；
3. 指标、告警和审计；
4. 故障注入测试：SC 成功/DB 失败、DB 成功/SC 超时、Agent 中途重启。

## 11. 最终建议

建议将 Agent 设计成“可恢复的执行器”，而不是新的产品 Control Plane：

- 中央管控决定客户能否操作以及操作哪个 Project/Branch；
- Agent 负责本地名称/Timeline 解析、SC 调用、Compute 执行和结果回传；
- Agent Metadata DB 取代 `.neon/config` 与 `endpoint.json` 中的元数据；
- Storage Controller 仍是 Tenant/Timeline/祖先/LSN 的事实来源；
- Operation 表保证外部调用与本地持久化之间能够重试、恢复和对账。

最小上线表为：

1. `agent_environments`；
2. `agent_tenants`；
3. `agent_branch_mappings`；
4. `agent_operations`。

如果 Agent 同时管理 Compute，再增加 `agent_endpoint_bindings`。

## 源码依据

- `control_plane/src/bin/neon_local.rs`
- `control_plane/src/local_env.rs`
- `control_plane/src/storage_controller.rs`
- `control_plane/src/endpoint.rs`
- `control_plane/src/branch_mappings.rs`
- `libs/pageserver_api/src/models.rs`

## 关联文档

- [[storage-controller-branch-commands]]
- [[storage-controller-branch-api-curl]]
- [[branch-control-plane-api]]
