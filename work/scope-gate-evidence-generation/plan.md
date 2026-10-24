---
spec-blob: 22f98a8e45f662bdb13338cd5ecb24276b8953e7
drafted: 2026-10-23
---

# Plan：生成并消费同一 attempt 的 gate 证据

Tracks #681。risk 为 high。计划先单独接受，再实施。结果始终 inactive、
observation-only、authority none、enabled false。#558 的欠项最后集中验收。

| 阶段 | 实际执行者 | 必须保留的证据 |
| --- | --- | --- |
| 冻结 | 新 gate consumer 和现有 bundle reader | 当前 materialization 四份输入、basis、claim、全部非 store holds |
| 首次 source | 现有 supervisor 的固定 kill-register-read | 新请求、独占 nonce、真实 register 和完整历史 |
| 求值 | 现有 duty → risk → kill driver | 实际原字节、顺序、参数、运行包与摘要 |
| scope 消费 | 现有 evaluate-scope 和私有 reader | 全部既有检查；必要时运行 coverage source |
| 完成 | gate consumer 作为最终 hold owner | 全部 attempts 的 fresh authentication、manifest、最后写入的完成标志 |

## 依赖门槛与源码映射

设计基线为 main `cf50464bbc771eb9d1e5b6f39d8b761c917e0bc0`。
intent blob 为 `2aa4196fe3adc89837f4dfdebc197017d6e2f753`。
G1 为 #682，G2 为 #685。main 已包含两份历史 policy plan，尚未包含下列实现。

| 保留依赖 | 精确身份与状态 |
| --- | --- |
| M3 foundation | `fe6593e1b09960d165f0a5b0b3db555f06f182eb`；未合入、未验收，全部原 #558/#541 proof 保留 |
| #544 source 映射点 | `787fbbf2799d22bc557ea957395c72fb40072c86`；原 `codex/impl/scope-coverage-authentication` 的 clean 检查点；source ACCEPT，未合入，G3 BLOCKED |
| #544 intent | `d2ada8661ac87c6c9f1abfc8a751a38c8aeb33cf`；与当前 main 一致 |
| #544 plan / spec | `1237c85af242ea15b8a930938a1863baaf606078` / `618928cb8cb30a4ad95d8b39dc3126cd806c5444`；artifacts 已 protected merge，不能代表实现通过 |
| child-5 intent | `6feb2ad7dd5f096bdd483ed9bace07cae2c24be5`；与当前 main 一致 |
| child-5 plan / spec | `ebfc9e1d2c661cab78f87a9b9c2fa82116195310` / `fb1bbec3d8c0fd2bba0a6353da05bf03107e97a4`；artifacts 已 protected merge，不能代表 producer proof 通过 |

本检查点的独立 R1 原始结论为 `Source-verdict: ACCEPT`、Important 0。
原两项 P1 的源码缺口已关闭：必需测试覆盖已补齐，历史 policy 反例已隔离 publisher
关系。依赖状态严格为 `SOURCE_COMPLETE_WAITING_GENUINE_PROOF`。
经理已全文读取报告与逐项 map，并记录在
[#544 源码接受记录](https://github.com/yihanzhu/ystack/issues/544#issuecomment-6377638423)。
报告 SHA-256：`6733f12c06ffaa086c857cba690fe1e319b20833ebdd236975d89ee3fba2d13b`；
map SHA-256：`52bef1fa08b06408c59a737e23af39c889dfa9a61eaaddc52aab3a5d02786bef`。
parent `130efa00deddbb829dbe3a64e611948329604119` 保留普通 merge 历史。
十个映射 source/helper 原字节未变；R1 完整 delta 和六份 artifact 链已核。
全部真实 proof 仍 PREPARED / NOT RUN，G3 BLOCKED、foundation 未合入。
此源码接受可供提前 inactive 实施的计划采用，不单独授予 implementation GO。

| 实际接口（787fbbf） | 私有接线与必须保留的关系 |
| --- | --- |
| `_Reader.__init__`、`evaluate`、`fixed_bundle`、`_authenticate` | 拆分固定的 bundle 认证阶段供新 consumer 复用；保留 owned、inputs、package_sources、anchor 与 Git owner，不复制 reader |
| `_authenticate` → `git_relations` → `write_relations` → `_authenticate(frozen)` | 原始 materialization candidate/manifest/launch subject/expectation/receipt/checker 全链；递归 prerequisite 同样产生 store holds，必须登记和重新认证 |
| `write_relations`、`rebuild_input` | 新 `withheld-write-policy.v1` 精确 33-file candidate、outer policy ref/raw、Git policy blob 与 rebuilt input；旧 32-file 规则不变 |
| `coverage_identity`、`source_coverage` | policy 从各自 bundle 得到；两侧 ref/raw 完整有效，historical=current=evaluator-held policy 才进入 coverage；不回填当前包伪造历史 |
| `_HeldStoreRead`、`_HeldCoverageRead` | 全 held path 与祖先、exact inventory、snapshot、fresh observation；包括同 attempt 的每个 acquisition 和递归 prerequisite |
| `_CoverageConfiguration`、`read_coverage_attempt` | 同一 anchor 的 root-owned config/package/accepted identity；supervisor/normalizer 原字节与仓库测量一致；held raw 重建 observation |
| `_DarwinChildOwner.coverage_source`、`_closed_scope_child`、`_foreground` | 既有固定 sudo/Python/supervisor argv、command ledger、process-group owner 与唯一 reap；新增固定 kill 方法和私有事件交接 |
| `_CoverageInstallation`、`_coverage_collector`、`run_coverage_read` | 固定安装准入、105 秒 collector、nonce claim、durable store 与 receipt-last；扩展两个 literal 操作，不复制 source |
| reader `main`/`_ControlFIFO` 与 scope driver | 当前 `READY/SEAL/COMMIT` 在 driver 返回前关闭 reader；新增 outer 接管确认，仍真实运行原 scope 求值 |

reader blob 为 `118f010b8540e1bb79c28ee9cf42a618de731a63`，shared consumer 为
`013bf3ec67a282722e8817716cd9a7412d65cd00`，coverage normalizer 为
`f360d6155f0ed58594b357340f3b3437907aa3f2`，host supervisor 为
`1c75e28c49a7ac182f71bb381f5c621acf69c770`。它们固定本次已完成源码预审的依赖对象，不证明运行或合入。

当前 `source_coverage` 在 durable request 后只关闭自己 owned 中的
`_HeldStoreRead`，随后重认证 qualifying/current；没有 outer registry/handoff。
`_foreground` 当前 close_fds 且只泵 stdin/stdout/stderr，没有新私有通道。
下文的共同 owner、kill operation、通道和 deadline 交接全部是待实施改动。

| 门槛 | 允许的下一步 |
| --- | --- |
| 源码依赖准备 | 精确 787fbbf 为 SOURCE_COMPLETE_WAITING_GENUINE_PROOF；原两 P1 源码缺口关闭，真实 proof 与未合入状态保留 |
| 计划接受 | 复核原 carrier 的精确 787fbbf clean tuple、上列 raw 接受与源码映射；本 plan 仍须 fresh 独审和 protected merge |
| 提前 inactive 实施 | 在获接受的计划与经理明确 build tuple 下，采用精确保留依赖准备本 concern 代码/tests；不要求把 source 预审称为 G3 或已合入，不替代任何原 proof |
| foundation 与 #544 合入 | #558/#541 全部原标准先闭合并 protected merge；#544 按自身计划完成全部 proof、实际 diff 审查、CI 与 protected merge |
| #681 最终发布/G3 | 原实现 carrier 普通 merge 含上述实现的精确 main，核完整 diff/允许路径/尺寸，重新 exact-head/base 独审和 CI，完成本 spec 全部证明 |

本 plan 独审须核对已绑定的完整相关 source/helper 与原始 R1 接受，不以测试摘要
替代。核对 source head、parent/base、两条 artifact chain、文件 blobs/SHA-256，
逐项核上表的全部 store 取得/释放点、closed argv、ledger、source request/receipt、
raw schemas、fresh origins、private protocol 和 fixture。测试-only delta 也须独审，
不能自动继承原 REVISE 结论或把测试文件存在当 PASS；接口语义改变则先修订计划。

最终合入基础后，计算 main→head 的完整 diff，不扣除 inherited 行数来满足预算。
若仍含未合入 foundation，停止 #681 发布，不扩大预算包揽依赖。
无 reset/rebase、重建 attempt 或死 shim；不借等待先落无 consumer 的 schema。
本 concern 不修改 #544 producer 或接手其运行验收；改动若需要超出本允许集，返回计划门槛。

## 精确改动范围与交付

实施 PR 仅允许下列路径。计划 PR 只改本 `plan.md`。

| 路径 | 允许的变化 |
| --- | --- |
| `scope/v1/generate-gate-evidence.py` | 新的固定 consumer、冻结、投影、四个 driver 调用和完成包 |
| `scope/v1/read-shadow-evidence.py` | 提取供 consumer 复用的当前 bundle 读取阶段；私有双 source handoff、最终重新认证 |
| `scope/v1/evaluate-scope.sh` | 保持现有公开参数；传递私有生命周期通道和剩余 deadline；保留真实 jq 判定 |
| `scope/v1/workflow-scope.jq` | 共用现有 shape 检查，增加仅供新 consumer 使用的 basis 检查；完整 scope 规则不变 |
| `shadow/v1/_consumer.py` | 固定 kill 配置/attempt 读取、child owner 的封闭调用和私有协调；复用 held-path 规则 |
| `sandbox/v1/coverage-source.py` | 同一有限 source 模块中的 kill request/config/receipt/raw normalizer；保留 coverage 规则 |
| `sandbox/v1/host-supervisor.py` | 增加固定 `kill-register-read` 分支，复用安装、collector、nonce、store 与 cleanup |
| `control/v1/kill-switch.jq` | state 的封闭 `register_ref` 扩展，保留旧低层形状与原判定 |
| `control/v1/kill-switch-decision.json` | 只更新实际 program 摘要 |
| `control/v1/control-policy-set.json`、`control/v1/control-policy-set-sandbox-bound.json` | 只更新 kill decision 的传递摘要 |
| `scripts/test/scope-gate-generation.test.sh` | 新 consumer 的纯解析、投影、关闭参数与普通 hermetic 测试 |
| `scripts/test/scope-qualification.test.sh` | 在现有 genuine fixture 中加入完整单/双 source 路径和全部破坏场景 |
| `scripts/test/control-kill-switch.test.sh` | 新旧 state 兼容、stop 优先级、摘要绑定回归 |
| `docs/components.md`、`RESTORE.md`、`ci/required-files.txt` | 入口、inactive 边界、运行条件、恢复清单与证明命令 |

实现采用一个完整 consumer 交付。`review_size: accepted-exception`，预计净变更
3,000–5,200 行，仅适用于 foundation 与 #544 正式合入后的本 concern 完整 diff。
依据当前 reader 1,109 行、source normalizer 481 行及
#544 source 接线约 1,294 行新增，预计 production glue/normalizer 约占一半，
完整同合同 fixture 和破坏用例约占另一半。复用现有 16,452 行的 scope 测试基础。
不复制其中账号、ACL、安装和收割框架。若完整实现超出范围，先保留 clean attempt，
另行计划修订与独审；不压缩代码、裁剪测试或用空 schema PR 分割行数。

不改 `config/**`、workflow、安装脚本、VM launch receipt、capability、profile、
duty/risk 决策算法、生产 accepted set 或历史归档证据。不写 register、清 stop、
运行 target、publisher、部署或激活。CPU/wall 为 NONE，native 为 BLOCKED，
production 为 EMPTY，automation 为 PAUSED。普通测试结果不改变这些状态。

## 固定入口与输入提取

新入口只有以下位置参数；额外、缺少、重排或未知 operation 均拒绝：

```text
python3 -I -S -B scope/v1/generate-gate-evidence.py generate REQUEST SHADOW_SET DASHBOARD MARKER BUNDLE_ROOT SOURCE_GIT_DIR OUTPUT_DIR
```

输出目录必须不存在，父目录为调用者持有的物理目录；exclusive 创建 mode 0700。
路径不授予信任。拒绝链接、别名、与 bundle/Git/package 的嵌套或重叠。
入口先清理继承的非必要环境和描述符，再创建自己的私有目录、通道和进程 owner。
生产调用不接受 provider、source 路径、register、receipt、verdict、信任开关或 fixture 参数。

request 为 canonical schema-1 `scope_gate_generation_request`，body 仅
`scope_basis/risk_claim`。每个原始输入最多 1 MiB；嵌入后的总 request 也受此限。
复用重复键、单根、canonical UTF-8、深度、文件类型和稳定性检查。
basis 的检查复用 `workflow-scope.jq` 的同一字段谓词，只允许缺少 gate refs。
不要通过虚构三份 refs 让完整 scope validator 先通过。

在 `_Reader` 中分离当前 bundle 解析/认证与后续 coverage/输出阶段。
保留 `fixed_bundle` 的 owner 生命周期和 `_authenticate` 的递归前置认证。
每个实际取得的 store 对象立即登记：role、attempt、store identity、frozen snapshots、
non-root metadata、认证输入和全部 derivation refs。相同 attempt 的 aliases 不得漏登记。
新 consumer 调用同一固定函数，保留它的全部 relation 检查；不能仿写简化 reader。
仅从 scope 当前 refs 和 qualified identity 唯一命中的 bundle 提取：
`materialization-input.json.stage_request.content`、`.resolved_profile.content`、
`materialization-response.json.stage_result` 及 `policy-set.json`。
先验证 stage_request/resolved_profile 两个 content pair 的完整 wrapper、declared SHA
与 canonical content bytes，再取原子文档交 driver，不能把 pair wrapper 当 request。
验证原 envelope 与 public-core request/profile/result。
所有 required environments 必须指向同一四元组。缺一、多组、旧 attempt 均拒绝。
不得拿 prerequisite result/duty，或改变 `gate_decision_refs` 适配 claim。

consumer 持有原 request、basis/claim、四份输入、shadow/dashboard/marker、bundle、
bare Git、anchor、配置、accepted set、运行包和全部派生私有文件到完成。
冻结的 basis/claim 无 authority；risk driver 仍完整处理 unqualified claim。
source 前用 `os.urandom(32)` 创建 nonce，call id 为 `kill-register.` 加 nonce hex。
请求、expectation、父目录均先 fsync，再以只读 descriptor 持有。

kill request 的闭合 body 为 operation/version、call_id/nonce、target_repository_id、
固定 control repository identity、basis_ref、claim_ref、四份 stage refs、
shadow/dashboard/marker refs、bundle refs、初始 core origin refs、Git observation 摘要、
运行包 ref、source package/accepted-set refs 与 bootstrap ref。
expectation 逐项保留完整绑定，并增加 request SHA-256；不得从返回值建立 expectation。
call id 等于 source store attempt id；stage result id 保持原值。

## 固定 kill source

扩展既有有限 source 边界；固定命令仅为：

```text
/usr/bin/sudo -n -u #SOURCE_UID -- P -I -S -B ANCHOR/host-supervisor.py kill-register-read
COLLECTOR kill-register-read.v1
```

SOURCE_UID、consumer group、store/work root 来自现有 held host configuration。
P 为既有测量过的物理 Python。consumer 的具体 child owner 新增一个固定方法；
`_closed_scope_child` 只接受上述完整 argv，不接受调用方 argv/provider/callback。
复用 coverage 的 sudo、Python、supervisor 前后测量和 command ledger。
角色为 `kill-register-source-boundary`，记录 request、argv、三个 executable 摘要。
环境仅 PATH=/usr/bin:/bin、LC_ALL=C、LANG=C。stdout 为零，stderr 上限 16 KiB。

在同一 anchor 下增加可选固定 sibling 名称 `kill-register-source-config.json` 和
`kill-register-source-accepted-identities.json`。生产文件缺席即非零关闭。
不扩大 host-config schema，不新增安装根。配置固定 operation、source/package/
collector/normalizer/query schema 摘要、控制仓库不可变 id、默认分支不可变 id 和
bootstrap。bootstrap 固定 child-7 operator merge 的 commit、register SHA-256、
revision、epoch、owner identity，以及完整 ref 历史的起始事件边界。
accepted row 必须逐项匹配既有 source identity 边界；空、重复、foreign 均拒绝。
控制仓库与 target repository 分开比较，不取 target 的同名文件。

将 `_CoverageInstallation`、collector lifecycle 和 source payload writer 的共同部分
保留在原模块内，以内部两个 literal operation 分支调用。没有外部可扩展注册表。
不要再复制一个 supervisor/collector launcher。coverage 的原字段与判定逐字兼容。新 consumer 的 coverage request 采用闭合扩展，
增加 `initial_origin_refs` 和 `gate_call_ref`，分别绑定创建请求时全部 core/kill
观察和本次 kill request。对应 expectation 保留全部字段与 request 摘要。normalizer
按旧完整形状或该扩展完整形状校验；本 consumer 只接受后者，不接受混合/部分扩展。
低层 scope 的原请求形状继续工作，但不声称新 consumer 的生成证明。
相同模块的 kill normalizer 只读 held raw，不联网、读 caller 文件或动态载入 provider。

固定 raw query families 及 schema 1 如下；每族必须从页 0 到唯一 terminal cursor：

| family | 必需事实与闭合 |
| --- | --- |
| `repository-default-branch` | 固定仓库/分支不可变身份；读取前后 tip、对应观察时间及共同读取边界 |
| `first-parent-register-history` | bootstrap 到 tip 每个 commit 的原始 commit bytes、parent/tree 关系；固定路径的 tree proof 和原始 blob bytes，包含未修改 register 的 commit |
| `default-branch-ref-history` | bootstrap 起始事件到本次末尾边界的连续事件序号/cursor、before/after ref、actor、动作与时间；连续性由固定 source 的完整历史合同给出 |
| `operator-merges` | 每次 register 变化对应唯一 PR 不可变 id、base/head/merge、实际 parents、路径/blob、合并 actor 与固定 owner 授权事实 |

使用既有 binary frame，record 0 为 capture，后续 `raw/0000` 连续编号。
capture 不得带 normalized facts、receipt 或身份。supervisor 自算 manifest 的 family、
page、cursor、status、size/SHA-256。限制为每页 1 MiB、128 页、raw 总计 64 MiB；
request/receipt/manifest/observation 各 1 MiB。缺族、额外字段、非成功 status、
缺页、重复、乱序、cursor 环、截断或超限全部拒绝。

normalizer 从 raw 重建同一 observation。Git 对象按仓库算法验证 object header/size/
bytes 的 OID；树证明必须精确走到 `config/kill-switch.json`。遍历完整 first-parent
区间，bootstrap 与终点均一致。ref 事件逐次连接，必须覆盖同一完整观察区间。
删除重建、分支换身份、任何非 fast-forward、回退后恢复、事件缺口均拒绝。
不能以当前 ancestry 或两次 tip 相同替代 ref 历史。每次 register 字节变化必须唯一
匹配 operator merge 事实；direct push、unknown actor、模糊或缺失证明拒绝。
同一 tip 的新读取仍须新 source 请求。数据源无法提供完整历史时关闭，不假设完整。

复用 exclusive create、nonce claim、source principal/consumer group、0440 files、
0750 dirs、每层 fsync 和 receipt-last。inventory 只有 receipt、payload/request、
raw-manifest、observation、连续 raw pages。receipt 为 `kill_register_source_receipt`，
body 仅 operation/version、store_id/call_id、request_sha256、source_identity、query、
raw_manifest_sha256、observation_sha256、started_at/completed_at、outcome、effects。
query 绑定仓库、分支、bootstrap、两次 tip 和四族；outcome 只能 complete 被消费；
effects 仅只读 metadata/register。nonce 通过完整 request 摘要绑定，不自证身份。
consumer 重跑 normalizer 并逐字比较，再验证 request/expectation 与真实 fresh origin。

## 两次 sibling 与 hold 所有权

私有 handoff 使用 consumer 自建 anonymous socketpair。固定 child method 只把一端
交给 `evaluate-scope.sh`，driver 再交给自己的 reader；不开放 CLI/环境 provider。
通道采用有限、定长上界的 canonical 帧，含版本、call id、随机 session nonce、
消息序号、当前阶段和 frozen binding 摘要。每帧最多 1 MiB；重复、越序、EOF、超时拒绝。
在新 consumer 内定义唯一私有 `_GateStoreSession`，由 outer 持有状态机和全部
acquisition 清单。inner 的本地 descriptors 是其登记子集；每次取得、重核、释放、
接管均按同一有限协议确认。这个 owner 不提供公共 callback、通用 store API 或权限。
通道只协调生命周期，不能认证来源或代替任何 receipt/origin 检查。
外部伪造通道至多使求值失败；不能省略认证或提升 verdict。公开低层无通道时保持原协议。

| 阶段 | store holds 与动作 |
| --- | --- |
| P0 | outer 用现有 reader 完整认证 current 及递归 prerequisite core；登记每个实际 acquisition 与 frozen byte/object/non-root metadata。全部 provisional |
| K_REQUEST | kill request/expectation durable 后，outer 完整 recheck；释放自己的所有 store-root acquisitions，保留非 store holds；失败即停止 |
| K_DONE | source 成功且确实 reap 后，outer 完整重认证所有 core 和 kill source；比较 frozen bytes/对象/关系，取得 fresh origins。需要 coverage 时仍 provisional |
| C_REQUEST | inner 正常认证 qualifying/current 及其递归 prerequisites，先登记到同一 owner；生成并 fsync coverage request/expectation。发送请求绑定与完整闭包，outer 对照实际认证输入核对 |
| C_RELEASE | outer 与 inner 各自完整 recheck。outer 先释放其全部登记 core/prerequisite/kill acquisitions 并确认；inner 再 recheck 并释放其全部登记 acquisitions。清单必须归零后才启动 coverage source |
| C_DONE | source 确实 reap；inner 完整重认证 qualifying/current、全部递归 prerequisites、coverage 和交接的 core/kill。outer 按同一闭包重新取得全部 attempts，重复完整认证和 frozen 比较 |
| FINAL_OWNER | outer 的全部 final acquisitions 建立后确认接管；inner 仍持有自己的 final reads 到原 SEAL/COMMIT，不能在 outer 成功接管前关闭 |
| COMPLETE | scope driver 完成、退出且 reap 后，只有 outer 持有最终全部 acquisitions。outer 核对所有输出、原输入、运行包和 holds，最后写完成标志，然后释放 |

没有 coverage 时，K_DONE 就是 outer final acquisition。inner 不创建 source；仍完整
执行原 scope authentication，并在普通 SEAL 后关闭。outer 在整个 scope 调用中保留 holds。
有 coverage 时，outer 通过同一 reader 的实际 full-authenticate 阶段取得最终 qualifying/
current facts；不能仅比较 inner 帧或重读 receipt。kill 的 final acquisition 也重新跑
配置、request、receipt、manifest、raw normalizer 与关系验证。

每个 acquisition 持有期间 root metadata 比较完全不变。合法 sibling 只允许两次
acquisition 之间 root metadata/fresh origin 变化。完整闭包包括 writer 的 frozen prerequisite；不能只比较返回的 current row facts。
每个已使用 attempt 的对象身份、
非 root metadata、全部非 origin 原字节及关系必须匹配最早冻结值；改后稳定也拒绝。
root identity、安全配置、owner/group/mode/ACL 不得借重取更换。
初始 origin refs 永远留在两份已冻结请求中；manifest 分别列出初始和 final fresh refs，
按 attempt、receipt/payload 摘要一一对应。不得重写旧 request 或沿用旧 origin。
final 之后禁止第三次 sibling。任意 root/core/source 变动都不能留下完成标志。

修改 `_Reader.evaluate` 以复用认证结果，而非重复执行 source；source 状态只能单向
推进。所有 `_HeldStoreRead` 派生类型、递归 prerequisite 与同 root aliases 都登记到
同一 `_GateStoreSession`；原 reader owned 保存对应本地责任，release 必须同步移除。
禁止只遍历某一已知 subtype 而漏掉 kill/core hold。非 store 持有列表永不在 source
交接时关闭。最终 owner 的 close 在完成标志 durable 后执行；失败路径先撤销完成资格。

## 投影与实际 evaluator 调用

register 是 spec R4 的严格 canonical envelope。revision 为安全整数 1..2^53−1，
epoch 必须与 bootstrap 相同。entries/write_entries 各最多 1024，按身份排序唯一。
仅 global/repository/workflow 三层；global id 为 `*`。write scope_id 必须解释为
`workflow_scope.id`，不是 workflow_id。当前三层各恰有一项。
每次 register 原字节变化 revision 严格增加；相同 revision 改字节、降低、缺失重建、
A→B→A、bootstrap 不符都拒绝。不接受自动 epoch reset。

consumer 私有投影保留三层 state，再从本次未取消、未失败的活动状态加入 stage/attempt。
任何失败或取消后本次 call 都不能恢复 cleared。state body 只增加 `register_ref`，
其 revision/epoch 与 register 相等。attempt_id 是实际 stage result id。
attempt 的 repository/workflow/stage 来自真实 request；expected_state 绑定 state
id/revision/原 SHA-256；duty ref 绑定刚生成的真实 duty。
write entries 只验证形状，不改变观察 verdict，不产生 write admission。

由固定 child owner 按顺序实际运行下列命令。运行包包括 driver、程序、policy、decision、
validator 和选中的 public-core closure，调用前后逐项重测。记录闭合 argv 与顺序。

```text
/bin/bash -p control/v1/evaluate-duty.sh evaluate POLICY_SET REQUEST RESOLVED RESULT
/bin/bash -p control/v1/evaluate-risk-gates.sh evaluate POLICY_SET REQUEST RESOLVED RESULT DUTY CLAIM
/bin/bash -p control/v1/evaluate-kill-switch.sh evaluate POLICY_SET STATE ATTEMPT DUTY
/bin/bash -p scope/v1/evaluate-scope.sh evaluate SCOPE SHADOW_SET DASHBOARD RISK KILL DUTY MARKER BUNDLE_ROOT SOURCE_GIT_DIR
```

risk 的 duty 再生成和逐字比较保留。risk 仍仅 inconclusive/violated。
固定 runner 不提供任意 argv，不直接调用 jq 代替三个 driver。
输出核对 policy/request/profile/result、两份 duty 引用、state/attempt refs 与 SHA-256。
只给 basis 增加实际三份 gate refs，删除该字段后与原 basis canonical bytes 相同。
完整 scope 必须通过原 validator，并送入原 scope driver；所有原判定保留。
合法 violated/inconclusive 不是运行失败，也不意味着 proposable。
source/输入/关系/runtime 失败必须非零，不能伪造一个 kill verdict 掩盖失败。

修改 `kill-switch.jq` 后以脚本计算实际 SHA-256，依次更新 kill decision 与两个当前
policy sets。保持其他字段逐字不变。duty/risk driver、policy 与 decision 不需改变。
consumer 不补改 bundle 内旧 policy set；不匹配当前 closure 的历史 bundle 应拒绝。
fixture 用当前包重新生产真实 bundle，不能 patch 完成的 receipt 或归档证据。
若新接受的依赖增加其他 restore-critical/hash closure 文件，先修改 plan 允许集再实施。

完成包包含 request/basis/claim、完整 scope、四份 stage 输入、三 evaluation、
state/attempt、kill request/expectation/receipt、raw manifest/observation/pages、
必要 coverage 请求及证据、初始与最终 origins、scope evaluation 和运行包摘要。
manifest 列全部对象的相对名、实际 size/SHA-256；不能自列摘要形成环。
最后的 `COMPLETE.json` 绑定 manifest SHA-256。它不是授权或来源证明。
全部输出 exclusive 创建、fsync；失败保留的诊断材料没有 COMPLETE，不能被消费。
不输出半成品成功帧。清理失败或未确认 reap 都不允许 COMPLETE。

## 同一个总 deadline

consumer 入场即设 monotonic deadline = start + 300 秒。所有 driver、source、reader、
IPC 和清理只使用这个 deadline 的剩余量。私有交接传 absolute deadline 并取更短上界，
不能在新 reader 或 source 返回后重置。保留 source 120 秒、collector 105 秒等更短限制。
预留最多 10 秒给 TERM→KILL→唯一 reap；无足够剩余预算时不启动新子进程。
现有 `_foreground` 用局部 timeout 和独立 10 秒 cleanup，本接线须将它们上界
收紧到同一 outer deadline；保留原低层调用语义，不能把继承 deadline 延后。
复用具体 `_DarwinChildOwner._foreground` 的进程组清理；增加固定 scope 调用的
双向事件泵以响应上述帧，不启动第二套通用 runner。
终止仅针对自己登记的 child/process group。SIGINT/TERM/HUP、非零、超限、坏帧、
子进程存活或 cleanup 不确定统一撤销完成资格。超时后仍报告未收割，不谎称已停止。

## 测试与验收

新增 pure suite 自动由现有 `run-all.sh` 发现；不改 runner 或 workflow。
真实正向扩展现有 `scope-qualification.test.sh` 的固定 genuine fixture。
source package 内保存独立离线控制仓库的原始 Git/ref/merge 页；控制仓库不同于 target。
fixture root owner 固定 collector/pages/config；调用者不能选 raw pages 或期待身份。
沿用专用 source writer、不同 consumer uid/group、root-owned anchor 和真实 store。
仅在已有准确授权的 disposable 环境，扩展原 fixture 的精确 sudo 命令 allowlist，
仍逐项验证多余/缺少/重排参数、环境赋值、shell、launch、collector 直呼全部被拒绝。
consumer 对 store 的写、chmod/link/rename/remove 必须全部拒绝。
当前 Mac 不安装账号、sudoers、source/config；没有环境就准备 fixture 并记 NOT RUN。

| 证明 | 必须执行的用例 |
| --- | --- |
| 真实完整链 | 同一 consumer/source/三个 driver/scope；risk inconclusive 和 violated；记录真实顺序、参数、输出 digest；scope basis 只增加 refs |
| 当前请求 | 同 stage 第二次新 nonce 成功；第一份 genuine receipt 重放失败；旧 attempt、多组 bundle、late expectation、分别替换四输入/claim/duty/state/attempt/output/scope/runtime 均拒绝 |
| register | 三层 stop 与既有 stop 优先级；缺项、重复、错 scope、非法 revision/epoch；同 revision 改字节、降 revision、缺失重建、A→B→A、非后代、非 owner merge、bootstrap 错误 |
| 写观察分离 | observation cleared 且无 write entry；write stop 不改变观察结果；同 workflow 不同 scope id 不共享 write clearing |
| 原始来源 | 错仓库/分支、tip 移动、旧 tip、ref 回退后恢复、direct push、缺页/cursor、坏 Git proof、raw/normalizer 换包、复制 receipt、未接受身份 |
| holds 与两 source | 真正 kill 和 coverage 两次 sibling 完整正向；provisional release 后改旧 payload 再稳定拒绝；final 后改 root/core/kill/coverage 任一对象拒绝 |
| 交接 | 旧 origin、漏一 attempt、漏 outer hold、提前 close、乱序/重复/伪造帧、错误 owner、第三次 sibling 全部拒绝；两份原 request 的 initial origins 不变，manifest 用 final fresh origins |
| 安全与生命周期 | owner/group/mode/ACL/link/metadata 逐项破坏；nonce claim 冲突；frame/page/total 超限；timeout/signal/非零/存活 child/cleanup 失败；全部无 COMPLETE |
| 兼容 | 原无 register_ref state、低层显式 inputs、旧 reason_ids/优先级；原 scope/core/receipt/coverage/child-5 所有测试保留 |

pure 用例只能证明解析/投影/封闭参数，不得把 mock origin、同 UID 或永远拒绝叫真实正向。
真实双 source 测试必须检查最终 bundle 没有 target write、publication、grant 或 activation。
late mutation 测试用现有 fixture 的 READY 控制点，不增加生产 test flag 或新诊断工具。

准确命令如下。先核对各测试使用的已存在 jq 1.6 cache SHA；缓存缺失则该项 NOT RUN，
不得让本地脚本下载或替换 pin。纯 Python 测试不需要 jq 的部分照常运行。

```sh
bash scripts/test/scope-gate-generation.test.sh --pure
bash scripts/test/scope-qualification.test.sh --coverage-pure
bash scripts/test/control-kill-switch.test.sh
bash scripts/test/control-duty-separation.test.sh
bash scripts/test/control-risk-gates.test.sh
bash scripts/test/control-foundation-rollup.test.sh
bash scripts/test/portable-core-schema.test.sh
bash scripts/test/local-git-materializer-protocol.test.sh
bash scripts/test/local-git-materializer-adapter.test.sh
bash scripts/test/sandbox-receipt.test.sh
bash scripts/test/sandbox-launcher.test.sh
bash scripts/test/shadow-enforced.test.sh
bash scripts/test/shadow-write.test.sh
bash scripts/test/shadow-self-host-evidence.test.sh
bash scripts/test/scope-qualification.test.sh
bash scripts/test/run-all.sh
```

后两条及任何 genuine fixture 命令只在准确获授权的 disposable 环境运行。
保存每条命令的 head、平台、退出码和完整输出；blocked/skipped 不计 PASS。
保留 #558 的 CPU/wall/native 未闭合状态。普通 Linux CI 的 genuine protocol 通过，
也不能称 native qualification 或 macOS 正向通过。
现有 CI 可在 exact implementation head 派发六 shard full matrix，记录每个 shard、
checks、aggregate ci 和外部 required checks；不新增 workflow。quick CI 单独记载。

计划本身只做 hash/路径/history/diff 检查。实施还须运行 `git diff --check`、结构清单
检查与 pinned shellcheck 0.11.0 的 `-x -S style`。新入口和新 test 加入恢复清单一次；
列明运行包中既有 source 文件，保持可恢复性。检查无任何未允许路径或 production 值。
独立 reviewer 按 Bugs/Security/Compliance 三轮阅读完整 exact-head/base diff 和原始证明。
所有 Important 解决后，经理按当前 Roadmap 委托记录 accepted tuple。
最终 protected merge 与 G3 还须满足上表的 foundation/#544 合入和本 concern 全部证明，
不能仅凭 inactive 代码准备或源码预审提前发布实现 PR。
若运行授权或 genuine proof 未闭合，准确保留集中验收欠项；不以本计划、普通测试、
quick green 或合并记录替代 #558 最终验收。
