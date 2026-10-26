# Neon Branch 实现原理与本地部署调研

> 调研基于 Neon 官方开源仓库，代码版本：`fa504217c61bbcaf5c512d75830564541f917f8f`。
> 本文同时记录了在 Apple Silicon macOS 上完成的本地部署和分支隔离验证。

## 1. 结论摘要

Neon 的 branch 不是复制一套 PostgreSQL 数据文件，而是在 Pageserver 中创建一条新的 **timeline**：

- 新 timeline 保存 `ancestor_timeline_id` 和 `ancestor_lsn`；
- 分支点之前缺失的数据页，会沿祖先链读取，但读取位置被截断到 `ancestor_lsn`；
- 分支点之后，父、子 timeline 各自写入新的 WAL 和 layer，因此相互隔离；
- 创建分支主要是元数据操作，不需要立即复制祖先的全部数据，因而接近 O(1)；
- 祖先不能随意回收子分支仍依赖的历史数据。Neon 会用 GC cutoff/branch point 约束垃圾回收。

Neon 核心代码采用 Apache-2.0 许可证，可以自行编译和部署。官方仓库提供本地开发工具和 Docker Compose 示例，但该 Compose 明确偏向开发、测试和演示，并不等价于 Neon Cloud 的完整生产控制面。生产级私有化还需要补齐计算节点编排、认证、网络、监控、备份、升级以及高可用等能力。

## 2. Neon 的存储架构

Neon 将传统 PostgreSQL 的计算与持久化存储拆开：

```text
客户端
  │ PostgreSQL 协议
  ▼
Compute（修改版 PostgreSQL）
  ├── 读取数据页 ───────────────► Pageserver
  └── 产生 WAL ─► Safekeeper quorum ─► Pageserver
                                     │
                                     ▼
                              远端对象/文件存储
```

主要组件：

- **Compute**：运行 PostgreSQL SQL 层；本地磁盘主要用于缓存，持久状态由 WAL 和 Pageserver 管理。
- **Safekeeper**：接收并持久化 WAL，通常以 quorum 方式确认提交，提高 durability。
- **Pageserver**：根据某个 timeline 和 LSN 重建 PostgreSQL 数据页，管理 image/delta layer，并将 layer 上传到远端存储。
- **Storage Controller / Control Plane**：管理租户、timeline、节点调度和 compute 生命周期。开源仓库包含相关组件，但官方云服务的全部产品控制面并非一个开箱即用的单机部署包。

Pageserver 不维护传统 PostgreSQL 那样的一整份可变数据目录，而是维护不可变 layer：

- **Image layer**：某个 LSN 上一段 key 范围的完整镜像；
- **Delta layer**：某段 LSN 范围内 key 的增量变化；
- 读取时根据 `(key, lsn)` 从合适的 layer 中寻找记录并重建页面；
- compaction 把多个 layer 合并，GC 清理不再需要的历史版本。

这套多版本存储模型，是快速分支和时间点恢复的基础。

## 3. Branch 在代码中的含义

Neon 对外使用 project/branch 等产品概念，而存储层核心对象是：

```text
Tenant
└── Timeline（对应一个可独立演进的分支历史）
    ├── ancestor_timeline_id: 可选
    ├── ancestor_lsn: 可选
    ├── 本 timeline 新产生的 layers
    └── 本 timeline 的 WAL/LSN 进度
```

根 timeline 没有祖先。由它创建的分支 timeline 只需记录祖先 timeline 和分支 LSN；创建时不会把祖先的全部 layer 复制一份。

## 4. 创建 Branch 的调用链

### 4.1 CLI/控制面发起请求

本地 CLI 的 timeline branch 命令入口位于：

- [`control_plane/src/bin/neon_local.rs`](https://github.com/neondatabase/neon/blob/fa504217c61bbcaf5c512d75830564541f917f8f/control_plane/src/bin/neon_local.rs#L1276)

`TimelineCmd::Branch` 解析 tenant、父 timeline、新 timeline 和分支 LSN，构造
`TimelineCreateRequestMode::Branch`，然后向 Storage Controller/Pageserver 发起创建请求。

### 4.2 Pageserver HTTP 路由

Pageserver 的 timeline 创建路由位于：

- [`pageserver/src/http/routes.rs`](https://github.com/neondatabase/neon/blob/fa504217c61bbcaf5c512d75830564541f917f8f/pageserver/src/http/routes.rs#L589)

`timeline_create_handler` 负责解析请求、权限/参数检查，将 API 模型转换为
`CreateTimelineParams::Branch`，再进入 tenant 的 timeline 创建逻辑。

### 4.3 分支点校验

关键校验位于：

- [`pageserver/src/tenant.rs`](https://github.com/neondatabase/neon/blob/fa504217c61bbcaf5c512d75830564541f917f8f/pageserver/src/tenant.rs#L2690)

创建分支前会处理这些条件：

1. 父 timeline 必须存在并处于可用状态；
2. 若没有显式传入 LSN，则使用适当的父 timeline 位置；
3. branch LSN 不能早于父 timeline 的 GC cutoff；
4. branch LSN 不能超过父 timeline 已知/可用 WAL 位置；
5. 必要时等待父 timeline ingest 到目标 LSN，确保分支点可读；
6. 新 timeline ID 不能与已有 timeline 冲突。

### 4.4 落盘 timeline 元数据

`create_timeline` 完成父 timeline 状态和 LSN 检查后，会调用 `branch_timeline`；后者在
[`branch_timeline_impl`](https://github.com/neondatabase/neon/blob/fa504217c61bbcaf5c512d75830564541f917f8f/pageserver/src/tenant.rs#L4985) 中持有 GC 临界区并真正创建 timeline。
新 timeline 会写入类似下面的关系：

```text
new_timeline.ancestor_timeline_id = parent_timeline_id
new_timeline.ancestor_lsn         = branch_lsn
```

随后初始化新 timeline 自己的目录、metadata 和运行状态。这里的核心成本是元数据及少量初始化工作，不是数据规模相关的全量复制。

创建期间还会保护父 timeline 的分支点，避免 GC 并发越过该 LSN。否则子 timeline 尚未完成创建时，祖先历史就可能被回收。

## 5. 分支后的读取路径

timeline 读取的核心实现位于：

- [`pageserver/src/tenant/timeline.rs`](https://github.com/neondatabase/neon/blob/fa504217c61bbcaf5c512d75830564541f917f8f/pageserver/src/tenant/timeline.rs#L4440)

概念上，读取 `(key, requested_lsn)` 的过程如下：

```text
在当前 timeline 的 layer 中查找 key@requested_lsn
  │
  ├── 找到足够的 image/delta 记录：重建页面并返回
  │
  └── 当前 timeline 没有足够历史
        │
        ├── 没有祖先：返回缺失/错误
        │
        └── 有祖先：在祖先中继续查找
              ancestor_requested_lsn = min(requested_lsn, ancestor_lsn)
```

`min(requested_lsn, ancestor_lsn)` 是隔离语义的关键：子分支读取祖先时，最多只能看到分支点当时的父分支状态。父分支在分支点之后产生的新版本不会泄漏到子分支。

如果存在多级分支，这个过程可以沿祖先链递归：

```text
root timeline
  └── branch A @ LSN 100
        └── branch B @ LSN 180
```

读取 B 中自身不存在的旧页时，可以先查 A，再按 A 的分支边界查 root；每跨一条祖先边，都受到该边 `ancestor_lsn` 的限制。

## 6. 分支后的写入路径

分支 compute 启动后，会绑定新 timeline：

1. 初始化时从 Pageserver 读取分支点可见的数据页；
2. 新事务产生 WAL；
3. WAL 发送给 Safekeeper；
4. Pageserver ingest 新 timeline 的 WAL；
5. 新生成的 delta/image layer 只属于该 timeline。

因此父、子分支共享的是分支点之前的不可变历史，分支点之后各自追加自己的版本。这在语义上类似 copy-on-write，但实现载体是 timeline、LSN 和 layer，而不是文件系统块快照。

## 7. GC 与分支生命周期

快速分支不是完全“零成本”。只要子 timeline 仍依赖某个祖先分支点，祖先就必须保留足以重建该分支点的数据。

主要影响：

- 创建分支会形成一个历史保留约束；
- GC 不能越过仍被子分支引用的 branch point；
- 分支数量和存活时间会影响历史数据保留量；
- compaction 可改变 layer 的组织方式，但不能破坏 `(key, lsn)` 的可重建性；
- 删除子 timeline 后，对应的祖先保留约束才可能解除，实际空间释放还要等待后续 GC/远端删除流程。

所以“创建很快”与“长期没有存储成本”是两回事。

## 8. 与 Git Branch 的异同

相似点：

- 都记录一个共同祖先；
- 创建分支主要是创建引用/元数据；
- 分支之后独立演进。

不同点：

- Git 的对象通常按内容寻址，Neon 以数据 key、timeline 和 LSN 查找页面版本；
- Neon 要持续接收 WAL，并满足 PostgreSQL 的事务、崩溃恢复和持久性语义；
- 数据库分支通常不是自动做 SQL 级 merge。若要合并数据，需要应用层迁移、逻辑复制、导入导出或专门的数据合并流程。

## 9. 是否开源、能否自行部署

### 9.1 开源范围

Neon 官方仓库使用 Apache-2.0 许可证，核心存储和计算相关代码均可查看、修改和编译，包括 Pageserver、Safekeeper、本地控制工具和部分控制面组件。

### 9.2 可部署性

可以自行部署，但应区分两种目标：

1. **本地学习/功能验证**：官方 Docker Compose 和本地开发工具足够，可以运行 Pageserver、Safekeeper、Broker 和 Compute，体验 timeline/branch。
2. **生产私有化**：代码可用不代表存在一个与 Neon Cloud 等价的单命令安装包。需要自行负责 compute provisioning hooks、调度、认证、TLS、域名/代理、对象存储、监控告警、备份恢复、滚动升级和故障转移。

官方 `docs/docker.md` 也将仓库中的 Docker Compose 定位为测试用途。若目标是生产，应进一步评估 `storage_controller` 的部署模式以及外部 compute orchestration 集成。

## 10. 本机部署记录

### 10.1 环境与调整

本次在 Apple Silicon macOS 上用 Docker Compose 部署。最终运行组件：

- 1 个 Storage Broker；
- 1 个 Pageserver；
- 3 个 Safekeeper；
- 1 个父分支 Compute；
- 1 个子分支 Compute。

为了适配当前可获得的镜像和本地实验环境，做了两项调整：

- 旧版 MinIO 镜像目前无法匿名拉取，因此 Pageserver 的 remote storage 改为本地文件系统目录；
- Debian Bullseye 当前部分安全仓库包已不可直接获得，构建 Compute 镜像时固定到 Debian snapshot。

这些调整适合单机体验，不应作为生产存储方案。

### 10.2 实际资源

```text
tenant:          ff5117463416aef7a63e532978974a01
parent timeline: 8a1073677c60f7bf37ab2b49185f2802
branch timeline: 26b365690eed5226ec7f3c1056962552
branch LSN:      0/15DA1C0
```

连接信息：

```text
父分支: postgresql://cloud_admin:cloud_admin@localhost:55433/postgres
子分支: postgresql://cloud_admin:cloud_admin@localhost:55435/postgres
```

### 10.3 隔离验证

实验顺序：

1. 在父 timeline 创建表并写入第 1 行 `before branch`；
2. 在父 timeline 写入第 3 行 `parent only`，随后选取已提交的 LSN；
3. 在该 LSN 创建子 timeline；
4. 在子分支写入第 2 行 `child only`；
5. 在父分支继续写入第 4 行 `parent after branch`；
6. 分别查询两个 compute。

观察结果：

```text
父分支：1|before branch
        3|parent only
        4|parent after branch

子分支：1|before branch
        2|child only
        3|parent only
```

第 1、3 行在最终分支点之前提交，所以父子共同可见；第 2 行只存在于子分支，第 4 行只
存在于父分支。结果符合 timeline 祖先读取截断和分支后独立 WAL/layer 的设计。

### 10.4 一个容易踩的 LSN 坑

最初测试把建表、插入和读取 LSN 放在同一个 `psql -c` 事务中。取得的 LSN 可能早于该事务提交位置，用它创建分支后，子分支看不到刚创建的表。这不是分支错误，而是选择了一个事务尚未提交的分支点。

可靠流程应当是：

1. 单独执行并提交 DDL/DML；
2. 再获取当前 WAL LSN；
3. 确认 Safekeeper/Pageserver 已 ingest 到目标位置；
4. 最后用该 LSN 创建 timeline。

## 11. 本地实验文件说明

本地工作区中用于实验的文件包括：

- `docker-compose/docker-compose.local.yml`：本地覆盖配置，增加子分支 compute，并绕过旧 MinIO 依赖；
- `docker-compose/pageserver_config_local/pageserver.toml`：使用本地文件系统 remote storage 的 Pageserver 配置；
- `docker-compose/LOCAL_PLAYGROUND.md`：本地启动、连接和验证说明；
- `docker-compose/compute_wrapper/Dockerfile`：构建源固定到可复现的 Debian snapshot。

运行时生成的 Pageserver tenant/layer 数据和 remote storage 数据不应提交到 Git。

## 12. 关键代码索引

| 关注点 | 代码位置 | 作用 |
|---|---|---|
| 本地 branch CLI | [`control_plane/src/bin/neon_local.rs`](https://github.com/neondatabase/neon/blob/fa504217c61bbcaf5c512d75830564541f917f8f/control_plane/src/bin/neon_local.rs#L1276) | 解析 branch 参数并调用创建 API |
| Timeline HTTP API | [`pageserver/src/http/routes.rs`](https://github.com/neondatabase/neon/blob/fa504217c61bbcaf5c512d75830564541f917f8f/pageserver/src/http/routes.rs#L589) | `timeline_create_handler` 接收并转换 create/branch 请求 |
| Tenant timeline 创建 | [`pageserver/src/tenant.rs`](https://github.com/neondatabase/neon/blob/fa504217c61bbcaf5c512d75830564541f917f8f/pageserver/src/tenant.rs#L2690) | `create_timeline` 验证祖先和 LSN、等待 ingest |
| Branch 实际创建 | [`pageserver/src/tenant.rs`](https://github.com/neondatabase/neon/blob/fa504217c61bbcaf5c512d75830564541f917f8f/pageserver/src/tenant.rs#L4985) | `branch_timeline_impl` 保护 GC cutoff 并创建 metadata |
| Timeline 读取 | [`pageserver/src/tenant/timeline.rs`](https://github.com/neondatabase/neon/blob/fa504217c61bbcaf5c512d75830564541f917f8f/pageserver/src/tenant/timeline.rs#L4440) | layer 查询、页面重建、沿祖先读取并截断到 ancestor LSN |
| Pageserver 存储设计 | [`docs/pageserver-storage.md`](https://github.com/neondatabase/neon/blob/fa504217c61bbcaf5c512d75830564541f917f8f/docs/pageserver-storage.md) | image/delta layer、读取、compaction 与 GC |
| Docker 说明 | [`docs/docker.md`](https://github.com/neondatabase/neon/blob/fa504217c61bbcaf5c512d75830564541f917f8f/docs/docker.md) | 官方 Compose 的测试定位和启动方式 |
| Storage Controller | [`docs/storage_controller.md`](https://github.com/neondatabase/neon/blob/fa504217c61bbcaf5c512d75830564541f917f8f/docs/storage_controller.md) | 存储节点管理及与外部控制面的边界 |
| Safekeeper 协议 | [`docs/safekeeper-protocol.md`](https://github.com/neondatabase/neon/blob/fa504217c61bbcaf5c512d75830564541f917f8f/docs/safekeeper-protocol.md) | Compute、Safekeeper、Pageserver 的 WAL 协议 |

## 13. 官方资料

- [Neon 官方开源仓库](https://github.com/neondatabase/neon)
- [Pageserver storage design](https://github.com/neondatabase/neon/blob/main/docs/pageserver-storage.md)
- [Docker Compose documentation](https://github.com/neondatabase/neon/blob/main/docs/docker.md)
- [Storage Controller documentation](https://github.com/neondatabase/neon/blob/main/docs/storage_controller.md)
- [Safekeeper protocol](https://github.com/neondatabase/neon/blob/main/docs/safekeeper-protocol.md)

## 14. 总结

Neon branch 的本质，是在多版本 page storage 上创建一个带祖先 timeline 和分支 LSN 的新 timeline。新分支通过祖先链共享分支点之前的历史，通过独立 WAL 和 layer 写入实现分支点之后的隔离。它把传统“复制整库”的成本，转换成了便宜的元数据创建，以及后续按实际修改量付出的存储成本。

Neon 核心项目可以开源自部署，且本机已验证能够运行并完成父子分支隔离实验；但官方仓库中的 Compose 更适合作为技术体验环境，生产部署仍需工程化补齐完整控制面和运维体系。
