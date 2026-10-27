---
title: Neon Branch 服务化调研
aliases:
  - Neon Branch 调研索引
tags:
  - 数据库
  - Neon
  - Branch
  - 服务化
created: 2026-10-26
updated: 2026-10-27
---

# Neon Branch 服务化调研

本目录统一收录 Neon Cloud、Lakebase 和 Neon Local 的 Branch 能力验证、实现分析与服务化设计。三者研究的是同一套核心对象和能力，但产品管控层、接口与本地工具的职责边界不同，因此按环境保留独立报告。

## 01 Neon Cloud

- [[01-Neon Cloud/neon-cloud-branch-test|Neon Cloud Branch 阶段测试报告]]
- `neon-cloud-branch-test.docx`：便于独立分发的 Word 版本。
- `screenshots/`：报告引用的控制台、连接及验证截图。

## 02 Lakebase

- [[02-Lakebase/lakebase-branch-test|Lakebase Branch 测试报告（含全部截图）]]
- [[02-Lakebase/lakebase-neon-design|Lakebase Branch 能力总结与 Neon 服务化对接设计]]
- `screenshots/`：测试证据截图。

## 03 Neon Local

- [[03-Neon Local/neon-local-branch|Neon Branch 实现与本地部署调研]]
- [[03-Neon Local/neon-branch-architecture|Neon 完整分层与 Branch 管控能力]]
- [[03-Neon Local/neon-local-branch-3-audit-2026-10-27|Neon Local Branch 3 审计记录]]

## 04 Control Plane

- [[04-Control Plane/storage-controller-branch-api-curl|Storage Controller Branch API 与 curl 命令总表]]

## 阅读顺序

1. 先读 Neon Cloud 和 Lakebase 测试报告，确认服务化产品对外暴露的 Branch 能力。
2. 再读 Neon Local 实现与部署调研，理解 `tenant_id`、`timeline_id`、Compute endpoint 与本地管控的边界。
3. 阅读 Storage Controller API 命令总表，区分底层 Timeline 能力与产品管控能力。
4. 最后读 Lakebase 能力总结与对接设计，以及 Neon 完整分层文档，形成自建管控方案。
