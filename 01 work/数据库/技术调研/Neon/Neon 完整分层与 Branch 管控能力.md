# Neon 完整分层与元数据归属

本文从产品管控、开源本地管控、接入、Compute、存储控制、存储数据和持久化介质几个层次，说明 Neon 各组件的职责，以及 `project_id`、`tenant_id`、`timeline_id`、branch、endpoint 等对象之间的关系。

> 范围说明：本文以当前开源 Neon 仓库和 `neon_local` 开发环境为依据。Neon Cloud 或基于 Neon 构建的 Lakebase 服务还会有产品级 Control Plane；这部分不等同于开源仓库的 `control_plane/` 目录，也不一定完整开源。

## 1. 总体分层（未来目标结构）

下面的三层主干是未来预期的总体结构，也是本文后续讨论的目标模型。产品级 Control Plane、Proxy、Object Storage 和监控系统可以围绕它扩展，但不改变这三个核心域。当前开源实现与目标结构之间如有差异，以各节的“当前实现/边界”说明为准。

```text
Control / Orchestration
├── neon_local
│   └── 本地环境的轻量管控与 CLI
└── storage_controller
    └── 管理 tenant 分片、Pageserver 调度、timeline 生命周期等

Storage
├── pageserver
├── safekeeper
└── storage_broker

Compute
└── postgres / compute_ctl
```

### 1.1 Control / Orchestration 细化

```text
Control / Orchestration
│
├── neon_local                         本地开发环境总入口；不是生产 Control Plane
│   ├── CLI
│   │   ├── init / start / stop
│   │   ├── tenant create / list
│   │   ├── timeline create / branch / list
│   │   └── endpoint create / start / stop / list
│   │
│   ├── 本地元数据
│   │   ├── .neon/config
│   │   │   ├── 默认 tenant_id
│   │   │   ├── branch_name -> tenant_id + timeline_id
│   │   │   └── Broker / Safekeeper / Storage Controller 配置
│   │   ├── .neon/pageserver_<id>/pageserver.toml
│   │   │   └── Pageserver 地址、端口和存储配置
│   │   └── .neon/endpoints/<endpoint_id>/
│   │       ├── endpoint -> tenant_id + timeline_id
│   │       ├── PostgreSQL 版本和端口
│   │       └── compute_ctl spec/config
│   │
│   └── 本地进程编排
│       ├── 启停 storage_controller
│       ├── 启停 pageserver / safekeeper / storage_broker
│       └── 启停 compute_ctl / postgres
│
└── storage_controller                 存储集群内部的控制层；不是产品元数据库
    ├── Node 管理
    │   ├── Pageserver 注册与心跳
    │   ├── Safekeeper 注册/可用性
    │   └── 节点状态与调度可用性
    ├── Tenant 管理
    │   ├── tenant shard placement
    │   ├── attach / detach / migrate
    │   ├── 分片与调度策略
    │   └── tenant 请求定位到目标 Pageserver
    ├── Timeline 管理
    │   ├── 代理/协调 timeline create
    │   ├── 代理 timeline 查询
    │   ├── 协调 Pageserver timeline delete
    │   └── 启用 timelines_onto_safekeepers 时，调度 Safekeeper timeline create / delete / migrate
    └── Controller 持久化状态
        ├── tenant shard -> Pageserver placement
        ├── Pageserver/Safekeeper 节点记录
        ├── Safekeeper timeline placement（启用相关配置时）
        └── pending operation / reconciliation 状态
```

这一层内部有明确边界：

- `neon_local` 知道本地 branch 名称和 endpoint；Storage Controller 通常不知道 branch 名称。
- Storage Controller 知道 tenant、shard、timeline 请求和存储节点；它通常不知道 Project 名称、组织、计费和保护分支。
- 生产环境可以用自己的管控程序替代 `neon_local`，但通常仍保留 Storage Controller。

### 1.2 Storage 细化

```text
Storage
│
├── pageserver                         分层页面存储与历史版本引擎
│   ├── Timeline
│   │   ├── 逻辑标识：tenant_id + timeline_id
│   │   ├── Pageserver 分片级标识：tenant_shard_id + timeline_id
│   │   ├── ancestor_timeline_id
│   │   ├── ancestor_lsn
│   │   └── GC / PITR / archival 等状态
│   ├── 数据处理
│   │   ├── 从 Safekeeper 接收 WAL
│   │   ├── WAL redo / 页面版本重建
│   │   ├── image layer / delta layer
│   │   ├── compaction / GC
│   │   └── local cache <-> Object Storage
│   └── 对 Compute 提供
│       ├── GetPage(key, lsn)
│       ├── basebackup
│       ├── LSN lease
│       └── timeline size / 状态信息
│
├── safekeeper                         WAL 仲裁与持久化服务
│   ├── 以 tenant_id + timeline_id 管理 WAL 流
│   ├── 接收 Compute WAL push
│   ├── 多 Safekeeper 一致性/term/membership
│   ├── 计算 commit_lsn / flush_lsn
│   ├── 向 Pageserver 提供 WAL stream
│   └── WAL 截断、可选远端备份和 timeline 删除
│
└── storage_broker                     存储组件间的轻量协调通道
    ├── 转发 SafekeeperTimelineInfo
    ├── 转发 Safekeeper discovery request/response
    ├── 支持单 timeline 或全部 timeline 的 pub/sub
    └── 不保存 branch 映射、页面 layer 或完整 WAL
```

Storage Controller 面向上层使用逻辑标识 `tenant_id + timeline_id`，并把请求分发到 tenant 的各个 shard；单个 Pageserver 实际管理的是 `tenant_shard_id + timeline_id`。`tenant_shard_id` 是稳定的分片级标识，不是 Pageserver 节点地址；它可以被重新调度到其他 Pageserver。在未分片环境中，它的显示形式可能看起来与裸 `tenant_id` 相同。Safekeeper 按 `tenant_id + timeline_id` 管理 WAL。Pageserver 还理解 `ancestor_timeline_id + ancestor_lsn`，因此知道 timeline 的存储级父子关系；这些组件都不需要知道用户把 branch 命名为 `main` 还是 `dev`。

### 1.3 Compute 细化

```text
Compute
│
└── Compute endpoint
    ├── Endpoint 绑定                 由 Control Plane / endpoint 配置维护
    │   └── endpoint_id -> tenant_id + timeline_id
    │
    ├── compute_ctl                    单个 Compute 的管理进程
    │   ├── 接收 neon_local/产品 Control Plane 下发的 spec
    │   ├── 准备 pgdata 和 PostgreSQL 配置
    │   ├── 从 Pageserver 拉取 basebackup
    │   ├── 配置 Pageserver / Safekeeper 连接
    │   ├── 应用角色、数据库、扩展和 catalog 配置
    │   ├── 启停/刷新/终止 PostgreSQL
    │   └── 暴露 Compute 状态和管理 HTTP API
    │
    └── Neon PostgreSQL                SQL 执行数据面
        ├── PostgreSQL 协议、SQL、事务和查询执行
        ├── 产生 WAL -> Safekeeper
        ├── GetPage(key, lsn) -> Pageserver
        └── 本地 pgdata / Local File Cache
```

Compute endpoint 和 branch 不是同一对象：

- branch/timeline 可以存在而没有运行中的 Compute；
- Compute endpoint 必须指向某个 `tenant_id + timeline_id`；
- 删除 endpoint 只删除 Compute，不自动代表删除 timeline；
- 目标产品中同一 timeline 可以关联多少 endpoint 由产品策略决定；当前 `neon_local` 不允许同一 `(tenant_id, timeline_id)` 同时运行多个 Primary endpoint，Replica 需要单独区分。

## 2. 三种容易混淆的“Control Plane”

### 2.1 产品级 Control Plane

这是 Neon Cloud 或 Lakebase 面向用户的产品管控层，通常负责：

- Organization、用户、权限和 API Key；
- Project 的创建、删除和配额；
- 用户可见的 branch 名称、Branch UID 和默认分支；
- 目标产品中的 `project_id -> tenant_id`、`branch_id -> (project_id, timeline_id)` 和 `(project_id, branch_name) -> branch_id` 映射；
- Endpoint/Compute 的规格、区域、启停、自动挂起和扩缩容；
- 保护分支、删除保护、审计、计费和用量；
- 主要调用 Storage Controller 和 Compute 管理接口；只有受控运维、诊断或尚未由 Storage Controller 覆盖的能力才直接访问 Pageserver/Safekeeper。

产品层的 `project_id` 是产品对象，不是 Neon 存储协议天然要求的字段。本文把“一 Project 映射一 Tenant”作为未来目标设计约定，但这不是开源存储内核保证的恒等关系；开源 `neon_local` 本身也没有 Project 对象。

### 2.2 `control_plane/` 与 `neon_local`

开源仓库的 `control_plane/` 主要提供本地开发控制工具。生成的核心 CLI 是 `neon_local`，`cargo neon` 是对它的便捷调用。

它负责：

- 初始化 `.neon` 工作目录；
- 启停 Storage Controller、Pageserver、Safekeeper 和 Broker；
- 创建 tenant 和 timeline；
- 在 `.neon/config` 中维护本地 `branch_name -> (tenant_id, timeline_id)` 映射；
- 创建、启动、停止和销毁本地 Compute endpoint；
- 生成 `compute_ctl` 配置并启动 Compute。

它明确是开发/测试工具，不是生产级 Neon Cloud Control Plane。

### 2.3 Storage Controller

Storage Controller 是“存储系统内部的控制组件”，不是完整产品管控层。它负责：

- tenant shard 的放置、调度和迁移；
- Pageserver 节点注册、心跳和可用性；
- 将 tenant/timeline 请求路由到正确的 Pageserver；
- 协调 timeline 创建和删除；
- 保存 tenant shard、节点和 Safekeeper placement 等存储控制元数据；
- 协调 Safekeeper timeline 的创建、迁移与删除。

其中 Safekeeper timeline placement 与生命周期协调取决于 `timelines_onto_safekeepers` 等配置；未启用时不能把这项职责视为固定行为。Storage Controller 通常不知道用户看到的 Project 名称、branch 名称、组织、计费或保护分支策略，除非上层系统把相关能力显式实现到它的接口之外。

## 3. 核心 ID 与元数据权威归属

“谁分配 ID”和“谁保存该对象的运行状态”是两件事，不能合并为一个权威来源：

| 对象/字段 | 含义 | 分配/映射权威 | 运行时/存储状态权威 |
|---|---|---|---|
| `organization_id` | 产品租户/组织 | 产品 Control Plane | 产品 Control Plane DB；存储层不感知 |
| `project_id` | 产品级数据库项目 | 产品 Control Plane | 产品 Control Plane DB；存储层通常不感知 |
| `project_name` | 用户可见项目名 | 产品 Control Plane | 产品 Control Plane DB；存储层不感知 |
| `tenant_id` | Neon 逻辑存储命名空间 | 产品 Control Plane；本地为 `neon_local` | Storage Controller 管 placement；Pageserver 管 shard 数据；Safekeeper 管 WAL |
| `tenant_shard_id` | tenant 的稳定分片级标识，不包含节点位置 | Storage Controller 根据 tenant 的分片配置管理 | Storage Controller 管 `tenant_shard_id -> pageserver_node_id` placement；Pageserver 按该 ID 保存数据 |
| `branch_id` / Branch UID | 产品级 branch 对象 ID | 产品 Control Plane | 产品 Control Plane DB；存储层通常不感知 |
| `branch_name` | `main`、`dev` 等用户可见名称 | 产品 Control Plane；本地为 `neon_local` | 产品 Control Plane DB；本地为 `.neon/config` |
| `timeline_id` | tenant 内一条逻辑版本历史 | 产品 Control Plane；本地为 `neon_local` | Pageserver 管数据和 ancestor；Storage Controller 管 Safekeeper placement/删除状态；Safekeeper 管 WAL |
| `ancestor_timeline_id` | 创建当前 timeline 时引用的父 timeline | 创建请求选择父 timeline | Pageserver timeline metadata |
| `ancestor_lsn` | 从父 timeline 分叉的历史位置 | 创建请求显式指定，或由 Pageserver 选择当前合适 LSN | Pageserver timeline metadata |
| `endpoint_id` | 一个 Compute 实例/配置的标识 | 产品 Control Plane；本地为 `neon_local` | 产品 Control Plane/endpoint 配置；Compute 只接收配置 |
| `LSN` | PostgreSQL WAL 中的位置 | PostgreSQL 写 WAL 时产生 | Safekeeper 持久化/仲裁；Pageserver 消费并建立页面版本 |
| 保护分支策略 | 禁止或限制删除 branch | 产品 Control Plane | 产品 Control Plane DB；存储内核通常不感知 |

关键关系是：

```text
目标产品映射（不是开源存储内核强制的数据模型）：

Project
├── project_id = P
└── tenant_id = T -------------------------------> Tenant(tenant_id = T)

Branch
├── branch_id = B1
├── project_id = P
├── branch_name = "main"
└── timeline_id = TL1 ---------------------------> Logical Timeline(T, TL1)

Branch
├── branch_id = B2
├── project_id = P
├── branch_name = "dev"
└── timeline_id = TL2 ---------------------------> Logical Timeline(T, TL2)
                                                    ├── ancestor_timeline_id = TL1
                                                    └── ancestor_lsn = ...

约束与查找：
├── project_id -> tenant_id
├── branch_id -> project_id + timeline_id
└── UNIQUE(project_id, branch_name)
    └── (project_id, branch_name) -> branch_id -> timeline_id

Storage Controller 分片：

Tenant(T)
├── TenantShard(T, shard 0)
│   ├── Timeline shard instance(T, shard 0, TL1)
│   └── Timeline shard instance(T, shard 0, TL2)
└── TenantShard(T, shard 1)
    ├── Timeline shard instance(T, shard 1, TL1)
    └── Timeline shard instance(T, shard 1, TL2)

根 timeline TL1：
├── ancestor_timeline_id = None
└── ancestor_lsn = Lsn(0)           # Pageserver 内部元数据
                                     # HTTP API 通常显示为 null/None

Compute 管理：
Endpoint(endpoint_id)
├── tenant_id
├── timeline_id
└── PostgreSQL 端口/规格/状态
```

因此：

1. 目标产品的 Project 层保存 `project_id -> tenant_id` 映射；`project_id` 不天然等于 `tenant_id`。
2. Branch 通过 `project_id` 属于 Project，并继承该 Project 的 tenant 作用域；`branch_id` 是稳定主键，`branch_name` 是 Project 作用域内的名称，应建立 `UNIQUE(project_id, branch_name)`。
3. 定位逻辑 branch 数据时，先从 Project 得到 `tenant_id`，再从 Branch 得到 `timeline_id`，最终组成 `tenant_id + timeline_id`。
4. 对于分片 tenant，Storage Controller 再把逻辑 tenant 展开为多个 `tenant_shard_id`；Pageserver 按 `tenant_shard_id + timeline_id` 管理 timeline shard instance，并单独维护其到 Pageserver 节点的 placement。
5. branch 名称和 Branch UID 不存储在 Pageserver timeline metadata 中。
6. 一个 branch 可以暂时没有 endpoint；当前 `neon_local` 不允许同一 timeline 同时运行多个 Primary endpoint。
7. `ancestor_timeline_id` 表示存储内核中的 timeline 祖先关系；它不是 Branch UID，也不是产品 Project ID。

## 4. Timeline 分支模型

下面是逻辑 timeline 视角。对于分片 tenant，同一个逻辑 `timeline_id` 会出现在各个 `tenant_shard_id` 下，并由 Storage Controller 协调操作。假设 `dev` 从 `main` 的 LSN `0/1500000` 创建：

```text
tenant_id = T

main
timeline_id = A
WAL: 0/1000000 -------- 0/1500000 -------- 0/1800000
                            |
                            | branch point
                            v
dev
timeline_id = B
ancestor_timeline_id = A
ancestor_lsn         = 0/1500000
WAL:                       0/1500000 -------- 0/1700000
```

读取 `dev` 时：

- 对分叉点之前的历史，Pageserver 可以沿祖先 timeline 查找数据；
- 对分叉点之后的修改，`dev` 使用自己的 layer/WAL 历史；
- `main` 在分叉后继续写入，不会自动出现在 `dev`；
- `dev` 的写入也不会修改 `main`。

内核的父子关系是 timeline 元数据关系，不等于产品层可能展示的可变 branch 名称关系。

## 5. Branch 功能全集与实现边界

本节核验日期为 2026-10-26。这里把“产品级 Branch API”和“开源存储层 Timeline API”分开列出：前者包含名称、保护、过期和默认分支等产品策略，后者主要提供创建、祖先关系和删除等存储原语。Neon Cloud 和 Lakebase 列依据当前官方公开文档/API；`neon_local` 列同时依据当前仓库源码和本机实测。

符号含义：`是` 表示有公开、直接的产品能力；`部分` 表示只有低层原语或需要多步编排；`否` 表示当前公开 CLI/API 中没有等价能力；`UI` 表示文档只确认了产品界面流程。

### 5.1 产品级能力对照

| 能力 | Neon Cloud | Lakebase Autoscaling | 开源 `neon_local` / Storage Controller |
|---|---|---|---|
| Project 创建、查询、删除 | 是，产品 REST/CLI | 是，`/api/2.0/postgres/projects` REST/CLI/SDK | 否；只有 tenant，不存在 Project 产品对象 |
| Branch 创建/查询/列表 | 是，产品 REST/CLI | 是，Branch REST/CLI/SDK | 是（本地命名分支）；`neon_local` 创建 timeline 并维护 branch name 映射，支持按名称解析和带名称的列表展示；Storage Controller 只处理 timeline |
| 从默认父分支当前状态创建 | 是 | 是 | 是，`neon_local timeline branch`，默认祖先名为 `main` |
| 指定父分支创建 | 是，`parent_id` | 是，`spec.source_branch` | 是，`--ancestor-branch-name` |
| 从子分支再创建子分支 | 是 | 是 | 是，已实际验证两级祖先关系 |
| 按 LSN 创建 | 是，`parent_lsn` | 是，`source_branch_lsn` | 是，`--ancestor-start-lsn` 或 Timeline Create REST |
| 按时间创建 | 是，`parent_timestamp` | 是，`source_branch_time` | 部分；Pageserver 有“时间转 LSN”接口，但 `neon_local timeline branch` 不接受 timestamp，需要上层先换算 LSN 再创建 |
| Schema-only branch | 是 | 当前公开 Branch API 未提供等价字段 | 否；timeline 分支继承数据和 schema |
| 创建 Branch 时同时创建 Compute | 是，创建请求可带 `endpoints` | 否，Branch 和 Endpoint 是两个资源/请求 | 否；必须先 `timeline branch`，再 `endpoint create/start` |
| Branch 无 Compute 独立存在 | 是 | 是 | 是 |
| 一个主 Compute + Read Replica | 是，一个 read-write、多 read-only | 是，Endpoint/Read Replica 独立管理 | 部分；本地 endpoint 支持 primary/hot-standby，但不是云端弹性 Compute 产品能力 |
| 删除 Branch | 是；不能删 root/default、有子分支或受保护分支 | 是；保护等产品约束由管控层检查 | 部分；无 `timeline delete` CLI，Storage Controller 有 `DELETE /v1/tenant/{tenant}/timeline/{timeline}` |
| 重命名 Branch | 是，Branch `PATCH` 更新 `name` | 否；当前文档明确 UI/API 都不支持 rename | 否；`mappings map` 只新增映射，没有 rename/remove 命令 |
| 设置/取消保护 | 是，创建时或 `PATCH branch.protected` | 是，创建时或 `PATCH spec.is_protected` | 否；CLI、Storage Controller 和 Pageserver 均无 protected-branch 字段或路由 |
| Reset 到父分支最新状态 | 是，REST/CLI 支持 restore/reset 工作流 | UI；产品文档支持 reset，当前公开 Branch REST 参考未列出独立 reset 方法 | 否；没有保持同一 Branch 身份的原生 reset 操作 |
| 从自身/其他分支历史恢复 | 是，`POST .../branches/{branch_id}/restore`，支持 LSN/timestamp | 部分；可从时间点或 snapshot 创建恢复分支 | 否；可用低层“新建 timeline + 切换映射/Compute”自行编排，但不是原生 restore |
| 设置默认分支 | 是，`POST .../set_as_default` | UI；当前管理文档说明 API 不支持 | 否；`main` 只是默认祖先名称约定，`tenant set-default` 设置的是默认 tenant |
| 自动过期/TTL | 是，API/CLI/Console | 是，`expire_time`、`ttl`、`no_expiry` | 否；需自建管控定时删除 |
| 自动归档/唤醒 | 本次未在公开 Branch API 中确认独立能力 | 是，系统自动归档，受保护分支不归档 | 部分；存储层有 timeline archival/offload 原语，但不等同于产品 Branch 自动归档策略 |
| Snapshot 创建/恢复 | 是，产品 Snapshot API | 是，Snapshot API；可从 snapshot 创建 branch | 无产品级 Branch Snapshot；Pageserver 的历史存储原语不能直接等同 |
| Schema diff | 是，产品功能 | 是，产品 UI 功能 | 否；需启动 Compute 后自行比较数据库 schema |
| Branch 注解/业务元数据 | 是，创建 API 支持 annotations | 当前 Branch 对象未公开通用 annotations | 否；需自己的产品 Control Plane 保存 |

公开接口依据：

- Neon [Create branch API](https://api-docs.neon.tech/reference/createprojectbranch)、[Update branch API](https://api-docs.neon.tech/reference/updateprojectbranch)、[Delete branch API](https://api-docs.neon.tech/reference/deleteprojectbranch)、[Restore branch API](https://api-docs.neon.tech/reference/restoreprojectbranch) 和 [Set default branch API](https://api-docs.neon.tech/reference/setdefaultprojectbranch)。
- Lakebase [Branch API reference](https://docs.databricks.com/api/postgres/v1/branch)、[Lakebase API guide](https://docs.databricks.com/aws/en/oltp/projects/api-usage) 和 [Manage branches](https://docs.databricks.com/aws/en/oltp/projects/manage-branches)。

Lakebase 文档目前有一处需要谨慎处理：Branch API 的 Update 方法摘要称可设置 default，但公开请求 schema 没有可写的 default 字段；管理指南同时明确写着“设置默认分支不支持 API”。因此表中按可执行的公开契约标为 `UI`，不把摘要文字当成可用 REST 字段。

#### `neon_local` 已实现的 branch name 映射

`neon_local` 实际承担本地命名分支的管控职责。CLI 使用 `timeline` 命令组，不影响它在本地实现 branch name 的注册、解析、持久化和展示：

- **创建并注册名称**：`timeline create/branch` 创建底层 timeline 后，调用 `register_branch_mapping` 注册新名称；成功执行后将映射持久化到 `.neon/config`。
- **按名称定位**：`timeline branch --ancestor-branch-name main` 通过 `get_branch_timeline_id` 查找父 timeline；`endpoint create --branch-name dev` 也使用同一映射定位目标 timeline。
- **带名称展示**：`timeline list` 查询底层 timeline 后，合并本地 `timeline_name_mappings` 展示带 branch name 的树；`endpoint list` 也展示 branch name。
- **名称作用域**：查询键实际为 `(tenant_id, branch_name) -> timeline_id`。配置结构为 `branch_name_mappings: HashMap<String, Vec<(TenantId, TimelineId)>>`，同名 branch 可以出现在不同 tenant 中；同一 tenant 内，已有名称不能重新映射到不同 timeline。
- **能力边界**：这些名称由 `neon_local` 管理，Storage Controller/Pageserver 仍以 ID 处理 timeline。本地名称映射尚不包含独立的产品 Branch UID、保护策略或完整的 rename/delete 生命周期管理。

源码依据：[映射结构、注册与查找](https://github.com/neondatabase/neon/blob/main/control_plane/src/local_env.rs)、[CLI 创建、名称解析与列表展示](https://github.com/neondatabase/neon/blob/main/control_plane/src/bin/neon_local.rs)。本次修订依据源码核验，未重新运行 Neon 本地集成测试。

### 5.2 保护分支到底在哪里实现

Neon Cloud 和 Lakebase 的保护分支都是产品 Control Plane 属性，不是 `timeline_id` 的内核属性。

Neon Cloud 的 REST 形式为：

```http
PATCH /api/v2/projects/{project_id}/branches/{branch_id}
Content-Type: application/json

{"branch":{"protected":true}}
```

Lakebase 的 REST 形式为：

```http
PATCH /api/2.0/postgres/projects/{project_id}/branches/{branch_id}?update_mask=spec.is_protected
Content-Type: application/json

{
  "name": "projects/{project_id}/branches/{branch_id}",
  "spec": {"is_protected": true}
}
```

本地没有等价命令或 REST API。Storage Controller 的以下接口不能视为保护分支：

- `POST .../block_gc` 只持久化阻止 GC，保护仍被祖先依赖的历史数据；它不阻止 timeline delete。
- `PUT .../archival_config` 管理存储归档状态；它不提供删除保护。
- `PUT .../detach_ancestor` 改变 timeline 的祖先依赖；它不是 reset，也不是 branch protection。

如果自建服务化 Control Plane，需要在自己的 Branch 表中保存 `is_protected`，并在删除 Branch、删除 Project、删除关联 Compute、reset/restore 前统一做策略检查。还必须限制用户绕过产品 API 直接访问 Storage Controller/Pageserver，否则产品层的保护可被底层 `DELETE` 绕过。

### 5.3 本地删除的完整语义

本地删除不是一条完整的“产品 Branch 删除”操作，而是至少三类资源的编排：

```text
1. endpoint stop --destroy
   └── 停止 Compute，删除本地 pgdata

2. DELETE Storage Controller /v1/tenant/{tenant_id}/timeline/{timeline_id}
   ├── 协调 Pageserver 删除 timeline 数据
   └── 在启用相关配置时协调 Safekeeper timeline 删除

3. 清理 neon_local 元数据
   ├── .neon/config 中的 branch_name 映射
   └── 不再需要的 endpoint 配置
```

第 2 步不会自动执行第 1、3 步。这解释了为什么底层 `dev` timeline 删除成功以后，`.neon/config` 中仍可能保留 `dev -> timeline_id` 的悬空映射。Storage Controller 的成功删除语义是内部等待 Pageserver 从 `202 Accepted` 进入 `404 Not Found`，然后对调用者返回 `200 OK`；之后再次查询底层对象应为 `404`。

### 5.4 2026-10-26 本地实际验证

测试使用临时 tenant `c0de2026102600000000000000000001`，没有修改现有业务 tenant。验证结束后，临时 endpoint、timeline、tenant 和新增名称映射均已清理。

| 验证项 | 实际结果 |
|---|---|
| 创建临时 tenant/root timeline | 成功 |
| `main -> verify_child` | 成功；分叉 LSN 为 `0/1525E38` |
| `verify_child -> verify_grandchild` | 成功；`timeline list` 显示两级树 |
| 为 `verify_child` 创建并启动 Compute | 成功；监听 `127.0.0.1:55436` |
| 在该 Compute 执行只读 SQL | 成功；返回 `postgres\|cloud_admin\|f`，即主库而非 recovery replica |
| 父 timeline 尚有子 timeline 时删除父节点 | 被拒绝；Pageserver 返回 `Cannot delete timeline which has child timelines` |
| 先删孙节点、再删父节点 | 两次 Storage Controller REST 均返回 HTTP 200 |
| 删除临时 tenant 后再次查询 | HTTP 404，确认底层 tenant 已不存在 |
| 名称映射自动清理 | 不会自动清理；测试后由管控侧显式移除 |

本地源码边界也与实测一致：

- `control_plane/src/bin/neon_local.rs` 的 `TimelineCmd` 只有 `list/branch/create/import`，没有 delete、rename、reset、protect 或 expire。
- `TimelineBranchCmdArgs` 只有 `tenant_id`、新 `timeline_id`、`branch_name`、`ancestor_branch_name` 和 `ancestor_start_lsn`。
- `control_plane/src/local_env.rs` 只提供 branch mapping 注册和查找；`mappings` CLI 也只有 `map`。
- `storage_controller/src/http.rs` 提供 timeline create/delete、archival、detach ancestor、block/unblock GC 等低层接口，没有产品 Branch 更新或保护接口。
- `libs/pageserver_api/src/models.rs` 的 Branch 创建模型只接收 `ancestor_timeline_id`、`ancestor_start_lsn` 等存储字段。

### 5.5 自建 Control Plane 需要补齐什么

要达到 Neon Cloud/Lakebase 一类的服务化 Branch 管控能力，至少需要在开源存储组件之上补齐：

```text
Project 表
├── project_id
├── tenant_id
└── default_branch_id

Branch 表
├── branch_id / uid
├── project_id
├── branch_name
├── timeline_id
├── is_protected
├── expires_at
└── lifecycle state

Endpoint 表
├── endpoint_id
├── project_id / branch_id
├── tenant_id / timeline_id
└── compute spec / status
```

并由同一个受控入口实现创建、删除、reset、过期清理和保护检查。底层 Storage Controller/Pageserver API 应只允许这个管控服务访问，不能直接暴露给最终用户。

## 6. CLI 与 REST API 命令清单

下面的变量都需要替换为实际值。Cloud 示例需要相应 token；本地示例默认仓库位于 `/Users/kivan/Documents/neon`，并使用已经编译好的 `./target/debug/neon_local`。

### 6.1 本地 `neon_local`：Tenant、Timeline 和 Compute

启动和查看：

```bash
./target/debug/neon_local start

./target/debug/neon_local tenant list
./target/debug/neon_local timeline list --tenant-id "$TENANT_ID"
./target/debug/neon_local endpoint list

# 全部验证结束后停止本地服务
./target/debug/neon_local stop
```

创建临时 tenant 和初始 root timeline：

```bash
./target/debug/neon_local tenant create \
  --tenant-id "$TENANT_ID" \
  --timeline-id "$ROOT_TIMELINE_ID" \
  --pg-version 16
```

从 `main` 当前状态创建 `dev`：

```bash
./target/debug/neon_local timeline branch \
  --tenant-id "$TENANT_ID" \
  --timeline-id "$DEV_TIMELINE_ID" \
  --branch-name dev \
  --ancestor-branch-name main
```

从 `dev` 再创建子分支：

```bash
./target/debug/neon_local timeline branch \
  --tenant-id "$TENANT_ID" \
  --timeline-id "$FEATURE_TIMELINE_ID" \
  --branch-name feature \
  --ancestor-branch-name dev
```

从指定 LSN 创建：

```bash
./target/debug/neon_local timeline branch \
  --tenant-id "$TENANT_ID" \
  --timeline-id "$PITR_TIMELINE_ID" \
  --branch-name pitr_dev \
  --ancestor-branch-name main \
  --ancestor-start-lsn '0/1525E38'
```

为分支创建并启动 Compute。创建 timeline 不会自动执行这两条命令：

```bash
./target/debug/neon_local endpoint create dev-compute \
  --tenant-id "$TENANT_ID" \
  --branch-name dev \
  --pg-version 16

./target/debug/neon_local endpoint start dev-compute
```

连接 SQL，端口从 `endpoint list` 获取：

```bash
./pg_install/v16/bin/psql \
  -h 127.0.0.1 \
  -p "$PG_PORT" \
  -U cloud_admin \
  -d postgres
```

停止并销毁 Compute 的本地 `pgdata`：

```bash
./target/debug/neon_local endpoint stop dev-compute --destroy
```

手工新增名称映射；这个命令只能新增，不能 rename/remove：

```bash
./target/debug/neon_local mappings map \
  --tenant-id "$TENANT_ID" \
  --timeline-id "$TIMELINE_ID" \
  --branch-name dev
```

### 6.2 本地 Storage Controller / Pageserver REST

直接创建 timeline。`ancestor_start_lsn` 可以省略，此时从父 timeline 的合适最新位置分叉：

```bash
curl --fail-with-body -X POST \
  "http://127.0.0.1:1234/v1/tenant/${TENANT_ID}/timeline" \
  -H 'Content-Type: application/json' \
  -d "{
    \"new_timeline_id\": \"${NEW_TIMELINE_ID}\",
    \"ancestor_timeline_id\": \"${PARENT_TIMELINE_ID}\",
    \"ancestor_start_lsn\": \"0/1525E38\"
  }"
```

查询单个 timeline：

```bash
curl --fail-with-body \
  "http://127.0.0.1:1234/control/v1/tenant/${TENANT_ID}/timeline/${TIMELINE_ID}"
```

把 timestamp 转成 LSN，然后将返回的 `lsn` 传给 `--ancestor-start-lsn` 或 Timeline Create REST。分片 tenant 要使用 shard zero 的 `tenant_shard_id`：

```bash
curl --fail-with-body --get \
  "http://127.0.0.1:9898/v1/tenant/${TENANT_SHARD_ID}/timeline/${PARENT_TIMELINE_ID}/get_lsn_by_timestamp" \
  --data-urlencode 'timestamp=2026-10-26T08:00:00Z'
```

删除 timeline；必须先停止关联 Compute，并按叶子到父节点的顺序删除：

```bash
curl --fail-with-body -X DELETE \
  "http://127.0.0.1:1234/v1/tenant/${TENANT_ID}/timeline/${TIMELINE_ID}"
```

删除 tenant：

```bash
curl --fail-with-body -X DELETE \
  "http://127.0.0.1:1234/v1/tenant/${TENANT_ID}"
```

以下命令只是存储维护接口，不是保护分支：

```bash
# 阻止/恢复 timeline GC；不会禁止 DELETE timeline
curl --fail-with-body -X POST \
  "http://127.0.0.1:1234/v1/tenant/${TENANT_ID}/timeline/${TIMELINE_ID}/block_gc"

curl --fail-with-body -X POST \
  "http://127.0.0.1:1234/v1/tenant/${TENANT_ID}/timeline/${TIMELINE_ID}/unblock_gc"
```

本地不存在可执行的 `protect branch`、`rename branch`、`reset branch`、`set default branch` 或 `set branch TTL` REST 路由。

### 6.3 Neon Cloud REST API

认证和公共请求头：

```bash
export NEON_API_BASE='https://console.neon.tech/api/v2'
export NEON_API_KEY='replace-me'
export PROJECT_ID='replace-me'
```

列出 Project 和 Branch：

```bash
curl --fail-with-body "$NEON_API_BASE/projects" \
  -H "Authorization: Bearer $NEON_API_KEY"

curl --fail-with-body "$NEON_API_BASE/projects/$PROJECT_ID/branches" \
  -H "Authorization: Bearer $NEON_API_KEY"
```

从指定父分支创建 `dev`，但不创建 Compute：

```bash
curl --fail-with-body -X POST \
  "$NEON_API_BASE/projects/$PROJECT_ID/branches" \
  -H "Authorization: Bearer $NEON_API_KEY" \
  -H 'Content-Type: application/json' \
  -d "{
    \"branch\": {
      \"name\": \"dev\",
      \"parent_id\": \"$PARENT_BRANCH_ID\"
    }
  }"
```

创建分支时同时创建一个 read-write Compute：

```bash
curl --fail-with-body -X POST \
  "$NEON_API_BASE/projects/$PROJECT_ID/branches" \
  -H "Authorization: Bearer $NEON_API_KEY" \
  -H 'Content-Type: application/json' \
  -d "{
    \"branch\": {
      \"name\": \"dev-with-compute\",
      \"parent_id\": \"$PARENT_BRANCH_ID\"
    },
    \"endpoints\": [
      {\"type\": \"read_write\"}
    ]
  }"
```

按 LSN 或 timestamp 创建时，分别增加 `parent_lsn` 或 `parent_timestamp`；二者不要同时提供：

```json
{"branch":{"name":"pitr-lsn","parent_id":"br-parent","parent_lsn":"0/1525E38"}}
```

```json
{"branch":{"name":"pitr-time","parent_id":"br-parent","parent_timestamp":"2026-10-26T08:00:00Z"}}
```

重命名、保护和取消保护都是同一个 Update Branch API：

```bash
# rename
curl --fail-with-body -X PATCH \
  "$NEON_API_BASE/projects/$PROJECT_ID/branches/$BRANCH_ID" \
  -H "Authorization: Bearer $NEON_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"branch":{"name":"new-name"}}'

# protect
curl --fail-with-body -X PATCH \
  "$NEON_API_BASE/projects/$PROJECT_ID/branches/$BRANCH_ID" \
  -H "Authorization: Bearer $NEON_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"branch":{"protected":true}}'

# unprotect
curl --fail-with-body -X PATCH \
  "$NEON_API_BASE/projects/$PROJECT_ID/branches/$BRANCH_ID" \
  -H "Authorization: Bearer $NEON_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"branch":{"protected":false}}'
```

设置默认分支：

```bash
curl --fail-with-body -X POST \
  "$NEON_API_BASE/projects/$PROJECT_ID/branches/$BRANCH_ID/set_as_default" \
  -H "Authorization: Bearer $NEON_API_KEY"
```

从父分支最新状态、某个 LSN 或某个时间点 restore：

```bash
curl --fail-with-body -X POST \
  "$NEON_API_BASE/projects/$PROJECT_ID/branches/$BRANCH_ID/restore" \
  -H "Authorization: Bearer $NEON_API_KEY" \
  -H 'Content-Type: application/json' \
  -d "{
    \"source_branch_id\": \"$SOURCE_BRANCH_ID\"
  }"
```

需要历史位置时，在请求体中再加入 `source_lsn` 或 `source_timestamp`。如果目标 Branch 有子分支，API 可能要求提供 `preserve_under_name`。

删除 Branch：

```bash
curl --fail-with-body -X DELETE \
  "$NEON_API_BASE/projects/$PROJECT_ID/branches/$BRANCH_ID" \
  -H "Authorization: Bearer $NEON_API_KEY"
```

使用当前 Neon CLI 的通用 API 入口也可以发出同样请求，例如：

```bash
neon api "/projects/$PROJECT_ID/branches" \
  -X POST \
  -F branch.name=dev \
  -F branch.parent_id="$PARENT_BRANCH_ID"
```

### 6.4 Lakebase CLI 与 REST API

登录并准备 REST 环境：

```bash
databricks auth login --host https://your-workspace.cloud.databricks.com

export WORKSPACE='https://your-workspace.cloud.databricks.com'
export DATABRICKS_TOKEN="$(databricks auth token | jq -r .access_token)"
export PROJECT_ID='replace-me'
```

列出 Project 和 Branch：

```bash
databricks postgres list-projects
databricks postgres list-branches "projects/$PROJECT_ID" --output json

curl --fail-with-body \
  "$WORKSPACE/api/2.0/postgres/projects/$PROJECT_ID/branches" \
  -H "Authorization: Bearer $DATABRICKS_TOKEN"
```

创建永久子分支：

```bash
databricks postgres create-branch \
  "projects/$PROJECT_ID" dev \
  --json "{
    \"spec\": {
      \"source_branch\": \"projects/$PROJECT_ID/branches/production\",
      \"no_expiry\": true
    }
  }"
```

对应 REST：

```bash
curl --fail-with-body -X POST \
  "$WORKSPACE/api/2.0/postgres/projects/$PROJECT_ID/branches?branch_id=dev" \
  -H "Authorization: Bearer $DATABRICKS_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{
    \"spec\": {
      \"source_branch\": \"projects/$PROJECT_ID/branches/production\",
      \"no_expiry\": true
    }
  }"
```

按 LSN 或 timestamp 创建时，使用 `source_branch_lsn` 或 `source_branch_time`：

```json
{
  "spec": {
    "source_branch": "projects/my-project/branches/production",
    "source_branch_lsn": "0/1525E38",
    "no_expiry": true
  }
}
```

设置/取消保护：

```bash
databricks postgres update-branch \
  "projects/$PROJECT_ID/branches/dev" \
  spec.is_protected \
  --json '{"spec":{"is_protected":true}}'
```

```bash
curl --fail-with-body -X PATCH \
  "$WORKSPACE/api/2.0/postgres/projects/$PROJECT_ID/branches/dev?update_mask=spec.is_protected" \
  -H "Authorization: Bearer $DATABRICKS_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{
    \"name\": \"projects/$PROJECT_ID/branches/dev\",
    \"spec\": {\"is_protected\": true}
  }"
```

取消保护时将 `is_protected` 改成 `false`。

设置 7 天 TTL：

```bash
databricks postgres update-branch \
  "projects/$PROJECT_ID/branches/dev" \
  spec.expiration \
  --json '{"spec":{"ttl":"604800s"}}'
```

删除过期策略时使用 `{"spec":{"no_expiry":true}}`，并保留 `update_mask=spec.expiration`。

查询和删除 Branch：

```bash
databricks postgres get-branch \
  "projects/$PROJECT_ID/branches/dev" --output json

databricks postgres delete-branch \
  "projects/$PROJECT_ID/branches/dev"
```

```bash
curl --fail-with-body -X DELETE \
  "$WORKSPACE/api/2.0/postgres/projects/$PROJECT_ID/branches/dev" \
  -H "Authorization: Bearer $DATABRICKS_TOKEN"
```

Lakebase Branch 删除是异步长任务，返回的 operation 需要等待 `done=true`。当前公开文档中，rename 不支持，设置 default 和 reset-from-parent 只给出了 UI 流程，因此这里不伪造不存在的 CLI/REST 命令。

## 7. 一句话总结

```text
产品 Control Plane 管“用户看到的 Project、Branch 和 Endpoint”；
Storage Controller 管“tenant shard 应该放在哪个存储节点”；
Pageserver 管“timeline shard instance 的页面版本历史与祖先关系”；
Safekeeper 管“tenant/timeline 的近期 WAL 持久化”；
Compute 管“SQL 执行”；
Object Storage 管“Pageserver page layer 的长期持久化”。
```

用户可见的 branch 通常是管控层对象：逻辑存储接口使用 `tenant_id + timeline_id`，Storage Controller 负责把 tenant 展开为 shard，并维护 `tenant_shard_id -> pageserver_node_id` placement；Pageserver 按 `tenant_shard_id + timeline_id` 管理 timeline shard instance，并通过 `ancestor_timeline_id + ancestor_lsn` 表达 timeline 的分支历史。
