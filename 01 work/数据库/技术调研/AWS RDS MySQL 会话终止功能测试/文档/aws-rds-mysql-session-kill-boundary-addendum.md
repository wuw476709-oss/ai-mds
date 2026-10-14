# AWS RDS MySQL 会话终止功能边界补测

## 已由过程定义确认的保留账号保护

AWS RDS for MySQL 8.0.45 的 `mysql.rds_kill` 与
`mysql.rds_kill_query` 均为 `rdsadmin@localhost` 定义的过程。两者在执行
`KILL` 前采用相同的目标保护逻辑：

1. 根据传入线程 ID 从 `information_schema.processlist` 读取目标的 `USER`、
   `HOST`。
2. 以用户名查询 `mysql.rds_reserved_users`。
3. 先判断 `CONNECTION_ID() = thread`。如果目标就是当前调用连接，则跳过保留账号
   判断，但随后仍会执行 KILL。
4. 目标不是当前调用连接时，如果目标 host 与保留记录精确相等，或保留记录 host
   为 `%`，则抛出 `SQLSTATE '45000'`，消息为
   `CANNOT KILL <USER> SESSION`。
5. 未命中保护时，分别执行 `KILL thread` 或 `KILL QUERY thread`。

所以准确答案是：其他连接不能通过这两个过程终止命中
`mysql.rds_reserved_users` 的内置保留账号会话。该检查位于 Definer 过程内部，
因此 RDS 管理员、全局 `EXECUTE` 持有者或 `rds_superuser_role` 持有者都不能绕过。
但源码对“调用者终止自己的当前连接”留有例外：它会跳过保留检查并继续 KILL。
正常客户不能登录内置保留账号，因此该例外通常不可从客户侧触发。

需要注意，它不是单纯按“用户名在表中”判断，而是用户名加 host 规则。复刻时必须
明确是否完整复制这种匹配规则，还是使用更稳健的服务器内部账号标记。

## 为什么不直接终止 AWS 内部线程验证

直接对 `rdsadmin`、备份、复制、监控等内部线程发起终止可能干扰实例管理面，且没有
必要。过程定义已经给出确定的控制流。AWS 摸排阶段只应：

- 读取 `mysql.rds_reserved_users`；
- 将其与 `information_schema.processlist` 做只读关联；
- 保存两个过程的 `SHOW CREATE PROCEDURE`；
- 不对匹配到的真实内部线程调用终止过程。

如果必须进行动态负向验证，应在可丢弃的内部测试构建中注入一个假的保留账号，不应
在正式 RDS 实例上拿真实管理线程测试。

## 全局 EXECUTE 与转授权边界

必须把“可以使用权限”和“可以转授权限”分开测试：

| 授权状态 | 可以调用 RDS 过程 | 可以向第三人授予 EXECUTE |
|---|---:|---:|
| `EXECUTE ON *.*` | 实测是 | 实测否，`ERROR 1045` |
| `EXECUTE ON *.* WITH GRANT OPTION` | 实测是 | 实测是 |
| 过程级 `EXECUTE` | 仅对应过程 | 预期否 |
| 过程级 `EXECUTE ... WITH GRANT OPTION` | 仅对应过程 | 需要实测 |

补测脚本同时覆盖无 `GRANT OPTION` 和有 `GRANT OPTION` 两条路径，并在结束时只撤销
测试账号的全局 `EXECUTE`，不会删除已有测试库、用户或过程级授权。

2026-10-14 在 RDS MySQL 8.0.45 上进一步确认：普通用户可以把全局
`EXECUTE WITH GRANT OPTION` 连同授权能力继续传给另一个普通用户；得到
`GRANT OPTION` 的第二层普通用户还能向第三层账号转授。第三层只获得
`EXECUTE` 后能够进入 `rds_kill_query`，以不存在的线程 0 调用时返回
`ERROR 1094`，证明例程执行权限有效。没有 `GRANT OPTION` 的任何一层转授均返回
`ERROR 1045`。

实测保留表包含：`mysql.infoschema@localhost`、`mysql.session@localhost`、
`mysql.sys@localhost` 和 `rdsadmin@localhost`。采集时有两个
`rdsadmin@localhost` 的 Sleep 会话；只进行了只读关联，没有对其发送 KILL。

## 在开源 MySQL 8.0.45 复刻前应补齐的测试

### 1. 对象与安装生命周期

- 初始化、升级、重复升级后两个过程是否存在且定义一致。
- Definer 账号是否锁定、能否登录、能否被删除或重建。
- 普通管理员能否 `ALTER`、`DROP`、同名重建过程。
- 过程授权是否在升级、重启、主备切换后保留。
- binlog、复制及备库只读状态下调用过程的行为。

### 2. 授权与授权链

- 全局、库级、过程级 `EXECUTE` 分别能否调用两个过程。
- 三种作用域分别带或不带 `GRANT OPTION` 时能否继续转授。
- 转授者被撤权后，下游授权是否保留；MySQL 的 REVOKE 通常不级联，必须实测。
- 已在线连接在 GRANT、REVOKE、角色激活和角色撤销后的即时行为。
- 默认角色、未激活角色、嵌套角色和角色循环的影响。
- 账号使用不同 host 条目匹配登录时，以 `USER()` 还是 `CURRENT_USER()` 判权。

### 3. 保护目标矩阵

- 保留账号用户名 + 精确 host。
- 保留账号用户名 + `%` host。
- 同名但 host 不匹配的账号。
- 用户名大小写、host 大小写、IPv4、IPv6、DNS 名称及 `host:port` 表示。
- RDS 主用户、普通高权限用户、`SYSTEM_USER`、`CONNECTION_ADMIN`、复制账号。
- 未认证连接、后台 THD、复制线程、事件调度器、插件线程。
- 调用者自己的当前连接，以及同一认证账号的另一连接。
- 保留账号当前连接的 self-kill 分支与其他连接 kill 保留账号的分支顺序。
- 保护表不存在、表损坏、重复记录或读取失败时是否 fail closed。

开源实现不宜仅依赖可由 SQL 修改的普通表来保护核心线程；至少要保证该表及写权限
不可被能力持有者修改，或者直接使用服务端内部账号/线程分类。

### 4. 目标 ID 与竞态

- 不存在、已退出、刚退出的线程 ID。
- 查询自然结束与 `KILL QUERY` 同时发生。
- 连接退出与 `KILL CONNECTION` 同时发生。
- 两个调用者同时操作同一线程。
- 线程 ID 回绕或复用后不能误杀新连接。
- 读取目标身份后、执行 KILL 前目标发生 `CHANGE USER` 的竞态。

最后两项是复刻时最关键的 TOCTOU 边界：不能只查一次 PROCESSLIST 后凭裸线程 ID
继续执行，需要在持有正确生命周期引用的情况下重新核验目标身份。

### 5. QUERY 与 CONNECTION 语义

- 活跃长查询、空闲连接、锁等待、DDL、存储过程内部语句。
- 显式事务中 `KILL QUERY` 后连接和事务是否仍然有效。
- `KILL CONNECTION` 后未提交事务是否回滚、行锁/元数据锁是否释放。
- 准备语句、游标、大结果集发送阶段和客户端断流。
- 目标连接下一条语句的错误和恢复行为。

### 6. 参数与错误契约

- `NULL`、0、负数、小数、文本、科学计数法和溢出。
- 32 位边界、64 位边界以及不同 `sql_mode` 下的转换。
- 过程无 EXECUTE、线程不存在、目标受保护三类错误必须可区分。
- 两个过程对相同非法输入的错误码、SQLSTATE 和消息保持一致。
- 预处理协议与文本协议的行为一致。

### 7. 可见性、审计与安全

- 没有 `PROCESS`、看不到目标线程的用户，在知道 ID 时是否仍能终止。
- 错误消息是否泄露保留账号名称、线程存在性或其他租户信息。
- 成功、拒绝、线程不存在、竞态失败是否形成审计记录。
- 审计记录包含调用者认证身份、目标 ID、动作类型、结果和时间，但不泄漏 SQL 正文。
- 高频调用、并发调用、审计写入失败及磁盘满时的 fail-open/fail-closed 行为。

### 8. 与原生 KILL 的隔离

- 新过程不能扩大调用者执行原生 `KILL` 的权限。
- 直接 `KILL`、`mysqladmin kill`、协议层 COM_PROCESS_KILL 与新过程分别测试。
- 保护规则只作用于新过程还是也作用于原生管理员 KILL，需要在需求中明确。
- 撤销过程 `EXECUTE` 后，原生权限不应被改变。

## 推荐的复刻判定基线

在开始编码前至少要锁定以下产品决策：

1. 是精确复制 AWS 的保留表 + host 匹配，还是保护所有内部账号和内部线程。
2. 是允许普通用户获得 `WITH GRANT OPTION` 后继续转授，还是只允许指定管理员授权。
3. RDS 主用户和高权限普通账号是否也是可终止目标。
4. 是否允许终止当前调用连接；AWS 明确先跳过自身线程的保留检查，最终仍执行 KILL。
5. 保护表读取失败时必须拒绝操作，不能跳过保护继续执行。
6. `KILL QUERY` 保留事务、`KILL CONNECTION` 回滚事务的语义是否完全沿用 MySQL。

