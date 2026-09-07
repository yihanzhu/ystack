# Copied from evals/v1/evals.jq at c76f42a5753f604c6c57245ee2c87a4eff474637 and
# from the schema module of the selected core v2 generation
# (core/v2/generations/<generation>/modules/schema.jq) at that same commit —
# keep in sync. The eval dashboard has one fixed emitted shape, so the
# qualification gate is written against that whole shape rather than a
# hand-picked subset a stub could satisfy. Everything below is verbatim except
# two mechanical adaptations: the `schema::` module qualifiers are dropped (this
# program is run without a module path, and the helpers below are those module
# functions byte for byte), and `evaluator_shape` is replaced by the scope-side
# reading described above its own definition.
def exact_fields($required; $optional):
  . as $value |
  ($value | type) == "object" and
  (($value | keys_unsorted) - ($required + $optional) | length) == 0 and
  all($required[]; . as $key | $value | has($key));

def bounded_set($minimum; $maximum; item_ok; key):
  . as $items |
  ($items | type) == "array" and
  ($items | length) >= $minimum and
  ($items | length) <= $maximum and
  all($items[]; item_ok) and
  (($items | map(key)) as $keys |
   ($keys | length) == ($keys | unique | length) and
   $keys == ($keys | sort));

def enum_set_ok($minimum; $maximum; $allowed):
  . as $items |
  ($items | type) == "array" and
  ($items | length) >= $minimum and
  ($items | length) <= $maximum and
  all($items[]; . as $item | $allowed | index($item) != null) and
  ($items | length) == ($items | unique | length) and
  $items == ($items | sort);

def id_ok: type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");
# Schema receives only values accepted by the raw canonical-byte gate; jq 1.6 preserves -0 here.
def int_ok:
  type == "number" and
  . == floor and
  . >= 0 and
  . <= 2147483647 and
  tostring != "-0";
def sha256_ok: type == "string" and test("\\A[0-9a-f]{64}\\z");
def media_type_ok:
  type == "string" and
  length <= 127 and
  test("\\A[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*\\z");

def time_ok:
  type == "string" and
  test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z") and
  (capture("\\A(?<year>[0-9]{4})-(?<month>[0-9]{2})-(?<day>[0-9]{2})T(?<hour>[0-9]{2}):(?<minute>[0-9]{2}):(?<second>[0-9]{2})Z\\z") as $parts |
   ($parts.year | tonumber) as $year |
   ($parts.month | tonumber) as $month |
   ($parts.day | tonumber) as $day |
   ($parts.hour | tonumber) as $hour |
   ($parts.minute | tonumber) as $minute |
   ($parts.second | tonumber) as $second |
   ($year % 4 == 0 and ($year % 100 != 0 or $year % 400 == 0)) as $leap |
   [31,(if $leap then 29 else 28 end),31,30,31,30,31,31,30,31,30,31] as $days |
   $month >= 1 and $month <= 12 and
   $day >= 1 and $day <= $days[$month - 1] and
   $hour >= 0 and $hour <= 23 and
   $minute >= 0 and $minute <= 59 and
   $second >= 0 and $second <= 59);

def content_ref_ok:
  exact_fields(["content_id","media_type","sha256"];[]) and
  (.content_id | id_ok) and
  (.content_id | contains(":") | not) and
  (.content_id | contains("/") | not) and
  (.media_type | media_type_ok) and
  (.sha256 | sha256_ok);

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

def document_ref($doc; $sha):
  {schema_version:1,kind:$doc.kind,id:$doc.id,sha256:$sha};

def ref_shape($content_id; $media_type):
  content_ref_ok and
  .content_id == $content_id and .media_type == $media_type;

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

def active_seed_sources:
  ["adapters.provider-normalizers.v1","control.duty-separation.v1","control.risk-gates.v1",
   "control.sandbox-policy.v1","core.stage-run.v2","orchestrator.reconciliation-plan.v1",
   "orchestrator.state-scanner.v1"];

def flow_metric_ids:
  ["accepted-plan-to-merge-time","dora-instability","dora-throughput","escaped-defects",
   "escaped-vulnerabilities","first-pass-success","human-gate-wait","intent-to-spec-time",
   "queue-wait","review-latency","review-precision","review-recall-samples",
   "review-stale-rate","rework-cycles","target-outcome"];
def telemetry_metric_ids: ["cost","latency","tokens"];
def absent_metric($reason): {state:"absent",reason_id:$reason};
def dashboard_id: "evals.dashboard.v1";

# The one adaptation. The evals framework checks this block against the pinned
# closure digests of the core, orchestrator, control, and adapter files it
# replayed, and against the driver, program, and catalog digests its own run
# measured. This evaluator replays nothing and is handed no evals run, so it
# cannot know those digests; pinning another component's file digests here would
# also make an unrelated edit anywhere in the tree refuse every scope. It reads
# the block the framework emits structurally instead: the evaluator document's
# own identity, every body key, the portable core contract, each shipped
# artifact reference by content id and media type, the four closures as
# path/digest lists, and the runtime block down to the pinned jq 1.6 digests.
def closure_shape:
  type == "array" and length >= 1 and length <= 64 and
  all(.[];
      exact_fields(["path","sha256"];[]) and
      (.path | type == "string" and length >= 1 and length <= 255) and
      (.sha256 | sha256_ok));
def evaluator_shape:
  exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_framework_evaluator" and
  .id == "evals.framework.v1" and
  (.body |
   exact_fields(
     ["adapter_closure","bootstrap_ref","catalog_ref","control_closure","core_closure",
      "core_contract","driver_ref","launcher_ref","orchestrator_closure","program_ref",
      "runtime"];[]) and
   .core_contract == expected_core and
   (.core_closure | closure_shape) and
   (.orchestrator_closure | closure_shape) and
   (.control_closure | closure_shape) and
   (.adapter_closure | closure_shape) and
   (.bootstrap_ref | ref_shape("evals-framework-bootstrap.v1";"text/x-shellscript")) and
   (.launcher_ref | ref_shape("evals-framework-launcher.v1";"text/x-shellscript")) and
   (.driver_ref | ref_shape("evals-framework-driver.v1";"text/x-shellscript")) and
   (.program_ref | ref_shape("evals-framework-program.v1";"text/x-jq")) and
   (.catalog_ref |
    ref_shape("evals-catalog.v1";"application/vnd.ystack.eval-catalog+json")) and
   (.runtime |
    exact_fields(
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

def dashboard_input_shape:
  exact_fields(
    ["observed_at","result_sha256","run_id","seed_set_ref","seed_source","summary"];[]) and
  (.run_id | id_ok) and (.result_sha256 | sha256_ok) and
  (.seed_source as $source | active_seed_sources | index($source) != null) and
  (.observed_at | time_ok) and
  (.seed_set_ref |
   exact_fields(["id","kind","schema_version","sha256"];[]) and
   .schema_version == 1 and .kind == "eval_seed_set" and (.id | id_ok) and
   (.sha256 | sha256_ok)) and
  (.summary | exact_fields(["failed","inconclusive","passed","total"];[]) and
   all(.[]; int_ok and . >= 0));


def dashboard_shape($catalog; $catalog_sha; $evaluator_sha; $results; $result_shas;
                    $observed_at):
  exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_dashboard" and .id == dashboard_id and
  (.body |
   exact_fields(
     ["activation_state","authority_effect","catalog_ref","core_contract","coverage",
      "evaluator","families","flow","inputs","mode","observed_at","quality","recovery",
      "telemetry"];[]) and
   .activation_state == "inactive" and .authority_effect == "none" and
   .mode == "deterministic-offline" and .core_contract == expected_core and
   .catalog_ref == document_ref($catalog;$catalog_sha) and
   (.evaluator | exact_fields(["content","sha256"];[]) and
    (.content | evaluator_shape) and .sha256 == $evaluator_sha) and
   .observed_at == $observed_at and
   (.inputs | bounded_set(1;16;dashboard_input_shape;.result_sha256)) and
   ((.inputs | map(.result_sha256) | sort) == ($result_shas | sort)) and
   (.families | bounded_set(9;9;
      (exact_fields(
         ["cases","family_id","grader_kinds","runs","seed_sources","seed_status",
          "trial_policy"];[]) and
       (.family_id as $id | family_ids | index($id) != null) and
       (.runs | int_ok) and .runs >= 0 and .runs <= 16 and
       (.cases | all(.[]; int_ok and . >= 0)));.family_id)) and
   (.coverage | exact_fields(
      ["families_declared","families_seeded","families_total","families_with_results",
       "sources_with_results"];[]) and .families_total == 9 and
    .families_seeded + .families_declared == 9 and
    (.sources_with_results | enum_set_ok(1;8;active_seed_sources))) and
   (.quality | all(.[]; int_ok and . >= 0)) and
   (.recovery | all(.[]; int_ok and . >= 0)) and
   (.telemetry | keys == telemetry_metric_ids and
    all(.[]; .state == "absent" and (.reason_id | id_ok))) and
   (.flow | keys == flow_metric_ids and
    all(.[]; . == absent_metric("evals.no-operating-history"))));

# End of the copied dashboard shape. Everything below is this component's own.

def count_ok:
  type == "number" and . == floor and . >= 0 and . <= 2147483647;

# This component's own document reference: core v2 documents are schema_version
# 2, so the schema version comes from the document rather than being fixed at 1
# the way the copied evals helper of the same name fixes it. The copy above kept
# its own; from here on this definition is the one in scope.
def document_ref($doc; $sha):
  {schema_version: $doc.schema_version, kind: $doc.kind, id: $doc.id, sha256: $sha};

def content_ref($content_id; $media_type; $sha):
  {content_id: $content_id, media_type: $media_type, sha256: $sha};

def oid_ok($algorithm):
  type == "string" and
  (if $algorithm == "sha256" then test("\\A[0-9a-f]{64}\\z")
   else test("\\A[0-9a-f]{40}\\z") end);

def revision_ok($repository_id):
  . as $revision |
  type == "object" and
  (keys | sort) == ["commit_id", "hash_algorithm", "repository_id"] and
  $revision.repository_id == $repository_id and
  ($revision.hash_algorithm == "sha1" or $revision.hash_algorithm == "sha256") and
  ($revision.commit_id | oid_ok($revision.hash_algorithm));

def exact($fields):
  type == "object" and (keys | sort) == ($fields | sort);

# Every real control evaluation names the policy set it was produced under.
def policy_set_ok:
  exact(["id", "sha256"]) and (.id | id_ok) and (.sha256 | sha256_ok);

def content_ref_ok($media_type):
  exact(["content_id", "media_type", "sha256"]) and (.content_id | id_ok) and
  .media_type == $media_type and (.sha256 | sha256_ok);

def document_ref_ok($schema_version; $kind):
  exact(["id", "kind", "schema_version", "sha256"]) and
  .schema_version == $schema_version and .kind == $kind and (.id | id_ok) and
  (.sha256 | sha256_ok);

def core_document_ref_ok($kind): document_ref_ok(2; $kind);

def control_document_ref_ok($kind): document_ref_ok(1; $kind);

# The portable core contract block the risk and duty evaluators copy out of the
# control policy set they ran under.
def core_contract_ok:
  exact(["generation_id", "package_ref", "semantic_identity"]) and
  (.semantic_identity | id_ok) and
  (.generation_id | type == "string" and test("\\Ag-[0-9a-f]{64}\\z")) and
  (.package_ref | content_ref_ok("application/vnd.ystack.core-contract+json"));

# The stage block the risk and duty evaluators both emit: which request, which
# resolved profile, which result the evaluation is about.
def stage_ok:
  exact(["request_ref", "resolved_profile_ref", "result_ref"]) and
  (.request_ref | core_document_ref_ok("stage_request")) and
  (.resolved_profile_ref | core_document_ref_ok("resolved_profile")) and
  (.result_ref | core_document_ref_ok("stage_result"));

def envelope_ok($kind):
  exact(["body", "id", "kind", "schema_version"]) and .schema_version == 1 and
  .kind == $kind and (.id | id_ok) and (.body | type == "object");

# The markers every control evaluation carries: it changed nothing, it only
# observed, its references are identities, and it names one policy set, one
# verdict from its own vocabulary, and a non-empty set of reason ids.
def control_markers_ok($verdicts):
  .activation_state == "inactive" and
  .evaluation_mode == "observation-only" and
  .reference_semantics == "identity-only" and
  (.policy_set | policy_set_ok) and
  (.verdict as $verdict | $verdicts | index($verdict) != null) and
  (.reason_ids |
   type == "array" and length >= 1 and length <= 64 and all(.[]; id_ok) and
   . == (sort | unique));

# The three gate evaluations are accepted only in the exact shape their own
# evaluators emit (control/v1/risk-gates.jq, control/v1/kill-switch.jq, and
# control/v1/duty-separation.jq), field for field and ref for ref, so a
# hand-written document carrying the envelope, the markers, and a verdict cannot
# stand in for a real evaluation. Each also has to be internally consistent: a
# verdict that does not follow from the reasons beside it is not something the
# real evaluator produces.
def risk_evaluation_ok:
  envelope_ok("risk_gate_evaluation") and
  (.body |
   exact(["activation_state", "authority_effect", "classification",
     "core_contract", "decision_claim_ref", "decision_ref",
     "duty_evaluation_ref", "evaluation_mode", "policy_ref", "policy_set",
     "reason_ids", "reference_semantics", "stage", "verdict"]) and
   control_markers_ok(["inconclusive", "violated"]) and
   .authority_effect == "none" and
   (.classification | exact(["declared_tier", "minimum_tier"]) and
    (.declared_tier as $tier |
     ["bootstrap", "high", "routine"] | index($tier) != null) and
    (.minimum_tier as $tier |
     ["bootstrap", "high", "routine", "unknown"] | index($tier) != null)) and
   # "inconclusive" iff every reason is one of the two unknowns the risk gate
   # can emit; anything else beside that verdict is a violation.
   ((.reason_ids |
     all(.[]; . == "duty.inconclusive" or
       . == "decision.provenance-unqualified")) ==
    (.verdict == "inconclusive")) and
   (.core_contract | core_contract_ok) and
   (.decision_claim_ref |
    content_ref_ok("application/vnd.ystack.risk-gate-decision-claim+json")) and
   (.decision_ref |
    content_ref_ok("application/vnd.ystack.control-decision+json")) and
   (.duty_evaluation_ref |
    content_ref_ok("application/vnd.ystack.duty-separation-evaluation+json")) and
   (.policy_ref |
    content_ref_ok("application/vnd.ystack.control-policy+json")) and
   (.stage | stage_ok));

def kill_evaluation_ok:
  envelope_ok("kill_switch_evaluation") and
  (.body |
   exact(["activation_state", "attempt_ref", "authority_effect", "decision_ref",
     "duty_decision_ref", "duty_evaluation_ref", "evaluation_mode", "policy_ref",
     "policy_set", "reason_ids", "reference_semantics", "state_ref",
     "verdict"]) and
   control_markers_ok(["inconclusive", "satisfied", "violated"]) and
   .authority_effect == "none" and
   # The kill-switch evaluator emits "satisfied" only with the single reason
   # kill.cleared-current, and never that reason with any other verdict.
   (if .verdict == "satisfied" then .reason_ids == ["kill.cleared-current"]
    else (.reason_ids | index("kill.cleared-current")) == null end) and
   (.decision_ref |
    content_ref_ok("application/vnd.ystack.control-decision+json")) and
   (.duty_decision_ref |
    content_ref_ok("application/vnd.ystack.control-decision+json")) and
   (.policy_ref |
    content_ref_ok("application/vnd.ystack.control-policy+json")) and
   (.state_ref | control_document_ref_ok("kill_switch_state")) and
   (.attempt_ref | control_document_ref_ok("kill_switch_attempt")) and
   (.duty_evaluation_ref |
    control_document_ref_ok("duty_separation_evaluation")));

def duty_evaluation_ok:
  envelope_ok("duty_separation_evaluation") and
  (.body |
   exact(["activation_state", "core_contract", "decision_ref",
     "evaluation_mode", "policy_ref", "policy_set", "reason_ids",
     "reference_semantics", "stage", "verdict"]) and
   control_markers_ok(["inconclusive", "satisfied", "violated"]) and
   # The duty evaluator emits "satisfied" only as duty.satisfied and
   # "inconclusive" only as actual.capability-unclassified; a violation is
   # neither of those reasons.
   ((.verdict == "satisfied" and .reason_ids == ["duty.satisfied"]) or
    (.verdict == "inconclusive" and
     .reason_ids == ["actual.capability-unclassified"]) or
    (.verdict == "violated" and
     (.reason_ids |
      all(.[]; . != "duty.satisfied" and
        . != "actual.capability-unclassified")))) and
   (.core_contract | core_contract_ok) and
   (.decision_ref |
    content_ref_ok("application/vnd.ystack.control-decision+json")) and
   (.policy_ref |
    content_ref_ok("application/vnd.ystack.control-policy+json")) and
   (.stage | stage_ok));

# Copied verbatim from shadow/v1/incident-record.jq at
# 949e08ddbe01252b405191e7e5ad5cc12afb8f75 (origin/main): the failing-check
# shape the incident record carries and the shadow record copies into its check
# block. The `exact`, `id_ok`, and `sha256_ok` helpers above are the same
# definitions that file uses.
def repo_path_ok:
  type == "string" and utf8bytelength >= 1 and utf8bytelength <= 4096 and
  (test("[[:cntrl:]]") | not) and (contains("\\") | not) and
  (startswith("/") | not) and
  (split("/") |
   length <= 64 and
   all(.[];
       . != "" and . != "." and . != ".." and (ascii_downcase != ".git") and
       (endswith(".") | not) and (endswith(" ") | not)));

def failing_check_ok:
  (exact(["expected_sha256","kind","path"]) and .kind == "file-digest" and
   (.path | repo_path_ok) and (.expected_sha256 | sha256_ok)) or
  (exact(["check_id","kind"]) and .kind == "named-check" and
   (.check_id | id_ok));
# End of the copied incident-record shape.

# A claimed shadow record is judged against the whole record the shadow slice
# emits, not a hand-picked subset of it: a scope may only be backed by evidence
# a real shadow run produced, and a hand-written document carrying the envelope,
# the markers, and an accepted outcome is not that. The slice encodes most of
# the record's shape in bash-built JSON rather than in jq, so the exact-key
# predicates below are written here and cited: the record body is built at
# shadow/v1/reproduce.sh:434-474 and pinned again by that script's own
# post-build self-check at 475-480; the environment evaluation section is built
# at 249-254, the materialization section at 290-297 under the read-only
# relations asserted at 283-288, and the check execution section at 342-346.
# All line numbers are in shadow/v1/reproduce.sh at
# 949e08ddbe01252b405191e7e5ad5cc12afb8f75 (origin/main).
def shadow_ref_ok($content_id; $media_type):
  exact(["content_id","media_type","sha256"]) and
  .content_id == $content_id and .media_type == $media_type and
  (.sha256 | sha256_ok);

def absent_section_ok($reasons):
  exact(["reason_id","state"]) and .state == "absent" and
  (.reason_id as $reason | $reasons | index($reason) != null);

# The sandbox evaluation the slice copies out of control/v1/sandbox.jq when the
# environment is listed and that evaluator returned a document. The verdict
# vocabulary and the satisfied/reason pairing are that evaluator's own
# (control/v1/sandbox.jq:254-256).
def environment_evaluation_ok:
  type == "object" and
  (if .state == "absent"
   then absent_section_ok(["environment.evaluation-refused","environment.unlisted"])
   else
     exact(["state","value"]) and .state == "present" and
     (.value |
      exact(["evaluation_ref","reason_ids","verdict"]) and
      (.verdict as $verdict |
       ["inconclusive","satisfied","violated"] | index($verdict) != null) and
      (.reason_ids |
       type == "array" and length >= 1 and length <= 64 and all(.[]; id_ok)) and
      ((.verdict == "satisfied") ==
       (.reason_ids == ["sandbox.declaration-satisfied"])) and
      (.evaluation_ref |
       shadow_ref_ok("shadow-sandbox-evaluation";
         "application/vnd.ystack.control-evaluation+json")))
   end);

# The materialization section, with the receipt fields
# adapters/local-git-materializer/v1/protocol.jq:266-277 builds and the
# relations the slice asserts over that receipt before recording it: the
# materialization ran at this record's own repository and revision, changed
# nothing, and named the core v2 stage result it produced.
def materialization_ok($revision; $repository):
  type == "object" and
  (if .state == "absent"
   then absent_section_ok(["materialization.not-attempted","materialization.refused"])
   else
     exact(["state","value"]) and .state == "present" and
     (.value |
      exact(["adapter_id","candidate","outcome","source","stage_result_ref"]) and
      .adapter_id == "adapter.local-git-materializer.v1" and
      # A shadow reproduction materializes the incident revision with an empty
      # patch, so the only materialization a real record can carry is a
      # no-change one; any other stage-result outcome is not a shadow record.
      .outcome == "no-change" and
      (.candidate |
       exact(["commit_id","hash_algorithm","parent_commit_id","repository_kind",
         "tree_id"]) and
       .repository_kind == "bare" and
       .hash_algorithm == $revision.hash_algorithm and
       .commit_id == $revision.commit_id and
       .parent_commit_id == $revision.commit_id and
       (.tree_id | oid_ok($revision.hash_algorithm))) and
      .source == {repository_id: $repository,
        hash_algorithm: $revision.hash_algorithm,
        commit_id: $revision.commit_id, tree_id: .candidate.tree_id} and
      (.stage_result_ref | core_document_ref_ok("stage_result")))
   end);

# The check block: the incident's failing check verbatim, and the execution
# section the slice records only after digesting the blob at that path.
def check_block_ok:
  . as $check |
  exact(["execution","failing_check"]) and
  ($check.failing_check | failing_check_ok) and
  ($check.execution |
   type == "object" and
   (if .state == "absent"
    then absent_section_ok(["check.not-attempted","check.unreadable"])
    else
      exact(["state","value"]) and .state == "present" and
      # Only a file-digest check is ever executed; a named check is
      # check.not-runnable and never reaches this section.
      ($check.failing_check.kind == "file-digest") and
      (.value |
       exact(["matches_expected","observed_sha256","tool_id"]) and
       .tool_id == "tool.git-blob-digest" and
       (.observed_sha256 | sha256_ok) and
       .matches_expected ==
         (.observed_sha256 == $check.failing_check.expected_sha256))
    end));

# The slice sets exactly one reason id per run, and each one fixes the outcome
# and which sections that run left present or absent
# (shadow/v1/reproduce.sh:227-347: the initial inconclusive/unlisted state, then
# the environment, materialization, and check stages in order, each reassigning
# `reason` as it goes). Any other combination is one no run of the slice can
# produce.
def slice_states:
  [{reason_id:"environment.unlisted",outcome:"inconclusive",
    environment:"absent",materialization:"absent",execution:"absent"},
   {reason_id:"environment.evaluation-refused",outcome:"inconclusive",
    environment:"absent",materialization:"absent",execution:"absent"},
   {reason_id:"environment.not-satisfied",outcome:"inconclusive",
    environment:"unsatisfied",materialization:"absent",execution:"absent"},
   {reason_id:"check.not-runnable",outcome:"inconclusive",
    environment:"satisfied",materialization:"absent",execution:"absent"},
   {reason_id:"materialization.refused",outcome:"inconclusive",
    environment:"satisfied",materialization:"absent",execution:"absent"},
   {reason_id:"check.unreadable",outcome:"inconclusive",
    environment:"satisfied",materialization:"present",execution:"absent"},
   {reason_id:"check.passed-at-revision",outcome:"no-change",
    environment:"satisfied",materialization:"present",execution:"matched"},
   {reason_id:"check.failed-at-revision",outcome:"reproduced",
    environment:"satisfied",materialization:"present",execution:"differed"}];

def slice_state_ok:
  . as $body |
  (slice_states | map(select(.reason_id == $body.reason_id))) as $states |
  ($states | length) == 1 and
  ($states[0] as $state |
   $body.outcome == $state.outcome and
   ($body.environment.evaluation |
    if $state.environment == "absent"
    then .state == "absent" and .reason_id == $body.reason_id
    else .state == "present" and
         ((.value.verdict == "satisfied") == ($state.environment == "satisfied"))
    end) and
   $body.materialization.state == $state.materialization and
   (if $state.materialization == "absent"
    then $body.materialization.reason_id ==
         (if $body.reason_id == "materialization.refused"
          then "materialization.refused"
          else "materialization.not-attempted" end)
    else true end) and
   ($body.check.execution |
    if $state.execution == "absent"
    then .state == "absent" and
         .reason_id == (if $body.reason_id == "check.unreadable"
                        then "check.unreadable" else "check.not-attempted" end)
    else .state == "present" and
         (.value.matches_expected == ($state.execution == "matched"))
    end));

def shadow_record_ok:
  exact(["body","id","kind","schema_version"]) and
  .schema_version == 1 and .kind == "shadow_reproduction_record" and
  (.id | id_ok) and
  (.body |
   . as $body |
   exact(["activation_state","authority","check","deploy_authority","effects",
     "environment","evaluation_mode","git_revision_ref","incident_ref",
     "materialization","observed_at","outcome","qualification","reason_id",
     "shadow","target_repository_id","trace_ledger_ref"]) and
   .activation_state == "inactive" and .authority == "none" and
   .deploy_authority == "none" and .shadow == true and
   .evaluation_mode == "observation-only" and
   .effects == ["caller-disposable-candidate-repository"] and
   .qualification == {state:"unavailable",reason_id:"shadow.unqualified"} and
   (.observed_at | time_ok) and
   (.target_repository_id | id_ok) and
   # The slice records the exact revision it reproduced at, so the scope can be
   # bound to it; a record that does not say which revision it ran against is
   # not a record this evaluator can attach qualification to.
   (.git_revision_ref | revision_ok($body.target_repository_id)) and
   (.incident_ref |
    shadow_ref_ok("shadow-incident-record";
      "application/vnd.ystack.shadow-incident-record+json")) and
   (.trace_ledger_ref |
    shadow_ref_ok("shadow-trace-ledger";
      "application/vnd.ystack.telemetry-trace-ledger+json")) and
   (.environment |
    exact(["claim_ref","environment_id","evaluation","registry_ref"]) and
    (.environment_id | id_ok) and
    (.claim_ref |
     shadow_ref_ok("shadow-environment-claim";
       "application/vnd.ystack.control-execution-environment-claim+json")) and
    (.registry_ref |
     shadow_ref_ok("shadow-environment-registry";
       "application/vnd.ystack.shadow-environment-registry+json")) and
    (.evaluation | environment_evaluation_ok)) and
   (.materialization |
    materialization_ok($body.git_revision_ref; $body.target_repository_id)) and
   (.check | check_block_ok) and
   # The shadow slice's closed outcome vocabulary, which is the one this
   # component's policy names; anything else is not a shadow record this
   # evaluator understands, so the set is malformed.
   (.outcome as $outcome |
    ($policy[0].body.accepted_shadow_outcomes +
     $policy[0].body.refused_shadow_outcomes) |
    index($outcome) != null) and
   slice_state_ok);

$policy[0].body as $p |
$scope[0] as $scope_doc |
$scope_doc.body as $s |
$s.qualified_identity as $identity |
$s.gate_evidence_refs as $gate_refs |
$shadow_set[0] as $set |
$dashboard[0] as $dash |
$risk[0] as $risk_doc |
$kill[0] as $kill_doc |
$duty[0] as $duty_doc |
$marker[0] as $mode_doc |

# Every supplied record is bound by kind, id, and the digest the driver measured
# over that record's own canonical bytes. Nothing a record says about itself is
# taken on trust beyond these shape checks.
(($record_shas | type == "array" and all(.[]; sha256_ok) and
  (length == (unique | length)))) as $shas_ok |
($shas_ok and
 ($set | type == "object" and .schema_version == 1 and
  .kind == "shadow_evidence_set" and (.id | id_ok) and
  (.body | type == "object" and (keys | sort) == ["records"]) and
  (.body.records |
   type == "array" and length >= 1 and length <= 16 and
   all(.[]; shadow_record_ok)) and
  ((.body.records | length) == ($record_shas | length)))) as $set_ok |
# The dashboard is judged against the evals framework's complete emitted shape,
# copied at the top of this file, and not against a subset of it: a stub that
# carried only the fields this evaluator reads could otherwise drive a
# proposable outcome. Four of that predicate's parameters are identities only an
# evals run holds — the catalog document, the evaluator digest, the result
# digests, and the observation time — so they are read back out of the candidate
# and the comparisons against them are checked here instead, for what a
# self-supplied value cannot establish: the catalog reference is a well-formed
# schema-version-1 eval_catalog reference, the evaluator digest is a digest, and
# the observation time is a real UTC timestamp. The scope-specific family reads
# this evaluator makes on top of the shape are kept as they were.
($dash |
 # A type guard first, so a block of the wrong type is a refusal rather than a
 # jq error part way through reading it.
 type == "object" and (.body | type == "object") and
 (.body |
  ([.catalog_ref, .evaluator, .quality, .recovery, .telemetry, .flow] |
   all(.[]; type == "object")) and
  (.inputs | type == "array" and all(.[]; type == "object")) and
  (.families |
   type == "array" and
   all(.[]; type == "object" and (.cases | type == "object")))) and
 dashboard_shape(
   {schema_version: .body.catalog_ref.schema_version,
    kind: .body.catalog_ref.kind, id: .body.catalog_ref.id};
   .body.catalog_ref.sha256; .body.evaluator.sha256; null;
   (.body.inputs | map(.result_sha256)); .body.observed_at) and
 (.body.catalog_ref | document_ref_ok(1; "eval_catalog")) and
 (.body.evaluator.sha256 | sha256_ok) and
 (.body.observed_at | time_ok) and
 (.body.families |
  type == "array" and length == 9 and
  (map(.family_id) | length == (unique | length)) and
  all(.[];
      type == "object" and (.family_id | type == "string") and
      (.seed_status | type == "string") and
      (.cases |
       type == "object" and (.total | count_ok) and (.failed | count_ok) and
       (.inconclusive | count_ok))))) as $dash_ok |
($risk_doc | risk_evaluation_ok) as $risk_ok |
($kill_doc | kill_evaluation_ok) as $kill_ok |
($duty_doc | duty_evaluation_ok) as $duty_ok |
($mode_doc | type == "object" and (.status | type == "string")) as $mode_ok |

# The scope names its three gate evaluations by kind, id, and digest, exactly as
# it names its shadow evidence, and the driver measured each supplied document
# itself. A document the scope did not name is not the one it was qualified
# against, so it is refused as malformed instead of being read for a verdict.
# The three must also belong together: one policy set; the risk and duty
# evaluations about the same stage request and result and about the resolved
# profile the scope records; and the risk and kill evaluations each naming this
# duty evaluation, which is the only reference the kill-switch evaluation shares
# with the other two. The shared duty reference is compared by id: the digest in
# it is each evaluator's own binding, while the bytes of all three documents are
# already pinned by the scope's own refs above.
def named_by($ref; $document; $sha):
  $ref == {schema_version: $document.schema_version, kind: $document.kind,
    id: $document.id, sha256: $sha};
($risk_ok and $kill_ok and $duty_ok and
 named_by($gate_refs.risk_gate_evaluation_ref; $risk_doc; $risk_sha) and
 named_by($gate_refs.kill_switch_evaluation_ref; $kill_doc; $kill_sha) and
 named_by($gate_refs.duty_separation_evaluation_ref; $duty_doc; $duty_sha) and
 $risk_doc.body.policy_set == $kill_doc.body.policy_set and
 $risk_doc.body.policy_set == $duty_doc.body.policy_set and
 $risk_doc.body.stage.request_ref == $duty_doc.body.stage.request_ref and
 $risk_doc.body.stage.result_ref == $duty_doc.body.stage.result_ref and
 $risk_doc.body.stage.resolved_profile_ref == $identity.resolved_profile_ref and
 $duty_doc.body.stage.resolved_profile_ref == $identity.resolved_profile_ref and
 # Gate outputs must be about this scope's own stage request, not another
 # workflow's or attempt's that happened to use the same profile.
 $risk_doc.body.stage.request_ref == $identity.stage_request_ref and
 $duty_doc.body.stage.request_ref == $identity.stage_request_ref and
 # The risk and kill evaluations must name this duty evaluation by digest, not
 # only by id: outputs computed over different duty bytes never combine.
 $risk_doc.body.duty_evaluation_ref.content_id == $duty_doc.id and
 $risk_doc.body.duty_evaluation_ref.sha256 == $duty_sha and
 $kill_doc.body.duty_evaluation_ref.id == $duty_doc.id and
 $kill_doc.body.duty_evaluation_ref.sha256 == $duty_sha) as $gates_bound |

# Binding the three by digest still leaves them free to contradict each other
# about what the duty evaluation said, and the real evaluators never do. In
# control/v1/risk-gates.jq the duty verdict enters the risk reasons directly:
# "duty.violated" is emitted exactly when the duty verdict is "violated" and
# "duty.inconclusive" exactly when it is "inconclusive". In
# control/v1/kill-switch.jq the same two verdicts become "kill.duty-violated"
# and "kill.duty-inconclusive", but only once that evaluator has verified the
# duty document it was handed; a duty document it cannot verify yields
# "kill.duty-unverifiable" instead, and a claimed duty evaluation this program
# has already accepted whole is not that. Its two reasons for an attempt or
# state it could not read at all — "kill.attempt-invalid" and
# "kill.state-invalid" — stand alone with no duty reason beside them, so that
# case is mirrored rather than forced. Any other pairing is evidence no run
# produced, and the set is refused as malformed rather than read for a verdict.
def carries($reason): .body.reason_ids | index($reason) != null;
$duty_doc.body.verdict as $verdict |
($risk_ok and $kill_ok and $duty_ok and
 ($risk_doc | carries("duty.violated")) == ($verdict == "violated") and
 ($risk_doc | carries("duty.inconclusive")) == ($verdict == "inconclusive") and
 ($kill_doc | carries("kill.duty-unverifiable") | not) and
 (if ($kill_doc | carries("kill.attempt-invalid")) or
     ($kill_doc | carries("kill.state-invalid"))
  then ($kill_doc | carries("kill.duty-violated") | not) and
       ($kill_doc | carries("kill.duty-inconclusive") | not)
  else ($kill_doc | carries("kill.duty-violated")) == ($verdict == "violated") and
       ($kill_doc | carries("kill.duty-inconclusive")) ==
         ($verdict == "inconclusive") end)) as $gates_consistent |

# Only the two statuses the mode record can carry are meaningful: "active" is
# construction and "retired" is operating. Anything else is unknown and refuses.
(if ($mode_ok | not) or $mode_repo_state == "differs" then "unknown"
 elif $mode_doc.status == "active" then "construction"
 elif $mode_doc.status == "retired" then "operating"
 else "unknown" end) as $mode_state |

(if $set_ok then
   [range(0; $set.body.records | length) as $index |
    $set.body.records[$index] as $record |
    {schema_version: 1, kind: "shadow_reproduction_record", id: $record.id,
     sha256: $record_shas[$index],
     environment_id: $record.body.environment.environment_id,
     outcome: $record.body.outcome,
     target_repository_id: $record.body.target_repository_id,
     target_revision: $record.body.git_revision_ref}] |
   sort_by(.sha256)
 else [] end) as $bound_records |
($bound_records | map(del(.target_revision))) as $records |

# The scope names the shadow records it claims as its own, by id and by digest.
# A supplied record counts only when one of those refs names it exactly, so a
# record produced for another workflow or task class never qualifies this scope.
# Records nobody claimed are ignored and reported by digest; a ref that names no
# supplied record leaves the claim unmet.
($s.shadow_evidence_refs // []) as $refs |
def claimed_by_scope($refs): . as $record |
  $refs | any(.id == $record.id and .sha256 == $record.sha256);
($bound_records | map(select(claimed_by_scope($refs)))) as $claimed |
($records | map(select(claimed_by_scope($refs) | not) | .sha256) |
 sort | unique) as $unclaimed |
($refs |
 all(. as $ref |
     $records | any(.id == $ref.id and .sha256 == $ref.sha256))) as $refs_resolved |
# Evidence counts only when it was gathered for this scope's own target: the
# same repository, and the same revision the scope's recorded identity names.
# A record from another revision is evidence about a different target version.
($claimed |
 map(select(.target_repository_id == $s.target_repository_id and
   .target_revision == $identity.target_revision))) as $mine |

# A glob is protected when it names, or could expand into, a path the roadmap's
# high-risk list reserves. A wildcard in any directory segment could expand into
# a protected directory name, so it is refused with the same reason. Names are
# compared case-insensitively: a checkout may be case-insensitive, so a glob that
# differs from a protected name only by case reaches the same file.
($p.protected_path_prefixes | map(ascii_downcase)) as $protected_prefixes |
($p.protected_root_files | map(ascii_downcase)) as $protected_root_files |
($p.protected_path_segments | map(ascii_downcase)) as $protected_segments |
(($s.allowed_paths |
  map((split("/") | map(ascii_downcase)) as $segments |
      ($protected_prefixes | index($segments[0] + "/") != null) or
      (($segments | length) == 1 and
       ($protected_root_files | index($segments[0]) != null)) or
      ($segments |
       any(. as $segment | $protected_segments | index($segment) != null)) or
      ($segments[0:-1] | any(test("[*?]"))) or
      # A leaf wildcard is judged by what it could expand to: if its pattern
      # matches any protected segment name (or, for a root glob, any protected
      # root file), the glob can reach a protected path.
      (($segments[-1] | test("[*?]")) and
       (($segments[-1] |
         gsub("\\."; "\\.") | gsub("\\*"; ".*") | gsub("\\?"; ".")) as $leaf_re |
        (($protected_segments +
          (if ($segments | length) == 1 then $protected_root_files else [] end)) |
         any(test("\\A" + $leaf_re + "\\z")))))) |
  any(.))) as $protected |

(if $dash_ok then
   ($dash.body.families | map({key: .family_id, value: .}) | from_entries)
 else {} end) as $families |
(if $dash_ok then
   [$s.required_eval_families[] as $family |
    $families[$family] as $entry |
    if $entry == null or
       $entry.seed_status != $p.required_eval_seed_status then
      "scope.eval-family-unseeded"
    # A family counts only when every case actually passed: at least one case,
    # none failed or inconclusive, and the passed count equal to the total (a
    # total no passing case accounts for is not evidence).
    elif $entry.cases.total < 1 or $entry.cases.failed > 0 or
         $entry.cases.inconclusive > 0 or $entry.cases.passed < 1 or
         $entry.cases.passed != $entry.cases.total then
      "scope.eval-failing"
    else empty end]
 else ["scope.eval-family-unseeded", "scope.eval-failing"] end) as $eval_reasons |

((if $s.risk_tier != "routine" then ["scope.tier-not-routine"] else [] end) +
 (if $risk_ok and $risk_doc.body.classification.declared_tier == "routine" and
     $risk_doc.body.classification.minimum_tier == "routine" and
     $risk_doc.body.verdict != "violated"
  then [] else ["scope.tier-not-routine"] end) +
 (if $protected then ["scope.protected-path"] else [] end) +
 (if $set_ok and $refs_resolved and
     ($s.required_shadow_environments |
      all(. as $environment |
          $mine |
          any(. as $record |
              $record.environment_id == $environment and
              ($p.accepted_shadow_outcomes | index($record.outcome) != null))))
  then [] else ["scope.shadow-evidence-missing"] end) +
 (if $set_ok and
     ($mine |
      any(. as $record |
          $p.refused_shadow_outcomes | index($record.outcome) != null) | not)
  then [] else ["scope.shadow-inconclusive"] end) +
 $eval_reasons +
 (if $kill_ok and $kill_doc.body.verdict == "satisfied" then []
  else ["scope.kill-switch"] end) +
 (if $duty_ok and $duty_doc.body.verdict == "satisfied" then []
  else ["scope.duty-violation"] end) +
 (if $mode_state == "unknown" then ["scope.mode-construction"] else [] end) +
 (if $shas_ok and $set_ok and $dash_ok and $risk_ok and $kill_ok and $duty_ok and
     $mode_ok and $gates_bound and $gates_consistent
  then [] else ["scope.malformed"] end) |
 sort | unique) as $refusals |

(if ($refusals | length) == 0 then "proposable" else "not-proposable" end) as $outcome |
content_ref("scope-qualification-policy";
  "application/vnd.ystack.control-policy+json"; $policy_sha) as $policy_ref |
content_ref("workflow-scope-record";
  "application/vnd.ystack.workflow-scope+json"; $scope_sha) as $scope_content_ref |
content_ref("operating-mode-marker"; "application/json"; $marker_sha) as $mode_ref |
{
  eval_dashboard_ref: document_ref($dash; $dashboard_sha),
  kill_switch_evaluation_ref: document_ref($kill_doc; $kill_sha),
  duty_evaluation_ref: document_ref($duty_doc; $duty_sha),
  mode_marker_ref: $mode_ref,
  policy_ref: $policy_ref,
  risk_evaluation_ref: document_ref($risk_doc; $risk_sha),
  shadow_records: $records,
  shadow_set_ref: document_ref($set; $shadow_set_sha),
  unclaimed_shadow_records: $unclaimed
} as $evidence |

{
  schema_version: 1,
  kind: "scope_qualification_evaluation",
  id: $scope_doc.id,
  body: {
    activation_state: "inactive",
    authority: "none",
    authority_effect: "none",
    enabled: false,
    evaluation_mode: "observation-only",
    reference_semantics: "identity-only",
    qualification: {state: "unavailable",
      reason_id: "scope.enablement-requires-operator-pr"},
    operating_mode: {state: $mode_state, repository_marker: $mode_repo_state,
      marker_ref: $mode_ref},
    outcome: $outcome,
    reason_ids: (if $outcome == "proposable" then ["scope.proposable"]
                 else $refusals end),
    scope_ref: document_ref($scope_doc; $scope_sha),
    evidence: $evidence,
    proposal:
      (if $outcome != "proposable" then {state: "absent"}
       else
         {state: "present",
          document: {
            schema_version: 1,
            kind: "scope_enablement_proposal",
            id: ("proposal." + $scope_doc.id),
            body: {
              activation_state: "inactive",
              authority: "none",
              enabled: false,
              push_allowed: false,
              qualification: {state: "unavailable",
                reason_id: "scope.enablement-requires-operator-pr"},
              enablement: {state: "blocked",
                reason_id: (if $mode_state == "construction"
                            then "scope.mode-construction"
                            else "scope.enablement-requires-operator-pr" end)},
              operator_action: "Enabling this scope is an independent operator-merged pull request after the operating-mode transition. This document only records what that pull request would add; it turns nothing on and grants no authority.",
              operating_mode: $mode_state,
              qualification_scope_ref: {
                purpose: "qualification",
                decision_record_ref: $policy_ref,
                subject_ref: {type: "artifact",
                  value: {type: "content", value: $scope_content_ref}},
                scope_sha256: $scope_sha},
              scope_document_ref: document_ref($scope_doc; $scope_sha),
              qualified_identity: $identity,
              gate_evidence_refs: $gate_refs,
              target_repository_id: $s.target_repository_id,
              workflow_id: $s.workflow_id,
              task_class: $s.task_class,
              risk_tier: $s.risk_tier,
              allowed_paths: $s.allowed_paths,
              required_proof_kinds: $s.required_proof_kinds,
              required_eval_families: $s.required_eval_families,
              max_attempts: $s.max_attempts,
              environments: $s.required_shadow_environments,
              evidence: $evidence}}}
       end)
  }
}
