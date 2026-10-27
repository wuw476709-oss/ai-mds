# AWS RDS MySQL 8.0.45 会话终止功能测试归档

## 归档范围

本目录归档 2026-10-14 在 AWS RDS for MySQL 8.0.45 实例 `database-1`
（`eu-north-1`，斯德哥尔摩）完成的会话终止功能测试。

归档内容包括：

- 测试大纲、边界补充和最终实测报告；
- 可重复执行的全部测试脚本；
- 初始核心测试、授权链补测和五批最终有效运行的原始 MySQL 回显；
- 每批结果的清单、错误索引和合并回显；
- 全归档文件校验清单。

管理员密码、测试用户明文密码和 AWS 凭据没有进入归档。

## 建议阅读顺序

1. [[docs/aws-rds-mysql-8.0.45-empirical-test-report|AWS RDS MySQL 8.0.45 最终实测报告]]
2. [[docs/aws-rds-mysql-session-kill-exploratory-test-plan|测试大纲与用例设计]]
3. [[docs/aws-rds-mysql-session-kill-boundary-addendum|保留账号与授权链边界补充]]
4. [[docs/初始核心测试报告|初始核心测试报告]]
5. [[docs/初始授权链与保留账号补测报告|初始授权链与保留账号补测报告]]

## 有效运行索引

| 阶段 | 结果目录 | 内容 |
|---|---|---|
| 初始核心测试 | `raw-results/20261014T070919Z-core` | 基础权限、QUERY/SESSION、初始参数与撤权 |
| 初始边界补测 | `raw-results/20261014T080200Z-grant-reserved-boundaries` | 全局 EXECUTE、GRANT OPTION、保留账号只读采集 |
| 完整授权作用域 | `raw-results/20261014T082933Z-grant-scope-matrix` | 全局、mysql.*、过程级授权与多级链 |
| 角色授权链 | `raw-results/20261014T084157Z-role-delegation` | ADMIN OPTION、多级角色转授、上游撤权 |
| 深度语义 | `raw-results/20261014T084300Z-deep-semantics` | 持久连接、self-kill、事务锁、目标矩阵、竞态、参数 |
| rdsadmin query 保护 | `raw-results/20261014T085351Z-reserved-query` | 对真实空闲 rdsadmin 执行 rds_kill_query |
| rdsadmin session 保护 | `raw-results/20261014T085820Z-reserved-session` | 对真实空闲 rdsadmin 执行 rds_kill |

每个结果目录中的 `raw-mysql/` 包含：

- `manifest.tsv`：证据文件大小和校验值；
- `mysql-output.log`：按文件边界合并的完整回显；
- `mysql-errors.tsv`：ERROR/WARNING 索引。

## 已实测的主要结论

- 普通用户只有相应 EXECUTE 或已激活 `rds_superuser_role` 才能调用过程；
- `PROCESS` 本身不提供调用能力；
- 已有连接上的 GRANT/REVOKE 会影响下一次调用；
- `rds_kill_query` 保留连接及现有事务锁；
- `rds_kill` 断开连接、回滚未提交事务并释放锁；
- 过程调用者能终止同账号、跨账号、PROCESS 用户、角色用户和管理员的测试会话；
- 原生 KILL 与 RDS 存储过程是不同权限路径；
- 全局、数据库级和过程级 EXECUTE 都遵循 GRANT OPTION；
- 上游撤权不会级联撤销已产生的下游授权；
- `rds_superuser_role WITH ADMIN OPTION` 可以多级转授，下游角色不随上游撤权级联删除；
- 对真实空闲 `rdsadmin@localhost` 调用两个过程均返回
  `1644 / 45000 / CANNOT KILL RDSADMIN SESSION`，目标保持存活。

## 明确未执行的项目

- 对复制、备份和监控等其他 AWS 内置线程发送 KILL；
- RDS 重启、Multi-AZ 故障切换和版本升级；
- 8.0.35、8.0.36、8.4 等跨版本对比；
- 连接 ID 高压回绕/复用；
- 目标在身份检查与 KILL 之间执行 CHANGE USER 的竞态；
- CloudWatch、审计插件和数据库审计日志验证。

这些项目没有被写成实测结论。

## 当前测试对象状态

测试结束后保留了测试数据库、测试账号以及指定的过程级权限，便于继续检查；没有
遗留全局 EXECUTE 或 `mysql.*` 数据库级 EXECUTE。角色转授权专用账号的角色权限已
撤销。详情以最终实测报告第 13 节和 AWS 实例当前状态为准。

## 完整性校验

仓库内的 `SHA256SUMS` 记录归档文件的 SHA-256。校验时在本目录执行：

```bash
shasum -a 256 -c SHA256SUMS
```
