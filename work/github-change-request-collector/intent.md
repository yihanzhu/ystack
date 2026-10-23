# Intent：采集有界的 GitHub change-request 观察

Tracks #304。

| 目标 | 证明边界 |
| --- | --- |
| inactive 的真实 HTTPS GET collector | 本次不授权真实网络或凭据使用 |
| 同一路径的无 socket 隔离测试 | 测试通过只证明实现，不证明真实 provider 资格 |
| 供现有 normalizer 使用的真实观察 | 缺失事实保持不可用、inconclusive 或拒绝 |

## 问题

Roadmap step 4 要求可用的 GitHub forge adapter。
现有 `adapters/github-forge/v1/normalize.jq` 检查提供给它的快照。
它不负责采集这些观察。
合成输入不能证明实际采集路径正确，也不能证明 provider 提供所需事实。

采集还必须说明证据的限度。
读取身份、文件内容完整性和多次响应的一致性都需要真实依据。
把调用方预期的 App ID 复制到观察中，会伪造身份依据。
缺失 patch 时计算空字符串摘要，会伪造内容依据。
双读一致不能被称为原子快照。
具体 provider 能提供什么事实，须由 G2 核验。

## 目标与成功标准

交付一个保持 inactive、有明确资源边界的 GitHub.com GET collector。
请求构造、响应读取、映射和失败处理须属于实际产品路径。
通过私有 scripted connection 测试同一路径。
不另建仅返回假数据的 collector 或泛用 provider 框架。

成功须满足以下条件：

- 核对预期 repository 和 change-request 身份。
  绑定 head、base 与观察事实，并在明确边界内处理完整分页。
  采集结果如实记录完整性及证据限度。
- 明确定义 collector 与现有 normalizer 的关系。
  保留其安全检查和测试。缺失身份、patch 或一致性依据不能变成成功。
  后续可信 consumer 仍需独立检查鲜度与权限。
- 使用固定 HTTPS origin 和允许的 GET routes。
  校验路由输入，固定 API/media 选择，并校验证书。
  响应大小、页数和耗时均须有界。错误记录不得泄露敏感数据。
- 隔离测试不使用 socket、真实凭据或 provider 服务。
  在接受的映射允许时，覆盖真实 collector 到 normalizer 的行为。
  覆盖缺失事实、畸形或截断响应、超限、分页漂移、重复或缺失文件、
  不可用 patch、错误、中断、脱敏及禁止的目的地。
- 保留相关现有测试，交付完整证明和恢复文档。
  新 restore-critical 文件进入 manifest。
  独立审查、准确 head/base 和规定 CI 继续作为门槛。

## 受影响的系统

GitHub forge adapter、现有 normalizer 及相关测试和恢复文档。
GitHub 请求与映射留在 adapter 私有边界内，core 保持 provider-neutral。
当前 default profile 的 local Git materializer 不被替换。
后续 Step 8 child 11 可使用 #304 observations，但其执行不属于本 concern。

## 非目标与权限边界

不接入调用方任意 URL 或 command。
不继承 proxy、netrc、gh 配置，不发现环境中的 token，也不使用 credential helper。
不提供公开的假成功开关。
不创建 token，不做 POST 或写操作，不做 provider retry 或 cache。
不抓取 Git object 或重建 diff，不采集 Actions，不支持其他 forge。
不执行 model 或 harness，不扩诊断工程。

本 concern 不授权新凭据、真实 provider 网络、真实 transport/provider qualification、
安装、profile 选择、激活或 target 执行。
如设计需要可信 credential-provider receipt，必须明确该依赖及缺失行为。
不能制造 receipt，也不能用隔离测试通过替代真实来源证明。

修改已接受的 normalizer contract 必须显式回到相应 artifact gate。
降低证明标准或扩大权限，须将具体决定交回 operator。
本 concern 不执行 publisher、post-write 检查或真实写入，也不授予写入许可。

## 顺序与后续门槛

用户直接决定允许先完成剩余 inactive 仓库实现与测试。
原顺序暂停的解除只允许本 concern 进入 artifact 流程。
它不证明 step 7 完成，也不接受任何未交付依赖。
#558 全部原验收欠项保留，最后集中闭合。验收标准不降低。
本 concern 不宣称 Roadmap step 4、step 7 或 #558 已验收。

本 intent 仅定义产品目标与边界，不预选 provider 字段或映射方案。
后续 G2 须依据 primary provider 文档确定合同、风险与文件范围，并独立审查。
实施前仍须通过适用 plan gate。高风险 plan 须单独审查并先合并。

## G2 待解决的问题

- 哪些 provider 事实能确认 change request、repository 及 fork 的 head/base 身份？
- 怎样获得真实读取身份依据？可信凭据来源缺失时，哪些结果必须不可用或拒绝？
- patch 缺失和非原子分页下，内容摘要与完整性可以诚实证明到什么程度？
- 怎样与现有 normalizer 衔接，同时保留既有证据标准？是否需要显式合同修订？
- 哪些边界和测试能证明同一真实 GET 路径，又不授权实际网络或凭据使用？
