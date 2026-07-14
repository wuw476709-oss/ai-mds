---
title: 云数据库厂商 AI 查询优化器进展调研
aliases:
  - AI 查询优化器友商调研
  - 数据库 AI 优化器竞品分析
tags:
  - 数据库
  - 友商调研
  - AI4DB
  - 查询优化器
  - 云数据库
created: 2026-07-14
updated: 2026-07-14
status: completed
---

# 云数据库厂商 AI 查询优化器进展调研

**调研日期：2026-07-14**  
**调研范围：阿里云、腾讯云、火山引擎（字节跳动），补充华为云及其他国内数据库厂商**  
**主题口径：AI for DB 中与 SQL 查询优化直接相关的能力，包括基数/代价估计、计划搜索与选择、执行反馈、自适应优化，以及外围的 SQL 诊断、索引推荐和运维 Agent。**

> 说明：厂商常把向量检索、NL2SQL、智能问数、慢 SQL 诊断统称为“数据库 AI”。本报告将“AI 进入优化器内核决策链路”与“AI 在优化器外围提供建议”分开，避免将不同成熟度的能力直接类比。

## 一、结论摘要

截至 2026 年 7 月，国内云数据库厂商在 AI 查询优化上的竞争已经从“智能诊断/索引推荐”进入“学习模型参与执行计划决策”的早期产品化阶段，但各家侧重点明显不同。

1. **腾讯云的公开产品化最直接。** TDSQL-C MySQL 版已经推出名为“AI 优化器”的正式控制台能力：以 SQL 模板为单位收集执行反馈、持续训练和探索候选计划，并自动绑定更优计划。它已经可以在新购和存量实例上开启，但截至调研日仍处于**白名单灰度**，属于早期商用验证阶段，而非全面 GA。
2. **阿里云形成了“成熟自治服务 + 新一代 Learned Optimizer 研发”的双层路线。** DAS 自动 SQL 优化已多年商用，具备异常发现、索引/改写建议、灰度变更、收益跟踪和回滚闭环；PolarDB MySQL 也已提供自适应执行计划能力。更值得关注的是 2026 年披露的 MaxCompute **LOAM**：它用学习型代价模型对原生优化器产生的候选计划进行选择，已在内部大规模环境完成 flighting 评估，但尚未发现面向公有云客户独立开放的产品入口。
3. **火山引擎在 OLAP 内核研究上最深入、公开技术链条最完整。** ByteHouse 已商用自研 RBO/CBO 优化器和运维 Agent；研发侧先后公开 ByteCard 学习型基数估计、HBO（历史反馈优化）、学习型谓词下推和 Join build/probe 侧选择。2026 年论文显示 AI 模型已经进入 ByteHouse 的计划决策链路并在生产轨迹上验证，但公有云文档仍主要宣传传统优化器与智能诊断，AI 内核能力没有形成独立、可配置的公开产品项。
4. **华为云是不可忽视的对标对象。** GaussDB 已公开交付 ABO（AI-Based Optimizer），包括智能基数估计、多计划缓存及自适应选择；其产品公告比多数厂商更明确地写出了能力边界和典型场景收益。华为同时持续推进自动查询改写与优化器搜索框架研究。
5. **当前行业共识不是用 AI 完全替换 CBO，而是“增强和护航原生优化器”。** 主流落地形态都是：原生优化器负责语义正确性与候选计划生成，学习模型负责估计、排序或局部决策，再用 plan binding、多版本计划、灰度和回退机制控制尾部风险。

### 综合成熟度判断

| 厂商/产品 | AI 进入内核计划决策 | 外围诊断/自治 | 当前公开状态 | 本报告判断 |
|---|---:|---:|---|---|
| 腾讯云 TDSQL-C MySQL AI 优化器 | 高：计划探索、选择、绑定 | 有 DBbrain/DatabaseClaw | 白名单灰度，可在控制台开启 | **最明确的 MySQL 商用品形态，但仍需验证稳定性与收益覆盖率** |
| 阿里云 DAS + PolarDB | 中：自适应计划；DAS 主要在内核外围 | 很强，闭环成熟 | DAS/自适应优化已商用 | **生产闭环最成熟，不能等同于端到端 Learned Optimizer** |
| 阿里 MaxCompute LOAM | 高：学习型代价预测和候选计划选择 | 不适用 | 内部 flighting/论文披露，未见公有云开关 | **研发领先，商业开放状态待确认** |
| 火山 ByteHouse | 高：学习型基数估计、HBO、局部计划选择 | 已有运维 Agent | 部分商用、部分论文/内部生产验证 | **OLAP AI 优化技术储备深，公开产品包装滞后于研发披露** |
| 华为云 GaussDB ABO | 高：智能基数估计、多计划自适应选择 | 有智能诊断/助手 | 产品版本公告明确列出 | **已交付的内核 AI 优化能力，值得重点实测** |
| OceanBase / TiDB | 未发现同等公开证据 | 重点在 AI SQL、向量、Agent/RAG | 多数能力已商用或 Beta | **当前公开重点是 DB for AI，不宜宣称已有 Learned Query Optimizer** |

## 二、判断框架：什么才算“AI 优化器”

本报告将能力分为四层：

| 层级 | 典型能力 | 是否属于优化器内核 AI | 风险/价值 |
|---|---|---:|---|
| L1：智能运维与建议 | 慢 SQL 归因、SQL 改写、索引推荐、自然语言问诊 | 否，通常在内核外 | 易产品化；依赖建议质量，自动执行需强安全控制 |
| L2：反馈与自治闭环 | 基于历史 workload 发现退化，自动创建/删除索引，验证收益并回滚 | 部分 | 对生产价值高，但核心计划选择仍可能是传统 CBO |
| L3：学习增强型优化器 | Learned cardinality/cost、计划排序、局部算子或 Join 决策、HBO | 是 | 当前最可行路线；可保留原生优化器和回退机制 |
| L4：端到端 Learned Optimizer | AI 直接生成 Join 顺序和物理计划，替换主要搜索/代价模型 | 是 | 学术上活跃，生产中仍受泛化、训练成本和性能回退限制 |

当前几家头部厂商的真实落点主要在 L2–L3。腾讯的产品文案看起来接近 L3；阿里 LOAM、ByteHouse 的 ByteCard/HBO/AI plan selection、GaussDB ABO 都属于 L3。尚无充分公开证据表明任一家已在广泛生产负载中用纯端到端神经优化器全面替代原生 CBO。

## 三、重点厂商进展

### 3.1 阿里云

#### 已商用产品

**1）数据库自治服务 DAS：自动 SQL 优化闭环**

DAS 能够自动检测新增慢 SQL、性能恶化 SQL和低效 SQL，基于执行代价评估索引、SQL 改写和引擎等候选建议；之后在运维窗口执行变更，并持续跟踪性能，出现回退时自动回滚。官方披露该服务已在阿里集团内部稳定运行多年，日均诊断约 5 万次，诊断成功率超过 98%，慢 SQL 推荐率超过 75%。

需要准确理解其定位：DAS 使用 workload 异常检测、代价模型和决策树等算法形成自治闭环，但公开材料的主要自动动作仍是**索引上线/删除、SQL 改写建议与限流联动**，并非以神经网络替换数据库原生查询优化器。

- [DAS 自动 SQL 优化产品文档](https://help.aliyun.com/zh/das/user-guide/automatic-sql-optimization)
- [DAS SQL 优化技术与闭环架构](https://help.aliyun.com/zh/das/product-overview/sql-optimization-technology)
- [DAS SQL 优化操作说明](https://help.aliyun.com/zh/das/user-guide/sql-optimization)

**2）PolarDB for MySQL：自适应优化与计划管理**

PolarDB MySQL 提供自适应优化能力，根据运行环境和执行因素动态调整执行计划；同时提供 Statement Outline、Auto Plan Cache 等计划稳定性机制。这一方向已产品化，核心价值是处理统计信息滞后、负载变化和计划回退。

- [PolarDB MySQL Adaptive Optimization](https://www.alibabacloud.com/help/en/polardb/polardb-for-mysql/user-guide/adaptive-optimization/)
- [PolarDB MySQL 执行计划管理](https://help.aliyun.com/zh/polardb/polardb-for-mysql/user-guide/execution-plan-management/)

#### 研发与试验方向

**LOAM：MaxCompute 的 Learned Query Optimizer 框架（2026）**

LOAM 不从零生成计划，而是以“steering”方式控制 MaxCompute 原生优化器生成多样候选计划，再用学习型代价预测器选出预计 CPU 成本最低的计划。其关键设计包括：

- 将动态执行环境特征编码进训练，降低多租户资源波动对成本预测的影响；
- 不依赖在线候选计划真实执行，以历史默认计划和 CPU 成本训练；
- 用 domain adaptation 提升模型从默认计划向未见候选计划的泛化；
- 先通过规则过滤项目，再用 learned ranker 选择最可能获益的租户，避免对所有项目盲目部署。

论文在 MaxCompute 内部超过 1 万台机器的 flighting 环境中评估，披露训练时间通常小于 1 小时、模型约 20 MB；随机抽样的 30 个项目中约 10% 获得不低于 10% 的明显收益。这个结果也揭示了现实边界：并非所有 workload 都有足够优化空间或训练数据。

状态判断：**已实现并在内部环境评估，属于接近生产的研发成果；截至调研日未找到公有云 MaxCompute 面向客户的 LOAM 功能开关或 GA 公告。**

- [LOAM 论文：Learned Query Optimizer in Alibaba MaxCompute](https://arxiv.org/abs/2602.07336)
- [ACM SIGMOD Companion 论文页面](https://doi.org/10.1145/3788853.3803074)

**其他可衔接技术**

- AWM（Alibaba Workload Miner）利用 SQL 语义与执行特征进行实时 workload pattern 挖掘，并把模式用于查询处理优化，说明阿里已具备云上大规模训练数据和 workload 分群基础。[AWM 论文](https://arxiv.org/abs/2307.02626)
- ALECE 用注意力模型做动态 workload 下的学习型基数估计，在 PostgreSQL 实验中改善计划质量；作者团队包含阿里研究人员，但尚不能据此判断已进入某个公开产品。[ALECE 论文](https://arxiv.org/abs/2310.05349)

#### 对阿里的判断

阿里的优势是生产数据规模、DAS 安全闭环和 MaxCompute 多租户工程经验；其策略较审慎，先识别“哪些 workload 值得用 AI”，再部署模型。短板是公有云产品文档尚未把 LOAM 这类内核学习能力开放为用户可见特性，因此对外容易被腾讯“AI 优化器”这一清晰产品名抢占认知。

### 3.2 腾讯云

#### 已推出产品

**TDSQL-C MySQL 版 AI 优化器**

腾讯云官方定义的流程是：

1. 通过 AWR 收集执行数据并识别执行计划走偏的 SQL 模板；
2. 自学习优化器持续训练，探索和量化候选执行计划；
3. 结合腾讯混元大模型能力扩展计划探索空间，官方宣称可扩展至“百亿级执行计划数量”；
4. 自动将更优计划绑定到 SQL，并持续多轮优化；
5. 控制台展示 SQL 总执行时间、平均 CPU、平均慢日志数及逐模板优化明细，用户可停止或恢复训练。

支持条件为 TDSQL-C MySQL 8.0、内核小版本 3.1.19.001 及以上，预置资源和 Serverless 实例均可使用；当前功能免费。开启时会同步启用 AWR，实例需要经历训练和数据收集期。

**成熟度限制：截至 2026-07-14，官方仍标注“白名单灰度阶段”。** 因此它已经超过论文或概念验证，具备真实控制台和自动执行闭环，但仍不能按全量 GA 评价。官方也提示 CPU、慢日志等指标可能因使用方式出现优化后高于优化前的情况。

- [TDSQL-C AI 优化器概述](https://intl.cloud.tencent.com/zh/document/product/1098/80435)
- [开启和查看 AI 优化器](https://cloud.tencent.com/document/product/1003/131980)
- [TDSQL-C 产品动态](https://intl.cloud.tencent.com/zh/document/product/1098/40613)

#### 外围 AI for DB 产品

**DBbrain** 是较早商用的数据库自治运维平台，使用机器学习、专家规则和代价评估做异常诊断、SQL 优化、索引建议和配置优化。它和新的 AI 优化器区别在于：DBbrain 更像跨数据库的诊断/运维服务，TDSQL-C AI 优化器直接围绕执行计划训练、探索和绑定。

- [DBbrain 产品页](https://cloud.tencent.com/product/dbbrain)
- [DBbrain SQL 优化文档](https://intl.cloud.tencent.com/zh/document/product/1035/48635)

**TencentDB AI Service / DatabaseClaw** 是 2026 年进一步推出的数据库运维智能体，面向自然语言巡检、慢 SQL 分析、CPU 异常归因与可插拔 Skill。它代表 LLM Agent 在 DBA 工作流中的产品化，但不应与内核查询优化器混称。

- [腾讯云数据库 AI 服务](https://cloud.tencent.com/product/tdai)

#### 对腾讯的判断

腾讯当前最强的竞争点是“直接可见、可开关、可观察收益”的 MySQL AI 优化器产品形态；在宣传和客户试用上最有冲击力。需要重点核验的不是功能是否存在，而是：候选计划如何生成、混元大模型实际参与哪一环、计划回退保护、训练数据隔离、额外资源开销，以及在非重复 SQL/低频模板上的覆盖率。公开文档没有给出足以复现实验的总体 benchmark 数字。

### 3.3 火山引擎 / 字节跳动

#### 已商用产品

**1）ByteHouse 自研 RBO/CBO 优化器**

ByteHouse 针对 ClickHouse 在多表 Join、子查询和复杂查询上的不足，自研 Cascade 搜索框架的 CBO，支持 Join 枚举、Histogram 代价估计、Outer Join reorder、Magic Set Placement，以及列裁剪、谓词下推、子查询解关联等 RBO 能力。这是 AI 能力的传统优化器底座，本身不能直接算 Learned Optimizer。

- [ByteHouse 优化器文档](https://www.volcengine.com/docs/6464/164683?lang=zh)
- [ByteHouse 查询优化器设计介绍](https://developer.volcengine.com/articles/7348847247909453833)

**2）ByteHouse 运维 Agent 与 SQL 诊断**

运维 Agent 已支持集群健康诊断、查询失败/慢查询根因分析、优化建议和部分 SQL 自动改写；SQL 诊断页则基于慢 Query 日志、SQL 指纹和资源指标定位高消耗查询。二者属于 L1/L2 外围优化能力，目前公开文档没有说明它会自动替换执行计划。

- [ByteHouse 运维 Agent](https://www.volcengine.com/docs/6464/1913835?lang=zh)
- [ByteHouse SQL 诊断](https://www.volcengine.com/docs/6464/1744773)

#### 研发与内部生产方向

**1）ByteCard：学习型基数估计（2024）**

ByteCard 用学习模型替换传统 Selinger-like 基数估计器在部分场景中的估计结果，兼顾推理延迟、模型大小和训练开销。论文称，在真实数据集和 ByteHouse 优化场景中，集成 ByteCard 后查询 P99 延迟最高改善 30%。这是从传统 CBO 走向 AI 增强优化器的明确证据。

- [ByteCard 论文](https://arxiv.org/abs/2403.16110)

**2）HBO + AI-assisted plan selection（2026）**

ByteHouse 2026 年 SIGMOD Companion 论文披露：

- HBO 重用历史执行的 runtime statistics，修正选择率、基数和算子成本；
- AI 模型学习查询结构、数据分布和运行行为的相关性，以泛化到历史中未直接出现的计划片段；
- 已探索基于 ML 的 Predicate Pushdown Selectivity（动态决定下推策略）；
- 已探索学习型 Join Side Selection（决定 Hash Join 的 build/probe 侧），并用 1,000 条真实生产 Join 查询评估；
- 优化器还面向文本、向量和结构化条件混合查询做 runtime filter、Join 顺序及多模态访问路径优化。

论文明确描述了 100 节点生产集群实验和生产查询轨迹，但面向火山引擎客户的产品文档尚未给出相应开关、版本或 SLA。因此本报告将其判断为**已进入内部生产验证/逐步集成，公有云开放范围待确认**。

- [ByteHouse 2026 系统论文](https://arxiv.org/abs/2602.08226)
- [ACM DOI 页面](https://doi.org/10.1145/3788853.3803080)

#### 对火山引擎的判断

火山的特点是围绕 OLAP 做纵深演进：基数估计 → 历史反馈 → 局部计划选择 → 多模态混合查询优化。相比腾讯 TDSQL-C，它更偏大规模分析场景和算子级决策；相比阿里 LOAM，它公开展示了多个可插入原生优化器的局部模型。潜在风险同样是外部客户难以确认哪些论文能力已进入当前商业版本。

### 3.4 华为云 GaussDB（补充重点对标）

GaussDB 的 ABO（AI-Based Optimizer）已出现在产品版本公告中，公开能力包括：

- 智能基数估计：改善多列等值查询的基数估计；
- 多计划缓存与自适应计划选择；
- 官方给出的典型场景指标为，增强统计/基数估计算法效率翻倍、典型性能提升 50%，自适应计划选择效率翻倍。

后续产品公告还披露了多版本计划自动回退、智能统计增强和优化器鲁棒性改进。华为的路线与腾讯相似，都重视“多个计划 + 在线选择 + fallback”，但 GaussDB 更早以 ABO 概念对外，且主要面向 PostgreSQL/分布式数据库技术栈。

- [GaussDB 产品版本公告 PDF（ABO 见相关内核版本章节）](https://support.huaweicloud.com/eu/bulletin-gaussdb/bulletin-gaussdb-pdf.pdf)
- [GaussDB 查询执行过程与传统 CBO](https://support.huaweicloud.com/intl/en-us/distributed-devg-v3-gaussdb/gaussdb-12-0249.html)
- [GaussDB AI Native 发布说明](https://www.huawei.com/en/news/2019/5/huawei-launches-ai-native-database)
- [Learned Query Optimizers on PostgreSQL and GaussDB（2022）](https://doi.org/10.1109/ACCESS.2022.3190376)
- [GRewriter：GaussDB 自动查询改写研究](https://www.vldb.org/pvldb/vol18/p4991-jiang.pdf)

### 3.5 OceanBase、TiDB 的公开侧重点

OceanBase 和 TiDB 都在大力发展向量检索、RAG、AI 函数、NL2SQL 与 Agent 数据底座，这些属于 **DB for AI**。截至本次公开资料检索，没有找到像腾讯 AI 优化器、GaussDB ABO、ByteCard 或 LOAM 那样明确且可核验的“学习模型参与关系查询执行计划选择”的现行产品说明。因此更稳妥的判断是：它们目前对外 AI 叙事重点不在 Learned Query Optimizer，不能仅凭“AI Database”品牌推断已有对应内核能力。

- [OceanBase AI SIG](https://oceanbase.github.io/docs/sig/AI/sig_intro)
- [TiDB Cloud AI Features](https://docs.pingcap.com/tidbcloud/ai-feature-concepts/)

## 四、横向技术路线对比

| 技术环节 | 阿里 | 腾讯 | 火山/字节 | 华为 |
|---|---|---|---|---|
| Workload 采集/聚类 | DAS、AWM，规模化基础强 | AWR、DBbrain | Query Log、SQL 指纹、HBO | 智能统计与诊断 |
| 学习型基数估计 | ALECE 等研究；LOAM 可无统计预测成本 | 公开细节较少 | ByteCard 已有明确论文与效果 | ABO 智能基数估计已列入产品公告 |
| 候选计划生成 | 原生优化器 steering | 宣称扩展百亿级计划空间，算法未公开 | Cascade CBO + 局部候选 | 原生 CBO + 多版本计划 |
| 学习型计划选择 | LOAM learned cost predictor | 自学习训练、量化、自动绑定 | AI-assisted selection、JSS/PPS | ABO 自适应计划选择 |
| 历史执行反馈 | DAS 闭环、PolarDB adaptive、LOAM 历史训练 | 持续多轮训练 | HBO | 多计划缓存与智能统计 |
| 自动执行与回退 | DAS 灰度/回滚成熟；LOAM 未对外 | 自动绑定，可人工停止/恢复；回退细节待核验 | Agent 主要给建议；内核 AI 开放状态不明 | 公告强调 fallback/鲁棒性 |
| 优势场景 | 云上多租户、MySQL 自治、离线数仓 | MySQL 重复 SQL、计划走偏、慢查询 | OLAP、多 Join、多模态混合查询 | 分布式/集中式关系库、复杂查询 |

## 五、趋势研判

### 1. “外挂增强”会长期胜过“全替代”

LOAM、ByteCard、GaussDB ABO 以及公开学术界的 Lero/Bao 都保留原生优化器，让 ML 做代价预测、候选排序或局部决策。这可以复用几十年积累的语义规则和物理算子能力，并在模型不确定时回退。未来两三年的主战场更可能是增强型优化器，而不是完全由大模型直接生成执行计划。

### 2. 最大难点从平均收益转向尾部风险

学习型优化器通常能在部分 workload 上显著提速，但客户最担心单条关键 SQL 出现数量级回退。腾讯采用自动绑定并允许停止训练，阿里强调只选择有收益空间的项目，华为强调多版本计划 fallback，都是在解决同一问题。评价产品时应优先看 P95/P99 回退比例、最大退化倍数和恢复时间，而不是只看平均加速比。

### 3. 重复 SQL 模板和稳定 workload 最先受益

当前产品依赖历史执行、SQL 模板聚合和多轮训练，因而更适合 SaaS/ERP、核心交易系统中的重复 SQL，或数据仓库中的周期性 ETL/报表。对 ad-hoc、低频、结构快速变化的查询，训练数据不足和分布漂移会显著降低收益。

### 4. LLM Agent 与 Learned Optimizer 会形成上下两层

DBbrain/DatabaseClaw、ByteHouse 运维 Agent、DAS 智能诊断解决的是“人如何发现和处理数据库问题”；Learned Optimizer 解决的是“内核如何自动选计划”。两者未来会连接起来：Agent 负责解释、审批和编排，内核模型负责低延迟决策，安全策略负责灰度与回滚。不能用 LLM 替代需要微秒/毫秒级推理、强确定性和严格正确性的内核优化器。

### 5. 多模态查询将催生新的优化问题

ByteHouse 已公开探索结构化过滤、全文检索、向量检索混合计划的选择。随着数据库支持向量、文本和关系数据统一查询，传统基数与代价模型很难精确估算 ANN recall、过滤选择率与 Join 的相互影响，这会成为 AI 优化器的新差异化方向。

## 六、建议的竞品验证方案

若要把公开调研转化为可信的竞品结论，建议申请腾讯 TDSQL-C 白名单、ByteHouse 企业版和 GaussDB 对应版本，并用同一套 workload 做黑盒验证。

### 核心测试集

1. **重复 OLTP 模板**：参数分布倾斜、热点变化、索引选择错误、prepared statement 参数敏感。
2. **复杂 Join**：TPC-DS、JOB、10 表以上 Join，故意制造统计信息过期和列相关性。
3. **分布漂移**：训练后批量导入/删除数据，改变热点和 NDV，观察恢复速度。
4. **资源扰动**：并发、CPU 限制、Buffer Pool 冷热变化、Serverless 弹性变化。
5. **低频/ad-hoc SQL**：验证无足够历史样本时是否安全回退。
6. **回归攻击集**：强制构造一个候选计划平均较优但尾延迟极差的场景。

### 必测指标

- 优化覆盖率：被识别、训练、产生新计划并最终绑定的 SQL 模板比例；
- 收益分布：P50/P95/P99 加速比，而非只统计总体平均；
- 回退风险：退化 SQL 比例、最大退化倍数、错误绑定持续时间；
- 收敛成本：所需执行次数、训练时间、CPU/内存/存储额外开销；
- 泛化能力：新参数、新 SQL 结构、数据漂移和版本升级后的表现；
- 可运维性：解释信息、审批控制、计划版本、回滚、租户隔离和审计；
- 稳定性：模型服务不可用或元数据不完整时，是否无损回退原生 CBO。

### 建议向厂商直接追问的问题

1. “百亿级计划”是实际枚举、模型隐式搜索空间，还是大模型生成/重排的理论规模？
2. 训练标签采用真实 wall-clock latency、CPU cost，还是原生优化器估算 cost？如何消除并发噪声？
3. 模型作用于基数、代价、Join order、访问路径、并行度中的哪些环节？
4. 是否会在线执行探索计划？探索慢计划如何限时、隔离和熔断？
5. 计划绑定是实例级、SQL digest 级还是参数区间级？如何解决 parameter-sensitive plan？
6. 如何检测数据/负载分布漂移？模型重训和失效机制是什么？
7. 最坏回退倍数、P99 退化比例、自动回滚时延是多少？是否有 SLA？
8. 训练数据和模型是否跨租户共享？如何处理 SQL 文本、常量和业务数据隐私？

## 七、对自研 MySQL 优化器的启示

如果目标是在 MySQL 内核或云服务中建设可落地的 AI 优化能力，建议采用渐进路线：

1. **先做安全的多版本计划基础设施。** 建立 SQL digest、计划指纹、运行时反馈、plan cache 多版本、绑定/失效/回退机制。这是腾讯、华为路线共同依赖的底座。
2. **优先选择可解释的局部模型。** 从参数敏感计划选择、基数校正、Index/Join method ranking 开始，比端到端 Join order 更易控制风险。
3. **采用 champion/challenger。** 原生 CBO 始终作为 champion；AI 计划先影子评估或小流量灰度，只有置信度和收益达到阈值才绑定。
4. **把收益空间识别作为一等能力。** 借鉴 LOAM，先判断 SQL/租户是否有足够重复度、优化空间和训练数据，避免 AI 对无收益 workload 增加开销。
5. **将尾部退化作为首要目标函数。** 模型训练不只优化平均 latency，还要加入最大回退约束、超时惩罚和不确定性估计。
6. **打通外围 Agent，但保持内核决策独立。** Agent 可解释执行计划、生成测试方案和审批变更；关键计划选择仍应由轻量模型和确定性策略完成。

## 八、信息可信度与限制

- **高可信**：厂商产品文档、版本公告、控制台操作说明；用于判断功能是否可用、支持版本及公开限制。
- **中高可信**：ACM/VLDB/SIGMOD 等论文及 arXiv 作者稿；用于判断技术实现和内部实验，但不自动代表公有云已 GA。
- **需验证**：厂商自行披露的性能数字。各家 workload、硬件、基线和统计口径不同，不能横向直接比较。
- 本报告依据截至 2026-07-14 可公开访问资料。白名单、地域、内核小版本及商业开放状态变化较快，正式采购或立项前应再次向厂商确认。

## 九、延伸阅读

- [Lero：Learning-to-Rank Query Optimizer](https://arxiv.org/abs/2302.06873)
- [Bao：Making Learned Query Optimization Practical](https://dl.acm.org/doi/10.1145/3448016.3452838)
- [Neo：A Learned Query Optimizer](https://arxiv.org/abs/1904.03711)
- [Learned Query Optimizer: What Is New and What Is Next（SIGMOD Tutorial）](https://bolinding.github.io/papers/sigmod24learnedqo.pdf)
- [Simple Adaptive Query Processing vs. Learned Query Optimizers](https://link.springer.com/article/10.1007/s00778-025-00936-6)
