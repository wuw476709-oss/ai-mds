# AWS RDS 全局 EXECUTE 授权链与保留账号补测报告

- 日期：2026-10-14
- 引擎：AWS RDS for MySQL 8.0.45
- 实例：database-1，eu-north-1
- 测试账号：`cskaws_ue`、`cskaws_u0`、`cskaws_same`

## 结论

1. `EXECUTE ON *.*` 允许普通用户调用 `mysql.rds_kill` 和
   `mysql.rds_kill_query`。
2. 只有全局 `EXECUTE`、没有 `GRANT OPTION` 的普通用户不能转授，返回
   `ERROR 1045 (28000)`。
3. 普通用户拥有 `EXECUTE ON *.* WITH GRANT OPTION` 后，可以向另一个普通用户
   授予全局 `EXECUTE`。
4. 如果把 `WITH GRANT OPTION` 也授给下游，下游可以继续向第三层普通用户授权。
5. 第三层普通用户获得全局 `EXECUTE` 后调用 `rds_kill_query(0)` 返回
   `ERROR 1094 Unknown thread id: 0`，而不是 `ERROR 1370`，证明调用已经通过
   EXECUTE 检查并进入过程。
6. AWS 没有阻止普通用户形成全局 EXECUTE 的多级授权链；链条是否继续完全由
   `GRANT OPTION` 决定。

## 授权链证据

| 步骤 | 操作 | 结果 |
|---|---|---|
| A1 | 管理员授予 UE `EXECUTE ON *.*` | 成功 |
| A2 | UE 调用 `rds_kill_query(0)` | `ERROR 1094`，已进入过程 |
| A3 | UE 向 U0 授予全局 EXECUTE | `ERROR 1045` |
| B1 | 管理员授予 UE 全局 EXECUTE WITH GRANT OPTION | 成功 |
| B2 | UE 向 U0 授予全局 EXECUTE | 成功 |
| B3 | U0 调用 `rds_kill_query(0)` | `ERROR 1094`，已进入过程 |
| B4 | U0 未获得 GRANT OPTION 时向 SAME 转授 | `ERROR 1045` |
| C1 | UE 向 U0 补授 WITH GRANT OPTION | 成功 |
| C2 | U0 向 SAME 授予全局 EXECUTE | 成功 |
| C3 | SAME 调用 `rds_kill_query(0)` | `ERROR 1094`，已进入过程 |
| D1 | 管理员单独给无过程级权限的 U0 授予全局 EXECUTE | 成功 |
| D2 | U0 分别调用 `rds_kill_query(0)`、`rds_kill(0)` | 均为 `ERROR 1094`，两个过程都已进入 |
| D3 | 管理员撤销 U0 的全局 EXECUTE | 成功，恢复基线 |

## 保留账号

实测 `mysql.rds_reserved_users`：

| user | host | 类型 |
|---|---|---|
| mysql.infoschema | localhost | MySQL 内置系统账号 |
| mysql.session | localhost | MySQL 内置系统账号 |
| mysql.sys | localhost | MySQL 内置系统账号 |
| rdsadmin | localhost | RDS 管理账号 |

当时 PROCESSLIST 中匹配到两个 `rdsadmin@localhost` Sleep 会话。为避免干扰 RDS
管理面，未对这些内部会话发送 KILL。两个过程的源码均证明：目标不是调用者自身且
命中保留账号时，抛出 `SQLSTATE 45000 / CANNOT KILL <USER> SESSION`。

## 测试后状态

- 本轮新增的全局 `EXECUTE` 已从 UE、U0、SAME 撤销。
- 本轮新增的全局 `GRANT OPTION` 已从 UE、U0 撤销。
- `cskaws_ue` 原有的过程级 `EXECUTE ON mysql.rds_kill` 仍保留。
- 测试库和测试用户均保留。
- 安全组保留 MYSQL/Aurora TCP/3306、来源 `124.70.231.10/32`。
