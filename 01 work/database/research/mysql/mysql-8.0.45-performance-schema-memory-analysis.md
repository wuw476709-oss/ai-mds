# MySQL 8.0.45 Performance Schema 参数内存分析与本机验证

## 结论

在 `performance_schema=ON` 的前提下：

| 参数 | 单独设为最大值 `1048576` | 启动 OOM 风险 | 原因 |
|---|---:|---|---|
| `performance_schema_digests_size` | 启动成功，但峰值 RSS 约 1.24 GiB，内部累计分配约 6.25 GiB | **很高** | 启动时一次性创建 digest record、digest token 和 SQL sample 数组 |
| `performance_schema_max_table_instances` | 与基线 RSS 基本相同 | **低（启动期）** | 只建立可扩展容器，table share 按 4096 个一页延迟分配 |
| `performance_schema_max_sql_text_length` | 启动成功，但峰值 RSS 约 1.41 GiB，理论新增分配约 5.17 GB | **很高** | 同时放大 digest sample、history-long 和每线程 statement 缓冲区 |
| `performance_schema_max_digest_length` | 启动成功，但峰值 RSS 约 1.69 GiB，PFS 计数新增约 5.17 GB | **很高** | 同时放大 digest、history-long 和每线程 digest token 缓冲区 |
| 四项全部最大 | 未启动完成；约 2.03 GiB RSS 时被 macOS `SIGKILL` | **确定存在** | 仅 digest 模块理论容量就超过 2 TiB |

单项长度或数量最大值能够在本机启动成功，不代表配置安全。macOS 对大量零页、内存压缩和虚拟内存的处理，使 RSS 远小于 MySQL 已经累计记录的分配字节数；在 Linux、容器 memory limit 或并发负载下，结果可能更早变成 `ENOMEM` 或 OOM Kill。

## 验证环境

- 日期：2026-10-27（Asia/Shanghai）
- 主机：Apple arm64，Darwin 27.0.0
- mysqld：MySQL 8.0.45 Source distribution
- 二进制：`mysql-8.0.45/build-session-kill-execute/runtime_output_directory/mysqld`
- 数据目录：独立初始化的 `/private/tmp/mysql-pfs-memory-validation-20261027/data`
- 网络：`--skip-networking --mysqlx=OFF`，只使用独立 Unix socket
- 主要降噪配置：
  - `innodb_buffer_pool_size=16M`
  - `innodb_redo_log_capacity=16M`
  - `key_buffer_size=1M`
  - `max_connections=20`
  - `table_open_cache=64`
  - `table_definition_cache=400`
- RSS：用 `ps -o rss` 每 50 ms 采样
- PFS 内存：汇总 `performance_schema.memory_summary_global_by_event_name` 中的 `memory/performance_schema/%`

每个 case 都串行启动、采样、通过 `mysqladmin shutdown` 干净关闭后再运行下一个。测试结束后没有 mysqld 残留进程，也没有使用或修改仓库中的现有 runtime 数据目录。

## 最大值实测

以下是对单参数最大值的直接启动结果：

| Case | Ready | 退出码 | 峰值 RSS | `@@performance_schema` | PFS 报告字节数 | 结果 |
|---|---:|---:|---:|---:|---:|---|
| 基线 | 是 | 0 | 305,904 KiB | 1 | 135,353,832 | 正常 |
| `digests_size=1048576` | 是 | 0 | 1,304,400 KiB | 1 | 5,633,032,680 | 正常启动后主动关闭 |
| `max_table_instances=1048576` | 是 | 0 | 306,080 KiB | 1 | 135,353,832 | 与基线基本相同 |
| `max_sql_text_length=1048576` | 是 | 0 | 1,475,504 KiB | 1 | 4,262,708,712 | 正常启动后主动关闭 |
| `max_digest_length=1048576` | 是 | 0 | 1,773,600 KiB | 1 | 5,310,260,712 | 正常启动后主动关闭 |
| 四项全部最大 | 否 | 137 | 2,131,232 KiB | 不可用 | 不可用 | 启动期间收到 `SIGKILL` |

### 安全限制说明

最初计划使用 `ulimit -v 786432` 将 mysqld 地址空间限制在 768 MiB，但 macOS shell 明确返回：

```text
ulimit: virtual memory: cannot modify limit: Invalid argument
```

因此该限制实际没有生效。四项全最大 case 在 mysqld 创建 error log 之前就被系统终止，进程退出状态为 137，最后采样 RSS 为 2,131,232 KiB。发现这一点后立即停止了最大值测试；后续只运行带 768 MiB RSS 主动终止保护的低量级 case。

这次 `SIGKILL` 是测试子进程自身的内存压力终止，没有影响其他进程或现有 MySQL 数据，但它也说明 macOS 上不能依赖 `RLIMIT_AS` 来安全验证 TiB 级请求。

## 低量级线性复核

为了验证公式而不再制造高内存压力，使用了 50,000 digest 和 64 KiB 长度：

| Case | 峰值 RSS | PFS 报告字节数 | 相对基线的 PFS 增量 | RSS 保护触发 |
|---|---:|---:|---:|---:|
| 基线 | 305,904 KiB | 135,353,832 | — | 否 |
| `digests_size=50000` | 606,848 KiB | 392,505,832 | 257,152,000 | 否 |
| `max_table_instances=1048576` | 307,168 KiB | 135,353,832 | 0 | 否 |
| `max_sql_text_length=65536` | 616,928 KiB | 389,531,112 | 254,177,280 | 否 |
| `max_digest_length=65536` | 617,104 KiB | 454,043,112 | 318,689,280 | 否 |

### `digests_size=50000`

当前构建中：

```text
sizeof(PFS_statements_digest_stat) = 4224 bytes
```

PFS 可见的理论增量为：

```text
(50000 - 1000) × (4224 + 1024)
= 257,152,000 bytes
```

实测增量也是 **257,152,000 bytes**，逐字节吻合。

此外还有 digest sample SQL text：

```text
(50000 - 1000) × 1024
= 50,176,000 bytes
```

这部分由源码真实分配，但没有出现在上述 PFS memory 汇总中。两部分合计新增 307,328,000 bytes，约 293.09 MiB；实测 RSS 增长约 293.89 MiB，吻合。

### `max_digest_length=65536`

当前自动 sizing 实际涉及的记录数为：

```text
digest summary              1000
statements history-long      100
current: 256 threads × 10   2560
history: 256 threads × 5    1280
合计                        4940
```

相对默认 1024 字节的理论增量：

```text
4940 × (65536 - 1024)
= 318,689,280 bytes
```

实测 PFS 增量同样是 **318,689,280 bytes**。

### `max_sql_text_length=65536`

PFS memory 表中可见的 current、history 和 history-long 记录数合计为 3940：

```text
3940 × (65536 - 1024)
= 254,177,280 bytes
```

实测 PFS 增量也是 **254,177,280 bytes**。

digest summary 还另外分配 1000 条 query sample：

```text
1000 × (65536 - 1024)
= 64,512,000 bytes
```

源码中的 `builtin_memory_digest_sample_sqltext` 有定义和实际计数调用，但没有在 `init_all_builtin_memory_class()` 中注册，因此这 64,512,000 bytes 不会显示为一条 PFS memory event。加入它后，总理论增量也是 318,689,280 bytes，与 RSS 增量约 303.73 MiB 基本吻合。

## 源码路径与理论公式

### 参数上限

四个参数的上限都为 `1024 * 1024`：

- [`performance_schema_max_table_instances`](../../mysql-8.0.45/sql/sys_vars.cc#L762)
- [`performance_schema_digests_size`](../../mysql-8.0.45/sql/sys_vars.cc#L916)
- [`performance_schema_max_digest_length`](../../mysql-8.0.45/sql/sys_vars.cc#L940)
- [`performance_schema_max_sql_text_length`](../../mysql-8.0.45/sql/sys_vars.cc#L975)

### Digest 启动分配

[`init_digest()`](../../mysql-8.0.45/storage/perfschema/pfs_digest.cc#L74) 在启动时一次性分配：

```text
D × sizeof(PFS_statements_digest_stat)
D × performance_schema_max_digest_length
D × performance_schema_max_sql_text_length
```

其中 `D = performance_schema_digests_size`。

当三项都为最大值时：

```text
1048576 × 4224       =   4.125 GiB
1048576 × 1048576    =   1 TiB digest token
1048576 × 1048576    =   1 TiB SQL sample
digest 模块合计      ≈   2.004 TiB
```

而且 [`pfs_malloc()`](../../mysql-8.0.45/storage/perfschema/pfs_global.cc#L60) 对这些分配使用 `MY_ZEROFILL` 后执行整块 `memset`，并非只保留一个完全不触碰的虚拟地址区间。

### Statement history-long

[`init_events_statements_history_long()`](../../mysql-8.0.45/storage/perfschema/pfs_events_statements.cc#L72) 还会在启动期分配：

```text
history_long_size × max_digest_length
history_long_size × max_sql_text_length
```

### 每线程缓冲区

[`PFS_thread_allocator::alloc_array()`](../../mysql-8.0.45/storage/perfschema/pfs_buffer_container.cc#L492) 使用：

```text
thread_page_size × max_sql_text_length × statement_stack_size
thread_page_size × max_sql_text_length × statements_history_size
thread_page_size × max_digest_length × statement_stack_size
thread_page_size × max_digest_length × statements_history_size
```

线程容器每页 256 个线程，见 [`PFS_thread_container`](../../mysql-8.0.45/storage/perfschema/pfs_buffer_container.h#L1573)。所以即使 digest summary 很小，把任一长度设成 1 MiB 仍会在首次创建线程页时产生 GiB 级请求。

### Table instances 按需增长

table share 容器是：

```cpp
PFS_buffer_scalable_container<PFS_table_share, 4 * 1024, 4 * 1024>
```

见 [`PFS_table_share_container`](../../mysql-8.0.45/storage/perfschema/pfs_buffer_container.h#L1441)。初始化只设置页面上限并把页面指针置空，不创建全部对象，见 [`PFS_buffer_scalable_container::init()`](../../mysql-8.0.45/storage/perfschema/pfs_buffer_container.h#L442)。

当前构建的 `sizeof(PFS_table_share)=1024`，因此：

```text
单页：4096 × 1024 = 4 MiB
完全使用 1048576 个实例：约 1 GiB 基础数组
```

hash、table lock stat 和 index stat 需要额外内存，但也随实际 table share 使用情况增长。实测最大上限与基线启动 RSS 基本一致，验证了它不是启动期全量预分配。

## 配置建议

不要把前三个参数设置为最大值。建议从以下范围起步，再根据监控调整：

```ini
performance_schema_digests_size=10000
performance_schema_max_sql_text_length=1024
performance_schema_max_digest_length=1024
performance_schema_max_table_instances=-1
```

如果必须保留更长 SQL，建议先尝试 4096 或 8192，并同时核算：

```text
digest 数量
+ statement history-long 数量
+ PFS thread 页数 × (statement stack + per-thread history)
```

还应注意 `performance_schema_max_digest_length` 与服务器级 `max_digest_length` 是两个参数。如果后者仍为默认 1024，把 PFS 存储长度提高到 1 MiB 基本只是在预留无法有效使用的空间。

## 复现脚本

[`run_validation.sh`](./run_validation.sh) 默认只执行低量级、安全 case，并带 768 MiB RSS 主动终止保护。脚本刻意不再包含“四项全最大”case，因为 macOS 不支持本次需要的 `RLIMIT_AS`，重复运行存在不必要的系统内存压力。
