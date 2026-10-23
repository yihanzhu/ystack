# Intent：为同一 scope attempt 生成并绑定真实 gate 证据

Tracks #681。范围是父 `work/step8-bounded-write-readiness/spec.md` R8 child 9。

| 交付 | 保留的门槛 |
| --- | --- |
| inactive 的真实 gate 生成与消费路径 | 真实来源、独立审查、准确 head/base 和规定 CI |
| 同一路径内的 register 验证与 attempt 投影 | operator 独占 stop 清除权；观察与写入许可分开 |
| 离线实现与测试证明 | child 7 bootstrap、真实使用和激活仍待原专门授权 |

## 问题

`control/v1/` 已有 risk、duty、kill evaluator。
`kill-switch.jq` 使用调用方提供的 state，不读取共享 register。
`scope/v1/scope-gates.jq` 会检查输出身份及相互摘要。
这些检查尚不能为 scope 自己的 `stage_request_ref` 生成真实证据。
它们也不能证明 register 来源。
仅拼装 fixture verdict，或新增没有真实调用方的 schema，不能补上这个缺口。

## 目标与成功标准

交付一个保持 inactive 的调用路径。
它复用三个现有 evaluator，为同一 scope attempt 生成 risk、duty、kill 输出。
必要的 register 验证和投影属于该路径内部。
输出必须交给已有 scope 消费边界。

成功须满足以下条件：

- 使用同一实际 stage request、resolved profile、stage result 和 policy set。
  三份输出绑定当前 attempt、scope 自己的请求及彼此的真实摘要。
  拒绝混合输入、旧 attempt 和被替换的输出。
- 按父 R5.4 投影 register。绑定其 SHA-256 和严格递增的 revision。
  保留 authority_epoch，并增加当前 attempt 的 stage/attempt 状态。
  观察仅读 entries。观察 cleared 不授予写入许可。
  缺少 write entry 仍不允许写。任何 agent 都不能借投影清除 stop。
- 保留父 R5.3–6 的来源真实性、当前默认分支 tip 鲜度和失败关闭要求。
  缺失、不可读、畸形、回退或来源含糊时，不能产生供真实 scope 使用的 cleared 证据。
  历史提交、调用方摘要和临时 fixture 不能冒充当前来源或 operator bootstrap。
- 离线临时 fixture 运行同一生成与消费路径，调用实际 shipped evaluator。
  证明完整输出关系、投影、拒绝行为和兼容性。
  原样保留 evaluator 的 inconclusive/violated，不改策略制造 satisfied。
  fixture 成功只证明实现，不证明生产来源、native qualification 或启用资格。
- 原有控制、scope 和相关集成测试继续通过。
  新 restore-critical 文件进入 manifest。不扩诊断工程。

## 受影响的系统

现有 `control/v1/` evaluator、scope 消费边界及相关测试。
operator 仍拥有 kill switch；作者、审者和后续 publisher 的职责继续分开。
本 concern 复用现有策略和求值语义，不建立第二套 evaluator 或泛用 schema 服务。

## 边界与顺序

当前经理直接收到的用户决定允许先完成剩余仓库实现与测试，保持 inactive。
该决定已由 PR #680 记录。#558 全部验收欠项保留，最后集中闭合。
这只调整实施顺序，不降低标准，也不证明任何依赖已交付。
提前开展 inactive 实现须按原 artifact 修订程序记录。
父 child 7 先于 child 9 真实使用的门槛继续保留。

child 7 仍须按原专门决定提交 `config/kill-switch.json`。
operator 为 owner，观察 entries cleared，任何 scope 都无 write entry。
实际 config 提交、默认分支来源启用和 operator bootstrap 不在本 concern 内。
缺少这些事实时，生产路径继续失败关闭。不能因此关闭 child 7。

本 concern 不改 `config/**`，不提交 register，不建立已启用 scope。
不实现 child 11 publisher/post-write 调用或 child 12 激活。
不安装、不使用真实网络、不执行或写入 target。
不增加 credential、admin、profile 启用、release、deployment 或生产动作。
不清理或替换旧 attempt。#412、#183 和 dirty credential plan 保持原边界。

本 intent 仅定义目标与边界。
后续仍须独立 G2、单独 high-risk plan、实现审查与规定 CI。
安全控制和证据绑定使本 concern 按 high 风险进入 G2，风险由 G2 正式接受。

## G2 待解决的问题

- 准确输入从哪里取得？怎样确认它们属于当前 scope attempt？
- 三个 evaluator 按什么顺序运行？怎样保持生成与消费绑定同一请求？
- register 怎样与当前请求绑定？怎样验证来源、当前默认分支 tip 和 revision，拒绝回退与重放？
- 来源或依赖未就绪时，怎样失败关闭，同时让离线 fixture 证明同一实现路径？
- 公共 API、字段、来源协议、准确文件范围和完整证明是什么？
  这些由 G2 与 plan 决定，本 intent 不预选。
