# AWS RDS for MySQL 会话终止权限测试报告

## 1. 测试结论

本次在 AWS RDS for MySQL 8.0.45 上完成了 `mysql.rds_kill` 与
`mysql.rds_kill_query` 的权限、作用范围、语义和授权生命周期测试。

核心结论如下：

1. RDS 管理员账号可以调用两个存储过程。
2. 普通用户默认不能调用，单独拥有 `PROCESS` 也不能调用。
3. 管理员可以把指定存储过程的 `EXECUTE` 权限直接授予普通用户；获得权限后，
   普通用户可以终止其他账号的查询或连接。
4. `rds_superuser_role` 也能提供调用能力，但角色必须在当前会话中激活；
   `SET ROLE NONE` 后调用失败，`SET ROLE ALL` 后调用成功。
5. `rds_kill_query` 只终止当前语句，连接继续可用；`rds_kill` 终止整个连接。
6. 撤销存储过程 `EXECUTE` 权限或撤销角色后，新建立连接的下一次调用失败；原始脚本
   每次调用都会重新连接，因此“已有连接无需重新登录即生效”仍需持久连接补测。
7. 实测允许终止同一账号的其他连接，也允许跨账号终止目标查询或连接。

这说明 AWS 的核心模型是“`SQL SECURITY DEFINER` 存储过程 + 可授予的
`EXECUTE` 权限”，而不是在存储过程内部检查调用者是不是管理员。对本项目的设计，
可以采用相同的能力入口，但如果需求规定“只有 root 可对外授权”，仍需在 MySQL
权限授予路径中额外限制谁能授予该能力，不能仅依赖普通的 `EXECUTE ... WITH GRANT
OPTION` 语义。

## 2. 测试环境

| 项目 | 实测值 |
|---|---|
| 产品 | AWS RDS for MySQL |
| 区域 | eu-north-1（斯德哥尔摩） |
| MySQL 版本 | 8.0.45 Source distribution |
| 实例 | database-1 |
| 管理员账号 | admin@% |
| 管理员角色 | rds_superuser_role@% |
| 执行时间 | 2026-10-14 |
| 结果编号 | 20261014T070919Z |

报告和原始日志中未保存管理员密码。

## 3. 权限矩阵

| 调用者状态 | `rds_kill_query` | `rds_kill` | 结论 |
|---|---:|---:|---|
| RDS 管理员 | 成功 | 成功 | 具备调用能力 |
| 普通用户 | 拒绝 | 未单独重复 | `ERROR 1370`，无 `EXECUTE` |
| 普通用户 + `PROCESS` | 拒绝 | 未单独重复 | `PROCESS` 不是调用凭据 |
| 普通用户 + 对应过程 `EXECUTE` | 成功 | 成功 | 可操作其他用户会话 |
| 已授予 `rds_superuser_role`，但 `SET ROLE NONE` | 拒绝 | 未单独重复 | 未激活角色不生效 |
| 已授予 `rds_superuser_role`，且 `SET ROLE ALL` | 成功 | 未单独重复 | 激活角色后生效 |
| `REVOKE EXECUTE` 后的新连接 | 拒绝 | 未撤销，仍保留 | 已证明新连接生效；已有连接待补测 |
| `REVOKE rds_superuser_role` 后的新连接 | 拒绝 | 未单独重复 | 已证明新连接生效；已有连接待补测 |

## 4. 两个接口的行为差异

### `mysql.rds_kill_query(thread_id)`

- 实际执行 `KILL QUERY thread_id`。
- 正在执行的语句被中断。
- 目标客户端连接仍然存在，可继续提交下一条语句。

### `mysql.rds_kill(thread_id)`

- 实际执行 `KILL thread_id`。
- 目标客户端连接被断开。
- 目标客户端后续操作失败，需要重新连接。

因此，产品接口应同时保留“终止查询”和“终止会话”两种能力，不能用一个接口模糊
替代另一个接口。

## 5. AWS 存储过程实现观察

两个过程的定义者均为 `rdsadmin@localhost`，过程体在执行前查询目标线程账号，检查
目标是否属于 `mysql.rds_reserved_users`；目标不是当前调用连接且命中保留账号时
拒绝，其他情况下最终分别执行 `KILL QUERY` 或 `KILL`。由于当前连接判断位于保留
账号判断之前，过程源码存在“保留账号调用过程终止自身时跳过保留检查”的例外；
正常客户无法登录这些内置账号，因此本次没有动态触发该分支。

过程体没有检查调用者是否为管理员。调用权限由 MySQL 的例程 `EXECUTE` 权限或已
激活的 `rds_superuser_role` 决定。这一点解释了为什么普通账号在获得过程级
`EXECUTE` 后，也能终止其他账号的会话。

## 6. 参数行为

`thread` 参数类型为 `BIGINT`，实测输入被转换后再传给 `KILL QUERY`：

| 输入 | 实际报错中的线程号 |
|---|---:|
| `NULL` | 0 |
| `0` | 0 |
| `-1` | 4294967295 |
| `1.5` | 2 |
| 文本 | 0 |
| `4294967296` | 0 |

以上均因目标不存在返回 `ERROR 1094 Unknown thread id`。本项目若希望错误更稳定、
更易理解，可以在过程入口显式校验非空、正整数和范围，而不是完全复刻 AWS 的隐式
转换结果。

## 7. 保留对象与当前安全状态

按要求未执行清理，以下对象仍保留在实例中：

- 测试库：`cskaws_db`
- 测试用户：`cskaws_same`、`cskaws_t1`、`cskaws_u0`、`cskaws_ue`、
  `cskaws_up`、`cskaws_ur`

最终权限状态需要特别注意：

- `cskaws_ue` 的 `mysql.rds_kill_query` 权限已被撤销，但仍保留
  `mysql.rds_kill` 的 `EXECUTE` 权限。
- `cskaws_ur` 的 `rds_superuser_role` 已被撤销。
- 测试结束时没有遗留的 `cskaws_*` 活跃连接。
- 按后续测试要求，安全组当前保留公网 TCP/3306 单 IP 入站规则：
  `124.70.231.10/32`。测试完成后应由账号所有者决定何时撤销。

## 8. 结果解释限制

1. 自动报告中，拒绝调用用例的 `Target alive = no` 是测试框架随后终止本地目标进程
   产生的清理结果，不代表未授权调用成功杀死了目标。权限判断应以调用返回码和
   `ERROR 1370` 为准。
2. 原始用例名 `SCOPE_2B_SAME_SESSION` 实际覆盖的是“同一管理员账号的另一条连接”，
   不是让一条连接调用过程杀死自身。此次可以确认同账号其他连接允许被终止；真正的
   self-kill 仍应单列用例。
3. 本报告确认的是当前实例和当前 RDS MySQL 8.0.45 的实测行为。AWS 后续升级过程定义
   或权限模型时，应重新执行回归测试。

## 9. 对本项目设计的建议

建议保留以下分层：

- 两个独立存储过程：一个对应 `KILL CONNECTION`，一个对应 `KILL QUERY`。
- 一个专用动态权限控制普通用户是否可以调用这些受控过程。
- 所有 root 账号可授予/撤销该专用权限；非 root 即使拥有该权限，也只能使用能力，
  不能继续转授。
- 过程内部保留目标线程存在性、保留系统账号、同账号其他连接和审计信息等检查。
- `REVOKE` 应对下一次调用立即生效并覆盖已有连接；这是本项目要求，AWS 已有连接的
  行为需由持久连接脚本另行实测，不能从原始新连接用例推导。

AWS 证明了“过程级能力入口”可以保持实现简单；本项目额外的授权者限制是产品需求，
应集中放在权限授予层实现，避免把 root 判定、调用者能力、目标范围和 KILL 执行逻辑
散落到多个代码路径。

## 10. 2026-10-14 补充授权链测试

补测确认 AWS 沿用 MySQL 的 `GRANT OPTION` 授权链语义：

| 场景 | 实测结果 |
|---|---|
| 管理员给普通用户 `EXECUTE ON *.*` | 普通用户可调用两个 RDS 过程 |
| 上述普通用户转授全局 EXECUTE | 失败，`ERROR 1045` |
| 管理员给普通用户 `EXECUTE ON *.* WITH GRANT OPTION` | 授权成功 |
| 该普通用户向第二个普通用户授予全局 EXECUTE | 成功 |
| 第二个普通用户未获得 GRANT OPTION 时继续转授 | 失败，`ERROR 1045` |
| 上游把 GRANT OPTION 一并授给第二层用户 | 成功 |
| 第二层用户继续向第三层授予全局 EXECUTE | 成功 |
| 第三层用户调用 `rds_kill_query(0)` | 到达过程并返回 `ERROR 1094 Unknown thread id` |
| 无过程级权限的 U0 仅获全局 EXECUTE 后分别调用两个过程 | 两者均返回 `ERROR 1094`，证明全局授权覆盖二者 |

结论：全局 `EXECUTE` 本身只有使用权；能否转授完全取决于相同作用域上的
`GRANT OPTION`。AWS 没有额外禁止普通用户形成多级授权链。

本轮新增的全局 `EXECUTE` 和 `GRANT OPTION` 已全部撤销，未删除测试库或测试用户。
为继续测试保留了安全组规则：MYSQL/Aurora TCP/3306，仅允许
`124.70.231.10/32`。

## 11. 保留账号只读补测

`mysql.rds_reserved_users` 实测包含：

- `mysql.infoschema@localhost`
- `mysql.session@localhost`
- `mysql.sys@localhost`
- `rdsadmin@localhost`

采集时 PROCESSLIST 中存在两个匹配的 `rdsadmin@localhost` Sleep 会话。基于安全
约束没有对这些 AWS 管理线程执行动态 KILL；保护行为由两个过程的完整定义确认。
