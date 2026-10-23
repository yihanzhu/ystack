---
spec-blob: 618928cb8cb30a4ad95d8b39dc3126cd806c5444
risk: high
drafted: 2026-10-23
---

# Plan: authenticate later-revision scope coverage

Tracks #544. Risk is high. This is the mandatory second delivery of Step 8 child
6. It implements the complete parent R3 later-revision rule for the fixed write
workflow and task. The accepted #541 core remains the exact-revision foundation.
Both deliveries must pass before child 6 completes or child 7 starts.

Implementation PR: `review_size: accepted-exception`, 3,600–5,400 net changed
lines. This range applies to the final #544 diff against a main that already
contains the separately accepted and protected-merged foundation. Count that
actual diff in full; do not subtract unmerged inherited files to fit this range.
It does not cover or authorize publication of M3. This is one end-to-end coverage
authentication concern. The preserved
#544 checkpoint adds 2,464 net lines over its M3 foundation. The producer portion
adds an estimated 600–1,100 lines. Reader integration, paired policy tests, and
completion of the existing damage proof supply the remaining range. These are
estimates, not targets. Preserve readable code and all required tests. A material
overrun returns through the separate plan amendment gate before more code.

## Preserved carrier and pre-code gate

本修订只闭合历史 policy 的生产与消费。意图 blob 保持
`d2ada8661ac87c6c9f1abfc8a751a38c8aeb33cf`，风险保持 high。
唯一实现 carrier 是 `codex/impl/scope-coverage-authentication`，工作树为
`/private/tmp/ystack-coverage-impl-20261023`。暂停的 clean head 是
`44c8ded3ad850767cfd7bb469aecb4d182e8784e`。保留其 M3 基础
`fe6593e1b09960d165f0a5b0b3db555f06f182eb`、原 claim 和全部实现历史。
原 Sol 6.1 / medium 作者在此 carrier 完成一次 producer → reader → coverage
实现。不得另建 producer 实现分支、PR、intake 或替代 attempt。

M3 是保留的未验收依赖，尚未合入当前 main。当前 carrier 相对 main 的 diff
同时包含 inherited foundation 与 #544 自身改动，不能当作上面预算内的可发布
#544 diff，也不能把 inherited 源码视为已接受。本修订只提前 inactive 代码与
测试准备；不提前 foundation 的验收、发布或 G3。

| 阶段 | 必须满足的边界 |
| --- | --- |
| 提前实现 | 两份 plan 通过下述 gate 后，在原 carrier 修改本 concern 的允许路径。保留 inherited foundation；其授权、完整源码审查、测试与验收仍属于原 #558/#541 gate。 |
| foundation 合入 | 先完成 #558/#541 的全部原标准和 required proof，经其自身独审、CI 与 protected merge 合入 foundation。普通测试或本文档不代替任何原缺项。 |
| #544 最终发布与 G3 | 原 carrier 普通 merge 届时精确 main，保留全部历史。重核 artifact hashes、实际 diff 的完整 allowlist 与整体尺寸，取得 fresh exact-head/base 独审和 CI，并完成 #544 全部证明，才可发布实现 PR、通过 G3 或合入。 |

最终 diff 若仍含未合入的 foundation 内容，停止发布；不得扩大本预算包揽 M3，
也不得复制、重建或另开实现来隐藏该内容。foundation 自身修订在其原 gate
完成；本 plan 不授权在 carrier 改写那部分。后续普通 merge 若产生超出本
concern 的冲突，暂停协调原 foundation gate，不自行扩大下列路径或语义。

生产契约来自已合并的 child 5 spec blob
`fb1bbec3d8c0fd2bba0a6353da05bf03107e97a4`。对应 producer plan 已独审 ACCEPT，
PR #690 尚待受保护合并。其
head `4a9fdf72466e5599521f7d9964187dd87aa6c0f3`、base
`604a3d28cf5222be72220a343ded85b2a87eb7b4`、plan blob
`ebfc9e1d2c661cab78f87a9b9c2fa82116195310`，不能据此宣称已合并或已实现。
该 plan 定义生产步骤与生产测试；本 plan 定义共同 carrier、完整路径并集、
消费步骤与端到端证明。其六个 producer 路径只是责任子集；其尺寸估计只是分项。
同一实现 PR 仅使用上面的整体尺寸声明。

两份 high-risk plan 必须各自独审并受保护合并，才能继续代码。若 producer
plan 的契约改变，先修订本引用并重新审查。经理记录包含两份 plan 的最新
default OID、各自 intent/spec/plan blob、风险、原 carrier head、claim 和 clean
状态。旧 GO 不继承。base 再变时先 fresh review/reaffirmation，不能直接开工。
由原作者普通 merge 该精确 main 到原 carrier。不得 reset、rebase、覆盖旧状态。
源码冲突只能在下列已接受路径内解决；语义超出两份契约即暂停并返回相应 gate。
恢复前再核对三向闭合：main 的上游 blob、两份 plan 的 hash link、carrier
实际合入的 artifact bytes 全部一致。每轮记录新 exact head/base 和独审 round。

## Files that change

The plan PR changes only this file. The following union allowlist permits only
this concern's own changes on the preserved carrier. It does not authorize its
inherited foundation changes or replace their separate gate. After that foundation
lands, the final #544 diff against the merged main must contain only these paths:

- `scope/v1/read-shadow-evidence.py` — extend the #541 private reader with the
  qualifying/current pair, evaluator-owned request, fixed source launch, source
  attempt read, and measured coverage observation.
- `scope/v1/evaluate-scope.sh` — retain the nine-argument public command, hold
  the private workspace and pass the closed internal observation to jq.
- `scope/v1/workflow-scope.jq` — admit the exact coverage block only for the
  fixed write workflow and task.
- `scope/v1/scope-gates.jq` — validate the internal coverage observation and
  apply identity, history, age, current-binding, and invalidation rules.
- `scope/v1/scope-policy.json` — add only `scope.enablement-stale` to the closed
  reason vocabulary if #541 has not already added it.
- `sandbox/v1/host-supervisor.py` — add the one fixed `coverage-read` operation,
  source admission, bounded collector lifecycle, source receipt, and durable
  exact-inventory write.
- `sandbox/v1/coverage-source.py` — new private schema and normalizer for the
  fixed collector frame, raw forge pages, and canonical coverage observation.
- `shadow/v1/_consumer.py` — add the dedicated fixed source-configuration and
  coverage-attempt readers by reusing the existing held-path controls; admit the
  fixed policy form and its exact held inventory under the producer contract.
- `shadow/v1/write-shadow.py` — implement the accepted explicit `prepare-policy`
  producer path, fixed policy snapshot, candidate and outer-record binding.
- `shadow/v1/write-materialization-input.jq` — rebuild only the closed old/new
  form inventories and generated-input metadata required by that producer plan.
- `scripts/test/shadow-write.test.sh` — implement the producer plan's actual
  production and tamper pairs; retain the old-form regression proof.
- `scripts/test/scope-qualification.test.sh` — add the full same-contract source
  fixture and every R9 positive and negative.
- `docs/components.md` and `RESTORE.md` — document the inactive source boundary,
  fixed files, restore set, old/new form distinction, and proof commands. These
  two paths plus the four shadow paths above are the six-path producer subset.
- `ci/required-files.txt` — add `sandbox/v1/coverage-source.py` exactly once.

Do not change a workflow, `scripts/test/run-all.sh`, portable-core capability,
profile binding, duty or stage contract, tracked production source configuration,
registry, accepted identity, credential, network route, installation script,
publication authority, target writer, or construction marker. The implementation uses
`Closes #544` only after #541 is complete; that closes child 6, with no activation.

当前 checkpoint 已有 `_Reader.write_relations`、`rebuild_input`、
`coverage_identity`、`source_coverage`、`read` 和 `fixed_bundle`。共享边界是
`_HeldBundle`、`_ReadOnlyGit`、`_HeldStoreRead` 与既有 child owner。
继续这些函数和已实现的 source 路径，保留 M3 的 Git owner 与 held reader。
不得从旧 main 复制另一套 reader，也不得增加兼容 shim。新 restore-critical
文件仍只有 `sandbox/v1/coverage-source.py`，manifest 恰好登记一次。
六个 producer 路径已有登记；生成的 candidate policy 不是仓库 restore 文件。

## Fixed public flow

Keep `evaluate-scope.sh` as the sole public entry. Its command stays:

```text
evaluate SCOPE SHADOW_SET DASHBOARD RISK KILL DUTY MARKER BUNDLE_ROOT SOURCE_GIT_DIR
```

Do not add a coverage argument, source locator, endpoint, host, credential,
provider id, raw fact, observation, trust flag, or fixture switch. The first
seven inputs retain their canonical one-MiB snapshots and stale checks.
`BUNDLE_ROOT` and `SOURCE_GIT_DIR` retain the #541 held physical checks and prove
nothing by their path. The validated scope selects coverage only when its
workflow and task are exactly the accepted write pair.

For that pair, `workflow-scope.jq` requires one exact `coverage` block with only:

- `coverage_base` as the target repository's canonical revision ref;
- `coverage_rule_version: "scope-coverage.v1"`; and
- sorted unique qualifying shadow-record refs.

Existing shadow refs remain the current refs. Both sets resolve by raw digest in
the same held shadow set and bundle root. A partial or mixed workflow/task pair
is malformed. A scope matching neither field must omit coverage and keeps the
#541 exact-revision, full-identity, no-change path. Record fields and caller
booleans never select the class.

The driver snapshots and measures its package before invoking the private reader.
It creates one exclusive scratch child for the reader output. The reader returns
one canonical internal `scope_shadow_evidence_observation`; its coverage section
is either a complete authenticated result or one closed missing/stale state. The
driver passes only that observation to jq and rechecks all input, package,
directory, Git, request, expectation, and output objects before success.

## Qualifying and current evidence

Extend the #541 reader rather than create another evidence evaluator. Authenticate
the qualifying and current bundles through the same fixed package, controlled
store, receipt checker, native registry, accepted set, record-form, held Git, and
write relations. Every required environment has exactly one row in each set.
Missing, duplicate, foreign, unproven, legacy, or cross-form rows cannot count.

Treat the controlled-store acquisitions in this first pass as provisional. Keep
each one through the complete bundle authentication and through durable creation
of the source request and expectation. Then recheck and close only those initial
store acquisitions and remove them from the reader's owned set before the source
process starts. Continue to hold the bundle directories, package, input, anchor,
Git, request, expectation, and all other reader objects. Closing a store
acquisition does not turn its captured bytes or relations into trusted final
evidence; the final pass below must authenticate them again.

Compare the closed coverage identity field by field. It contains only the scope,
workflow, task, model request, artifact refs, complete resolved-profile source and
bindings, environment and registry entry, control policy bytes, coverage base,
and rule version named by the spec. Preserve the sole forge materialization
capability. No digest supplied by the scope replaces this comparison.

The qualifying rows bind `coverage_base`. The current rows bind R. Everything
outside the closed identity is recomputed for R, including target and candidate
Git facts, stage/profile/result refs, materialization, publisher request,
post-check, sandbox receipt and current source refs. A value matching the base is
neither required nor sufficient.

## 历史 policy 的固定消费路径

生产步骤按 child 5 plan 执行。显式命令是
`write-shadow.py prepare-policy REQUEST BUNDLE WORK OUTPUT`。原 `prepare`
和旧 `withheld-write.v1` 保持原 32-file exact-revision 语义。新 form 固定为
`withheld-write-policy.v1`；不得由文件数或调用方 bool 推断。下列消费改动与
producer 在同一 carrier 完成，随后才运行端到端证明。

| 现有边界 | 必须完成的改动 |
| --- | --- |
| `write-shadow.py` 的 workspace、candidate、admission、outer record | 按 producer plan 使用同一 held 固定 policy，产生真实 candidate 与 preparation，再将相同 bytes 放入 outer record。不得按当前路径重读或补填历史值。 |
| `_HeldBundle` 与 `_Reader.read` | 将新 form 加入闭合集合。只对新 form 要求 `scope_policy_ref` 和固定 snapshot 文件。旧 form 禁止这两个新增项。维持原 owner、inventory、receipt 与最终 recheck。 |
| `_Reader.write_relations` | 从 receipt/preparation 所绑定的实际 candidate tree 读取固定 policy blob。完整复算新 form 的 33-file write set、patch、generated input、postcheck 和原有所有关系。 |
| `_Reader.rebuild_input` | 与 producer builder 共用相同闭合 form 选择和 `incident_id`。两阶段生成 metadata 都含这两个字段；只有 final 阶段含 `stage_request_sha256`。原 form 的生成结果保持不变。 |
| `_Reader.coverage_identity` 与 `source_coverage` | 使用各 record 已认证的 snapshot 构造其 policy identity。在 source 请求前比较 qualifying/current bytes，并单独核验 current 与 evaluator held policy 相等。 |
| `fixed_bundle` 与 `scope-gates.jq` | 新 form 的内部 measured facts 加且仅加闭合 `scope_policy_ref`。旧 facts 不加。更新 record/body/measured-row 及 write-materialization 分支的固定 form 集合，保留其他闭合字段与决定顺序。 |

新 candidate 固定增加 `ystack-evidence/<incident-id>/scope-policy.json`，mode
`100644`。它与旧 32 个文件合为精确 33 个。frozen reproduction 仍是原 29 个
evidence 文件加 bundle marker，不加入 policy。新 outer bundle 在原 31 个文件
上增加固定 `scope-policy.json`，总计 32 个；marker 恰好列出 31 个 entry。
不能把这三种 inventory 的数量混用，也不能按 caller 提供的任意路径选择文件。

`scope_policy_ref` 只有 `name`、`size_bytes`、`sha256`。name 固定为
`scope-policy.json`。size 是 1 至 1,048,576 的非 bool 整数。sha256 是小写
64 位十六进制。reader 读取 canonical JSON 的原始 bytes，核验实际 size、
SHA-256、candidate Git blob 和 manifest。outer bytes 必须与 actual candidate
固定 blob 完全相同。完整链保持 candidate tree → preparation manifest/record →
launch subject/prelaunch expectation → controlled-store receipt → held reader。
仅重算 outer checksum 不构成认证。不得增加 VM subject、receipt authority、
trust root、source/provider、配置开关或公共 policy selector。

每个 qualifying record 和 current record 都取自己的 snapshot。移除
`coverage_identity` 用当前 `package_sources["scope/v1/scope-policy.json"]`
填充两侧历史 identity 的做法。current snapshot 还必须与 evaluator 从固定
package 持有的 policy 原始 bytes 相同。qualifying/current bytes 相同后才比较
其他 closed identity 并建立 coverage request；摘要仅代表已经认证的 bytes。
候选 blob、outer、当前 evaluator policy 任一缺失、不同或未认证都不产生 coverage。

新 form 不能改变 closed scope/workflow/task/model/artifact/profile/environment/
registry identity，也不能改变 current revision 派生、Git interval、时间或 source
认证规则。旧 form、混合 form、current package backfill 都不能证明历史 coverage。
旧 form 的 exact-revision 支持保持。policy 改变仍触发父规则的 Eval → shadow
失效重跑，不得缩为只重跑 shadow。`workflow-scope.jq` 的公共 coverage shape 和
九参数 evaluator 不变。新内部 facts 只由实际 reader 生成；jq 不接受调用方证明。

policy snapshot 和 candidate relation 也属于 provisional 全量认证结果。source
request/expectation durable 后只释放原 controlled-store acquisitions。继续持有
非 store inputs、snapshot 所在 bundle、package、anchor 和 Git。source 写完后重开
全部 qualifying/current attempts，重新认证上述完整链，并比较原 bytes/non-origin
refs；不能只比较缓存 policy hash。最终 fresh origins 与其他 held objects 一直保留
到 completion，此时不得再创建 sibling。下面的 deadline、失败与 cleanup 规则不变。

## Evaluator-owned request

After both bundle sets and the bare Git snapshot pass, the private reader creates
32 random bytes from the physical runtime and derives one unique attempt id. In
an exclusive directory it writes canonical `coverage_source_request` and
`coverage_source_expectation` files with create-exclusive, mode `0600`, file
fsync, directory fsync, and retained read-only descriptors. No source process
starts before both are durable.

The request and expectation contain exactly the fields in spec R3. The reader
derives every ref from held scope, seven original documents, authenticated bundle
sets, current profile/stage/result/materialization/publisher/post-check facts,
qualifying receipts, Git observation, and the fixed source package selected by
the root-owned configuration. It accepts none of those values back from a caller.
The initial store acquisitions remain held until these exact files are durable;
only then may the reader release them as described above.

Add one closed source method to the concrete private child owner used by the
reader. This is a #544 responsibility; #541 supplies no sudo owner or source
launcher. The source method opens and holds physical `/usr/bin/sudo`, the current
Python and installed supervisor, reuses the reader's one deadline and closed
command ledger, and accepts only the canonical request bytes. It exposes no argv,
environment, callback, role, timeout, or output-limit argument.

The method records role `coverage-source-boundary`, the request digest, fixed argv
digest, sudo digest, and supervisor digest in that ledger. It rechecks all three
executables before and after use. Use the existing private bounded child lifecycle
and its process-group cleanup; extend that concrete owner with this one method
rather than copy the lifecycle or expose a generic runner. The source role has a
120-second cap within the reader's deadline, zero stdout, at most 16 KiB stderr,
a clean environment containing only `PATH=/usr/bin:/bin`, `LC_ALL=C`, and
`LANG=C`, TERM then KILL cleanup bounded to 10 seconds, and one exact reap. Its
only argv is:

```text
/usr/bin/sudo -n -u #SOURCE_UID -- P -I -S -B ANCHOR/host-supervisor.py coverage-read
```

Send the held request bytes on stdin. `SOURCE_UID` is the same dedicated
supervisor principal already fixed by the held host configuration. The source
cannot alter the held expectation. A reused nonce or attempt, request mismatch,
timeout, nonzero exit, signal, malformed frame, uncertain reap, late file change,
or changed expectation refuses before any facts count.

## Optional source installation

Do not widen the exact sandbox host-config schema. The coverage path opens the
optional fixed siblings `coverage-source-config.json` and
`coverage-source-accepted-identities.json` relative to the already held anchor
descriptor. Absence is the normal production state and produces
`scope.enablement-stale`. Presence requires the existing root-owner, mode, ACL,
one-link, no-follow, ancestor, held-descriptor, and final-recheck controls.

The source config is one canonical closed document. It fixes:

- operation `coverage-read.v1` and rule version `scope-coverage.v1`;
- the three query families and each exact schema version;
- a physical source-package manifest and its SHA-256;
- one physical collector executable and its SHA-256;
- one target-specific canonical `publisher_identity_ref`;
- the accepted-set path and digest; and
- the existing store id and dedicated principal/group relation.

The publisher identity is an independent root-controlled expectation. The
evaluator holds it from this configuration and compares every qualifying
publisher-PR actor ref with it. It is not derived from a PR row, publisher
request, scope field, matching digest, resolved-profile publisher binding, or
caller label. It does not add a field to the closed coverage identity or to the
exact evaluator-owned request.

The accepted set is a separate canonical closed document. It is inactive and has
zero or one row for this source id. A qualifying row matches operation version,
host-supervisor digest, source-package digest, collector digest, and normalizer
digest field for field. Duplicate, absent, unqualified, foreign, placeholder, or
caller-labelled rows refuse. Do not populate a tracked production config or set.

`coverage-source.py` is part of the measured root-owned package and is compared
byte for byte with the repository source before use. The source-package manifest
is a finite closure over that normalizer, the one collector, and its fixed query
schemas. It is not a plugin manifest or provider registry. A future production
collector, credential, route, installation, and accepted identity require their
own artifact and authority decision.

## Fixed collector protocol

The supervisor validates installation and configuration before parsing stdin.
It claims the nonce in the existing held work root and claims the same attempt id
in the existing controlled store before collector execution. It invokes only:

```text
COLLECTOR coverage-read.v1
```

Use a clean fixed environment, stdin as the canonical request, closed unrelated
descriptors, one foreground process group, a fixed deadline, bounded stdout and
stderr, TERM/KILL cleanup, and exact reap. The request contains no endpoint,
host, credential, executable path, page path, cursor supplied by the caller, or
trust flag. The collector and its root-owned package choose physical requests and
pagination.

Collector stdout is one existing binary frame. Record zero is canonical
`capture.json`; remaining records are consecutive `raw/0000` through
`raw/NNNN`. Capture rows contain only family, page index, response status, input
cursor, and output cursor. The three families are fixed default-branch history,
publisher pull requests, and complete branch-rule history. Each family starts at
index zero, forms one cursor chain, and has one terminal cursor. Require every
family, at most 128 pages, at most one MiB per page, at most 64 MiB total raw
bytes, and at most one MiB for every canonical document. Reject missing, extra,
duplicate, reordered, truncated, oversized, unknown-family, bad-status, or
unterminated input before normalization.

The supervisor computes request digest, raw sizes, raw digests, and the canonical
raw manifest itself. It never accepts a collector manifest, receipt, normalized
observation, source identity, status claim, or timestamp. The fixed normalizer
reads only held raw bytes and emits the six-field observation in spec R6. It has
no network, caller-file, environment-provider, dynamic import, or plugin path.
Re-normalize before storage and again in the consumer; both canonical byte strings
must match.

## Durable source attempt

Reuse `check_store_root`, `create_attempt_dir`, `mkdir_excl`, `write_excl`, and
`write_receipt_file`. Add one dedicated `write_coverage_payload` beside the
existing launch writer because the coverage inventory has a required `raw/`
directory. Do not make the existing launch inventory caller-configurable.

The source attempt has exactly:

```text
receipt.json
payload/request.json
payload/raw-manifest.json
payload/observation.json
payload/raw/0000 ... payload/raw/NNNN
```

Write every file mode `0440` and every directory mode `0750` as the source
principal and consumer group. Use exclusive relative creation, one link,
per-file fsync, raw-directory fsync, payload fsync, attempt fsync, receipt last,
and final store-root fsync. The supervisor writes canonical started/completed UTC
seconds and the exact source identity, query, effects, request, manifest, and
observation digests. Effects are only `read-forge-metadata` with no target write,
publication, or authority effect.

Add a dedicated `read_coverage_attempt` to `_consumer.py`. Its inventory and
bounds are constants, not arguments. It opens every object descriptor-relative
with the existing owner, group, mode, ACL, link, no-follow, held-descriptor, size,
and before/after metadata rules. It compares the stored request byte for byte with
the held request; verifies receipt, nonce, attempt, source identity, query,
manifest, page chain, raw bytes, and observation; runs the same normalizer; then
rechecks every descriptor and the anchor. Copied bytes, archived origin, caller
directories, matching digests, and supplied JSON remain unauthenticated.

The fresh origin may reflect lawful store-directory metadata changes completed
before acquisition. It authenticates the current read by itself. A mutation
during the acquired read refuses stale. The archived source origin never
authenticates a new read and no reread refreshes the qualifying sandbox receipt's
original `terminated_at`.

After the source process has completed its receipt-last write and exited, open a
fresh source attempt and freshly reacquire every qualifying and current controlled
store attempt. Repeat the full receipt, payload, checker, native-registry,
accepted-set, form, materialization, request, write-relation, and reference
authentication. Require every original receipt and payload byte and every check,
materialization, request, and non-origin ref to equal the provisional result and
the held source request. A completed source sibling may change only the fresh
store-root metadata recorded by these new origin observations. It may not change
an old attempt, its original timestamp, or any authenticated relation.

Keep all final core attempt acquisitions and the source attempt acquisition owned
through jq evaluation, `READY`, and `SEAL`. Their root identities are taken only
after the source sibling is complete. Any store-root, attempt, directory, receipt,
payload, or source mutation after that acquisition refuses stale through the
unchanged identity, no-follow, descriptor, inventory, and byte rechecks. Do not
whitelist a root metadata change or weaken the held-path identity.

## History and decision rules

The normalized observation contains exactly repository, default branch, baseline
and current snapshots, first-parent commits, publisher pull requests, and branch
rules. Compare its repository and immutable branch identities with the held
request. Require R to be the authenticated current default-branch tip and a
first-parent descendant of `coverage_base`.

Use the #541 held Git owner for an independent interval. Walk the exact first
parent from R through the base. Compare every commit id, parent, and tree to the
source observation in order. Compare the base snapshot only with base Git facts
and the current snapshot only with R facts. Missing, alternate-parent, duplicate,
rewritten, or caller-supplied history refuses.

For every commit, compare its own tree. No commit may change `.ystack/` or a CI
workflow. Under `ystack-evidence/`, accept only additions tied to this scope's
own publisher PR. Bind PR node/number, fixed publisher identity, base, head,
merge, source branch, scope, changed paths, and retained publisher request to the
actual Git change. Foreign, direct, rewritten, deleted, changed-existing, or
ambiguous evidence refuses. Ordinary source changes outside protected sets stay
allowed. Compare the publisher actor ref directly with the independently held
`publisher_identity_ref`; a source row cannot define or authenticate its own
expected publisher.

Replay the complete branch-rule event interval from the authenticated baseline.
After every event and at current, require the full sorted set of all rules that
apply to the default branch to equal baseline. Compare rule id, target pattern,
enforcement, bypass actors, type, and bounded canonical parameters. The four
required enforcing kinds are a minimum, not an exhaustive allowlist. Addition,
deletion, a permanent field change, or A-to-B-to-A change in any fifth kind
refuses.

Parse age from the original authenticated qualifying sandbox receipt
`timing.terminated_at`. Compare it with the authenticated current source receipt
`completed_at` at their full UTC precision. Accept only a real difference greater
than or equal to zero and less than or equal to exactly 2,592,000 seconds. Never
truncate, floor, round, or discard a fractional second; 2,592,000 seconds plus any
fraction refuses. A future or malformed value also refuses. A new source attempt,
store reread, or copied timestamp cannot refresh it.

Jq receives only the closed measured result. It emits
`scope.enablement-stale` for missing, incomplete, unauthenticated, replayed,
stale, or invalid coverage. Malformed shapes and runtime failures keep their
closed driver errors. Output remains inactive, observation-only, authority none,
enabled false, qualification unavailable, and contains no grant, tip-read,
credential, publisher, target-write, activation, or production authority.

## Same-contract fixture

以下是必须实现和完成的证明，不授予新的管理员或执行权限。只有已明确授权的
disposable 环境可执行相应 exact-command setup。若现有授权未覆盖新的
`coverage-read` sudo 命令，先完成 fixture 代码、完整命令与预期断言，保留
`NOT_RUN`，由经理在集中验收的具体资源包中核验执行权。当前 Mac 不安装账号、
sudoers、anchor 或 source。inactive 代码与普通回归不必等待 native 验收完成；
真实 positive、G3 和 #558 完整验收仍不得据此通过。

Extend the #541 fixture in `scope-qualification.test.sh`; do not add a second
fixture framework. On Linux CI, reuse its unique dedicated writer, distinct
read-only consumer, consumer group, root-owned anchor, controlled store, and
actual bare Git repository. Add the optional source files and a root-owned offline
collector package only inside that disposable fixture. The outer root setup also
creates one unique fixture-only sudoers file with exclusive no-follow creation,
root ownership, mode `0440`, and one exact `NOPASSWD:NOSETENV` command. Validate
that file with physical `/usr/sbin/visudo -cf` before running the consumer. The
command permits only the consumer to become the source uid for the physical
Python, `-I -S -B`, exact held supervisor path, and final `coverage-read` argument
shown above. It has no wildcard argv, shell, `env`, alternate executable,
`SETENV`, launch role, collector command, or store-writer command.

A unique trap removes only that sudoers file, verifies it is absent, then removes
the fixture accounts and group. Prove the exact command reaches the real source
request and that an extra, missing, reordered, or replaced argument, a different
Python or supervisor, an environment assignment, `launch`, a shell, and every
writer/helper command all fail. The consumer must still fail every direct store
write, chmod, link, rename, and removal. This temporary rule exists only on the
ordinary disposable Linux CI fixture. Production and the current development Mac
install no rule. The macOS positive waits for a separately verified disposable
host with an already authorized equivalent exact-command setup.

The fixture collector is the authoritative offline forge. Its physical package
contains pinned raw repository/default-branch, PR, and full rule-history pages.
The root-owned config selects them and one fixed fixture publisher identity ref.
The evaluator caller cannot name, replace, or supply a page, cursor, source
observation, publisher expectation, or accepted identity. Run the actual consumer
under the read-only identity and the actual source supervisor and collector under
the dedicated source principal. Prove a matching raw PR actor passes and a changed
or foreign actor refuses while the held publisher expectation remains unchanged.

The positive must use an existing authenticated qualifying/current attempt set,
create its own source sibling, then pass the complete final reacquisition with
fresh root metadata and unchanged old attempt bytes and relations. A paired case
mutates the store root or any old/source attempt after final reacquisition and
before `SEAL`; it must refuse stale. A mock origin, accepted root-mutation
exception, or skipped second authentication cannot satisfy either case.

Build real Git commits A, ordinary source B, own-publisher evidence C, and current
R. The source pages and bare Git facts must agree on the complete first-parent
interval. Keep `.ystack/`, workflows, and the complete applicable branch-rule set
unchanged. Include the four required enforcing kinds and an unchanged fifth kind.
Use identical closed coverage identity and freshly derived current refs.

For the exact 30-day positive and its one-second neighbors, use the real UTC time
written by the source supervisor. Create a fresh qualifying fixture and fresh
source attempt for each case. Start just after a second boundary and permit at
most eight new attempts within 120 seconds solely to obtain the intended exact
delta. Retain every failed attempt and record both authenticated timestamps for
each. If no attempt matches, the test fails. Never reuse a nonce, alter a completed
receipt, patch or truncate the clock, pass a time environment variable, or treat
an unmatched attempt as a skip or pass.

Prepare the same fixed fixture and cases for macOS. Run them only on a verified
disposable evidence host whose owner already authorized root setup, account/group
lifecycle, anchor, and physical runtime. This plan does not create or install
that environment. Until it exists, ordinary code and tests may be prepared, but
the macOS real positive and G3 remain blocked. A mock, same-uid tree, copied
origin, permanent refusal, or skipped test cannot replace either platform's real
positive.

## Proof and completion

新增 policy 证明使用真实 `prepare-policy` producer 输出，经既有 fixture 的
materializer/preparation、receipt、reader 路径消费。不得手写一个“已认证”record
代替正例。普通机制测试与真正不同 principal 的 source positive 分开记账。
每个负例保留其余 closed identity 和 revision 条件，并配对应同-policy 正例。

| 测试位置 | 成对证明 |
| --- | --- |
| `shadow-write.test.sh` | 真实新 producer 产生精确 33-file candidate、固定 policy ref、完整关系；旧 `prepare` 仍为原 32-file。对照 new32、old33、错误 path/mode/inventory 必拒绝。 |
| `shadow-write.test.sh` | 同一 held policy 贯穿 candidate 与 outer；在 snapshot、candidate 或最后 seal 前改 policy 必拒绝。ref 的缺项、额外项、错误 name、bool/越界 size、错误 digest 必拒绝。 |
| `scope-qualification.test.sh` | 两个真实新 form records 各自产生并认证相同 policy，current 等于 evaluator held policy，完整 source/history 条件满足时 coverage 通过。历史 policy 与 current 不同必拒绝。 |
| `scope-qualification.test.sh` | 两 record policy 相同但 current 与 evaluator held policy 不同必拒绝；更新当前 package 不能补填历史缺失或修复旧 form。新/旧混合与两个旧 form 都不能证明 later-revision coverage。 |
| `scope-qualification.test.sh` | 改 outer snapshot 并重算 ref、marker 和所有 outer checksums，保留 genuine candidate/preparation/receipt，仍拒绝。candidate、manifest 和相关 hash 一起改，但保留原 genuine receipt，也拒绝。 |
| `scope-qualification.test.sh` | snapshot 不在 receipt 所绑定的 actual candidate、仅保存 current hash、缺固定文件或任意替代文件均拒绝；相同 policy 的真实链对照通过。 |
| `scope-qualification.test.sh` | 新 form 正例必须经过 provisional → durable request → release → source sibling → final full authentication；final root、old attempt、source attempt 或 policy 任一 mutation 必拒绝。 |

这些测试增加到现有完整 suite，不用新 selector、独立 fixture framework 或永久
拒绝替代完整路径。producer plan 的生产端测试义务仍全量适用；下列原 R9 一项不减。

Besides the real positive, cover every spec R9 case:

- exact write pair; each partial and mixed pair; read-only exact-revision positive
  and cross-revision refusal; forged coverage fields cannot select the class;
- every closed-identity field and every current-derived ref changed separately;
- absent/duplicate/foreign/unproven source config and accepted identity; changed
  supervisor, source package, collector, normalizer, query schema, publisher
  expectation, anchor, store, owner, group, mode, ACL, link, descriptor, request,
  expectation, nonce, attempt, receipt, manifest, page, cursor, observation, and
  final recheck;
- replay of the first genuine attempt during a second same-R evaluation, followed
  by a new genuine attempt that passes;
- lawful source-sibling creation between provisional and final acquisitions,
  unchanged old attempt bytes and refs on full final reauthentication, and any
  root or attempt mutation during the final hold refusing stale before `SEAL`;
- another repository/default branch; non-descendant and second-parent paths;
  missing, duplicate, reordered, alternate, and incomplete first-parent history;
- protected Git changes; direct, foreign, rewritten, deleted, changed-existing,
  wrong-PR, wrong-publisher, wrong-base/head/merge/path evidence; legal ordinary
  source changes remain allowed;
- branch-rule add/delete and every field change; permanent and A-to-B-to-A changes
  in the fifth kind; the unchanged five-kind interval passes;
- age one second before, exactly at, and one second after 30 days, plus future and
  malformed values; qualifying reread preserves the original time;
- collector timeout, signal, nonzero, oversized or malformed frame, partial store
  write, receipt failure, cancellation, exact group cleanup, and unique reap;
- no target write, publication, credential, network call, production config,
  accepted production identity, activation, or capability/profile change.

保留全部 #541 core positive 和 negative。在获准的对应环境执行以下完整
suites，保留完整原始 stdout/stderr、实际 exit、环境与同一 final implementation
head。没有执行权限或前置条件时标明 `NOT_RUN`，不能标成 skip/pass：

```sh
bash scripts/test/scope-qualification.test.sh
bash scripts/test/sandbox-launcher.test.sh
bash scripts/test/shadow-enforced.test.sh
bash scripts/test/shadow-write.test.sh
bash scripts/test/shadow-self-host-evidence.test.sh
bash scripts/test/sandbox-receipt.test.sh
bash scripts/test/local-git-materializer-protocol.test.sh
bash scripts/test/local-git-materializer-adapter.test.sh
bash scripts/test/portable-core-schema.test.sh
bash scripts/test/run-all.sh
```

在相应已授权环境运行上述 materializer protocol、adapter suites，以及现有
full runner 发现的全部相关 integration tests。不得为不存在的 aggregate test
另造别名。在 Linux 和 macOS 完成真实 principal 证明，记录 OS、filesystem、
uid/gid/groups、ACL、timestamps、source package 和 exact head。在该 head
完成六分片 full matrix，全部 shards、checks、aggregate CI 与外部 required
checks 必须通过。quick CI 仅是额外证据。

恢复时保留原普通 source 128 项结果及其 exact-head 归属。原四个 Git-owner
失败、SDK/runtime `UNKNOWN`、genuine fixtures `NOT_RUN` 仍是原始事实，不能用
此文档或新普通测试覆盖。不得重跑 Mac probes、SDK、官方 GET 或新诊断。
不得在本地盲跑完整 scope suite 或 full LOCAL7，也不占用 #558 完整窗口。
旧 82 ordinary 特定资源包不授权本轮新 development tests。普通安全机制回归可用
既有开发/CI 权限；真实 principal 测试须另有匹配的准确执行权。
测试所需固定 Python、jq 与其他工具按 producer plan 校验；缓存缺失不触发下载或
安装。代码可在 inactive 状态完成，所有未执行证明和完整日志随原 carrier 保留，
最后集中验收仍必须满足完整标准。quick CI 不代表 native 或完整 #558 window。

Before publication, run `git diff --check`, compare the diff with this exact path
list, verify intent/spec/plan blobs and risk, require the new manifest entry once,
and prove tracked production config, registry, accepted set, workflow, capability,
profile, and duty files did not change. A separate read-only reviewer reads the
complete exact-head/base diff and raw proof. Resolve every Important finding. The
named manager alone performs the protected merge and records the receipt. No
artifact, test, fixture, or merge may claim native qualification, enablement,
production source availability, or child 7 completion.
