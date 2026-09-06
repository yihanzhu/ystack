import "schema" as schema;

# Inactive eval/trace framework contracts (Roadmap item 5, unit 1).
# Pure jq 1.6. Consumes only canonical core-v2 documents and caller-supplied
# offline observations. Grants nothing, executes nothing, records no cost.

def expected_core:
  {
    generation_id_sha256:
      "84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
    package_ref:{
      content_id:"core-contract-package.v2",
      media_type:"application/vnd.ystack.core-contract+json",
      sha256:"eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"
    },
    semantic_identity:"core.contracts.v2"
  };

def expected_core_closure:
  [
    {path:"core/v2/generation-registry.json",
     sha256:"3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/contracts.jq",
     sha256:"65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/core-ingress.sh",
     sha256:"dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/profile_graph.jq",
     sha256:"c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_facts.jq",
     sha256:"8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_truth.jq",
     sha256:"ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/schema.jq",
     sha256:"8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/stage_request.jq",
     sha256:"6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e"},
    {path:"scripts/core-contract.sh",
     sha256:"b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9"}
  ];

# The inactive state scanner and reconciliation planner replayed for the events
# family, pinned like the core.
def expected_orchestrator_closure:
  [
    {path:"orchestrator/v1/reconciliation-plan.jq",
     sha256:"03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4"},
    {path:"orchestrator/v1/scan-state.sh",
     sha256:"556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5"},
    {path:"orchestrator/v1/state-scanner-driver.sh",
     sha256:"5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b"},
    {path:"orchestrator/v1/state-scanner-launcher.sh",
     sha256:"9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb"},
    {path:"orchestrator/v1/state-scanner.jq",
     sha256:"722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae"}
  ];

# The inactive control evaluators replayed here: the sandbox-policy evaluator for
# the boundaries family, and the risk-gates evaluator (with the duty-separation
# evaluator it regenerates) for the approval family. Both read only this closure
# and the core mirror.
def expected_control_closure:
  [
    {path:"control/v1/duty-separation-decision.json",
     sha256:"4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99"},
    {path:"control/v1/duty-separation-policy.json",
     sha256:"b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9"},
    {path:"control/v1/duty-separation.jq",
     sha256:"b4e480748dd4fb7dec769b25f0f7649b0e5dc31f9de438bba690e9eab6ac236c"},
    {path:"control/v1/evaluate-duty.sh",
     sha256:"146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa"},
    {path:"control/v1/evaluate-risk-gates.sh",
     sha256:"0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8"},
    {path:"control/v1/evaluate-sandbox.sh",
     sha256:"8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb"},
    {path:"control/v1/policy-set.jq",
     sha256:"2be97550574ee4522fc0bd14780c92dee3c1b455f2c04b7763b0e437665a8d58"},
    {path:"control/v1/risk-gates-decision.json",
     sha256:"8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5"},
    {path:"control/v1/risk-gates-policy.json",
     sha256:"3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e"},
    {path:"control/v1/risk-gates.jq",
     sha256:"d00fccd8e31b770c6df01fba17e3cc315d58edfbbf0a8055d66d537dc6ad21ff"},
    {path:"control/v1/sandbox-decision.json",
     sha256:"c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd"},
    {path:"control/v1/sandbox-policy.json",
     sha256:"4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e"},
    {path:"control/v1/sandbox.jq",
     sha256:"83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3"},
    {path:"control/v1/validate.sh",
     sha256:"cf173ad0eaa08244bf636e3937845e894b21f14291fc5e66753e8673bdd2bd2a"}
  ];

# The inactive default and alternative normalizers replayed for the adapter
# family: three GitHub-side defaults, the GitLab forge, and the Codex CLI producer.
def expected_adapter_closure:
  [
    {path:"adapters/codex-cli-producer/v1/normalize.jq",
     sha256:"dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25"},
    {path:"adapters/codex-native-reviewer/v1/normalize.jq",
     sha256:"7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603"},
    {path:"adapters/github-actions-ci/v1/normalize.jq",
     sha256:"690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7"},
    {path:"adapters/github-forge/v1/normalize.jq",
     sha256:"b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be"},
    {path:"adapters/gitlab-forge/v1/normalize.jq",
     sha256:"ff2ec298eef102f94f28995f5306adeba8e078d19e4c22860c3b167cd9b7c37a"}
  ];

def ref_shape($content_id; $media_type):
  schema::content_ref_ok and
  .content_id == $content_id and .media_type == $media_type;

def present_shape(value_ok):
  (schema::exact_fields(["state"];[]) and .state == "absent") or
  (schema::exact_fields(["state","value"];[]) and .state == "present" and
   (.value | value_ok));

def pair_shape($kind):
  schema::exact_fields(["content","sha256"];[]) and
  (.content | schema::envelope_ok($kind)) and
  (.sha256 | schema::sha256_ok);

def grader_kinds: ["deterministic","human","model"];
def verdicts: ["failed","inconclusive","passed"];
def family_ids:
  ["actor-rerun-identity",
   "adapter-contract-compliance",
   "approval-invalidation-no-push-after-approval",
   "empty-fake-timed-out-degraded-reviews",
   "malicious-instructions",
   "protected-path-credential-network-publisher-boundaries",
   "repeated-cancelled-missed-events",
   "reviewer-severity-false-positive-negative",
   "stale-moved-artifacts"];
def seed_sources:
  ["adapter-tests.contract.v1","adapters.provider-normalizers.v1","control.risk-gates.v1",
   "control.sandbox-policy.v1","core.stage-run.v2","orchestrator.reconciliation-plan.v1",
   "orchestrator.state-scanner.v1"];
def stage_statuses:
  ["blocked","cancelled","completed","failed","skipped","stale"];
def core_error_tokens:
  ["E_CANONICAL","E_LIMIT","E_PARSE","E_REF","E_RELATION","E_RUNTIME","E_SHAPE","E_USAGE"];
def request_roles: ["producer","reviewer","verifier"];
def active_seed_sources:
  ["adapters.provider-normalizers.v1","control.risk-gates.v1","control.sandbox-policy.v1",
   "core.stage-run.v2","orchestrator.reconciliation-plan.v1","orchestrator.state-scanner.v1"];
def risk_gates_error_tokens: ["E_DUTY","E_LIMIT","E_RELATION","E_RUNTIME","E_USAGE"];
def normalizer_ids:
  ["codex-cli-producer","codex-native-reviewer","github-actions-ci","github-forge","gitlab-forge"];
def normalizer_error_ids:
  ["E_SHAPE","E_STALE","E_TRUST",
   "codex-reviewer.invalid-envelope","codex-reviewer.invalid-snapshot",
   "codex-reviewer.invalid-trust-context","github-actions-ci.invalid-envelope",
   "github-actions-ci.invalid-snapshot","github-actions-ci.invalid-trust-context",
   "github-actions-ci.provider-contradiction","github-forge.invalid-envelope",
   "github-forge.invalid-snapshot","github-forge.invalid-trust-context",
   "gitlab-forge.invalid-envelope","gitlab-forge.invalid-snapshot",
   "gitlab-forge.invalid-trust-context"];
def normalizer_states:
  ["action-required","cancelled","changed","clean","closed-unmerged","dismissed","failed",
   "findings","in-progress","inconclusive","merged","no-change","open-blocked","open-ready",
   "passed","queued","stale","timed-out","timeout"];
def sandbox_error_tokens:
  ["E_CANONICAL","E_LIMIT","E_PARSE","E_POLICY_SET","E_RELATION","E_RUNTIME","E_USAGE"];
def sandbox_verdicts: ["inconclusive","satisfied","violated"];
# The risk-gates evaluator has no satisfied result: no qualified decision
# provenance exists, so an accept claim is at most inconclusive.
def risk_gates_verdicts: ["inconclusive","violated"];
def planner_error_tokens: ["E_RECONCILIATION_INPUT"];
def plan_operations: ["dispatch-stage","recover-stranded-attempt","retry-stage"];
def delivery_modes: ["first-delivery","redelivery"];
def scanner_error_tokens:
  ["E_CANONICAL","E_LIMIT","E_PARSE","E_RELATION","E_RUNTIME","E_SHAPE","E_STALE","E_USAGE"];
def scanner_classes: ["blocked","pending","retryable","stale","stranded","terminal"];
def scanner_actions:
  ["dispatch-stage","none","operator-reconcile","recover-stranded-attempt",
   "refresh-stage-inputs","resolve-stage-blocker","retry-stage","wait-for-attempt"];
def scanner_reason_ids:
  ["scanner.attempt-deadline-reached","scanner.attempt-in-flight","scanner.no-attempt",
   "scanner.retry-limit-reached","scanner.stage-blocked","scanner.stage-cancelled",
   "scanner.stage-completed","scanner.stage-failed","scanner.stage-skipped",
   "scanner.stage-stale","scanner.target-revision-moved"];
def tool_content_id($source):
  if $source == "core.stage-run.v2" then "core-contract-front-door.v2"
  elif $source == "orchestrator.state-scanner.v1" then "orchestrator-state-scanner-bootstrap.v1"
  elif $source == "control.sandbox-policy.v1" then "control-evaluator-driver.sandbox.v1"
  elif $source == "control.risk-gates.v1" then "control-evaluator-driver.risk-gates.v1"
  else "orchestrator-reconciliation-planner.v1" end;
def tool_media_type($source):
  if $source == "orchestrator.reconciliation-plan.v1" then "text/x-jq"
  else "text/x-shellscript" end;

def trial_policy_shape:
  (schema::exact_fields(["kind"];[]) and .kind == "single") or
  (schema::exact_fields(["kind","minimum_trials"];[]) and .kind == "multi" and
   (.minimum_trials | schema::int_ok) and
   .minimum_trials >= 2 and .minimum_trials <= 16);

def family_shape:
  schema::exact_fields(
    ["family_id","roadmap_requirement","grader_kinds","trial_policy",
     "evidence_kinds","seed_status","seed_sources"];[]) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.roadmap_requirement | schema::short_text_ok) and
  (.grader_kinds | schema::enum_set_ok(1;3;grader_kinds)) and
  (.trial_policy | trial_policy_shape) and
  (.evidence_kinds | schema::enum_set_ok(1;4;schema::evidence_kinds)) and
  (.seed_status == "seeded" or .seed_status == "declared") and
  (.seed_sources | schema::enum_set_ok(0;4;seed_sources)) and
  ((.seed_status == "seeded") == ((.seed_sources | length) >= 1)) and
  # A family that only a model or human can grade may not claim a single trial.
  (if (.grader_kinds | index("deterministic")) == null
   then .trial_policy.kind == "multi" else true end);

def catalog_shape:
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_catalog" and .id == "evals.catalog.v1" and
  (.body |
   schema::exact_fields(
     ["activation_state","catalog_version","core_contract","fail_mode",
      "families","grader_kinds","verdicts"];[]) and
   .activation_state == "inactive" and .fail_mode == "closed" and
   .catalog_version == "v1" and .core_contract == expected_core and
   .grader_kinds == grader_kinds and .verdicts == verdicts and
   (.families | schema::bounded_set(9;9;family_shape;.family_id)) and
   ((.families | map(.family_id) | sort) == family_ids));

def evaluator_shape:
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_framework_evaluator" and
  .id == "evals.framework.v1" and
  (.body |
   schema::exact_fields(
     ["adapter_closure","bootstrap_ref","catalog_ref","control_closure","core_closure",
      "core_contract","driver_ref","launcher_ref","orchestrator_closure","program_ref",
      "runtime"];[]) and
   .core_contract == expected_core and .core_closure == expected_core_closure and
   .orchestrator_closure == expected_orchestrator_closure and
   .control_closure == expected_control_closure and
   .adapter_closure == expected_adapter_closure and
   (.bootstrap_ref | ref_shape("evals-framework-bootstrap.v1";"text/x-shellscript")) and
   (.launcher_ref | ref_shape("evals-framework-launcher.v1";"text/x-shellscript")) and
   # Shipped artifacts are pinned to the digests the launcher and driver verified,
   # so an archived result cannot claim a program, driver, or catalog that never ran.
   (.driver_ref | ref_shape("evals-framework-driver.v1";"text/x-shellscript") and
    .sha256 == $driver_sha256) and
   (.program_ref | ref_shape("evals-framework-program.v1";"text/x-jq") and
    .sha256 == $program_sha256) and
   (.catalog_ref |
    ref_shape("evals-catalog.v1";"application/vnd.ystack.eval-catalog+json") and
    .sha256 == $catalog_sha256) and
   (.runtime |
    schema::exact_fields(
      ["execution_mode","host_architecture","host_os","jq_architecture",
       "jq_ref","shell_ref"];[]) and
    (.jq_ref | ref_shape("jq-runtime.v1";"application/x-executable")) and
    (.shell_ref | ref_shape("bash-runtime";"application/x-executable")) and
    ((.host_os == "linux" and .host_architecture == "x86_64" and
      .jq_architecture == "x86_64" and .execution_mode == "native" and
      .jq_ref.sha256 ==
        "af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44") or
     (.host_os == "darwin" and .host_architecture == "x86_64" and
      .jq_architecture == "x86_64" and .execution_mode == "native" and
      .jq_ref.sha256 ==
        "5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef") or
     (.host_os == "darwin" and .host_architecture == "arm64" and
      .jq_architecture == "x86_64" and .execution_mode == "rosetta" and
      .jq_ref.sha256 ==
        "5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef"))));

def stage_run_expectation_shape:
  (schema::exact_fields(["disposition","status"];[]) and
   .disposition == "accepted" and
   (.status as $status | stage_statuses | index($status) != null)) or
  (schema::exact_fields(["disposition","error_token"];[]) and
   .disposition == "rejected" and
   (.error_token as $token | core_error_tokens | index($token) != null));

def classification_shape:
  schema::exact_fields(["action","class","reason_id"];[]) and
  (.class as $c | scanner_classes | index($c) != null) and
  (.action as $a | scanner_actions | index($a) != null) and
  (.reason_id as $r | scanner_reason_ids | index($r) != null);

def scanner_expectation_shape:
  (schema::exact_fields(["action","class","disposition","reason_id"];[]) and
   .disposition == "observed" and (del(.disposition) | classification_shape)) or
  (schema::exact_fields(["disposition","error_token"];[]) and
   .disposition == "rejected" and
   (.error_token as $token | scanner_error_tokens | index($token) != null));

# A plan is graded on exactly which stage, request, operation, and attempt it
# would deliver, defer, or suppress, and which stages it hands to an operator.
# Provenance and document refs stay the planner's own concern.
def plan_stage_key_shape:
  schema::exact_fields(["initiative_id","stage_id","task_class_id","workflow_id"];[]) and
  all(.[]; schema::id_ok);

def plan_item_shape($extra):
  schema::exact_fields(
    ["attempt_number","operation","request_sha256","stage_key"] + [$extra];[]) and
  (.attempt_number | schema::int_ok) and .attempt_number >= 1 and .attempt_number <= 10 and
  (.operation as $o | plan_operations | index($o) != null) and
  (.request_sha256 | schema::sha256_ok) and
  (.stage_key | plan_stage_key_shape);

def plan_summary_shape:
  schema::exact_fields(["deferred","deliveries","operator_messages","suppressed"];[]) and
  (.deliveries | type == "array" and length <= 64 and
   all(.[]; plan_item_shape("delivery_mode") and
            (.delivery_mode as $m | delivery_modes | index($m) != null))) and
  (.deferred | type == "array" and length <= 64 and
   all(.[]; plan_item_shape("reason_id") and (.reason_id | schema::id_ok))) and
  (.suppressed | type == "array" and length <= 64 and
   all(.[]; plan_item_shape("reason_id") and (.reason_id | schema::id_ok))) and
  (.operator_messages | type == "array" and length <= 64 and
   all(.[];
     schema::exact_fields(["action","class","stage_key"];[]) and
     (.action as $a | scanner_actions | index($a) != null) and
     (.class as $c | scanner_classes | index($c) != null) and
     (.stage_key | plan_stage_key_shape)));

def planner_expectation_shape:
  (schema::exact_fields(
     ["deferred","deliveries","disposition","operator_messages","suppressed"];[]) and
   .disposition == "planned" and (del(.disposition) | plan_summary_shape)) or
  (schema::exact_fields(["disposition","error_token"];[]) and
   .disposition == "rejected" and
   (.error_token as $token | planner_error_tokens | index($token) != null));

# A sandbox evaluation is graded on its verdict and exact reason set.
def control_evaluation_shape($verdicts):
  schema::exact_fields(["reason_ids","verdict"];[]) and
  (.verdict as $v | $verdicts | index($v) != null) and
  (.reason_ids | schema::bounded_set(1;64;schema::id_ok;.));
def sandbox_evaluation_shape: control_evaluation_shape(sandbox_verdicts);

# A normalizer is graded on the generic state it reports, its reason, and the
# exact set of stale bindings; provider text stays opaque and ungraded.
def normalization_shape:
  schema::exact_fields(["reason_id","stale_bindings","state"];[]) and
  (.state as $st | normalizer_states | index($st) != null) and
  (.reason_id | schema::id_ok) and
  (.stale_bindings | schema::bounded_set(0;16;schema::id_ok;.));

def normalizer_expectation_shape:
  (schema::exact_fields(["disposition","reason_id","stale_bindings","state"];[]) and
   .disposition == "normalized" and (del(.disposition) | normalization_shape)) or
  (schema::exact_fields(["disposition","error_token"];[]) and
   .disposition == "rejected" and
   (.error_token as $token | normalizer_error_ids | index($token) != null));

def control_expectation_shape($verdicts; $tokens):
  (schema::exact_fields(["disposition","reason_ids","verdict"];[]) and
   .disposition == "evaluated" and
   (del(.disposition) | control_evaluation_shape($verdicts))) or
  (schema::exact_fields(["disposition","error_token"];[]) and
   .disposition == "rejected" and
   (.error_token as $token | $tokens | index($token) != null));
def sandbox_expectation_shape:
  control_expectation_shape(sandbox_verdicts; sandbox_error_tokens);
def risk_gates_expectation_shape:
  control_expectation_shape(risk_gates_verdicts; risk_gates_error_tokens);

def expectation_shape($source):
  if $source == "core.stage-run.v2" then stage_run_expectation_shape
  elif $source == "orchestrator.state-scanner.v1" then scanner_expectation_shape
  elif $source == "control.sandbox-policy.v1" then sandbox_expectation_shape
  elif $source == "control.risk-gates.v1" then risk_gates_expectation_shape
  elif $source == "adapters.provider-normalizers.v1" then normalizer_expectation_shape
  else planner_expectation_shape end;

def stage_run_case_shape:
  schema::exact_fields(["case_id","family_id","expectation","request_role","result"];[]) and
  (.case_id | schema::id_ok) and
  (.request_role as $role | request_roles | index($role) != null) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.expectation | stage_run_expectation_shape) and
  (.result | pair_shape("stage_result"));

# Snapshots are schema_version 1 orchestrator documents, not core-v2 envelopes.
def snapshot_pair_shape:
  schema::exact_fields(["content","sha256"];[]) and
  (.content |
   schema::exact_fields(["body","id","kind","schema_version"];[]) and
   .schema_version == 1 and .kind == "orchestrator_state_snapshot" and
   (.id | schema::id_ok) and (.body | type == "object")) and
  (.sha256 | schema::sha256_ok);

# Planner inputs are plain bundles, not envelopes; the planner validates them.
def planner_input_pair_shape:
  schema::exact_fields(["content","sha256"];[]) and
  (.content |
   schema::exact_fields(
     ["delivery_ledger","delivery_ledger_ref","max_in_flight","observation",
      "observation_ref"];[])) and
  (.sha256 | schema::sha256_ok);

def planner_case_shape:
  schema::exact_fields(["case_id","expectation","family_id","input"];[]) and
  (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.expectation | planner_expectation_shape) and
  (.input | planner_input_pair_shape);

# Control documents are schema_version 1 envelopes of a fixed kind.
def control_pair_shape($kind):
  schema::exact_fields(["content","sha256"];[]) and
  (.content |
   schema::exact_fields(["body","id","kind","schema_version"];[]) and
   .schema_version == 1 and .kind == $kind and
   (.id | schema::id_ok) and (.body | type == "object")) and
  (.sha256 | schema::sha256_ok);

def sandbox_case_shape:
  schema::exact_fields(["case_id","expectation","family_id","inputs"];[]) and
  (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.expectation | sandbox_expectation_shape) and
  (.inputs |
   schema::exact_fields(["claim","duty","policy_set"];[]) and
   (.policy_set | control_pair_shape("control_policy_set")) and
   (.duty | control_pair_shape("duty_separation_evaluation")) and
   (.claim | control_pair_shape("execution_environment_claim")));

# Normalizer inputs are untrusted provider envelopes with caller bindings. Only
# the normalizer judges their shape, so a malformed envelope can be a case.
def normalizer_case_shape:
  schema::exact_fields(["case_id","expectation","family_id","input","normalizer"];[]) and
  (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.normalizer as $n | normalizer_ids | index($n) != null) and
  (.expectation | normalizer_expectation_shape) and
  (.input |
   schema::exact_fields(["content","sha256"];[]) and
   (.content | type == "object") and
   (.sha256 | schema::sha256_ok));

# A risk-gates case carries the whole tuple the evaluator binds: the policy set,
# the core request, resolved profile, and result, the duty evaluation, and the
# decision claim under judgement.
def risk_gates_case_shape:
  schema::exact_fields(["case_id","expectation","family_id","inputs"];[]) and
  (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.expectation | risk_gates_expectation_shape) and
  (.inputs |
   schema::exact_fields(["claim","duty","policy_set","request","resolved_profile","result"];[]) and
   (.policy_set | control_pair_shape("control_policy_set")) and
   (.request | pair_shape("stage_request")) and
   (.resolved_profile | pair_shape("resolved_profile")) and
   (.result | pair_shape("stage_result")) and
   (.duty | control_pair_shape("duty_separation_evaluation")) and
   (.claim | control_pair_shape("risk_gate_decision_claim")));

def scanner_case_shape:
  schema::exact_fields(
    ["case_id","expected_revision","expectation","family_id","snapshot"];[]) and
  (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.expected_revision | schema::git_revision_ref_ok) and
  (.expectation | scanner_expectation_shape) and
  (.snapshot | snapshot_pair_shape);

# The run id is "evals.run." + seed id, so a seed id must leave room for the
# prefix inside the shared 128-character id limit.
def run_id_prefix: "evals.run.";
def seed_set_id_ok: schema::id_ok and ((run_id_prefix + .) | schema::id_ok);

def seed_set_shape:
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_seed_set" and (.id | seed_set_id_ok) and
  (.body |
   schema::exact_fields(["cases","core_contract","seed_source","shared"];[]) and
   .core_contract == expected_core and
   (.seed_source as $source | active_seed_sources | index($source) != null) and
   (if .seed_source == "core.stage-run.v2" then
      (.shared |
       schema::exact_fields(["requests","resolved_profile"];[]) and
       (.requests | type == "object" and length >= 1 and
        all(keys[]; . as $role | request_roles | index($role) != null) and
        all(.[]; pair_shape("stage_request"))) and
       (.resolved_profile | pair_shape("resolved_profile"))) and
      (.cases | schema::bounded_set(1;64;stage_run_case_shape;.case_id)) and
      # Every case names a request the shared set actually carries.
      (.shared.requests | keys) as $roles |
      all(.cases[]; .request_role as $role | $roles | index($role) != null)
    elif .seed_source == "orchestrator.state-scanner.v1" then
      # Scanner cases are self-contained: each carries its own snapshot.
      .shared == {} and
      (.cases | schema::bounded_set(1;64;scanner_case_shape;.case_id))
    elif .seed_source == "control.sandbox-policy.v1" then
      .shared == {} and
      (.cases | schema::bounded_set(1;64;sandbox_case_shape;.case_id))
    elif .seed_source == "control.risk-gates.v1" then
      .shared == {} and
      (.cases | schema::bounded_set(1;64;risk_gates_case_shape;.case_id))
    elif .seed_source == "adapters.provider-normalizers.v1" then
      .shared == {} and
      (.cases | schema::bounded_set(1;64;normalizer_case_shape;.case_id))
    else
      .shared == {} and
      (.cases | schema::bounded_set(1;64;planner_case_shape;.case_id))
    end));

# A seed set may only feed families the catalog says draw on its source.
def seed_set_bound($catalog):
  seed_set_shape and
  (.body.seed_source as $source |
   all(.body.cases[]; .family_id as $family |
     ([$catalog.body.families[] | select(.family_id == $family) | .seed_sources[]] |
      index($source)) != null));

def stage_run_observation_shape:
  schema::exact_fields(["case_id","disposition","error_token","status"];[]) and
  (.case_id | schema::id_ok) and
  ((.disposition == "accepted" and
    (.status | present_shape(. as $s | stage_statuses | index($s) != null)) and
    .error_token == {state:"absent"}) or
   (.disposition == "rejected" and .status == {state:"absent"} and
    (.error_token | present_shape(. as $t | core_error_tokens | index($t) != null))));

def scanner_observation_shape:
  schema::exact_fields(["case_id","classification","disposition","error_token"];[]) and
  (.case_id | schema::id_ok) and
  ((.disposition == "observed" and
    (.classification | present_shape(classification_shape)) and
    .classification.state == "present" and .error_token == {state:"absent"}) or
   (.disposition == "rejected" and .classification == {state:"absent"} and
    (.error_token | present_shape(. as $t | scanner_error_tokens | index($t) != null)) and
    .error_token.state == "present"));

def planner_observation_shape:
  schema::exact_fields(["case_id","disposition","error_token","plan"];[]) and
  (.case_id | schema::id_ok) and
  ((.disposition == "planned" and
    (.plan | present_shape(plan_summary_shape)) and .plan.state == "present" and
    .error_token == {state:"absent"}) or
   (.disposition == "rejected" and .plan == {state:"absent"} and
    (.error_token | present_shape(. as $t | planner_error_tokens | index($t) != null)) and
    .error_token.state == "present"));

def normalizer_observation_shape:
  schema::exact_fields(["case_id","disposition","error_token","normalization"];[]) and
  (.case_id | schema::id_ok) and
  ((.disposition == "normalized" and
    (.normalization | present_shape(normalization_shape)) and
    .normalization.state == "present" and .error_token == {state:"absent"}) or
   (.disposition == "rejected" and .normalization == {state:"absent"} and
    (.error_token | present_shape(. as $t | normalizer_error_ids | index($t) != null)) and
    .error_token.state == "present"));

def control_observation_shape($verdicts; $tokens):
  schema::exact_fields(["case_id","disposition","error_token","evaluation"];[]) and
  (.case_id | schema::id_ok) and
  ((.disposition == "evaluated" and
    (.evaluation | present_shape(control_evaluation_shape($verdicts))) and
    .evaluation.state == "present" and .error_token == {state:"absent"}) or
   (.disposition == "rejected" and .evaluation == {state:"absent"} and
    (.error_token | present_shape(. as $t | $tokens | index($t) != null)) and
    .error_token.state == "present"));
def sandbox_observation_shape:
  control_observation_shape(sandbox_verdicts; sandbox_error_tokens);
def risk_gates_observation_shape:
  control_observation_shape(risk_gates_verdicts; risk_gates_error_tokens);

def observation_shape($source):
  if $source == "core.stage-run.v2" then stage_run_observation_shape
  elif $source == "orchestrator.state-scanner.v1" then scanner_observation_shape
  elif $source == "control.sandbox-policy.v1" then sandbox_observation_shape
  elif $source == "control.risk-gates.v1" then risk_gates_observation_shape
  elif $source == "adapters.provider-normalizers.v1" then normalizer_observation_shape
  else planner_observation_shape end;

def observation_set_shape($source):
  type == "array" and length >= 1 and length <= 64 and
  all(.[]; observation_shape($source)) and
  (map(.case_id) as $ids | ($ids | length) == ($ids | unique | length));

# Deterministic grading. A family without a deterministic grader cannot be
# decided here and stays inconclusive; nothing is inferred from silence.
def grade($family; $expectation; $observation):
  if ($family.grader_kinds | index("deterministic")) == null then
    {verdict:"inconclusive",reason_id:"evals.no-deterministic-grader"}
  elif $observation == null then
    {verdict:"inconclusive",reason_id:"evals.observation-missing"}
  elif $expectation.disposition != $observation.disposition then
    {verdict:"failed",reason_id:"evals.disposition-mismatch"}
  elif $expectation.disposition == "accepted" then
    if $observation.status == {state:"present",value:$expectation.status} then
      {verdict:"passed",reason_id:"evals.expectation-met"}
    else {verdict:"failed",reason_id:"evals.status-mismatch"} end
  elif $expectation.disposition == "observed" then
    if $observation.classification ==
       {state:"present",value:($expectation | del(.disposition))} then
      {verdict:"passed",reason_id:"evals.expectation-met"}
    else {verdict:"failed",reason_id:"evals.classification-mismatch"} end
  elif $expectation.disposition == "planned" then
    if $observation.plan == {state:"present",value:($expectation | del(.disposition))} then
      {verdict:"passed",reason_id:"evals.expectation-met"}
    else {verdict:"failed",reason_id:"evals.plan-mismatch"} end
  elif $expectation.disposition == "evaluated" then
    if $observation.evaluation ==
       {state:"present",value:($expectation | del(.disposition))} then
      {verdict:"passed",reason_id:"evals.expectation-met"}
    else {verdict:"failed",reason_id:"evals.verdict-mismatch"} end
  elif $expectation.disposition == "normalized" then
    if $observation.normalization ==
       {state:"present",value:($expectation | del(.disposition))} then
      {verdict:"passed",reason_id:"evals.expectation-met"}
    else {verdict:"failed",reason_id:"evals.normalization-mismatch"} end
  else
    if $observation.error_token == {state:"present",value:$expectation.error_token} then
      {verdict:"passed",reason_id:"evals.expectation-met"}
    else {verdict:"failed",reason_id:"evals.error-token-mismatch"} end
  end;

def grader_kind_for($family):
  if ($family.grader_kinds | index("deterministic")) != null
  then "deterministic" else "none" end;

def trace_event($case; $family; $tool_ref; $evaluator_ref):
  {
    event_kind:"eval-case",
    case_id:$case.case_id,
    family_id:$family.family_id,
    grader_kind:grader_kind_for($family),
    tool_ref:$tool_ref,
    adapter:{state:"absent"},
    gate:{state:"absent"},
    identity:{evaluator_ref:$evaluator_ref},
    latency:{state:"absent"},
    cost:{state:"absent"}
  };

def evaluator_ref($evaluator_sha):
  {content_id:"evals-framework-evaluator.v1",
   media_type:"application/vnd.ystack.eval-framework-evaluator+json",
   sha256:$evaluator_sha};

def document_ref($doc; $sha):
  {schema_version:1,kind:$doc.kind,id:$doc.id,sha256:$sha};

# The tool each case was replayed through: the core front door for stage runs,
# the scanner bootstrap, the sandbox evaluator, the planner, or the one
# normalizer the case names. Digests come from the caller.
def tool_ref($source; $case):
  if $source == "adapters.provider-normalizers.v1" then
    {content_id:("adapter-normalizer." + $case.normalizer + ".v1"),media_type:"text/x-jq",
     sha256:$normalizer_shas[$case.normalizer]}
  else
    {content_id:tool_content_id($source),media_type:tool_media_type($source),
     sha256:(if $source == "core.stage-run.v2" then $tool_sha256
             elif $source == "orchestrator.state-scanner.v1" then $scanner_sha256
             elif $source == "control.sandbox-policy.v1" then $sandbox_sha256
             elif $source == "control.risk-gates.v1" then $risk_gates_sha256
             else $planner_sha256 end)}
  end;

def tool_ref_ok($source):
  if $source == "adapters.provider-normalizers.v1" then
    schema::content_ref_ok and .media_type == "text/x-jq" and
    (.content_id | test("\\Aadapter-normalizer\\.(codex-cli-producer|codex-native-reviewer|github-actions-ci|github-forge|gitlab-forge)\\.v1\\z")) and
    .sha256 == $normalizer_shas[.content_id | ltrimstr("adapter-normalizer.") | rtrimstr(".v1")]
  else ref_shape(tool_content_id($source);tool_media_type($source)) end;

def build_run_result(
    $catalog; $catalog_sha; $evaluator; $evaluator_sha;
    $seed_set; $seed_set_sha; $observations; $observed_at):
  ($catalog.body.families | map({key:.family_id,value:.}) | from_entries) as $families |
  ($observations | map({key:.case_id,value:.}) | from_entries) as $observed |
  ($seed_set.body.cases | sort_by(.case_id) | map(
     . as $case |
     $families[$case.family_id] as $family |
     $observed[$case.case_id] as $observation |
     grade($family;$case.expectation;$observation) as $graded |
     {
       case_id:$case.case_id,
       family_id:$case.family_id,
       grader_kind:grader_kind_for($family),
       expectation:$case.expectation,
       observation:(if $observation == null then {state:"absent"}
                    else {state:"present",value:$observation} end),
       verdict:$graded.verdict,
       reason_id:$graded.reason_id,
       subject_ref:
         (if $seed_set.body.seed_source == "core.stage-run.v2" then
            {schema_version:2,kind:"stage_result",
             id:$case.result.content.id,sha256:$case.result.sha256}
          elif $seed_set.body.seed_source == "orchestrator.state-scanner.v1" then
            {schema_version:1,kind:"orchestrator_state_snapshot",
             id:$case.snapshot.content.id,sha256:$case.snapshot.sha256}
          elif $seed_set.body.seed_source == "control.sandbox-policy.v1" then
            {schema_version:1,kind:"execution_environment_claim",
             id:$case.inputs.claim.content.id,sha256:$case.inputs.claim.sha256}
          elif $seed_set.body.seed_source == "control.risk-gates.v1" then
            {schema_version:1,kind:"risk_gate_decision_claim",
             id:$case.inputs.claim.content.id,sha256:$case.inputs.claim.sha256}
          elif $seed_set.body.seed_source == "adapters.provider-normalizers.v1" then
            {content_id:"adapter-provider-snapshot.v1",
             media_type:"application/json",sha256:$case.input.sha256}
          else
            {content_id:"orchestrator-reconciliation-input.v1",
             media_type:"application/json",sha256:$case.input.sha256}
          end)
     })) as $cases |
  {
    schema_version:1,
    kind:"eval_run_result",
    id:(run_id_prefix + $seed_set.id),
    body:{
      activation_state:"inactive",
      authority_effect:"none",
      mode:"deterministic-offline",
      core_contract:expected_core,
      catalog_ref:document_ref($catalog;$catalog_sha),
      evaluator:{content:$evaluator,sha256:$evaluator_sha},
      seed_set_ref:document_ref($seed_set;$seed_set_sha),
      seed_source:$seed_set.body.seed_source,
      observed_at:$observed_at,
      summary:{
        total:($cases | length),
        passed:($cases | map(select(.verdict == "passed")) | length),
        failed:($cases | map(select(.verdict == "failed")) | length),
        inconclusive:($cases | map(select(.verdict == "inconclusive")) | length)
      },
      cases:$cases,
      trace:($seed_set.body.cases | sort_by(.case_id) | map(
        trace_event(.;$families[.family_id];tool_ref($seed_set.body.seed_source;.);
                    evaluator_ref($evaluator_sha))))
    }
  };

def subject_ref_shape($source):
  if $source == "core.stage-run.v2" then schema::document_ref_kind_ok("stage_result")
  elif $source == "orchestrator.reconciliation-plan.v1" then
    ref_shape("orchestrator-reconciliation-input.v1";"application/json")
  elif $source == "adapters.provider-normalizers.v1" then
    ref_shape("adapter-provider-snapshot.v1";"application/json")
  elif $source == "control.risk-gates.v1" then
    schema::exact_fields(["id","kind","schema_version","sha256"];[]) and
    .schema_version == 1 and .kind == "risk_gate_decision_claim" and
    (.id | schema::id_ok) and (.sha256 | schema::sha256_ok)
  elif $source == "control.sandbox-policy.v1" then
    schema::exact_fields(["id","kind","schema_version","sha256"];[]) and
    .schema_version == 1 and .kind == "execution_environment_claim" and
    (.id | schema::id_ok) and (.sha256 | schema::sha256_ok)
  else
    schema::exact_fields(["id","kind","schema_version","sha256"];[]) and
    .schema_version == 1 and .kind == "orchestrator_state_snapshot" and
    (.id | schema::id_ok) and (.sha256 | schema::sha256_ok)
  end;

def case_result_shape($source):
  schema::exact_fields(
    ["case_id","expectation","family_id","grader_kind","observation",
     "reason_id","subject_ref","verdict"];[]) and
  (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.grader_kind == "deterministic" or .grader_kind == "none") and
  (.expectation | expectation_shape($source)) and
  (.observation | present_shape(observation_shape($source))) and
  (.verdict as $v | verdicts | index($v) != null) and
  (.reason_id | schema::id_ok) and
  (.subject_ref | subject_ref_shape($source)) and
  (if .grader_kind == "none" then .verdict == "inconclusive" else true end) and
  (if .observation.state == "absent" then .verdict == "inconclusive" else true end);

def trace_event_shape($source):
  schema::exact_fields(
    ["adapter","case_id","cost","event_kind","family_id","gate","grader_kind",
     "identity","latency","tool_ref"];[]) and
  .event_kind == "eval-case" and (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.grader_kind == "deterministic" or .grader_kind == "none") and
  (.tool_ref | tool_ref_ok($source)) and
  .adapter == {state:"absent"} and .gate == {state:"absent"} and
  .latency == {state:"absent"} and .cost == {state:"absent"} and
  (.identity |
   schema::exact_fields(["evaluator_ref"];[]) and
   (.evaluator_ref |
    ref_shape("evals-framework-evaluator.v1";
              "application/vnd.ystack.eval-framework-evaluator+json")));

def run_result_shape($catalog_sha; $evaluator_sha; $seed_set; $seed_set_sha):
  . as $result |
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_run_result" and (.id | schema::id_ok) and
  (.body |
   schema::exact_fields(
     ["activation_state","authority_effect","cases","catalog_ref","core_contract",
      "evaluator","mode","observed_at","seed_set_ref","seed_source","summary",
      "trace"];[]) and
   .activation_state == "inactive" and .authority_effect == "none" and
   .mode == "deterministic-offline" and .core_contract == expected_core and
   .seed_source == $seed_set.body.seed_source and
   .seed_source as $source |
   (.catalog_ref |
    schema::exact_fields(["id","kind","schema_version","sha256"];[]) and
    .schema_version == 1 and .kind == "eval_catalog" and .id == "evals.catalog.v1" and
    .sha256 == $catalog_sha) and
   (.seed_set_ref |
    schema::exact_fields(["id","kind","schema_version","sha256"];[]) and
    .schema_version == 1 and .kind == "eval_seed_set" and .id == $seed_set.id and
    .sha256 == $seed_set_sha) and
   (.evaluator |
    schema::exact_fields(["content","sha256"];[]) and
    (.content | evaluator_shape) and .sha256 == $evaluator_sha) and
   $result.id == (run_id_prefix + $seed_set.id) and
   (.observed_at | schema::time_ok) and
   (.cases | schema::bounded_set(1;64;case_result_shape($source);.case_id)) and
   (.trace | schema::bounded_set(1;64;trace_event_shape($source);.case_id)) and
   ((.cases | map(.case_id)) == (.trace | map(.case_id))) and
   # A trace event never claims a grader the case result did not have.
   ((.cases | map([.case_id, .grader_kind, .family_id])) ==
    (.trace | map([.case_id, .grader_kind, .family_id]))) and
   (.summary |
    schema::exact_fields(["failed","inconclusive","passed","total"];[]) and
    all(.[]; schema::int_ok) and
    .total == ($result.body.cases | length) and
    .passed == ($result.body.cases | map(select(.verdict == "passed")) | length) and
    .failed == ($result.body.cases | map(select(.verdict == "failed")) | length) and
    .inconclusive ==
      ($result.body.cases | map(select(.verdict == "inconclusive")) | length)) and
   all(.trace[]; .identity.evaluator_ref.sha256 == $result.body.evaluator.sha256));

# Flow/quality dashboard over one or more validated run results. Every number
# is a count derived from the results handed in; nothing is measured live, so
# latency, cost, and operating-flow metrics are recorded absent with a reason.
def flow_metric_ids:
  ["accepted-plan-to-merge-time","dora-instability","dora-throughput","escaped-defects",
   "escaped-vulnerabilities","first-pass-success","human-gate-wait","intent-to-spec-time",
   "queue-wait","review-latency","review-precision","review-recall-samples",
   "review-stale-rate","rework-cycles","target-outcome"];
def telemetry_metric_ids: ["cost","latency","tokens"];
def absent_metric($reason): {state:"absent",reason_id:$reason};
def dashboard_id: "evals.dashboard.v1";

def verdict_counts:
  {total:length,
   passed:(map(select(.verdict == "passed")) | length),
   failed:(map(select(.verdict == "failed")) | length),
   inconclusive:(map(select(.verdict == "inconclusive")) | length)};

# Recovery evidence is read from the events family's passed cases: what the
# scanner or planner did with a missed, cancelled, or repeated event.
def recovery_counts:
  map(select(.family_id == "repeated-cancelled-missed-events" and .verdict == "passed")) |
  {stranded_recovered:
     (map(select(.expectation.class == "stranded" or
                 ((.expectation.deliveries // []) |
                  any(.operation == "recover-stranded-attempt")))) | length),
   cancelled_stayed_terminal:
     (map(select(.expectation.reason_id == "scanner.stage-cancelled")) | length),
   repeats_redelivered_once:
     (map(select((.expectation.deliveries // []) | any(.delivery_mode == "redelivery"))) | length),
   repeats_suppressed_after_acknowledgement:
     (map(select(((.expectation.suppressed // []) | length) > 0)) | length),
   retry_limit_enforced:
     (map(select(.expectation.reason_id == "scanner.retry-limit-reached")) | length),
   events_refused:
     (map(select(.expectation.disposition == "rejected")) | length)};

def build_dashboard($catalog; $catalog_sha; $evaluator; $evaluator_sha; $results;
                    $result_shas; $observed_at):
  ([range(0; $results | length) as $index |
    {run_id:$results[$index].id,
     seed_source:$results[$index].body.seed_source,
     seed_set_ref:$results[$index].body.seed_set_ref,
     result_sha256:$result_shas[$index],
     observed_at:$results[$index].body.observed_at,
     summary:$results[$index].body.summary}] | sort_by(.result_sha256)) as $inputs |
  ([$results[].body.cases[]]) as $cases |
  ([$results[].body.trace[]]) as $trace |
  {
    schema_version:1,
    kind:"eval_dashboard",
    id:dashboard_id,
    body:{
      activation_state:"inactive",
      authority_effect:"none",
      mode:"deterministic-offline",
      core_contract:expected_core,
      catalog_ref:document_ref($catalog;$catalog_sha),
      evaluator:{content:$evaluator,sha256:$evaluator_sha},
      observed_at:$observed_at,
      inputs:$inputs,
      coverage:{
        families_total:($catalog.body.families | length),
        families_seeded:([$catalog.body.families[] | select(.seed_status == "seeded")] | length),
        families_declared:([$catalog.body.families[] | select(.seed_status == "declared")] | length),
        families_with_results:([$cases[].family_id] | unique | length),
        sources_with_results:([$results[].body.seed_source] | unique)
      },
      families:[
        $catalog.body.families[] | .family_id as $family |
        ([$cases[] | select(.family_id == $family)]) as $family_cases |
        {family_id:$family,
         seed_status:.seed_status,
         seed_sources:.seed_sources,
         grader_kinds:.grader_kinds,
         trial_policy:.trial_policy,
         runs:([$results[] | select(any(.body.cases[]; .family_id == $family))] | length),
         cases:($family_cases | verdict_counts)}
      ],
      quality:($cases | verdict_counts),
      recovery:($cases | recovery_counts),
      telemetry:(
        telemetry_metric_ids | map({key:.,
          value:(if . == "tokens" then absent_metric("evals.no-live-runs")
                 elif all($trace[]; .[if . == "cost" then "cost" else "latency" end] == {state:"absent"})
                 then absent_metric("evals.no-live-runs")
                 else absent_metric("evals.telemetry-not-aggregated") end)}) | from_entries),
      flow:(flow_metric_ids | map({key:.,value:absent_metric("evals.no-operating-history")}) |
            from_entries)
    }
  };

def dashboard_input_shape:
  schema::exact_fields(
    ["observed_at","result_sha256","run_id","seed_set_ref","seed_source","summary"];[]) and
  (.run_id | schema::id_ok) and (.result_sha256 | schema::sha256_ok) and
  (.seed_source as $source | active_seed_sources | index($source) != null) and
  (.observed_at | schema::time_ok) and
  (.seed_set_ref |
   schema::exact_fields(["id","kind","schema_version","sha256"];[]) and
   .schema_version == 1 and .kind == "eval_seed_set" and (.id | schema::id_ok) and
   (.sha256 | schema::sha256_ok)) and
  (.summary | schema::exact_fields(["failed","inconclusive","passed","total"];[]) and
   all(.[]; schema::int_ok and . >= 0));

def dashboard_shape($catalog; $catalog_sha; $evaluator_sha; $results; $result_shas;
                    $observed_at):
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_dashboard" and .id == dashboard_id and
  (.body |
   schema::exact_fields(
     ["activation_state","authority_effect","catalog_ref","core_contract","coverage",
      "evaluator","families","flow","inputs","mode","observed_at","quality","recovery",
      "telemetry"];[]) and
   .activation_state == "inactive" and .authority_effect == "none" and
   .mode == "deterministic-offline" and .core_contract == expected_core and
   .catalog_ref == document_ref($catalog;$catalog_sha) and
   (.evaluator | schema::exact_fields(["content","sha256"];[]) and
    (.content | evaluator_shape) and .sha256 == $evaluator_sha) and
   .observed_at == $observed_at and
   (.inputs | schema::bounded_set(1;16;dashboard_input_shape;.result_sha256)) and
   ((.inputs | map(.result_sha256) | sort) == ($result_shas | sort)) and
   (.families | schema::bounded_set(9;9;
      (schema::exact_fields(
         ["cases","family_id","grader_kinds","runs","seed_sources","seed_status",
          "trial_policy"];[]) and
       (.family_id as $id | family_ids | index($id) != null) and
       (.runs | schema::int_ok) and .runs >= 0 and .runs <= 16 and
       (.cases | all(.[]; schema::int_ok and . >= 0)));.family_id)) and
   (.coverage | schema::exact_fields(
      ["families_declared","families_seeded","families_total","families_with_results",
       "sources_with_results"];[]) and .families_total == 9 and
    .families_seeded + .families_declared == 9 and
    (.sources_with_results | schema::enum_set_ok(1;8;active_seed_sources))) and
   (.quality | all(.[]; schema::int_ok and . >= 0)) and
   (.recovery | all(.[]; schema::int_ok and . >= 0)) and
   (.telemetry | keys == telemetry_metric_ids and
    all(.[]; .state == "absent" and (.reason_id | schema::id_ok))) and
   (.flow | keys == flow_metric_ids and
    all(.[]; . == absent_metric("evals.no-operating-history"))));

# Results are accepted into a dashboard only after the driver and launcher have
# validated each one against its own seed set; here they must be distinct,
# canonical results of this catalog and program.
def dashboard_results_ok($result_shas):
  ($result_shas | type == "array" and length >= 1 and length <= 16 and
   all(.[]; schema::sha256_ok) and (length == (unique | length))) and
  length == ($result_shas | length) and
  all(.[]; schema::exact_fields(["body","id","kind","schema_version"];[]) and
           .schema_version == 1 and .kind == "eval_run_result" and
           (.body.seed_source as $source | active_seed_sources | index($source) != null) and
           (.body.evaluator.content | evaluator_shape) and
           (.body.catalog_ref.sha256 == $catalog_sha256));

# Driver entry points, selected with --arg evals_operation.
if $evals_operation == "validate-catalog" then
  $catalog_docs[0] | catalog_shape
elif $evals_operation == "validate-seed-set" then
  $seed_set_docs[0] | seed_set_bound($catalog_docs[0])
elif $evals_operation == "build-run-result" then
  ($catalog_docs[0] | catalog_shape) and
  ($seed_set_docs[0] | seed_set_bound($catalog_docs[0])) and
  ($observation_docs[0] | observation_set_shape($seed_set_docs[0].body.seed_source)) and
  ($evaluator_docs[0] | evaluator_shape) |
  if . then
    build_run_result(
      $catalog_docs[0];$catalog_sha256;$evaluator_docs[0];$evaluator_sha256;
      $seed_set_docs[0];$seed_set_sha256;$observation_docs[0];$observed_at)
  else error("E_SHAPE") end
elif $evals_operation == "build-dashboard" then
  ($catalog_docs[0] | catalog_shape) and
  ($evaluator_docs[0] | evaluator_shape) and
  ($result_docs | dashboard_results_ok($result_shas)) |
  if . then
    build_dashboard(
      $catalog_docs[0];$catalog_sha256;$evaluator_docs[0];$evaluator_sha256;
      $result_docs;$result_shas;$observed_at)
  else error("E_SHAPE") end
elif $evals_operation == "validate-dashboard" then
  ($catalog_docs[0] | catalog_shape) and
  ($evaluator_docs[0] | evaluator_shape) and
  ($result_docs | dashboard_results_ok($result_shas)) and
  ($candidate_docs[0] |
   dashboard_shape($catalog_docs[0];$catalog_sha256;$evaluator_sha256;$result_docs;
                   $result_shas;$observed_at)) and
  $candidate_docs[0] ==
    build_dashboard(
      $catalog_docs[0];$catalog_sha256;$evaluator_docs[0];$evaluator_sha256;
      $result_docs;$result_shas;$observed_at)
elif $evals_operation == "validate-run-result" then
  # A candidate passes only if it is exactly the result this program derives
  # from the same catalog, evaluator, seed set, and recorded observations.
  ($catalog_docs[0] | catalog_shape) and
  ($seed_set_docs[0] | seed_set_bound($catalog_docs[0])) and
  ($observation_docs[0] | observation_set_shape($seed_set_docs[0].body.seed_source)) and
  ($evaluator_docs[0] | evaluator_shape) and
  ($candidate_docs[0] |
   run_result_shape($catalog_sha256; $evaluator_sha256; $seed_set_docs[0]; $seed_set_sha256)) and
  $candidate_docs[0] ==
    build_run_result(
      $catalog_docs[0];$catalog_sha256;$evaluator_docs[0];$evaluator_sha256;
      $seed_set_docs[0];$seed_set_sha256;$observation_docs[0];$observed_at)
else error("E_RUNTIME") end
