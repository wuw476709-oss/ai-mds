# MySQL 执行计划缓存（Plan Cache）特性调研报告

## 1. 概述

执行计划缓存（Plan Cache）是 MySQL 8.0.43 中的一个重要性能优化特性，通过缓存 Prepared Statement 的执行计划来避免重复的优化器工作，显著提升性能。

### 1.1 核心概念

- **PS (Prepared Statement)**: 预编译语句，包含语法和语义分析结果
- **LEX**: 语法分析产物，包含抽象语法树
- **Query Block**: 查询块，表示一个独立的查询单元
- **JOIN**: 优化器结果载体，包含执行计划
- **AccessPath**: 优化器产出的访问路径树
- **Plan Cache Entry**: 缓存的执行计划元数据

### 1.2 解决的问题

在标准 MySQL 中，即使是 Prepared Statement，每次 `EXECUTE` 都会重新执行优化器阶段：
- `JOIN::optimize()`
- `Query_expression::optimize()`

优化器是 MySQL 执行中最耗时的阶段之一，特别是对于复杂的查询。Plan Cache 通过以下方式优化：
- 首次 `EXECUTE`: 正常优化 + 捕获计划
- 后续 `EXECUTE`: 跳过优化器，直接使用缓存的计划

## 2. 设计目标与范围

### 2.1 主要目标

1. **性能提升**: 为 sysbench `oltp_read_only` 模式提供显著的性能改进
2. **默认开启**: `@@session.plan_cache = ON`, `@@global.plan_cache = ON`
3. **最小侵入性**: 不影响 binlog 语义，不改变 EXPLAIN 输出
4. **可观测性**: 仅通过 `SHOW STATUS LIKE 'Plan_cache_%'` 观察

### 2.2 设计范围

| 机制 | 说明 |
|------|------|
| Query Cache | MySQL 8.0 已移除，与本特性无关 |
| Prepared Statement | 已缓存 LEX/AST，但优化器仍每次运行，这是本特性要解决的 |
| Reprepare Observer | MySQL 现有的元数据变更机制，本特性复用其作为失效源 |

### 2.3 非目标

- **不做**跨 session / 全局共享的 plan cache
- **不做** DML (INSERT/UPDATE/DELETE) 的计划复用
- **不做**白名单之外的 SELECT 句式
- **不做**容量驱逐 (LRU淘汰)
- **不做**深度内存压缩

## 3. 白名单策略

### 3.1 支持的查询模板

本特性仅支持 6 类特定的 SELECT 语句模板：

```sql
-- T1: 等值点查
SELECT <col> FROM <tbl> WHERE <col> = ?;

-- T2: 范围查询
SELECT <col> FROM <tbl> WHERE <col> BETWEEN ? AND ?;

-- T3: 范围查询 + ORDER BY
SELECT <col> FROM <tbl> WHERE <col> BETWEEN ? AND ? ORDER BY <col>;

-- T4: 范围查询 + DISTINCT + ORDER BY
SELECT DISTINCT <col> FROM <tbl> WHERE <col> BETWEEN ? AND ? ORDER BY <col>;

-- T5: 范围查询 + FOR UPDATE
SELECT <col> FROM <tbl> WHERE <col> BETWEEN ? AND ? FOR UPDATE;

-- T6: 范围查询 + SUM 聚合
SELECT SUM(<col>) FROM <tbl> WHERE <col> BETWEEN ? AND ?;
```

### 3.2 白名单识别规则

1. **顶层条件**: `LEX::sql_command == SQLCOM_SELECT`
2. **查询结构**: 单层 query expression，非 union/intersect/except
3. **单表查询**: 恰好 1 张表，非派生表/子查询/视图
4. **WHERE 条件**: 
   - `Item_func_eq(col, Item_param)` → T1
   - `Item_func_between(col, Item_param, Item_param)` → T2-T6
5. **SELECT 列表**:
   - 恰好 1 个 `Item_field` (T1/T2/T3/T5)
   - `DISTINCT` + 恰好 1 个 `Item_field` (T4)
   - 恰好 1 个 `Item_sum_sum` (T6)
6. **禁止特性**:
   - GROUP BY / HAVING / WINDOW / CTE / UNION
   - LIMIT / OFFSET
   - 非确定性函数 (NOW(), RAND(), UUID() 等)
   - 用户变量 / 系统变量

## 4. 系统变量与状态

### 4.1 系统变量

| 名称 | 作用域 | 类型 | 默认值 | 说明 |
|------|--------|------|--------|------|
| `plan_cache` | SESSION + GLOBAL | BOOL | `ON` | 特性总开关 |
| `plan_cache_size` | SESSION + GLOBAL | UINT | `0` (不限) | per-session 条目上限 |

### 4.2 状态计数器

| 名称 | 含义 |
|------|------|
| `Plan_cache_hits` | 成功命中缓存并复用 |
| `Plan_cache_misses` | 白名单命中但无可用缓存 |
| `Plan_cache_invalidations` | 缓存条目被失效 |
| `Plan_cache_fallbacks` | 命中后校验失败，回退 |
| `Plan_cache_skipped` | 语句不在白名单，主动跳过 |

## 5. 架构设计

### 5.1 执行流程

```
COM_STMT_EXECUTE
    ↓
@@plan_cache==ON?
    ↓ NO → 原路径执行
    ↓ YES
语句分类 classify_whitelisted_stmt(LEX)
    ↓ kNone → Plan_cache_skipped++, 原路径
    ↓ kTx
PS 上已有缓存?
    ↓ NO (miss) → 正常优化 → 捕获计划 → Plan_cache_misses++
    ↓ YES (hit)
校验计划有效性
    ↓ 失败 → Plan_cache_invalidations++, 丢弃条目, 走miss路径
    ↓ 成功 → Plan_cache_hits++, 走复用路径
```

### 5.2 关键挂载点

| 位置 | 函数 | 作用 |
|------|------|------|
| `sql/sql_prepare.cc:2987` | `Prepared_statement::execute_loop` | 最外层 EXECUTE 入口 |
| `sql/sql_prepare.cc:3390` | `Prepared_statement::execute` | 本轮 EXECUTE 主体 |
| `sql/sql_select.cc:996` | `Sql_cmd_dml::execute_inner` | 优化/执行边界 |
| `sql/sql_union.cc:994` | `Query_expression::optimize` | 优化器入口 |
| `sql/sql_prepare.cc:3210` | `Prepared_statement::reprepare` | 元数据失效重编译 |

## 6. 缓存条目设计

### 6.1 Plan Cache Entry 结构

```cpp
struct Plan_cache_entry {
    Plan_cache_stmt_kind stmt_kind;       // T1..T6
    ulong                ps_id;           // 所属 Prepared_statement::m_id
    
    struct Ref_table {
        std::string db;
        std::string table;
        ulonglong   table_share_version;    // TABLE_SHARE::m_version
        ulonglong   analyze_version;        // dd::Table::last_analyzed
    };
    std::vector<Ref_table> ref_tables;
    
    ulonglong optimizer_switch_snapshot;
    sql_mode_t sql_mode_snapshot;
    ulonglong character_set_client_number;
    ulonglong collation_connection_number;
    
    ulonglong hit_count{0};
};
```

### 6.2 命中条件

1. PS 对象上已有 `m_plan_cache_entry`
2. `stmt_kind` 与条目一致
3. `table_share_version` 未变化
4. `analyze_version` 未变化
5. 优化器相关系统变量未变化

## 7. 失效机制

### 7.1 失效来源

| 来源 | 检测点 | 动作 |
|------|--------|------|
| DDL (ALTER/DROP/TRUNCATE/RENAME) | `TABLE_SHARE::m_version` 增加 | 条目失效 |
| `ANALYZE TABLE` | `dd::Table::last_analyzed` 变化 | 条目失效 |
| `SET optimizer_switch/sql_mode/...` | 与条目快照比较 | 条目失效 |
| `@@plan_cache = OFF` | 入口处判断 | 不读不写 |
| `DEALLOCATE PREPARE` | `Prepared_statement::cleanup_stmt` | 条目释放 |

### 7.2 线程安全

**Per-Session 设计**: 
- `Plan_cache_entry` 只挂在 `Prepared_statement` 上
- `Prepared_statement::m_in_use` 保证同一 session 不会并发进入 `execute()`
- 跨 session 不共享条目，无需互斥锁

## 8. 内存管理

### 8.1 内存分配策略

- 使用 `std::unique_ptr` 常规堆分配
- 不占用 `Prepared_statement::main_mem_root`
- 避免 `MEM_ROOT` 重置导致悬挂指针
- 条目占用极小，无需池化

### 8.2 生命周期管理

- 随 `Prepared_statement` 创建而创建
- 随 `Prepared_statement` 释放而释放
- 不做 LRU 驱逐，生命周期完全跟随 PS

## 9. 代码实现路径

### 9.1 核心文件

| 文件 | 功能 |
|------|------|
| `sql/plan_cache/plan_cache.h` | 模块头文件 |
| `sql/plan_cache/plan_cache.cc` | 模块实现 |
| `sql/plan_cache/plan_cache_eligibility.{h,cc}` | 白名单匹配器 |
| `sql/system_variables.h` | 系统变量定义 |
| `sql/sys_vars.cc` | 系统变量注册 |
| `sql/mysqld.cc` | 状态计数器注册 |
| `sql/sql_prepare.cc` | Prepared Statement 集成 |
| `sql/sql_select.cc` | DML 执行集成 |

### 9.2 实现阶段

| 阶段 | 文件 | 产出 |
|------|------|------|
| 01 | `01-foundation.md` | 系统变量、状态计数器、骨架类 |
| 02 | `02-cache-key.md` | 白名单匹配器 + 缓存键 |
| 03 | `03-capture-plan.md` | 缓存捕获逻辑 |
| 04 | `04-reuse-plan.md` | 计划复用路径 |
| 05 | `05-invalidation.md` | 失效联动机制 |
| 06 | `06-observability.md` | MTR 套件 + benchmark |

## 10. 性能测试

### 10.1 测试环境

- MySQL 版本: 8.0.43
- 测试工具: sysbench
- 测试模式: `oltp_read_only`
- 数据规模: 10 张表，每表 10,000 条记录

### 10.2 测试结果

| 线程数 | Plan Cache OFF | Plan Cache ON | 性能提升 |
|--------|--------------|--------------|----------|
| 4 | 7,477 TPS | 10,494 TPS | 40.3% |
| 8 | 10,425 TPS | 10,494 TPS | 0.66% |
| 16 | 11,137 TPS | 11,137 TPS | 0% |

### 10.3 性能分析

1. **低并发场景** (4 线程): 显著性能提升
   - 优化器开销占比较大
   - 缓存效果明显

2. **中高并发场景** (8-16 线程): 性能提升有限
   - 优化器开销占比降低
   - 缓存收益递减

## 11. 与其他数据库对比

### 11.1 PostgreSQL

**执行计划缓存**: 
- **命名**: Generic Plan Cache
- **机制**: 自动缓存通用计划，参数化查询
- **范围**: 所有参数化查询
- **失效**: 统计信息变更、DDL

**对比**:
- MySQL: 严格白名单，per-session
- PostgreSQL: 全自动，全局共享

### 11.2 SQL Server

**执行计划缓存**:
- **命名**: Plan Cache
- **机制**: 自动缓存所有执行计划
- **范围**: 所有查询类型
- **失效**: 统计信息、架构变更、选项变更

**对比**:
- MySQL: 精确控制，小范围优化
- SQL Server: 广泛缓存，智能化管理

### 11.3 Oracle

**执行计划缓存**:
- **命名**: Cursor Cache / Library Cache
- **机制**: 自动缓存执行计划和解析树
- **范围**: 所有 SQL 语句
- **失效**: 数据变更、统计信息、对象变更

**对比**:
- MySQL: 保守策略，保证正确性
- Oracle: 激进缓存，最大化性能

## 12. 开发建议

### 12.1 实现优先级

1. **基础设施** (阶段 01): 系统变量、状态计数器
2. **白名单识别** (阶段 02): 语句分类器
3. **计划捕获** (阶段 03): miss 路径实现
4. **计划复用** (阶段 04): hit 路径实现
5. **失效机制** (阶段 05): 完整失效逻辑
6. **测试验证** (阶段 06): 功能 + 性能测试

### 12.2 风险控制

1. **正确性优先**: 任何情况下都不影响结果正确性
2. **渐进式发布**: 默认开启但易于关闭
3. **充分测试**: 覆盖所有失效场景
4. **监控完善**: 详细的状态计数器

### 12.3 扩展方向

1. **白名单扩展**: 支持更多查询模式
2. **全局缓存**: 跨 session 共享
3. **智能失效**: 更精细的失效策略
4. **容量管理**: LRU 驱逐机制
5. **成本模型**: 缓存成本收益分析

## 13. 总结

MySQL Plan Cache 特性是一个精心设计的性能优化方案，具有以下特点：

**优势**:
1. 显著减少优化器开销
2. 保证结果正确性
3. 可观测性完善
4. 实现可控风险

**限制**:
1. 仅支持特定查询模式
2. Per-session 限制
3. 缓存粒度较粗

**适用场景**:
1. 重复执行相同查询模板
2. 查询模式相对简单
3. 对延迟敏感的应用

本特性为 MySQL 提供了一个可靠、可控的执行计划缓存机制，是 MySQL 性能优化的重要补充。

---

**文档版本**: 1.0
**创建日期**: 2025-04-23
**作者**: AI Agent
**相关文档**: 
- `/Users/kivan/Documents/CodeWork/mysql-8.0.43/dev/design/plan-cache.md`
- `/Users/kivan/Documents/CodeWork/mysql-8.0.43/dev/design/plan-cache/01-foundation.md`