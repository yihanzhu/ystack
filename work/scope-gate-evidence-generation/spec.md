---
intent-blob: 2aa4196fe3adc89837f4dfdebc197017d6e2f753
risk: high
drafted: 2026-10-23
---

# Spec：生成并消费同一 scope attempt 的真实 gate 证据

Tracks #681。对应父 `step8-bounded-write-readiness/spec.md` R8 child 9。

| 顺序 | 输入与责任 | 输出 |
| --- | --- | --- |
| 1 | 固定 consumer 持有 scope basis，认证当前 child-5 bundle | 实际 request、profile、result、policy set |
| 2 | consumer 冻结 claim，创建新 source request 和 expectation | 当前调用独占的 nonce 与请求摘要 |
| 3 | 同一可信 source 边界读取控制仓库当前默认分支 | 真实 register、完整修订历史与来源 receipt |
| 4 | 调用已有 duty、risk、kill evaluator | 原样保留三份实际输出 |
| 5 | 填入 scope 的 gate refs，调用已有 scope evaluator | inactive evaluation 与完整绑定记录 |

## R1. 唯一生成与消费路径

1. 增加一个固定的 scope gate consumer。它负责生成和立即消费三份输出。
   register 验证、投影和 source 调用只服务这条路径。
   不增加第二套 verdict 逻辑、通用 provider 框架或独立 schema 产品。
2. 入口接收一个 canonical `scope_gate_generation_request`、现有 shadow set、
   dashboard、marker、完成的 child-5 bundle root 和 bare Git snapshot。
   request 是 schema 1，使用通常的 `schema_version/kind/id/body` envelope。
   body 恰有 `scope_basis` 和 `risk_claim`。claim 是现有完整 claim 文档。
   basis 是完整 `workflow_scope` 文档，仅省略 `body.gate_evidence_refs`。
   其余字段与当前 scope contract 相同；不是任意模板或 JSON patch。
3. consumer 只补 `gate_evidence_refs`。不得修改 scope id、身份、revision、
   paths、risk、coverage、shadow refs 或任何许可字段来使结果通过。
   最终 scope 必须通过现有 `workflow-scope.jq`，再交给 `evaluate-scope.sh`。
   既有 scope evaluator 是唯一 scope 决策器。
4. 原低层 evaluator 的显式文档输入保持兼容。它们仍只证明原有 identity-only
   关系。手工传入三份 verdict 不构成此 consumer 的真实生成证明。
   新入口不接受 risk/duty/kill 输出、register 文件、source receipt、端点、
   executable、provider、credential、trust flag 或 fixture 开关。
5. 本 concern 不执行 stage，也不重跑 target。它评价已认证的实际 stage attempt。
   新 source 请求是本次 gate 调用；不能把它称为新的 target 执行。
   全部结果保持 inactive、observation-only、authority none、enabled false。

## R2. 实际输入与当前请求所有权

1. 复用 child-5/#541 的固定 bundle reader、controlled-store origin、receipt、
   accepted environment、Git 和 materialization 检查。#558 的 M3 工作树仅是
   未验收的实现依赖。其集中验收欠项不因本 spec 或测试通过而消失。
2. 从被 scope 的 `shadow_evidence_refs` 与 qualified identity 精确命中的当前
   bundle 读取 `materialization-input.json` 内的 stage request 和 resolved profile；
   从 `materialization-response.json` 读取实际 stage result；从 bundle 的
   `policy-set.json` 读取 policy set。保留实际 canonical bytes。
   不取 prerequisite 的 duty/result 冒充本次 materialization。
3. 当前所需各 environment 的 bundle 必须指向同一 stage request、profile、
   result 和 policy set。存在多组或缺少唯一组时拒绝，不能任选一份。
   验证 request/profile/result 的 public-core 关系、scope 自己的 request/profile
   refs、repository、workflow、stage、result id 和实际 materialization refs。
4. claim 只是原有 `unqualified-input-claim`。冻结其输入字节并运行原 risk
   evaluator 的全部 claim 检查，包括 request basis、policy、required gates、
   decision ref、角色、时间和 classification。不能补造 accept 或提高来源资格。
   缺失/错误 decision 的原有 violated/inconclusive 含义必须保留。
   不改实际 stage request 的 `gate_decision_refs` 来适配另一个 claim。
5. 用 consumer 私有目录和 held descriptors 冻结 basis、claim、四份 stage 输入、
   shadow/dashboard/marker、bundle 与运行包。原始输入在结束前须重新核对。
   其 canonical 编码、大小、唯一根、无重复键、文件类型及稳定性检查不能放宽。
6. 在 source 启动前，由 consumer 生成 32 字节 OS 随机 nonce 和唯一调用 id。
   写入并 fsync canonical `kill_register_source_request` 与 expectation 及目录。
   保留只读 descriptors；返回 payload 不能建立或修改 expectation。
7. request 绑定 operation/version、调用 id、nonce、scope basis 与 claim 摘要、
   当前四份 stage 文档 refs、所有其他输入摘要、已认证 bundle/origin refs、
   固定运行包及 accepted-source-set refs。repository 分为 target repository
   与 source 配置固定的控制仓库，不能用 target 的 register 替代控制仓库。
   expectation 包含全部这些绑定及完整 request SHA-256。
8. 每次调用必须有新 nonce，即使 stage/result 完全相同。source store attempt id
   等于调用 id。返回 request 必须逐字相同。receipt、origin 和所有事实均须
   匹配 held expectation。旧真实 receipt、复制目录和 caller 摘要不能通过。
   nonce 不改写原 stage id/result id，也不冒充 operator authority epoch。

## R3. 固定 source 与当前默认分支

1. 沿用已接受 `scope-coverage-authentication/spec.md` R3–R5 的 root-owned
   anchor、专用 supervisor principal、consumer group、controlled store、
   immutable package 与 accepted source identity 边界。复用其有限 source 机制，
   仅增加私有只读 `kill-register-read.v1` 操作，不复制 trust root。
   不改变 core forge capability、resolved-profile binding、duty 或 stage 权限。
2. root-owned 的可选 source 配置固定控制仓库不可变身份、操作、collector/package
   摘要、accepted identity 和 operator bootstrap 锚点。bootstrap 锚点绑定
   child 7 经 operator 合并的初始 commit、register 原始摘要、revision、epoch
   和 owner 身份。调用方不能提供或选择这些值。生产值在本 concern 中缺席。
3. source 自己读取当前默认分支身份和 tip，并取得 tip 内固定路径
   `config/kill-switch.json` 的原始字节、Git blob/tree/commit 关系。
   读取结束前再次查询相同默认分支 tip；两次必须一致。
   consumer 不以本地 `origin/main`、历史 commit、cached response 或 caller bool
   证明当前 tip。不允许源数据缺失时退回 Git 工作树文件。
4. source 同时取得从 bootstrap 到该 tip 的完整 first-parent commit/register
   变化链、默认分支 ref 事件历史和相应 operator merge 事实。ref 历史须连续，
   拒绝任何非 fast-forward、删除重建或分支身份变化，包括回退到 bootstrap 的
   后代后再前进。仅有当前 commit 的祖先链不能证明没有回退。
   每次 register 改动必须归属于经固定
   owner 授权合并的 PR，并与实际 commit、父提交、路径和 blob 一致。
   direct push、未授权 actor、非后代、缺页、重写、来源含糊均拒绝。
   不能仅比较两端内容来漏掉 A→B→A。
5. source receipt 是 schema 1 `kill_register_source_receipt`。其 body 恰含
   operation/version、store/call id、request SHA-256、source identity、query、
   raw manifest/observation 摘要、supervisor 记录的 start/end UTC、outcome 和 effects。
   query 绑定固定控制仓库、默认分支不可变身份、bootstrap 和两次 tip。
   outcome 仅 `complete` 可消费；effects 仅只读 metadata/register，无授权效果。
6. 复用 source inventory：最后写入 `receipt.json`；payload 内只有 request、
   raw manifest、observation 和连续编号 raw pages。manifest 绑定 query family、
   页码、cursor 链、status、size 和 raw SHA-256。每个必需 family 完整终止。
   固定 normalizer 从 held raw pages 重建 observation，逐字比较。
   observation 闭合表达 R3.3–4 的仓库、分支、tip、Git 字节和合并历史事实。
7. 复用既有 owner/group/mode/ACL、no-follow、链接、exact inventory、held
   descriptor 和前后 metadata 检查。caller/consumer 无权写 source store。
   每次产生新的 origin observation；归档 origin 只能证明关系，不能证明新读取。
   receipt 标签、sha 相等和同 UID 临时文件均不能替代来源认证。
8. 每页最多 1 MiB，最多 128 页，总 raw 最多 64 MiB；request、receipt、manifest、
   observation 各最多 1 MiB。超限拒绝，不截断。沿用 source 固定截止时间和子进程
   收割规则；任何未确认停止都不能输出成功。完整读取后到消费前再核对 held source
   对象。该事实只代表本次 source 观察结束时的 tip，不承诺未来一直不变。
9. 缺少 source 配置、collector、accepted identity 或 child-7 bootstrap 时，
   生产路径失败关闭。此项不建立 production provider，不安装 source，不联网。
   后续真实使用仍需原专门授权。publisher 前和 post-write 的新读取属于 child 11；
   此次观察不能被缓存为它们的许可。

## R4. Register 验证与确定性投影

1. register 是 canonical schema-1 `kill_switch_register` envelope。
   body 恰含 `revision`、`authority_epoch`、`entries`、`write_entries`。
   revision 是 1..9007199254740991 的整数；epoch 为现有 id 语法。
   固定 owner 由认证的 bootstrap/source 身份证明，不由 register 自称。
2. entries 每项恰含 `scope_kind/scope_id/state`，仅 global/repository/workflow；
   global id 为 `*`，其余是有效 id，state 为 cleared 或 stop。
   write_entries 每项恰含 `scope_id/state`，scope_id 是 workflow id。
   两组各最多 1024 项，按身份排序且唯一。不能有 stage/attempt 或未知字段。
   匹配当前 global、repository、workflow 的观察 entry 各须恰有一项。
3. 从认证 bootstrap 检查每次 register 变化：revision 必须严格增加。
   原字节未变的连续 commit 和同一 tip 的新读取可以保留同一 revision。
   相同 revision 改字节、revision 降低、丢失重建、历史回退或不完整历史均拒绝。
   epoch 必须等于已授权 bootstrap epoch；epoch 改变需另行 operator 决定和
   新锚点，本 concern 不自动接受或重置 revision 下界。
4. consumer 只读 entries 来产生观察投影。选择当前三项并增加当前 stage/attempt
   两项。两项来自本次 consumer 的活动状态，不能取 caller 的 cleared 声明。
   健康且未停止的本次调用初始化为 cleared；一旦取消、失败或 stop，不能复用
   该调用恢复为 cleared。真实 register 的任何 stop 原样保留。
5. 投影为现有 schema-1 `kill_switch_state` 的封闭扩展：原字段不变，增加
   `register_ref`，其形状为现有 document ref，绑定 register 原字节 SHA-256。
   state.revision/authority_epoch 等于 register；attempt_id 等于实际 stage result id。
   state entries 恰为五种 scope，无重复、缺失或外来 scope。
   evaluator 保留原未投影 state 的低层兼容性，但此 consumer 只接受新投影形状。
6. 生成 `kill_switch_attempt`：scope 的 repository/workflow/stage 从实际请求取得，
   attempt_id 从实际 result 取得；expected_state 绑定刚生成的 state id、revision
   和实际 SHA-256；authority_epoch 保留原值；duty ref 指向本次真实 duty 输出。
   kill evaluation 的 state/attempt refs 与这些字节逐项验证。
7. observation cleared 不意味着 write cleared。验证 write_entries 形状，但不把
   它用于观察 verdict。缺失或 stop 的 write entry 仍禁止写。本 consumer 不产生
   write admission，不清 stop，不写 register，不给任何 agent 清除权。

## R5. 求值顺序和消费绑定

1. 在同一 frozen workspace，先实际调用 `evaluate-duty.sh evaluate`，输入实际
   policy-set/request/resolved/result。再调用 `evaluate-risk-gates.sh evaluate`，
   传同一四份输入、本次 duty 和冻结 claim。保留 risk 内部重新生成 duty 后的
   逐字比较及 runtime closure 验证，不能用另一份预制 duty 绕过。
2. 按 R4 生成 state/attempt，再实际调用 `evaluate-kill-switch.sh evaluate`，传
   同一 policy-set、state、attempt、duty。三个入口及被固定引用的依赖均须测量并
   前后核对。不得直接执行 jq 绕过 driver 校验，不替换 evaluator 程序。
3. 保留实际 verdict 和全部 reason_ids。risk 仍只会产生 inconclusive/violated。
   不添加 satisfied，不削弱 claim、策略、duty、kill 或 scope 的任何判定。
   生成完成意味着得到真实输出，不意味着 scope proposable 或可启用。
4. 按实际输出字节计算三个 refs，补入 basis，形成完整 scope。其余字节含义必须
   与 basis 一致。对当前 request/profile/result/policy 和两个 duty 摘要交叉引用
   做完整检查后，把这些原字节交给既有 `evaluate-scope.sh`。
   保留 scope 的全部现有 gate、shadow、环境、coverage、risk、eval 和 mode 检查。
5. source request 绑定生成前 basis，最终记录绑定生成后的完整 scope，避免摘要环。
   输出一个完成包：完整 scope、三份 evaluation、state、attempt、实际四份输入、
   claim、source request/expectation/receipt/origin 和最终 scope evaluation。
   一个 canonical manifest 列出每项实际大小和 SHA-256，另绑定 basis 与运行包。
   不把 manifest 当来源证明。完成标志在全部校验和子进程收割之后最后写入。
6. 实际 malformed、unreadable、source/关系失败、输入漂移、runtime 漂移、超限、
   timeout、signal、非零退出或未确认 reap，均为非零失败且不留下完成包。
   不伪造 kill violated 来掩盖 source 未认证，也不把失败输出当部分可用证据。
   形状合法且真实 evaluator 返回 inconclusive/violated 时保留完整结果，交给
   scope 原判定；不把这种 policy 结果改成程序执行失败或成功许可。
7. 新入口设一个 300 秒总 deadline，子调用只使用剩余时间。保留依赖更短的限制。
   deadline 包括 source、三 evaluator、scope 和清理。只停止自己拥有的进程；
   收割不确定时关闭输出。plan 固定启动、取消与清理实现，不追加诊断工程。

## R6. 必须完成的证明

1. 离线正向测试调用同一 consumer、source operation、实际三个 evaluator 和
   scope evaluator。fixture 是独立的离线控制仓库：固定 source package 保存原始
   commit/branch/operator-merge 页和 register bytes，caller 不能选择或改写它们。
2. fixture 沿用 root-owned configuration、专用 source writer 和不同的只读
   consumer principal/group。source 真正写受控 store；consumer 跑完整来源检查。
   不以 same-UID 临时目录、mock origin、伪造 verdict 或永久拒绝充当正向。
   它只证明协议实现，不证明生产来源、operator bootstrap 或 native qualification。
3. 新增 setup、账号、sudoers、管理员命令或 source 执行不由 G2 授权。
   只在已有准确授权的 disposable 环境运行。否则准备完整 fixture 和准确命令，
   把真实正向保留到集中验收。不得把 blocked/skipped 称为 passed。
   当前 Mac 不安装账号、sudoers、source 或配置。
4. 正向证明真实 duty/risk/kill 的顺序、参数和摘要，以及完整 scope 消费。
   至少覆盖真实 risk inconclusive 和 violated；按现有政策验证最终 scope 结果。
   证明 scope basis 只增加三个 refs，输入 request/profile/result 不被重写。
5. 逐项替换 request、profile、result、policy、claim、duty、state、attempt、输出、
   scope 或运行包均须拒绝。测试同 stage 的第二次 fresh source 请求成功，第一次
   genuine receipt 重放失败；多组 bundle、旧 attempt、late expectation 也须拒绝。
6. register 测试覆盖三层 stop、缺项、重复、错误 scope、观察 cleared 且无 write
   entry、write stop 不改观察 verdict、epoch 不符、非法 revision、同 revision 改字节、
   降 revision、删除重建、A→B→A、非后代、非 operator merge 和 bootstrap 不符。
7. source 测试覆盖错误仓库/分支、两次 tip 移动、旧 tip、缺页/cursor、原始字节
   或 normalizer 变更、复制 receipt、未接受身份、owner/group/mode/ACL/link/metadata
   换包、超限、deadline、signal、子进程存活和清理失败。每个拒绝证明无完成包。
8. 保留 control、scope、core stage/profile/duty、child-5 consumer、receipt/source
   和相关集成测试。新 restore-critical 文件进入 manifest，文档说明低层兼容边界。
   plan 必须列准确路径、命令和完整测试映射。规定 CI 和独立审查仍是硬门槛；
   quick CI 不能替代真实正向、完整安全证明或规定 milestone 的 full matrix。

## 范围、依赖与计划门槛

本次只交付 inactive 仓库实现与测试。用户的 implementation-first 决定仅调整
实施顺序；#558 全部欠项最后集中验收。#544/source 与 child 7 的真实使用依赖
仍须分别验收，不把它们的设计记录视为已实现或已安装。

不改 `config/**`，不提交 register，不增加 production provider/credential/network，
不安装、启用、运行真实 target、执行 publisher 或 production 动作。
child 7 bootstrap、child 11 三处写前后流程和 child 12 activation 不在本 concern。
#412、#183 和未获处置的 dirty attempt 保持原边界。

风险为 high。实现之前必须有单独接受的 high-risk plan。plan 选择最小准确文件集，
说明必要的 decision/hash closure 更新，并依据实际代码和完整测试估计 review size。
不得为猜测行数缩减安全检查、测试或可读性。作者和独立审者继续分开。
