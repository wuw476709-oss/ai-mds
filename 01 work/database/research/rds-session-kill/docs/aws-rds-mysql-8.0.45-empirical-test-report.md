# AWS RDS for MySQL 8.0.45 会话终止功能实测报告

## 1. 证据口径

本文只把已经在 AWS 实例上执行、并保存 MySQL 原始回显的项目写成“实测结果”。
存储过程源码阅读、MySQL 通常行为和预期值均不作为实测结论。

测试实例：

| 项目 | 实测对象 |
|---|---|
| AWS RDS 实例 | `database-1` |
| 区域 | `eu-north-1`（斯德哥尔摩） |
| 引擎 | RDS for MySQL 8.0.45 |
| 管理员账号 | `admin@%` |
| 测试日期 | 2026-10-14 |

本报告引用五次最终有效运行：

1. 深度语义与生命周期：`20261014T084300Z-deep-semantics`
2. EXECUTE 作用域和授权链：`20261014T082933Z-grant-scope-matrix`
3. `rds_superuser_role` 转授权：`20261014T084157Z-role-delegation`
4. rdsadmin query 动态保护：`20261014T085351Z-reserved-dynamic`
5. rdsadmin session 动态保护：`20261014T085820Z-reserved-session-stage`

每次运行均保存：

- 每个用例独立的原始 stdout/stderr；
- `status.tsv`；
- `raw-mysql/manifest.tsv`（文件大小和校验值）；
- `raw-mysql/mysql-output.log`（合并后的完整回显）；
- `raw-mysql/mysql-errors.tsv`（错误和警告索引）。

## 2. 调用权限实测

以下 SQL 均已在 AWS 上实际执行：

```sql
CALL mysql.rds_kill_query(0);
CALL mysql.rds_kill(0);
```

线程 0 不存在，因此 `ERROR 1094` 表示已经通过例程 EXECUTE 检查并进入过程；
`ERROR 1370` 表示在例程 EXECUTE 检查处被拒绝。

| 调用者状态 | `rds_kill_query` | `rds_kill` | 实测结论 |
|---|---|---|---|
| 普通用户 | 1370 / 42000 | 1370 / 42000 | 两个过程都不能调用 |
| 只有 `PROCESS` | 1370 / 42000 | 1370 / 42000 | PROCESS 不提供调用权 |
| 两个过程的过程级 EXECUTE | 1094 / HY000 | 1094 / HY000 | 两个过程均已进入 |
| 已授予角色但 `SET ROLE NONE` | 1370 / 42000 | 1370 / 42000 | 未激活角色不生效 |
| `SET ROLE rds_superuser_role` | 1094 / HY000 | 1094 / HY000 | 激活角色后两个过程均可进入 |

## 3. 同一已有连接上的 GRANT/REVOKE

本项保持同一个 MySQL 连接 ID `825`，实际顺序为：

```sql
CALL mysql.rds_kill_query(0);
-- 管理连接执行 GRANT
CALL mysql.rds_kill_query(0);
-- 管理连接执行 REVOKE
CALL mysql.rds_kill_query(0);
```

同一连接的三次回显依次为：

1. GRANT 前：`ERROR 1370`；
2. GRANT 后：`ERROR 1094 Unknown thread id: 0`；
3. REVOKE 后：`ERROR 1370`。

因此已实测确认：过程 EXECUTE 的 GRANT 和 REVOKE 都会作用于已经存在的下一次
调用，不要求重新登录。

角色测试保持同一个连接。角色激活后调用得到 1094；管理员从另一个连接撤销角色后，
该连接的 `CURRENT_ROLE()` 仍显示 `rds_superuser_role`，但下一次过程调用已经返回
1370。该结果说明“角色名称仍显示为 active”和“角色权限仍可使用”不是一回事。

## 4. 自己终止自己

实际执行：

```sql
CALL mysql.rds_kill_query(CONNECTION_ID());
CALL mysql.rds_kill(CONNECTION_ID());
```

实测结果：

- self `rds_kill_query` 返回 `ERROR 1317 Query execution was interrupted`；同一连接随后
  输出 `SELF_QUERY_CONNECTION_ALIVE`。
- self `rds_kill` 先返回 1317，随后客户端收到两次 2013；原连接 ID `844` 在
  PROCESSLIST 中的计数为 0，且没有输出连接存活标记。

## 5. 目标范围矩阵

调用者为同时拥有两个过程 EXECUTE 的普通用户。每个目标分别实际执行了
`rds_kill_query` 和 `rds_kill`。

| 目标 | query 调用 | query 后连接 | session 调用 | session 后连接 |
|---|---:|---|---:|---|
| 同账号另一连接 | 成功 | 存活 | 成功 | 断开 |
| 普通账号 | 成功 | 存活 | 成功 | 断开 |
| 只有 PROCESS 的账号 | 成功 | 存活 | 成功 | 断开 |
| 已激活 `rds_superuser_role` 的账号 | 成功 | 存活 | 成功 | 断开 |
| RDS 管理员账号 | 成功 | 存活 | 成功 | 断开 |

因此在本实例上，RDS 管理员和已激活 RDS 高权限角色的普通账号都不是这两个过程的
受保护目标。

## 6. 可见性与执行权分离

无 PROCESS、但有两个过程 EXECUTE 的用户执行：

```sql
SELECT COUNT(*)
  FROM information_schema.processlist
 WHERE ID = <已由控制连接取得的目标 ID>;
CALL mysql.rds_kill_query(<同一目标 ID>);
```

第一条返回 0，第二条成功，目标查询被终止且连接存活。实测确认：看不到目标线程，
但只要通过其他渠道知道 ID，EXECUTE 持有者仍能调用过程终止该查询。

## 7. QUERY、SESSION、事务与锁

### 7.1 空闲连接

对处于 Sleep 的连接调用 `rds_kill_query` 返回成功；原连接随后使用同一个连接 ID
输出 `IDLE_CONNECTION_ALIVE`。

### 7.2 显式事务

目标连接实际执行：

```sql
START TRANSACTION;
UPDATE cskaws_db.deep_lock_probe SET value=11 WHERE id=1;
SELECT SLEEP(30);
```

控制连接调用 `rds_kill_query` 后，管理员从 `information_schema.innodb_trx` 实际读到：

```text
trx_mysql_thread_id=848
trx_state=RUNNING
trx_rows_locked=1
trx_rows_modified=1
```

另一连接更新同一行得到 `ERROR 1205 Lock wait timeout exceeded`；目标执行 ROLLBACK
后，另一连接更新成功。实测确认 query kill 不结束事务，也不释放该事务已有的行锁。

另一轮事务把 `id=2` 未提交地更新为 21。调用 `rds_kill` 后：

- 目标收到 `ERROR 2013 Lost connection`；
- 管理连接读取值为 0，证明 21 没有提交；
- 管理连接随后成功更新为 22，证明行锁已释放。

### 7.3 锁等待目标

等待行锁的 UPDATE 分别作为两个过程的目标：

- `rds_kill_query`：调用成功，等待语句收到 1317；独立持锁连接仍可输出
  `HOLDER_STILL_ALIVE`。
- `rds_kill`：调用成功，等待连接收到 2013；独立持锁连接仍可输出
  `HOLDER_STILL_ALIVE`。

## 8. 原生 KILL 对照

对另一个普通账号的同一目标线程，以下调用者分别实际执行原生
`KILL QUERY <id>`：

- 普通用户；
- PROCESS 用户；
- RDS 过程 EXECUTE 用户；
- RDS 管理员 `admin`。

四者均返回：

```text
ERROR 1095 (HY000): You are not owner of thread
```

管理员执行原生 `KILL CONNECTION <id>` 也返回 1095。目标连接随后仍输出
`NATIVE_TARGET_ALIVE`。这与 `mysql.rds_kill*` 的成功结果形成直接对照。

## 9. 并发调用

两个管理员连接同时对同一个活动查询调用 `rds_kill_query`。本次最终运行中两个调用
都返回成功；目标 SLEEP 返回 1，随后连接输出存活标记。本用例只证明这一次并发结果，
不外推为所有竞态都必须双成功。

## 10. 参数转换

两个过程都实际执行了相同矩阵，回显一致：

| 输入 | 最终错误中的线程 ID |
|---|---:|
| `NULL` | 0 |
| `0` | 0 |
| `-1` | 4294967295 |
| `1.5` | 2 |
| `'123'` | 123 |
| `' 123 '` | 123 |
| `'1e2'` | 100 |
| `'abc'` | 0 |
| `4294967295` | 4294967295 |
| `4294967296` | 0 |
| 预处理参数字符串 `'0'` | 0 |

`CONNECTION_ID()` 作为参数时，两个过程都返回 1317；self session 的连接后果见第 4
节。

## 11. EXECUTE 作用域和授权链

### 11.1 全局作用域

实际执行 `GRANT EXECUTE ON *.*` 后，两个 RDS 过程都进入并返回 1094。没有
GRANT OPTION 时，普通用户转授全局 EXECUTE 返回 1045。

带 GRANT OPTION 后，G1→G2（继续带 GRANT OPTION）→G3 的两级转授权均成功。
管理员完整撤销 G1 的全局授权后，G3 调用过程仍返回 1094：下游授权没有级联撤销。

### 11.2 `mysql.*` 数据库作用域

实际执行 `GRANT EXECUTE ON mysql.*` 后，两个 RDS 过程都进入并返回 1094。没有
GRANT OPTION 时，转授返回 1044。

带 GRANT OPTION 后的 G1→G2→G3 链成功。管理员完整撤销 G1 后，G3 仍可进入
`rds_kill`，下游授权没有级联撤销。

### 11.3 单存储过程作用域

只授予 `mysql.rds_kill_query` 时：

- 调用 `rds_kill_query` 返回 1094；
- 调用 `rds_kill` 返回 1370；
- 没有 GRANT OPTION 时转授返回 1370。

带 GRANT OPTION 后的 G1→G2→G3 链成功。管理员同时撤销 G1 的过程 EXECUTE 和
过程 GRANT OPTION 后：

- G1 最终只有 `USAGE ON *.*`；
- G2 仍拥有过程 EXECUTE WITH GRANT OPTION；
- G3 仍拥有过程 EXECUTE；
- G3 调用 query 过程返回 1094，调用 session 过程返回 1370。

因此过程级授权也不随上游撤权级联删除。

## 12. rds_superuser_role 转授权

实际结果：

- R1 只有角色、没有 ADMIN OPTION 时，向 R2 授予角色返回 1227；
- 管理员给 R1 `WITH ADMIN OPTION` 后，R1→R2（带 ADMIN OPTION）→R3 成功；
- R3 激活角色后调用过程返回 1094；
- 管理员撤销 R1 的角色后，R3 再次激活角色并调用，仍返回 1094。

角色下游授权同样没有级联撤销。测试结束时，R1/R2/R3 的角色授权已全部撤销，仅保留
测试账号。

## 13. 最终 AWS 权限状态

最终只读 `SHOW GRANTS` 已实际核对：

- 没有遗留任何 `cskaws_*` 全局 EXECUTE；
- 没有遗留任何 `cskaws_*` 的 `mysql.*` 数据库级 EXECUTE；
- `cskaws_dx` 保留两个 RDS 过程的过程级 EXECUTE；
- `cskaws_dr` 保留 `rds_superuser_role`；
- `cskaws_g1` 只有 USAGE；
- `cskaws_g2` 保留 `rds_kill_query` EXECUTE WITH GRANT OPTION；
- `cskaws_g3` 保留 `rds_kill_query` EXECUTE；
- R1/R2/R3 只有 USAGE；
- 测试账号、`cskaws_db` 和 `deep_lock_probe` 按要求保留。

## 14. 明确未动态执行的项目

以下项目没有在本次 AWS 实例上动态执行，因此本文不对其结果作结论：

1. 对复制、备份、监控等其他 AWS 内置线程发送任一种 KILL；
2. 实例重启、故障切换、补丁升级后的权限和过程持久性；
3. 8.0.35、8.0.36、8.4 等其他版本的对比；
4. 长用户名旧版本缺陷；
5. 高压连接 ID 回绕/复用；
6. 目标在身份检查与 KILL 之间执行 `CHANGE USER` 的竞态；
7. 审计插件、CloudWatch 或数据库审计日志是否记录这些操作。

### 14.1 已补充的 rdsadmin 动态 query 探针

在后续独立运行 `20261014T085351Z-reserved-dynamic` 中，实际选中线程 13：

```text
13  rdsadmin  localhost  Sleep
```

实际执行：

```sql
CALL mysql.rds_kill_query(13);
```

AWS 返回：

```text
ERROR 1644 (45000): CANNOT KILL RDSADMIN SESSION
```

调用后再次查询，线程 13 仍为 `rdsadmin@localhost / Sleep`。因此
`rds_kill_query` 对该真实保留会话的动态保护已经实测，不再只是过程定义观察。

### 14.2 已补充的 rdsadmin 动态 session 探针

获得明确授权后，在独立第二阶段运行
`20261014T085820Z-reserved-session-stage` 中重新核验同一目标：

```text
13  rdsadmin  localhost  Sleep
```

随后实际执行：

```sql
CALL mysql.rds_kill(13);
```

AWS 返回：

```text
ERROR 1644 (45000): CANNOT KILL RDSADMIN SESSION
```

调用后再次查询，同一线程 13 仍为 `rdsadmin@localhost / Sleep`。因此本实例上的
`rds_kill_query` 和 `rds_kill` 都已经对真实空闲 rdsadmin 保留会话完成动态验证，
两者均以 1644/45000 拒绝，目标未被终止。

复制、备份和监控线程没有动态调用。

