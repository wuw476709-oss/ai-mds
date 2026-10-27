---
title: 云厂商数据库参与大模型推理实践调研（2026-08）
aliases:
  - 数据库加入大模型推理厂商实践
  - Database Augmented Reasoning Vendor Research
tags:
  - 数据库
  - 大模型
  - 推理
  - Agent
  - RAG
  - 云厂商
created: 2026-08-03
updated: 2026-08-03
status: completed
---

# 云厂商数据库参与大模型推理实践调研（2026-08）

**调研日期：2026-08-03**

**重点厂商：阿里云、腾讯云、AWS；补充 Google Cloud、Microsoft Azure、Oracle、Snowflake、Databricks。**

**关联文档：[[01 大模型推理机制详解]]、[[02 数据库介入大模型推理的关键环节]]。**

> 核心结论：数据库参与大模型推理已经从“存向量、做一次 Top-K 检索”发展到四条产品路线：数据库内直接调用模型、数据库作为 Agent 的受控工具、数据库承担长期记忆和 checkpoint、数据库驱动多轮 Agentic Retrieval。阿里、腾讯、AWS 都已有上线实践，但产品成熟度差异很大；同一厂商内部也同时存在 GA、商业计费、邀测、内测和仅有参考架构的能力，不能笼统称为“已经上线”。

## 一、调研口径

### 1.1 什么算“数据库加入推理”

本报告将实践分成五层。

| 层级 | 数据库参与方式 | 判断标准 | 典型产品 |
|---|---|---|---|
| L1：检索底座 | 保存向量、全文和元数据，向模型提供上下文 | 数据库只负责召回，不负责生成或循环控制 | Aurora pgvector、腾讯云向量数据库 |
| L2：库内 AI 调用 | SQL 中直接调用 Embedding、Rerank、LLM、Text-to-SQL | 数据库执行计划中出现远程模型函数或 AI 网关 | PolarDB-X AI Function、TencentDB PostgreSQL `tencentdb_ai`、Aurora ML |
| L3：Agent 数据工具 | 通过 MCP、API、语义层让 Agent 查询或操作数据库 | 模型决定是否调用，数据库侧实施权限和确定性执行 | 阿里 DMS MCP、Microsoft SQL MCP Server |
| L4：记忆与状态 | 保存短期/长期记忆、会话、checkpoint、审批和工具结果 | 数据库影响后续轮次推理，并支持恢复和审计 | TencentDB Agent Memory、DynamoDBSaver、Databricks Lakebase Memory |
| L5：Agentic Retrieval | 模型多轮改写查询、判断证据充分性并继续检索 | 检索不再是固定单次 Top-K，而是推理循环的一部分 | PolarDB Agent Express、AWS GraphRAG、Cosmos DB Agentic Retrieval Toolkit |

以下能力不直接算“数据库加入业务推理”，但会单独标注：

- AI 查询优化器；
- AI DBA、数据库诊断和运维 Agent；
- AI 帮助开发者写 SQL 或迁移数据库；
- 单纯的模型托管服务。

这些属于“AI 用于数据库”，方向与“数据库增强模型推理”相反，但两者正在通过 MCP、Skill 和 Agent 工作流发生融合。

### 1.2 状态判定

| 状态 | 本报告使用条件 |
|---|---|
| GA/正式商用 | 官方明确标注 General Availability、正式商用，或已有正式计费公告 |
| 可用但未明确 GA | 官方产品文档提供版本、开通和调用步骤，但页面未明确写 GA/Preview |
| Preview/Beta/内测 | 官方明确标注预览、Beta、邀测、内测或无 SLA |
| 参考实践 | 官方博客、教程或开源连接器，可自行部署，但不是托管产品能力 |
| Research/Coming soon | 论文、研究原型、内部实验，或官方明确写尚未发布 |

## 二、结论摘要

### 2.1 厂商成熟度总表

| 厂商 | 已上线或可用的代表能力 | 未正式上线/受限能力 | 路线判断 |
|---|---|---|---|
| 阿里云 | ADB PostgreSQL RAG 商用；PolarDB-X AI Function；DMS MCP；PolarDB MySQL 内置向量化 | PolarSearch 邀测；Agent Express 新能力未见明确 GA 声明 | **数据库内 AI 函数最激进，正在从 RAG 向 Agentic RAG 扩展** |
| 腾讯云 | Agent Memory 已正式计费；PostgreSQL `tencentdb_ai` 库内 RAG；向量数据库 RAG | DatabaseClaw/数据库 AI 服务总产品仍标注内测 | **记忆产品差异化最强，库内 RAG 很直接，运维 Agent 尚处内测** |
| AWS | Aurora+Bedrock RAG；Aurora ML；Redshift+Bedrock；结构化 KB；Neptune GraphRAG GA；DynamoDB checkpoint | AWS Context Coming soon；部分 AgentCore session 能力仍 Preview | **模块最完整，数据库分工清晰，强调托管编排和 IAM 治理** |
| Google Cloud | AlloyDB 向量检索、模型端点调用、自然语言查询 | `ai.if/rank/generate` 等多项 AI Functions 仍 Preview | **把自然语言条件和模型调用嵌入 SQL 算子，技术融合深** |
| Microsoft | Azure SQL 向量/Embedding；SQL MCP Server；Fabric AI Functions | Cosmos DB Agentic Retrieval Toolkit Preview | **最强调确定性工具和 RBAC，主动避免不受控 NL2SQL** |
| Oracle | Select AI：NL2SQL、RAG、LLM Chat、向量 | 部分新 AI Agent 能力按版本/部署形态受限 | **数据库原生自然语言入口成熟，SQL/PLSQL 一体化明显** |
| Snowflake | Cortex Agents GA；Cortex Analyst/Search；Cortex AI Functions GA | 部分 Cortex Search、多模态和优化功能仍 Preview | **目前最完整的“结构化+非结构化+规划+反思”数据 Agent 产品之一** |
| Databricks | Agent Framework、AI Search、Genie、Inference Tables | Managed Agent Memory Beta；KARL 属研究成果 | **湖仓承担数据、轨迹和 Agent 生命周期，记忆仍在快速产品化** |

### 2.2 三点行业判断

1. **“向量数据库就是 AI 数据库”的阶段正在结束。** 新产品开始把 Embedding、Rerank、LLM Generate、NL2SQL、Agent Memory 和 MCP 同时放进数据库产品面。
2. **真正进入推理闭环的标志，是数据库结果会影响下一步行动。** 单次 RAG 只是提供上下文；Agentic RAG、GraphRAG、MCP 和 checkpoint 才让数据库持续参与计划、观察、验证和恢复。
3. **产品路线分成两派。** 阿里、腾讯、Google、Oracle倾向把模型函数塞进 SQL；AWS、Microsoft、Snowflake 更强调数据库作为受治理的 Agent 工具或托管知识层。两条路线最终可能并存。

## 三、阿里云

### 3.1 已正式商用：AnalyticDB for PostgreSQL RAG Service

AnalyticDB for PostgreSQL 的 RAG Service 已于 **2024-10-21 正式商业化**。它不是单纯向量类型，而是托管了：

- 文档上传和解析；
- Chunking；
- Embedding；
- 向量与全文混合检索；
- Rerank；
- LLM 处理；
- API 和多语言 SDK。

官方 2026 年文档进一步描述了 dense vector、sparse vector、全文检索的融合，以及 namespace 多租户隔离。[商业化公告](https://www.alibabacloud.com/help/doc-detail/2851620.html)、[RAG Service 产品说明](https://www.alibabacloud.com/help/en/analyticdb/analyticdb-for-postgresql/what-is-rag-service)

**它怎样加入推理：** 数据库负责文档处理、召回和重排，再把高相关证据交给 LLM。已经达到 L1/L2，但核心推理规划通常仍在外部应用。

**成熟度判断：正式商用。**

### 3.2 已提供产品文档：PolarDB-X AI Function

PolarDB 分布式版在 2026 年加入 AI Function。企业版、指定内核版本以上的实例，可以开启 AI 网关，并从 SQL 直接调用：

- `AI_PROMPT`：调用 LLM 生成，可开启 Qwen3 thinking；
- `AI_EMBEDDING`：生成向量；
- `AI_SIMILARITY`：语义相似度；
- `AI_RANK`：交叉编码器精排；
- `AI_CLASSIFY`：零样本分类；
- `AI_EXTRACT`：按 JSON Schema 结构化抽取；
- `AI_SUMMARIZE`：摘要；
- `AI_PARSE_DOCUMENT`：文档解析；
- `AI_VL_EMBEDDING`：多模态向量；
- `AI_TEXT2SQL`：根据当前 schema 生成 SQL。

官方示例中 `AI_PROMPT` 支持 `enable_thinking`，这意味着模型推理可由一条 SQL 触发，数据库通过 AI 网关路由到模型。[PolarDB-X AI Function](https://help.aliyun.com/zh/polardb/polardb-for-xscale/ai-function)

**它怎样加入推理：** SQL 既可筛选关系数据，又可在同一查询中调用模型做语义判断、排序、抽取或生成，达到 L2。

**成熟度判断：可用但官方页面未明确写 GA。** 文档给出了版本门槛和控制台开通路径，因此高于概念验证；仍需实测区域、模型配额、事务语义和远程调用失败处理。

### 3.3 已有成熟入口：DMS MCP

阿里云 DMS MCP 将托管在 DMS 中的异构数据库统一暴露为大模型工具，提供：

- Schema 获取；
- 数据库实例录入；
- SQL 自动路由；
- 数据查询；
- Schema 分析与 DAO 代码生成；
- DMS 账号和权限体系复用。

官方强调它用于解决传统数据库 MCP 的异构兼容、凭据管理和 NL2SQL 接入问题。[DMS MCP](https://help.aliyun.com/zh/dms/use-cases/deploy-dms-mcp)

**它怎样加入推理：** Agent 先理解意图，再通过 MCP 调用 DMS 获取 schema 或执行查询，结果作为 observation 返回模型继续推理，达到 L3。

**成熟度判断：官方可部署实践。** 需要注意 MCP 本身不保证 SQL 正确，仍要使用 DMS 审批、权限和审计能力。

### 3.4 已有产品实践：PolarDB for MySQL 内置 AI/向量检索

PolarDB for MySQL 提供内置 AI 引擎和 `_polar4ai_text2vec` 模型，可在数据库中完成文档向量化，并通过 `distance()` 检索相似内容。[PolarDB 文档检索系统](https://www.alibabacloud.com/help/doc-detail/2667832.html)

**它怎样加入推理：** 数据库负责实时查询向量化和语义召回，属于 L1/L2；最终答案生成一般仍由外部模型服务完成。

### 3.5 新上线/状态需继续核验：PolarDB Agent Express 企业知识空间

2026 年 7 月文档披露了 PolarDB Agent Express 的企业知识空间，包含：

- 多模态解析；
- Hybrid Retrieval 和 Rerank；
- LLM、Embedding、OCR/VLM 托管；
- Agent orchestration；
- Agentic RAG：Agent 自主决定检索轮数、改写查询并判断证据是否充分；
- PolarDB PostgreSQL 管理任务状态、空间配置、文档生命周期和审计；
- PolarSearch 存储和检索向量及全文索引。

这已经不只是固定 RAG，而是 L4/L5 架构。[PolarDB Agent Express 企业知识空间](https://www.alibabacloud.com/help/en/polardb/polardb-for-postgresql/what-is-an-enterprise-knowledge-space)

**成熟度判断：官方产品文档已公开，但页面没有明确 GA/Preview 标识。** 考虑其发布时间很新，建议在采购判断中暂列“新发布、可用范围待确认”，不要直接按全面 GA 宣传。

### 3.6 未正式上线：PolarSearch 智能搜索

PolarSearch 将全文、向量、Hybrid Search、RAG 问答、Agentic Memory 和 Agentic Search 与 PolarDB-X 数据结合，但官方明确标注为 **invitational preview（邀测）**，需提交工单申请，预览期不收费。[PolarSearch 状态说明](https://www.alibabacloud.com/help/en/polardb/polardb-for-xscale/what-is-search-engine)

**它怎样加入推理：** 预期承担 L1 和 L5 的混合检索、记忆和 Agentic Search。

**成熟度判断：未正式商用，邀测。**

### 3.7 阿里路线评价

阿里的显著特点是把 AI 能力向 SQL 和数据库实例内部推进：

```text
向量类型
→ 内置 Embedding
→ SQL 调用 Rerank/LLM
→ Text-to-SQL
→ Agentic RAG 和知识空间
```

优势是减少跨系统数据搬运和编排代码；风险是远程模型调用进入 SQL 后，会把模型延迟、限流、非确定性和失败重试带进数据库执行语义。产品评测应重点检查：

- 一条 SQL 扫描大量行时会触发多少模型调用；
- 优化器能否下推普通过滤，减少 AI Function 输入；
- 模型调用失败时事务如何处理；
- Prompt 和数据是否离开 VPC；
- 账单能否按 SQL、用户和模型归因；
- AI Function 是否可被资源组、超时和并发策略限制。

## 四、腾讯云

### 4.1 已正式计费：TencentDB Agent Memory

TencentDB Agent Memory 提供短期和长期两层能力：

- 短期记忆：压缩工具日志、代码、搜索结果和长上下文；
- 长期记忆：Raw Log、Atomic Memory、Scene Block、Persona 四层结构；
- 主动召回：模型调用前自动注入相关记忆；
- 工具召回：让模型在信息不足时自主检索；
- 记忆写入：对一轮交互抽取事实、偏好和指令；
- 向量数据库保存索引，文件存储保存原始日志和大对象；
- HTTP、Python、TypeScript API/SDK。

腾讯云已在 **2026-06-16 发布正式计费公告**，新实例按月计费。[Agent Memory 介绍](https://cloud.tencent.com/document/product/1813/132100)、[正式计费公告](https://cloud.tencent.com/product/events/detail/7188)、[自研 Agent 接入](https://cloud.tencent.com/document/product/1813/132103)

**它怎样加入推理：** 每次推理前召回记忆，推理后写入并分层压缩；模型也可以把记忆检索作为工具自主调用，达到 L4/L5。

**成熟度判断：独立模块已正式商业化。** 官方披露的 token 降低和任务成功率提升来自特定评测场景，不能直接外推到所有业务。

### 4.2 可用产品能力：TencentDB for PostgreSQL `tencentdb_ai`

`tencentdb_ai` 插件允许 PostgreSQL 调用网络可达的模型 API。1.4 版本进一步提供：

- `retrieve()`：实时生成查询 embedding，并使用 pgvector 做 Top-N；
- `rag()`：在一条 SQL/PLpgSQL 调用中完成“检索→构造 Prompt→LLM 生成”；
- `call_model`、`get_embedding`、`chat_completions` 等底层能力；
- 参数绑定、标识符引用和距离类型白名单；
- `SECURITY INVOKER`，沿用调用者表权限。

[tencentdb_ai 插件](https://cloud.tencent.com/document/product/409/116227)、[tencentdb_ai RAG](https://cloud.tencent.com/document/product/409/133911)

**它怎样加入推理：** 数据库不仅召回证据，还直接触发最终模型生成，达到 L2；如果在外部 Agent 中循环调用，可成为 L5 的检索工具。

**成熟度判断：官方已提供版本化产品文档和完整操作步骤，但页面未明确写 GA。** 需要核对支持实例版本、地域、模型网络和费用。

### 4.3 已有产品：腾讯云向量数据库 + LLM RAG

腾讯云向量数据库提供 FLAT、HNSW、IVF、DISK_FLAT 等索引，并给出与 DeepSeek 等模型结合的 RAG 方案。[向量数据库 + DeepSeek](https://cloud.tencent.com/document/product/1709/116058)

**它怎样加入推理：** 主要是 L1，负责私域知识召回。它是较成熟的数据底座，但“有向量检索”本身不等于具备多轮推理或验证能力。

### 4.4 内测：DatabaseClaw 数据库运维 Agent

腾讯云数据库 AI 服务由 DatabaseClaw 和 Agent Memory 两部分组成。DatabaseClaw 的执行流程包括：

1. LLM 识别运维意图；
2. 从 Skill 池中选择诊断或运维技能；
3. 根据安全等级决定直接执行或请求人工确认；
4. VPC 内 Agent 连接目标数据库；
5. 结果流式返回，并保存推理与工具调用记录。

它已经具备控制台、API、实例创建、数据源绑定、CAM 角色、KMS 凭据加密和外部 Agent Skill 接入文档。[产品概述](https://cloud.tencent.com/document/product/1813/122696)、[实现原理](https://cloud.tencent.com/document/product/1813/130681)、[外部 Agent 集成](https://cloud.tencent.com/document/product/1813/132895)

但官方产品概述截至 2026-05-09 仍明确写着：**腾讯云数据库 AI 服务目前处于内测阶段**。

**它怎样加入推理：** 这是“AI 进入数据库运维”的反向实践。数据库指标、慢日志、执行计划和配置成为 Agent 的观察，Agent 多轮诊断后给出或执行动作。

**成熟度判断：功能完整度较高，但总产品仍是内测，不应列为 GA。** Agent Memory 已单独正式计费，不代表 DatabaseClaw 同时 GA。

### 4.5 腾讯路线评价

腾讯当前最有辨识度的是独立 Agent Memory，而不只是向量库。其四层记忆、主动/工具双通道召回和上下文卸载，直接针对长任务推理成本和连续性。

需要重点验证：

- 模型推测是否会被错误写成长期事实；
- 记忆冲突、修改和删除是否可审计；
- Persona 是否会跨用户或租户污染；
- 原始日志和提炼记忆能否同步删除；
- 工具召回是否可能形成无界循环；
- DatabaseClaw 高风险操作是否始终由确定性权限层拦截，而不是仅靠 Prompt。

## 五、AWS

### 5.1 已上线：Aurora PostgreSQL 作为 Bedrock Knowledge Base

Aurora PostgreSQL 可直接作为 Amazon Bedrock Knowledge Bases 的向量存储：

- S3 文档由 Knowledge Bases 切分并生成 embedding；
- chunk、vector、metadata 写入 Aurora PostgreSQL；
- Bedrock Agent 或应用执行检索；
- 检索结果作为上下文增强模型回答；
- 2025 年进一步支持向量+全文 Hybrid Search。

[Aurora 作为 Bedrock Knowledge Base](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraPostgreSQL.VectorDB.html)、[Hybrid Search 发布](https://aws.amazon.com/about-aws/whats-new/2025/04/amazon-bedrock-knowledge-bases-hybrid-search-aurora-postgresql-mongo-db-atlas-vector-stores/)

**参与层级：L1。成熟度：已上线。**

### 5.2 已上线：Aurora ML 直接调用 Bedrock

Aurora ML 将 Bedrock 模型暴露为 SQL 函数，可以在 SQL 内对数据库中的文本执行摘要等生成任务。AWS 于 2023-12 宣布这项集成和 Aurora 作为 Knowledge Base 向量存储同时上线。[Aurora PostgreSQL + Bedrock](https://aws.amazon.com/about-aws/whats-new/2023/12/amazon-aurora-postgresql-integration-bedrock-generative-ai/)

**参与层级：L2。成熟度：已上线，受区域和模型支持范围限制。**

### 5.3 已上线：Redshift SQL 调用 Bedrock

Redshift 可使用 `CREATE EXTERNAL MODEL` 指向 Bedrock LLM，并通过 SQL 执行文本生成、摘要、翻译、分类和情感分析。AWS 明确标注该能力为 GA。[Redshift + Bedrock GA](https://aws.amazon.com/about-aws/whats-new/2024/10/amazon-redshift-integration-bedrock-generative-ai/)

**参与层级：L2。** 其定位更像“库内批量非结构化分析”，不一定是交互式 Agent 推理。

### 5.4 已上线：Bedrock Knowledge Bases 结构化数据检索

Bedrock Knowledge Bases 能把自然语言转换为 SQL，通过 Redshift 查询引擎访问：

- Amazon Redshift；
- AWS Glue Data Catalog / Lake Formation 管理的数据。

它会利用 schema、查询历史和上下文生成 SQL，并提供 `Retrieve`、`RetrieveAndGenerate` 和 `GenerateQuery` API。AWS 在 2024-12 宣布结构化数据检索上线。[发布公告](https://aws.amazon.com/about-aws/whats-new/2024/12/amazon-bedrock-knowledge-bases-structured-data-retrieval/)、[官方文档](https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base-build-structured.html)

**参与层级：L3。成熟度：已上线。** AWS 同时明确警告 Text-to-SQL 的任意 SQL 风险，建议使用受限角色、只读数据库和沙箱。

### 5.5 已 GA：Neptune Analytics GraphRAG

Bedrock Knowledge Bases GraphRAG 已于 **2025-03 GA**：

- 自动从 S3 文档抽取实体、事实和关系；
- 将向量与图结构保存到 Neptune Analytics；
- 先做向量检索，再遍历相关邻域；
- 将跨 chunk、跨文档关系作为模型上下文；
- 支持元数据过滤。

[GraphRAG GA 公告](https://aws.amazon.com/about-aws/whats-new/2025/03/amazon-bedrock-knowledge-bases-graphrag-generally-available/)、[GraphRAG 工作方式](https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base-build-graphs.html)

**参与层级：L5。** 它比普通 RAG 更接近数据库参与多跳推理，但要注意：图遍历主要发生在检索阶段，最终语言推理仍由模型完成。

### 5.6 已有生产级参考实现：DynamoDB 保存 Agent Checkpoint

AWS 维护 `langgraph-checkpoint-aws`，其中 `DynamoDBSaver` 用 DynamoDB 保存 LangGraph checkpoint 和 thread metadata，大状态可卸载到 S3，并支持 TTL、压缩和故障恢复。[DynamoDB checkpoint 官方指南](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/ddb-langgraph-checkpoint.html)

**它怎样加入推理：** 每个 Agent super-step 后持久化状态，使任务可以暂停、恢复、人工审批和 time-travel，达到 L4。

**成熟度判断：官方连接器和生产参考实践，不是一个独立托管 Agent Memory 数据库产品。**

### 5.7 已 GA：Bedrock AgentCore Memory

AgentCore 已于 2025 年进入 GA。其 Memory 可保存：

- 同一 session 的消息和工具调用；
- 跨 session 的语义、摘要、用户偏好和情景记忆；
- 在 Agent 推理前自动加载相关历史。

[AgentCore 发布记录](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/release-notes.html)、[AgentCore Memory](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/harness-memory.html)

**参与层级：L4。** 它是托管 Agent 服务，不等同于单一数据库产品，但底层承担的正是数据库式持久记忆职能。

### 5.8 未上线：AWS Context

AWS 于 2026-06 宣布 **AWS Context（Coming soon）**：

- 自动映射数据库、湖仓、数据目录和业务知识之间的关系；
- 构建受治理的知识图谱；
- 为 Agent 提供 agentic search；
- 共享已学到的 Join 路径、schema 消歧和业务规则；
- 与 Glue Data Catalog、SageMaker Unified Studio、Lake Formation 集成。

[AWS Context 公告](https://aws.amazon.com/blogs/machine-learning/context-intelligence-for-your-data-and-ai-agents-at-scale/)

**参与层级：目标是 L5。成熟度：尚未上线。** 这是当前最值得跟踪的 AWS 数据+推理方向，因为它尝试把组织级 schema、血缘、业务定义和 Agent 经验汇总成统一上下文层。

### 5.9 AWS 路线评价

AWS 没有把所有功能塞进一款“AI 数据库”，而是分工：

```text
Aurora      → 向量、Hybrid RAG、SQL 模型函数
Redshift    → 结构化 NL2SQL、批量 LLM 分析
Neptune     → GraphRAG 和关系扩展
DynamoDB    → Agent checkpoint
AgentCore   → 托管记忆与 Agent 运行时
AWS Context → 未来的组织级知识图谱和上下文层
```

这种组合灵活，但系统复杂度和跨服务计费也更高。评估时要计算端到端成本，而不是只看数据库实例价格。

## 六、其他代表厂商

### 6.1 Google Cloud：AlloyDB AI

AlloyDB AI 已提供：

- pgvector 兼容向量存储；
- ScaNN 向量索引；
- 注册 Google、OpenAI、Anthropic、自托管模型端点；
- SQL 内生成 embedding 和调用 prediction；
- 自然语言生成 SQL；
- `ai.if`、`ai.rank`、`ai.generate`、`ai.summarize` 等 AI 算子。

[AlloyDB AI 总览](https://docs.cloud.google.com/alloydb/docs/ai)、[模型端点与状态](https://docs.cloud.google.com/alloydb/docs/reference/model-endpoint)

**上线判断：** 向量检索和基础模型端点管理已可用；多模态、`ai.if/rank/generate` 等多项函数仍明确标注 Preview。Google 的技术亮点是让自然语言条件进入 filter、join 和 order，而不仅是查询前后调用一次模型。

### 6.2 Microsoft：Azure SQL 与 SQL MCP Server

Azure SQL/SQL Server 2025 提供向量类型、`AI_GENERATE_EMBEDDINGS` 和文本 chunk 函数；Fabric 还提供 `AI_GENERATE_RESPONSE`、分类、抽取、摘要等函数。[AI Functions](https://learn.microsoft.com/en-us/sql/t-sql/functions/ai-functions-transact-sql?view=sql-server-ver17)

更有代表性的是 SQL MCP Server：

- 基于 Data API Builder；
- 只暴露配置过的表、视图和存储过程；
- 提供类型安全的 CRUD/aggregate 工具；
- 继承 RBAC、缓存和 OpenTelemetry；
- 故意不支持自由 NL2SQL，而是让 Agent 调用确定性实体 API。

[SQL MCP Server](https://learn.microsoft.com/en-us/azure/data-api-builder/mcp/overview)

**上线判断：** SQL MCP Server 已随 DAB 1.7/2.0 提供，可自托管或部署到 Azure Container Apps。它代表一条重要安全路线：模型负责意图，数据库工具层负责生成确定性 SQL。

Azure Cosmos DB 的 Agentic Retrieval Toolkit 会进行“初次检索→识别信息缺口→生成子问题→再次检索→综合答案”，但官方明确标注 **Preview、无 SLA、不建议生产使用**。[Cosmos DB Agentic Retrieval Toolkit](https://learn.microsoft.com/en-us/azure/cosmos-db/gen-ai/agentic-retrieval)

### 6.3 Oracle：Select AI

Oracle AI Database/Autonomous AI Database 的 Select AI 支持：

- 自然语言生成、执行和解释 SQL；
- RAG 和向量检索；
- LLM Chat；
- SQL/PLSQL 接口；
- 在数据库内使用 ONNX embedding 模型；
- 将数据库 schema 和数据作为生成上下文。

[Select AI 总览](https://docs.oracle.com/en/database/oracle/oracle-database/26/selai/select-ai-about.html)、[Select AI RAG](https://docs.oracle.com/en/cloud/paas/autonomous-database/serverless/adbsb/select-ai-retrieval-augmented-generation.html)

**上线判断：** Select AI 已进入正式数据库版本和 Autonomous Database 产品体系，但具体能力取决于数据库版本、云服务形态和 AI Provider。

### 6.4 Snowflake：Cortex Agents

Cortex Agents 已于 **2025-11 GA**。它把：

- Cortex Analyst：结构化数据和语义模型；
- Cortex Search：非结构化检索；
- LLM：规划、综合与反思；

组合成完整 Agent。Agent 会拆任务、路由工具，并在每次调用后判断是否需要澄清、继续迭代或输出。[Cortex Agents GA](https://docs.snowflake.com/en/en/release-notes/2025/other/2025-11-04-cortex-agents)

Snowflake 还提供 GA 的 Cortex AI Functions，使 SQL 对表中文本和图片执行抽取、分类、过滤、生成和分析；个别函数仍是 Preview。[Cortex AI Functions](https://docs.snowflake.com/en/user-guide/snowflake-cortex/aisql)

**参与层级：L2/L5。** 在已公开产品中，它是最接近“数据平台原生推理 Agent”的完整实现之一。

### 6.5 Databricks：Agent Memory、AI Search 与研究型 Knowledge Agent

Databricks 提供：

- AI Search/原 Vector Search 作为 Agent 检索工具；
- Genie 访问结构化数据；
- Agent Framework 部署和治理 Agent；
- Inference Tables 自动保存请求、响应和 traces；
- Lakebase 保存自管理的短期/长期状态；
- Managed Agent Memory。

截至 2026-06，**Managed Agent Memory 标注为 Beta**，自管理方案使用 Lakebase，并可接入 LangGraph 或 OpenAI Agents SDK。[Databricks Agent Memory](https://docs.databricks.com/aws/en/agents/agent-framework/stateful-agents)

Databricks Research 的 KARL 则通过强化学习训练 Knowledge Agent 使用向量搜索，提升证据获取和跨来源综合；但论文明确表示当前只使用一个 Vector Search 工具，结构化检索、代码执行和组合子 Agent 属未来方向。[KARL](https://www.databricks.com/karl.pdf)

**上线判断：** Agent Framework、AI Search 和轨迹表可用于生产；Managed Memory 仍 Beta；KARL 是研究成果，不能按产品能力宣传。

## 七、已上线与未上线能力清单

### 7.1 已正式商用或 GA

| 厂商 | 能力 | 参与推理方式 |
|---|---|---|
| 阿里 | ADB PostgreSQL RAG Service | 文档处理、Hybrid Retrieval、Rerank、LLM |
| 腾讯 | TencentDB Agent Memory | 推理前召回、推理后沉淀、跨会话记忆 |
| AWS | Aurora + Bedrock Knowledge Bases | 向量/混合检索提供上下文 |
| AWS | Aurora ML / Redshift + Bedrock | SQL 内调用模型 |
| AWS | Structured Data Knowledge Bases | NL2SQL 查询结构化数据 |
| AWS | Neptune GraphRAG | 向量召回 + 图遍历 |
| AWS | AgentCore Memory | 短期和长期 Agent 记忆 |
| Snowflake | Cortex Agents | 结构化/非结构化工具规划与反思 |
| Snowflake | Cortex AI Functions | SQL 内模型调用 |
| Oracle | Select AI | NL2SQL、RAG、Chat |

### 7.2 可用但官方未明确 GA

| 厂商 | 能力 | 需要核验 |
|---|---|---|
| 阿里 | PolarDB-X AI Function | 地域、模型、配额、费用和 SLA |
| 阿里 | DMS MCP | 自托管/托管边界、审批和写权限 |
| 阿里 | PolarDB Agent Express 知识空间 | 开通范围、价格和 GA 状态 |
| 腾讯 | PostgreSQL `tencentdb_ai` RAG | 支持版本、地域、网络和模型费用 |
| Microsoft | SQL MCP Server | 自托管运维责任和后端兼容范围 |
| Google | AlloyDB 基础模型端点和向量能力 | 具体函数逐项状态不同 |

### 7.3 Preview、Beta、内测或 Coming soon

| 厂商 | 能力 | 当前状态 |
|---|---|---|
| 阿里 | PolarSearch | 邀测 Preview |
| 腾讯 | DatabaseClaw/数据库 AI 服务总产品 | 内测 |
| AWS | AWS Context | Coming soon |
| AWS | AgentCore Runtime Managed Session Storage | Public Preview |
| Google | AlloyDB `ai.if/rank/generate` 等部分 AI Functions | Preview |
| Microsoft | Cosmos DB Agentic Retrieval Toolkit | Preview、无 SLA |
| Databricks | Managed Agent Memory | Beta |
| Databricks | KARL Knowledge Agent | Research |

## 八、值得关注的技术趋势

### 8.1 AI Function 进入 SQL

阿里 PolarDB-X、腾讯 PostgreSQL、Aurora/Redshift、AlloyDB、Azure SQL、Oracle、Snowflake 都在把模型能力封装为 SQL 函数。

下一步竞争点不会只是“能不能调用模型”，而是：

- 优化器是否知道 AI Function 的成本；
- 能否批量调用、缓存和去重；
- 能否先用普通谓词缩小数据集；
- 非确定性函数如何参与物化视图和事务；
- 模型版本变化如何影响结果可复现性；
- 是否提供 token、延迟和调用费用的 EXPLAIN/审计。

### 8.2 从 NL2SQL 转向受控工具

AWS 仍提供托管 NL2SQL，但明确建议只读和沙箱；Microsoft SQL MCP Server 则主动拒绝自由 NL2SQL，使用实体 API 和确定性 Query Builder。

这反映了两种路线：

```text
开放式路线：问题 → LLM 生成 SQL → 校验 → 执行
受控式路线：问题 → LLM 选择工具和参数 → 确定性 Query Builder → 执行
```

复杂分析偏向开放式路线，生产写操作更适合受控式路线。

### 8.3 Agent Memory 成为独立数据库品类

腾讯 Agent Memory、AWS AgentCore Memory、Databricks Managed/Lakebase Memory 已经把记忆从应用代码提升为平台能力。

未来竞争点包括：

- 记忆抽取准确率；
- 冲突和时态更新；
- 可追溯到原始事件；
- 用户可查看、修改和删除；
- 多 Agent 共享范围；
- 记忆压缩后的信息损失；
- 数据驻留和租户隔离；
- 根据任务自动选择 KV、全文、向量或图检索。

### 8.4 Agentic Retrieval 取代固定 Top-K

PolarDB Agent Express、Cosmos DB Toolkit、Snowflake Cortex Agents 和 AWS GraphRAG 都不再把检索视为一次性动作，而是允许：

- 查询改写；
- 生成子问题；
- 多路检索；
- 判断证据是否充分；
- 根据缺口继续检索；
- 跨结构化和非结构化数据路由。

这会提升复杂问题能力，但也引入查询次数失控、成本放大和循环终止问题。

### 8.5 组织级语义与上下文层

AWS Context、Snowflake Semantic Model/Cortex Analyst、AlloyDB 自然语言接口、Databricks Genie 都在解决同一问题：数据库 schema 本身不足以让模型理解业务。

真正的 Agent 数据层还需要：

- 指标定义；
- Join 路径；
- 同义词；
- 数据血缘；
- 权限；
- 历史正确查询；
- 业务规则；
- 数据质量和时效信息。

## 九、对数据库产品设计的启示

如果要设计自己的“数据库参与推理”能力，建议分四步，而不是直接做一个全能 Agent。

### 阶段一：安全数据工具

- 提供只读 MCP/API；
- 暴露经过挑选的视图和存储过程；
- 强制用户身份和行级权限；
- 记录工具参数、SQL、结果摘要和调用者；
- 支持超时、扫描量和返回行数上限。

### 阶段二：库内 AI Function

- 先支持 Embedding、Rerank、Extract、Classify；
- 再支持 Generate 和 Text-to-SQL；
- 建立批处理、缓存和预算控制；
- 让 `EXPLAIN` 展示模型、预计调用次数和费用；
- 将远程模型函数默认标记为 volatile/non-deterministic。

### 阶段三：Agent 状态和记忆

- 保存 task、step、attempt、checkpoint；
- 区分用户事实、系统验证事实和模型推测；
- 支持 TTL、版本、删除和来源追踪；
- 大对象卸载到对象存储；
- 提供 LangGraph/OpenAI Agents 等标准连接器。

### 阶段四：Agentic Retrieval 与验证

- 自动选择 SQL、全文、向量和图查询；
- 支持多轮检索但设置预算；
- 用数据库规则验证关键结论；
- 对模型生成 SQL 做 AST、权限和成本检查；
- 将失败轨迹沉淀为回归集。

## 十、采购或竞品验证清单

面对厂商“AI 原生数据库”“Agentic Database”宣传，建议逐项要求演示：

1. 能力是 GA、正式计费、Preview 还是只存在于博客？
2. 模型推理在数据库进程内、AI 网关还是外部服务执行？
3. 数据是否离开 VPC、地域或数据库服务边界？
4. SQL 扫描 100 万行时会触发多少次模型调用？
5. 能否限制每条 SQL 的 token、模型费用和并发？
6. 模型调用失败时，SQL 和事务返回什么状态？
7. NL2SQL 是否只读，是否有 AST、EXPLAIN 和扫描量限制？
8. Agent 是否继承真实用户权限，还是共享超级账号？
9. Memory 如何处理冲突、过期、删除和错误事实？
10. 是否能看到完整的工具调用、引用、模型和 Prompt 版本？
11. Agentic Retrieval 如何防止无限循环和重复查询？
12. 厂商公布的效果来自公开 benchmark、内部测试还是客户生产数据？

## 十一、最终判断

### 对阿里

阿里已经不是只提供向量数据库，而是在把 `LLM + Embedding + Rerank + Text-to-SQL` 变成数据库 SQL 能力，并进一步构建 Agentic RAG。产品创新速度快，但 2026 年新增功能较多，GA、邀测和新文档能力需要逐项核实。

### 对腾讯

腾讯最值得关注的是 Agent Memory 已独立商业化，以及 PostgreSQL 一条 SQL 完成完整 RAG。DatabaseClaw 虽然产品形态完整，但官方仍标注内测；应把它与已经正式计费的 Memory 分开评价。

### 对 AWS

AWS 的数据库参与推理体系最完整、状态最清晰：Aurora 做向量和模型函数，Redshift 做结构化数据与批量 AI，Neptune 做 GraphRAG，DynamoDB 做 checkpoint，AgentCore 做记忆。AWS Context 尚未上线，但可能成为未来最关键的组织级上下文层。

### 横向判断

如果以“数据库真正进入推理循环”的深度排序，而不是单看向量能力：

1. **Snowflake Cortex Agents、AWS Bedrock+Neptune/Redshift、腾讯 Agent Memory** 已形成明确产品闭环；
2. **阿里 PolarDB AI Function/Agent Express、Google AlloyDB AI** 在库内模型函数方向更激进；
3. **Microsoft SQL MCP Server** 在生产安全和确定性执行上最值得借鉴；
4. **Databricks Managed Memory、Cosmos Agentic Retrieval、AWS Context** 代表下一波仍在 Beta/Preview/Coming soon 的能力。

## 参考资料

### 阿里云

- [AnalyticDB PostgreSQL RAG Service 商业化公告](https://www.alibabacloud.com/help/doc-detail/2851620.html)
- [PolarDB-X AI Function](https://help.aliyun.com/zh/polardb/polardb-for-xscale/ai-function)
- [DMS MCP](https://help.aliyun.com/zh/dms/use-cases/deploy-dms-mcp)
- [PolarSearch 邀测状态](https://www.alibabacloud.com/help/en/polardb/polardb-for-xscale/what-is-search-engine)
- [PolarDB Agent Express 企业知识空间](https://www.alibabacloud.com/help/en/polardb/polardb-for-postgresql/what-is-an-enterprise-knowledge-space)

### 腾讯云

- [TencentDB Agent Memory](https://cloud.tencent.com/document/product/1813/132100)
- [Agent Memory 正式计费公告](https://cloud.tencent.com/product/events/detail/7188)
- [TencentDB PostgreSQL tencentdb_ai RAG](https://cloud.tencent.com/document/product/409/133911)
- [腾讯云数据库 AI 服务产品概述及内测状态](https://cloud.tencent.com/document/product/1813/122696)
- [DatabaseClaw 实现原理](https://cloud.tencent.com/document/product/1813/130681)

### AWS

- [Aurora PostgreSQL 作为 Bedrock Knowledge Base](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraPostgreSQL.VectorDB.html)
- [Bedrock Knowledge Bases 结构化数据检索](https://aws.amazon.com/about-aws/whats-new/2024/12/amazon-bedrock-knowledge-bases-structured-data-retrieval/)
- [Bedrock Knowledge Bases GraphRAG GA](https://aws.amazon.com/about-aws/whats-new/2025/03/amazon-bedrock-knowledge-bases-graphrag-generally-available/)
- [DynamoDB LangGraph Checkpoint](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/ddb-langgraph-checkpoint.html)
- [AWS Context Coming soon](https://aws.amazon.com/blogs/machine-learning/context-intelligence-for-your-data-and-ai-agents-at-scale/)

### 其他厂商

- [Google AlloyDB AI](https://docs.cloud.google.com/alloydb/docs/ai)
- [Microsoft SQL MCP Server](https://learn.microsoft.com/en-us/azure/data-api-builder/mcp/overview)
- [Azure Cosmos DB Agentic Retrieval Toolkit](https://learn.microsoft.com/en-us/azure/cosmos-db/gen-ai/agentic-retrieval)
- [Oracle Select AI](https://docs.oracle.com/en/database/oracle/oracle-database/26/selai/select-ai-about.html)
- [Snowflake Cortex Agents GA](https://docs.snowflake.com/en/en/release-notes/2025/other/2025-11-04-cortex-agents)
- [Databricks Agent Memory](https://docs.databricks.com/aws/en/agents/agent-framework/stateful-agents)
