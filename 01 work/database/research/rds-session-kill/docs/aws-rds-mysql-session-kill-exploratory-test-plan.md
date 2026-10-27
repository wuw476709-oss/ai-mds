# AWS RDS for MySQL 会话终止能力摸排测试大纲

## 1. 测试目的

通过黑盒测试确认 AWS RDS for MySQL 中 `mysql.rds_kill` 和
`mysql.rds_kill_query` 的真实授权模型、目标保护范围和运行语义，为
`CONTROLLED_SESSION_KILL` 的权限和过程设计提供对照依据。

本测试需要回答：

1. 是否只有创建实例时指定的主用户能够调用两个过程。
2. 判断依据是“主用户身份”、`rds_superuser_role`、`EXECUTE`、`PROCESS`
   等普通权限，还是过程内部的私有授权规则。
3. 主用户能否将调用能力直接或间接授予普通用户。
4. 获得调用能力的账号能够终止哪些账号和哪类线程。
5. `rds_kill`、`rds_kill_query` 与原生 `KILL CONNECTION`、
   `KILL QUERY` 的语义和限制有何差异。
6. 授权、撤权、角色激活和在线权限变化何时生效。
7. 全局、库级、过程级 EXECUTE 是否可以继续转授，以及 `GRANT OPTION` 的边界。
8. `mysql.rds_reserved_users` 如何保护 AWS 内置账号和内部线程。

## 2. 官方文档基线与待验证假设

AWS 的 RDS for MySQL 存储过程参考明确说明这些系统过程必须由主用户执行，
但单独的会话终止页面没有展开权限判断细节。RDS for MySQL 8.0.36 及以上
还引入了可授予其他账号的 `rds_superuser_role`，该角色包含全局 `EXECUTE`
和 `PROCESS`。因此不能仅凭文档断言实现一定硬编码了主用户名。

需要对照验证以下假设：

| 编号 | 假设 | 判定方法 |
|---|---|---|
| H1 | 只识别实例主用户 Auth ID | 主用户成功；拥有相同权限或角色的非主用户仍失败 |
| H2 | 识别 `rds_superuser_role` | 非主用户获得并激活该角色后成功 |
| H3 | 只依赖过程 `EXECUTE` | 普通用户被单独授予过程 EXECUTE 后成功 |
| H4 | 依赖全局管理权限组合 | 克隆主用户可授予权限后成功，但单独 EXECUTE 失败 |
| H5 | 过程可调用，但内部按目标账号再次鉴权 | 不同目标类型产生不同允许/拒绝结果 |
| H6 | 保留账号由 `mysql.rds_reserved_users` 保护 | 对照过程定义、保留表和 PROCESSLIST；不终止真实内部线程 |

文档参考：

- <https://docs.aws.amazon.com/zh_cn/AmazonRDS/latest/UserGuide/Appendix.MySQL.CommonDBATasks.End.html>
- <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.MySQL.SQLRef.html>
- <https://docs.aws.amazon.com/zh_cn/AmazonRDS/latest/UserGuide/Appendix.MySQL.CommonDBATasks.privilege-model.html>
- <https://docs.aws.amazon.com/zh_cn/AmazonRDS/latest/UserGuide/MySQL.KnownIssuesAndLimitations.html>

## 3. 测试环境与安全约束

### 3.1 环境

- 使用独立、可丢弃的 RDS for MySQL 测试实例，禁止在生产实例执行。
- 首选与目标产品一致的精确小版本；至少记录 8.0.x 或 8.4.x。
- 如需比较版本差异，分别准备 8.0.35 及以下、8.0.36 及以上、8.4 实例。
- 测试实例不承载业务、不作为复制源或复制目标。
- 每项测试至少建立一个独立控制连接，防止被测连接断开后丢失证据。

### 3.2 禁止项

- 不终止 `rdsadmin`、`rdsrepladmin`、复制、备份、监控或其他 AWS 内部线程。
- 不根据模糊的 PROCESSLIST 信息猜测系统线程身份。
- 不在有真实业务或未提交业务事务的连接上测试。
- 测试用账号、角色、会话和数据必须具有统一前缀，例如 `csk_aws_`。

## 4. 测试账号和连接模型

| 标识 | 身份 | 预期用途 |
|---|---|---|
| M | 实例主用户 | 基线调用者、授权管理员、控制连接 |
| U0 | 无额外权限普通用户 | 权限拒绝基线 |
| UE | 仅被授予过程 EXECUTE 的普通用户 | 判断是否可单独委派过程调用能力 |
| UP | 仅具有 PROCESS 的普通用户 | 分离线程可见性与终止能力 |
| UR | 获得 `rds_superuser_role` 的非主用户 | 判断是否按角色或按主用户身份鉴权 |
| UA | 尽可能复制主用户普通授权的非主用户 | 判断是否依赖一组可授予权限 |
| T1/T2 | 两个不同普通账号 | 跨账号目标测试 |
| TS1/TS2 | 同一普通账号的两个连接 | 同账号其他连接测试 |

每种身份都要保留独立连接，并记录：

```sql
SELECT VERSION(), @@version_comment, @@hostname;
SELECT USER(), CURRENT_USER(), CURRENT_ROLE(), CONNECTION_ID();
SHOW GRANTS;
```

## 5. 第一阶段：对象和权限元数据摸排

### META-1 过程元数据

由 M 执行：

```sql
SELECT ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE, DEFINER,
       SECURITY_TYPE, SQL_DATA_ACCESS, ROUTINE_COMMENT
  FROM information_schema.routines
 WHERE ROUTINE_SCHEMA = 'mysql'
   AND ROUTINE_NAME IN ('rds_kill', 'rds_kill_query')
 ORDER BY ROUTINE_NAME;

SHOW CREATE PROCEDURE mysql.rds_kill;
SHOW CREATE PROCEDURE mysql.rds_kill_query;
```

记录是否允许查看定义、Definer 和 `SQL SECURITY` 类型。看不到过程体也是有效结果，
不能据此判定过程不存在。

### META-2 初始授权

```sql
SHOW GRANTS;
SHOW GRANTS FOR rds_superuser_role@'%';

SELECT USER, HOST, DB, ROUTINE_NAME, ROUTINE_TYPE, GRANTOR, PROC_PRIV
  FROM mysql.procs_priv
 WHERE DB = 'mysql'
   AND ROUTINE_NAME IN ('rds_kill', 'rds_kill_query');
```

若查询系统授权表被拒绝，记录错误，不尝试直接修改 `mysql.*` 表。

### META-3 原生 KILL 基线

分别由 M、U0、UR 测试对自己创建的可丢弃连接执行：

```sql
KILL QUERY <test_thread_id>;
KILL CONNECTION <test_thread_id>;
```

目标是确认 AWS 所称“标准 KILL 被限制”的具体表现，并与 RDS 过程分开记录。

### META-4 保留账号保护元数据

```sql
SELECT * FROM mysql.rds_reserved_users ORDER BY user, host;

SELECT p.ID, p.USER, p.HOST, p.COMMAND, p.STATE,
       r.user AS reserved_user, r.host AS reserved_host
  FROM information_schema.processlist AS p
  JOIN mysql.rds_reserved_users AS r
    ON r.user = p.USER
   AND (r.host = '%' OR r.host = p.HOST)
 ORDER BY p.ID;
```

本项只读。不得拿查询出的 AWS 内部线程 ID 调用终止过程。动态负向验证应放在可注入
假保留账号的内部测试构建中完成。还要单独记录过程的判断顺序：AWS 对
`CONNECTION_ID() = thread` 先行放过保留检查，随后仍执行 KILL；因此外部终止保留
账号和保留账号 self-kill 是两个不同分支。

## 6. 第二阶段：谁能够调用过程

所有失败必须记录 SQLSTATE、MySQL errno 和完整错误消息，不能只记录成功/失败。

| 用例 | 调用者状态 | 操作 | 预期/观察重点 |
|---|---|---|---|
| AUTH-1 | M | 调用两个过程终止测试目标 | 官方基线应成功 |
| AUTH-2 | U0 | 调用两个过程 | 判断普通用户是缺 EXECUTE，还是进入过程后被内部拒绝 |
| AUTH-3 | UP，仅 PROCESS | 调用两个过程 | 判断 PROCESS 是否仅控制可见性 |
| AUTH-4 | UE，仅单过程 EXECUTE | 分别调用两个过程 | 判断能力能否按过程拆分授权 |
| AUTH-5 | UE，两个过程 EXECUTE | 调用两个过程 | 判断单独 EXECUTE 是否足够 |
| AUTH-6 | UR，角色未激活 | 调用两个过程 | 验证默认角色状态影响 |
| AUTH-7 | UR，`SET ROLE rds_superuser_role` | 调用两个过程 | 区分主用户身份和角色授权 |
| AUTH-8 | UA，复制可授予的主用户权限 | 调用两个过程 | 区分身份硬编码和权限集合 |
| AUTH-9 | U0，仅知道目标 ID、看不到完整 PROCESSLIST | 调用过程 | 分离“发现线程 ID”和“终止线程”权限 |
| AUTH-10 | UE，全局 EXECUTE，无 GRANT OPTION | 向 U0 授予全局 EXECUTE | 验证使用权不等于转授权权 |
| AUTH-11 | UE，全局 EXECUTE，带 GRANT OPTION | 向 U0 授予全局 EXECUTE | 判断 AWS 是否增加额外禁止转授策略 |
| AUTH-12 | U0，由 UE 转授但无 GRANT OPTION | 再向第三人转授 | 验证授权链在无 GRANT OPTION 处终止 |

授权操作也要作为测试结果：

```sql
GRANT EXECUTE ON PROCEDURE mysql.rds_kill TO 'csk_aws_ue'@'%';
GRANT EXECUTE ON PROCEDURE mysql.rds_kill_query TO 'csk_aws_ue'@'%';
GRANT rds_superuser_role@'%' TO 'csk_aws_ur'@'%';
```

如果 GRANT 本身被 AWS 拒绝，记录该限制，不用其他方式绕过。

## 7. 第三阶段：能够终止哪些目标

本阶段只使用 AUTH 阶段已确认能够调用过程的身份。每个目标分别测试
`rds_kill_query` 和 `rds_kill`。

| 用例 | 目标 | `rds_kill_query` 观察点 | `rds_kill` 观察点 |
|---|---|---|---|
| SCOPE-1 | 调用者当前连接 | 是否拒绝或仅终止当前语句 | 是否允许自断开 |
| SCOPE-2 | 调用者同账号的另一连接 | 查询被打断且连接保留 | 连接断开 |
| SCOPE-3 | 另一普通账号连接 | 是否允许跨账号 | 是否允许跨账号 |
| SCOPE-4 | 主用户的测试连接 | 是否受保护 | 是否受保护 |
| SCOPE-5 | 非主 `rds_superuser_role` 持有者 | 是否按高权限目标保护 | 是否按高权限目标保护 |
| SCOPE-6 | 仅 PROCESS 或 EXECUTE 用户 | 是否与普通用户相同 | 是否与普通用户相同 |
| SCOPE-7 | 不存在或已经结束的线程 ID | 错误码及信息 | 错误码及信息 |

对于 AWS 内部账号和系统线程只做以下只读摸排：

```sql
SHOW FULL PROCESSLIST;
SELECT ID, USER, HOST, COMMAND, STATE
  FROM information_schema.processlist
 ORDER BY ID;
```

记录调用者是否可见这些线程，不实际执行终止操作。

## 8. 第四阶段：KILL 与 KILL QUERY 运行语义

### SEM-1 活跃长查询

目标连接执行：

```sql
SELECT SLEEP(60);
```

调用者执行：

```sql
CALL mysql.rds_kill_query(<target_id>);
```

验证原查询报错、目标连接仍可执行 `SELECT 1`。随后以新一轮连接验证
`rds_kill` 会使连接完全断开。

### SEM-2 空闲连接

对 `Sleep` 状态目标调用 `rds_kill_query`，观察返回结果并验证目标下一条语句
是否仍可执行；再测试 `rds_kill`。

### SEM-3 事务中的查询

目标连接：

```sql
START TRANSACTION;
INSERT INTO csk_aws_test.t VALUES (...);
SELECT SLEEP(60);
```

调用 `rds_kill_query` 后检查：

```sql
SELECT @@session.in_transaction;
ROLLBACK;
```

确认只终止当前语句还是同时回滚事务。随后单独测试 `rds_kill`，由控制连接
验证未提交修改已回滚、行锁已释放。

### SEM-4 锁等待

构造两个测试连接之间的行锁等待，分别终止等待语句和等待连接，检查：

- 等待方错误码；
- 持锁方是否完全不受影响；
- `rds_kill_query` 后等待方连接和事务是否仍存在；
- `rds_kill` 后锁和未提交事务是否清理。

### SEM-5 并发和竞态

- 目标查询自然结束与 `rds_kill_query` 同时发生。
- 目标连接自然断开与 `rds_kill` 同时发生。
- 两个调用者同时终止同一个目标。
- 线程结束后快速建立新连接，观察是否存在 ID 复用误终止。

重点是不崩溃、不误终止新连接；允许其中一个调用返回“线程不存在”。

## 9. 第五阶段：参数和调用形式

两个过程都执行以下矩阵：

| 输入 | 示例 |
|---|---|
| NULL | `CALL mysql.rds_kill(NULL)` |
| 0、负数 | `0`, `-1` |
| 小数 | `1.5` |
| 数字字符串 | `'123'` |
| 带空白字符串 | `' 123'`, `'123 '` |
| 科学计数法 | `'1e3'` |
| 非数字字符串 | `'abc'` |
| 边界和溢出 | `4294967295`, `4294967296` |
| 表达式 | `CONNECTION_ID()`, `@id + 0` |
| 预处理参数 | `PREPARE` + `EXECUTE ... USING @id` |

记录参数是在过程调用前被 MySQL 隐式转换，还是由过程显式拒绝。

## 10. 第六阶段：授权生命周期

| 用例 | 步骤 | 观察点 |
|---|---|---|
| LIFE-1 | 在线连接后 GRANT EXECUTE | 当前连接下一条调用是否立即生效 |
| LIFE-2 | 在线连接后 REVOKE EXECUTE | 下一条调用是否立即失败 |
| LIFE-3 | 在线连接后授予并激活角色 | 激活前后差异 |
| LIFE-4 | 在线连接后撤销角色 | 当前已激活角色是否立即失效或需重连 |
| LIFE-5 | 新连接复测 | 排除会话权限缓存影响 |
| LIFE-6 | UE 尝试向第三人转授 EXECUTE | 是否需要 GRANT OPTION，能否形成授权链 |
| LIFE-7 | UR 尝试转授 `rds_superuser_role` | AWS 是否限制角色的再授权 |

## 11. 版本差异专项

至少记录并比较：

- 精确引擎版本和创建/升级路径；
- 8.0.36 前后是否存在 `rds_superuser_role`；
- 8.4 与 8.0 的主用户授权差异；
- 老版本中长度超过 16 字符的用户名作为目标时的已知限制；
- 升级前后过程元数据、授权和行为是否变化。

长用户名限制只需在 AWS 文档标明受影响的版本测试：创建 17 字符以上用户名，
对其普通测试连接分别调用两个过程，确认是否复现已知限制。

## 12. 结果记录模板

每条用例记录：

| 字段 | 内容 |
|---|---|
| Case ID | 如 AUTH-4 |
| RDS engine/version | 精确小版本 |
| Caller | `USER()`、`CURRENT_USER()`、`CURRENT_ROLE()` |
| Caller grants | `SHOW GRANTS` 输出 |
| Target | 用户、线程 ID、线程状态、是否同账号 |
| Operation | 完整 SQL |
| Result | 成功/失败 |
| Error | SQLSTATE、errno、完整消息 |
| Target aftermath | 查询、连接、事务和锁状态 |
| Cleanup | 是否完成 |

## 13. 判定标准

最终结论必须分别陈述：

1. **调用资格**：只有主用户、角色持有者、过程 EXECUTE 持有者，还是其他组合。
2. **委派能力**：主用户能否把该能力授予普通用户，接受者能否继续转授。
3. **目标范围**：同账号、跨账号、主用户和高权限账号分别是否可终止。
4. **动作语义**：QUERY 是否保留连接和事务，SESSION 是否可靠断开并回滚。
5. **可见性与执行权分离**：不知道或看不到线程不等于没有终止权限，反之亦然。
6. **版本边界**：结论适用的 RDS MySQL 精确版本，不外推到 Aurora MySQL。

只有当“非主用户即使获得单独 EXECUTE、PROCESS、可授予的主用户权限以及
`rds_superuser_role` 后仍全部失败”时，才能较有把握地得出 AWS 对主用户身份
做了不可委派的专门限制。

## 14. 本次实际执行状态

2026-10-14 已在 `database-1`（eu-north-1，RDS MySQL 8.0.45）执行自动化补测。
实测报告见 `aws-rds-mysql-8.0.45-empirical-test-report.md`，原始回显分别位于：

- `results/20261014T084300Z-deep-semantics/`
- `results/20261014T082933Z-grant-scope-matrix/`
- `results/20261014T084157Z-role-delegation/`

报告中的“实测”仅来自上述原始 MySQL 回显。对 AWS 内置线程的动态终止、重启、
故障切换、升级、跨版本、线程 ID 高压复用和 CHANGE USER 竞态仍标记为未执行。

补充运行 `results/20261014T085351Z-reserved-dynamic/` 已对真实、空闲且精确匹配
保留表的 `rdsadmin@localhost` 线程执行 `rds_kill_query`，AWS 返回 1644/45000
`CANNOT KILL RDSADMIN SESSION`，调用后目标仍存在。

获得明确授权后，`results/20261014T085820Z-reserved-session-stage/` 又对同一类目标
实际执行 `rds_kill`；AWS 同样返回 1644/45000，调用后目标仍存在。复制、备份和
监控线程未执行动态调用。
