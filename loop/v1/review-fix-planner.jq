def exact($fields): type == "object" and (keys | sort) == ($fields | sort);
def id_ok: type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");
def finding_id_ok:
  type == "string" and test("\\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\\z");
def provider_id_ok: type == "string" and test("\\A[1-9][0-9]{0,19}\\z");
def sha256_ok: type == "string" and test("\\A[0-9a-f]{64}\\z");
def int_ok:
  type == "number" and . == floor and . >= 0 and . <= 2147483647 and
  tostring != "-0";
def text_ok:
  type == "string" and utf8bytelength >= 1 and utf8bytelength <= 8192;
def media_type_ok:
  type == "string" and utf8bytelength <= 127 and
  test("\\A[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*\\z");
def time_ok:
  type == "string" and
  test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z") and
  (capture("\\A(?<year>[0-9]{4})-(?<month>[0-9]{2})-(?<day>[0-9]{2})T(?<hour>[0-9]{2}):(?<minute>[0-9]{2}):(?<second>[0-9]{2})Z\\z") as $parts |
   ($parts.year | tonumber) as $year |
   ($parts.month | tonumber) as $month |
   ($parts.day | tonumber) as $day |
   ($year % 4 == 0 and ($year % 100 != 0 or $year % 400 == 0)) as $leap |
   [31,(if $leap then 29 else 28 end),31,30,31,30,31,31,30,31,30,31] as $days |
   $month >= 1 and $month <= 12 and $day >= 1 and $day <= $days[$month - 1] and
   ($parts.hour | tonumber) <= 23 and ($parts.minute | tonumber) <= 59 and
   ($parts.second | tonumber) <= 59);
def commit_ok:
  type == "string" and (test("\\A[0-9a-f]{40}\\z") or test("\\A[0-9a-f]{64}\\z"));
def revision_ok:
  exact(["commit_id","hash_algorithm","repository_id"]) and
  (.repository_id | id_ok) and
  (if .hash_algorithm == "sha1" then (.commit_id | test("\\A[0-9a-f]{40}\\z"))
   elif .hash_algorithm == "sha256" then (.commit_id | test("\\A[0-9a-f]{64}\\z"))
   else false end);
def content_ref_ok:
  exact(["content_id","media_type","sha256"]) and (.content_id | id_ok) and
  (.media_type | media_type_ok) and (.sha256 | sha256_ok);
def versioned_document_ref_ok($schema_version; $kind):
  exact(["id","kind","schema_version","sha256"]) and
  .schema_version == $schema_version and .kind == $kind and (.id | id_ok) and
  (.sha256 | sha256_ok);
def document_ref_ok($kind): versioned_document_ref_ok(1; $kind);
def core_document_ref_ok($kind): versioned_document_ref_ok(2; $kind);
def typed_content_ref_ok($media): content_ref_ok and .media_type == $media;
def source_ref_ok($kind; $identity):
  exact(["id","kind","schema_identity","sha256"]) and .kind == $kind and
  .schema_identity == $identity and (.id | id_ok) and (.sha256 | sha256_ok);
def path_ok:
  type == "string" and utf8bytelength >= 1 and utf8bytelength <= 4096 and
  (test("[\\x{0000}-\\x{001f}\\x{007f}-\\x{009f}]") | not) and
  (contains("\\") | not) and
  (split("/") | all(.[]; . != "" and . != "." and . != ".."));
def id_set_ok($max):
  type == "array" and length <= $max and all(.[]; id_ok) and . == (sort | unique);

def policy_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "review_fix_policy" and .id == "loop-policy.review-fix" and
  (.body |
   exact(["actionable_severities","activation_state","fail_mode",
     "ignored_severities","max_attempts","policy_version","producer",
     "protected_path_prefixes","protected_path_segments","protected_root_files",
     "push_allowed","reference_semantics"]) and
   (.protected_path_prefixes | type == "array" and length >= 1 and length <= 32 and
    all(.[]; type == "string" and endswith("/")) and . == (sort | unique)) and
   (.protected_root_files | type == "array" and length >= 1 and length <= 32 and
    all(.[]; type == "string" and (contains("/") | not)) and . == (sort | unique)) and
   (.protected_path_segments | type == "array" and length >= 1 and length <= 32 and
    all(.[]; type == "string" and (contains("/") | not)) and . == (sort | unique)) and
   .activation_state == "inactive" and .fail_mode == "closed" and
   .policy_version == "v1" and .push_allowed == false and
   .reference_semantics == "identity-only" and
   (.max_attempts | int_ok) and .max_attempts >= 1 and .max_attempts <= 8 and
   (.actionable_severities | id_set_ok(32)) and
   (.actionable_severities | length) >= 1 and
   (.ignored_severities | id_set_ok(32)) and
   ((.actionable_severities + .ignored_severities) |
    length == (unique | length)) and
   (.producer |
    exact(["artifact_kind","capability_id","permissions","role"]) and
    .artifact_kind == "git-patch" and
    .capability_id == "core.harness.produce.v1" and .role == "producer" and
    (.permissions | id_set_ok(8)) and (.permissions | length) >= 1));

def approval_ok:
  exact(["approval_id","commit_id","recorded_at"]) and
  (.approval_id | id_ok) and (.commit_id | commit_ok) and
  (.recorded_at | time_ok);
def change_ref_ok:
  exact(["change_request_id","repository_id"]) and
  (.change_request_id | provider_id_ok) and (.repository_id | provider_id_ok);
def context_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "review_fix_change_context" and (.id | id_ok) and
  (.body | . as $body |
   exact(["activation_state","approvals","base","boundary_refs","change_ref",
     "head","kill_switch","observed_at"]) and
   .activation_state == "inactive" and
   (.head | revision_ok) and (.base | revision_ok) and
   .head.repository_id == .base.repository_id and
   .head.hash_algorithm == .base.hash_algorithm and
   .head.commit_id != .base.commit_id and
   (.change_ref | change_ref_ok) and
   (.observed_at | time_ok) and
   (.kill_switch |
    exact(["reason_id","state"]) and (.reason_id | id_ok) and
    (.state == "cleared" or .state == "engaged")) and
   (.approvals | type == "array" and length <= 64 and all(.[]; approval_ok) and
    all(.[]; .recorded_at <= $body.observed_at)) and
   ((.approvals | map(.approval_id)) as $ids |
    $ids == ($ids | sort) and ($ids | length) == ($ids | unique | length)) and
   (.boundary_refs |
    exact(["attempt_ledger_ref","credential_evaluation_ref",
      "reconciliation_plan_ref","risk_gate_evaluation_ref"]) and
    (.attempt_ledger_ref | document_ref_ok("review_fix_attempt_ledger")) and
    (.credential_evaluation_ref |
     document_ref_ok("credential_policy_evaluation")) and
    (.reconciliation_plan_ref |
     document_ref_ok("orchestrator_reconciliation_plan")) and
    (.risk_gate_evaluation_ref | document_ref_ok("risk_gate_evaluation"))));

def trust_context_ok:
  exact(["execution_boundary_id","expected_base","expected_change_request_id",
    "expected_github_app_id","expected_head","expected_repository_id",
    "expected_review_id","instruction_ref","invocation_kind","observation_time",
    "review_policy_ref"]) and
  (.expected_repository_id | provider_id_ok) and
  (.expected_change_request_id | provider_id_ok) and
  (.expected_review_id | provider_id_ok) and
  (.expected_github_app_id | provider_id_ok) and
  (.expected_head | revision_ok) and (.expected_base | revision_ok) and
  (.observation_time | time_ok) and (.instruction_ref | content_ref_ok) and
  (.review_policy_ref | content_ref_ok) and
  (.execution_boundary_id | id_ok) and .invocation_kind == "native-review";
def inline_finding_ok($head):
  exact(["body","commit_id","finding_id","line","path","provider_metadata",
    "provider_severity","side"]) and
  (.finding_id | finding_id_ok) and (.path | path_ok) and
  (.line | type == "number" and . == floor and . >= 1 and . <= 2147483647) and
  (.side == "LEFT" or .side == "RIGHT") and .commit_id == $head.commit_id and
  (.body | text_ok) and (.provider_severity | text_ok) and
  (.provider_metadata | type == "object");
def snapshot_ok:
  . as $snapshot |
  exact(["base","change_request_id","complete","dismissed_at","github_app_id",
    "head","hidden_execution","inline_findings","observed_at",
    "provider_metadata","reported_inline_count","reported_top_level_count",
    "repository_id","review_id","started_at","status","terminal_at",
    "top_level_findings","updated_at"]) and
  (.repository_id | provider_id_ok) and
  (.change_request_id | provider_id_ok) and (.review_id | provider_id_ok) and
  (.github_app_id | provider_id_ok) and
  (.head | revision_ok) and (.base | revision_ok) and
  (.observed_at | time_ok) and (.started_at | time_ok) and
  (.updated_at | time_ok) and (.complete | type == "boolean") and
  (.status |
   IN("COMPLETED","DISMISSED","TIMED_OUT","FAILED","IN_PROGRESS","UNKNOWN")) and
  (.terminal_at == null or (.terminal_at | time_ok)) and
  (.dismissed_at == null or (.dismissed_at | time_ok)) and
  (.hidden_execution | type == "object") and
  (.provider_metadata | type == "object") and
  (.reported_top_level_count | int_ok) and (.reported_inline_count | int_ok) and
  # The normalizer emits findings in one canonical order; anything else was
  # not produced by it and is refused.
  (.top_level_findings | type == "array" and length <= 256 and
   all(.[];
     exact(["body","finding_id","provider_metadata","provider_severity"]) and
     (.finding_id | finding_id_ok) and (.provider_severity | text_ok)) and
   (map(.finding_id) as $ids | $ids == ($ids | sort))) and
  (.inline_findings | type == "array" and length <= 256 and
   all(.[]; inline_finding_ok($snapshot.head)) and
   (map([.path,.line,.side,.finding_id]) as $keys | $keys == ($keys | sort))) and
  ((.top_level_findings + .inline_findings) | map(.finding_id) |
   length == (unique | length)) and
  (if .complete then
     .reported_top_level_count == (.top_level_findings | length) and
     .reported_inline_count == (.inline_findings | length)
   else true end) and
  # The normalizer's own status facts: a terminal status carries terminal_at,
  # only DISMISSED carries dismissed_at, and an open status carries neither.
  (if .status == "COMPLETED" or .status == "TIMED_OUT" or .status == "FAILED" then
     (.terminal_at | time_ok) and .dismissed_at == null
   elif .status == "DISMISSED" then
     (.terminal_at | time_ok) and (.dismissed_at | time_ok) and
     .terminal_at <= .dismissed_at
   else .terminal_at == null and .dismissed_at == null end) and
  .started_at <= .updated_at and .updated_at <= .observed_at and
  (if .terminal_at == null then true
   else .started_at <= .terminal_at and .terminal_at <= .updated_at end) and
  (if .dismissed_at == null then true else .dismissed_at <= .updated_at end);
def observation_ok:
  exact(["adapter","authority","effects","kind","observation","qualification",
    "reason_id","review_mode","schema_version","stale_bindings","state",
    "trust_context"]) and
  .schema_version == 1 and .kind == "adapter_observation" and
  .adapter == {id:"adapter.codex-native-reviewer.v1",version:"v1",
    status:"inactive"} and
  .review_mode == "read-only" and .authority == "none" and .effects == [] and
  .qualification == {state:"unavailable",reason_id:"adapter.unqualified"} and
  (.reason_id | id_ok) and
  (.state |
   IN("clean","dismissed","failed","findings","inconclusive","stale",
      "timeout")) and
  (.stale_bindings | type == "array" and length <= 16 and
   all(.[]; type == "string")) and
  (.trust_context | trust_context_ok) and (.observation | snapshot_ok);

# The two control evaluations are accepted only in the exact shape their own
# evaluators emit (control/v1/credential-policy.jq and control/v1/risk-gates.jq),
# so a document that carries the envelope, the markers and a verdict but none of
# the evaluator's own evidence cannot stand in for a real evaluation.
def core_contract_ok:
  exact(["generation_id","package_ref","semantic_identity"]) and
  .semantic_identity == "core.contracts.v2" and
  (.generation_id | type == "string" and test("\\Ag-[0-9a-f]{64}\\z")) and
  (.package_ref |
   typed_content_ref_ok("application/vnd.ystack.core-contract+json")) and
  .package_ref.content_id == "core-contract-package.v2";
def policy_set_ref_ok:
  exact(["id","sha256"]) and (.id | id_ok) and (.sha256 | sha256_ok);
def stage_refs_ok:
  exact(["request_ref","resolved_profile_ref","result_ref"]) and
  (.request_ref | core_document_ref_ok("stage_request")) and
  (.resolved_profile_ref | core_document_ref_ok("resolved_profile")) and
  (.result_ref | core_document_ref_ok("stage_result"));
# "satisfied" is kept in the vocabulary because it is the only verdict this
# planner treats as proof; no shipped evaluator emits it while everything is
# inactive, which is why real inputs refuse with boundaries-unproven.
def control_markers_ok:
  .activation_state == "inactive" and .authority_effect == "none" and
  .evaluation_mode == "observation-only" and
  .reference_semantics == "identity-only" and
  (.policy_set | policy_set_ref_ok) and
  (.verdict | IN("inconclusive","satisfied","violated")) and
  (.reason_ids | id_set_ok(64)) and (.reason_ids | length) >= 1;
def credential_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "credential_policy_evaluation" and (.id | id_ok) and
  (.body |
   exact(["activation_state","authority_effect","claim_ref","core_contract",
     "decision_ref","duty_evaluation_ref","evaluation_mode","policy_ref",
     "policy_set","qualification_effect","reason_ids","reference_semantics",
     "stage","verdict"]) and
   control_markers_ok and .qualification_effect == "none" and
   (.claim_ref | document_ref_ok("credential_boundary_claim")) and
   (.core_contract | core_contract_ok) and
   (.decision_ref |
    typed_content_ref_ok("application/vnd.ystack.control-decision+json")) and
   (.duty_evaluation_ref | document_ref_ok("duty_separation_evaluation")) and
   (.policy_ref |
    typed_content_ref_ok("application/vnd.ystack.control-policy+json")) and
   (.stage | stage_refs_ok));
def risk_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "risk_gate_evaluation" and (.id | id_ok) and
  (.body |
   exact(["activation_state","authority_effect","classification",
     "core_contract","decision_claim_ref","decision_ref","duty_evaluation_ref",
     "evaluation_mode","policy_ref","policy_set","reason_ids",
     "reference_semantics","stage","verdict"]) and
   control_markers_ok and
   (.classification | exact(["declared_tier","minimum_tier"]) and
    (.declared_tier | id_ok) and
    (.minimum_tier | IN("bootstrap","high","routine","unknown"))) and
   (.core_contract | core_contract_ok) and
   (.decision_claim_ref |
    typed_content_ref_ok(
      "application/vnd.ystack.risk-gate-decision-claim+json")) and
   (.decision_ref |
    typed_content_ref_ok("application/vnd.ystack.control-decision+json")) and
   (.duty_evaluation_ref |
    typed_content_ref_ok(
      "application/vnd.ystack.duty-separation-evaluation+json")) and
   (.policy_ref |
    typed_content_ref_ok("application/vnd.ystack.control-policy+json")) and
   (.stage | stage_refs_ok));

# The reconciliation plan is accepted only in the shape
# orchestrator/v1/reconciliation-plan.jq emits, entry for entry, so an empty
# envelope carrying arbitrary deliveries cannot report a reconciled boundary.
def stage_key_ok:
  exact(["initiative_id","stage_id","task_class_id","workflow_id"]) and
  all(.[]; id_ok);
def plan_operation_ok:
  . == "dispatch-stage" or . == "retry-stage" or
  . == "recover-stranded-attempt";
def delivery_key_ok:
  exact(["attempt_number","operation","request_sha256","stage_key"]) and
  (.stage_key | stage_key_ok) and (.request_sha256 | sha256_ok) and
  (.operation | plan_operation_ok) and (.attempt_number | int_ok) and
  .attempt_number >= 1 and .attempt_number <= 10;
def present_ok(value_ok):
  (exact(["state"]) and .state == "absent") or
  (exact(["state","value"]) and .state == "present" and (.value | value_ok));
def attempt_ok:
  exact(["attempt_id","attempt_number","deadline_at","request_ref","state"]) and
  (.attempt_id | id_ok) and (.attempt_number | int_ok) and
  .attempt_number >= 1 and .attempt_number <= 10 and
  (.deadline_at | time_ok) and
  (.request_ref | core_document_ref_ok("stage_request")) and
  (.state == "dispatched" or .state == "started");
def provenance_ok:
  exact(["active_attempt","evaluator_ref","item_ref","latest_result_ref",
    "request_ref","resolved_profile_ref","snapshot_ref"]) and
  (.snapshot_ref |
   source_ref_ok("orchestrator_state_snapshot";
     "orchestrator.state-snapshot.v1")) and
  (.evaluator_ref |
   typed_content_ref_ok(
     "application/vnd.ystack.orchestrator-state-scanner-evaluator+json")) and
  .evaluator_ref.content_id == "orchestrator-state-scanner-evaluator.v1" and
  (.item_ref | exact(["schema_identity","sha256"]) and
   .schema_identity == "orchestrator.state-item.v1" and
   (.sha256 | sha256_ok)) and
  (.request_ref | core_document_ref_ok("stage_request")) and
  (.resolved_profile_ref | core_document_ref_ok("resolved_profile")) and
  (.latest_result_ref | present_ok(core_document_ref_ok("stage_result"))) and
  (.active_attempt | present_ok(attempt_ok));
def recovery_ok:
  exact(["action","attempt_number","reason_id","retry_limit",
    "source_reason"]) and
  (.action | type == "string" and utf8bytelength >= 1 and
   utf8bytelength <= 128) and
  (.reason_id | id_ok) and (.source_reason | present_ok(id_ok)) and
  (.attempt_number | int_ok) and (.retry_limit | int_ok) and
  .retry_limit >= 1 and .retry_limit <= 10 and
  .attempt_number <= .retry_limit;
def class_action_ok:
  (.class == "terminal" and .recovery.action == "none") or
  (.class == "stale" and .recovery.action == "refresh-stage-inputs") or
  (.class == "blocked" and
   (.recovery.action == "resolve-stage-blocker" or
    .recovery.action == "operator-reconcile")) or
  (.class == "retryable" and .recovery.action == "retry-stage") or
  (.class == "stranded" and
   .recovery.action == "recover-stranded-attempt") or
  (.class == "pending" and
   (.recovery.action == "wait-for-attempt" or
    .recovery.action == "dispatch-stage"));
# The reconciler derives every public field of a candidate from the state
# classification it planned from, so the derivation must hold here too.
def candidate_ok:
  (.stage_key | stage_key_ok) and (.provenance | provenance_ok) and
  (.recovery | recovery_ok) and (.delivery_key | delivery_key_ok) and
  (.delivery_mode == "first-delivery" or .delivery_mode == "redelivery") and
  (.operation | plan_operation_ok) and .operation == .recovery.action and
  .delivery_key.operation == .operation and
  .delivery_key.stage_key == .stage_key and
  .delivery_key.request_sha256 == .provenance.request_ref.sha256 and
  .delivery_key.attempt_number ==
    (if .recovery.action == "recover-stranded-attempt"
     then .recovery.attempt_number else .recovery.attempt_number + 1 end) and
  (if .provenance.active_attempt.state == "present" then
     .provenance.active_attempt.value.request_ref == .provenance.request_ref and
     .provenance.active_attempt.value.attempt_number == .recovery.attempt_number
   else true end) and
  (if .recovery.action == "dispatch-stage" then
     .recovery.attempt_number == 0 and
     .provenance.active_attempt.state == "absent" and
     .provenance.latest_result_ref.state == "absent"
   elif .recovery.action == "retry-stage" then
     .recovery.attempt_number >= 1 and
     .recovery.attempt_number < .recovery.retry_limit and
     .provenance.active_attempt.state == "absent" and
     .provenance.latest_result_ref.state == "present"
   else
     .recovery.attempt_number >= 1 and
     .provenance.active_attempt.state == "present"
   end);
def delivery_ok:
  exact(["delivery_key","delivery_mode","operation","provenance","recovery",
    "stage_key"]) and candidate_ok;
def deferred_ok:
  exact(["delivery_key","delivery_mode","operation","provenance","reason_id",
    "recovery","stage_key"]) and
  .reason_id == "planner.backpressure-slots-exhausted" and candidate_ok;
def suppressed_ok:
  exact(["delivery_key","reason_id","stage_key"]) and
  .reason_id == "planner.delivery-acknowledged" and
  (.delivery_key | delivery_key_ok) and (.stage_key | stage_key_ok) and
  .delivery_key.stage_key == .stage_key;
def operator_message_ok:
  exact(["class","recovery","stage_key"]) and (.stage_key | stage_key_ok) and
  (.recovery | recovery_ok) and
  ((.recovery.action | plan_operation_ok) | not) and class_action_ok;
def reconciliation_ok:
  . as $plan |
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "orchestrator_reconciliation_plan" and (.id | id_ok) and
  (.body |
   exact(["activation_state","authority_effect","concurrency","deferred",
     "deliveries","delivery_ledger_ref","mode","observation_ref",
     "operator_messages","suppressed"]) and
   .activation_state == "inactive" and .authority_effect == "none" and
   .mode == "planning-only" and
   (.observation_ref |
    source_ref_ok("orchestrator_state_observation";
      "orchestrator.state-observation.v1")) and
   .observation_ref.id == $plan.id and
   (.delivery_ledger_ref |
    source_ref_ok("orchestrator_delivery_ledger";
      "orchestrator.delivery-ledger.v1")) and
   (.concurrency |
    exact(["active_pending","available_slots","max_in_flight"]) and
    all(.[]; int_ok) and .max_in_flight <= 64 and
    .active_pending <= .max_in_flight and
    .available_slots == .max_in_flight - .active_pending) and
   (.deliveries | type == "array" and length <= 256 and
    all(.[]; delivery_ok)) and
   (.deferred | type == "array" and length <= 256 and all(.[]; deferred_ok)) and
   (.suppressed | type == "array" and length <= 256 and
    all(.[]; suppressed_ok)) and
   (.operator_messages | type == "array" and length <= 256 and
    all(.[]; operator_message_ok)));

def ledger_entry_ok:
  exact(["attempt_id","attempt_number","head_commit_id","outcome",
    "recorded_at"]) and
  (.attempt_id | id_ok) and (.attempt_number | int_ok) and
  .attempt_number >= 1 and .attempt_number <= 8 and
  (.head_commit_id | commit_ok) and (.recorded_at | time_ok) and
  (.outcome | IN("abandoned","applied","failed"));
def ledger_ok:
  . as $ledger |
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "review_fix_attempt_ledger" and (.id | id_ok) and
  (.body |
   exact(["activation_state","change_ref","entries","ledger_contract",
     "recorded_at"]) and
   .activation_state == "inactive" and (.change_ref | change_ref_ok) and
   (.recorded_at | time_ok) and
   (.ledger_contract |
    exact(["declared_entry_count","maximum_entry_count","schema_identity"]) and
    .schema_identity == "loop.review-fix-attempt-ledger.v1" and
    .maximum_entry_count == 64 and
    (.declared_entry_count | int_ok) and
    .declared_entry_count == ($ledger.body.entries | length)) and
   (.entries | type == "array" and length <= 64 and all(.[]; ledger_entry_ok) and
    all(.[]; .recorded_at <= $ledger.body.recorded_at)) and
   ((.entries | map(.attempt_number)) as $numbers |
    $numbers == ($numbers | sort) and
    ($numbers | length) == ($numbers | unique | length)));

def input_ok($p; $o; $c; $cred; $rec; $risk; $led):
  ($p | policy_ok) and ($o | observation_ok) and ($c | context_ok) and
  ($cred | credential_ok) and ($rec | reconciliation_ok) and
  ($risk | risk_ok) and ($led | ledger_ok);

def ref($document; $sha):
  {schema_version:$document.schema_version,kind:$document.kind,
   id:$document.id,sha256:$sha};

def boundary_reasons($c; $cred; $rec; $risk; $led; $shas):
  $c.body.boundary_refs as $expected |
  ((if $expected.credential_evaluation_ref == ref($cred;$shas.credential)
    then [] else ["boundary.credential-identity-mismatch"] end) +
   (if $cred.body.verdict == "satisfied" then []
    else ["boundary.credential-not-satisfied"] end) +
   (if $expected.reconciliation_plan_ref == ref($rec;$shas.reconciliation)
    then [] else ["boundary.reconciliation-identity-mismatch"] end) +
   # Pending deliveries, in-flight deliveries counted by the reconciler, deferred
   # entries, and operator messages are all outstanding work; none may remain.
   (if ($rec.body.deliveries | length) == 0 and
       ($rec.body.deferred | length) == 0 and
       ($rec.body.operator_messages | length) == 0 and
       $rec.body.concurrency.active_pending == 0
    then [] else ["boundary.reconciliation-unreconciled"] end) +
   (if $expected.risk_gate_evaluation_ref == ref($risk;$shas.risk)
    then [] else ["boundary.risk-identity-mismatch"] end) +
   (if $risk.body.verdict == "satisfied" then []
    else ["boundary.risk-not-satisfied"] end) +
   (if $expected.attempt_ledger_ref == ref($led;$shas.ledger)
    then [] else ["boundary.attempt-ledger-identity-mismatch"] end) +
   (if $led.body.change_ref == $c.body.change_ref then []
    else ["boundary.attempt-ledger-change-mismatch"] end) +
   (if $led.body.recorded_at <= $c.body.observed_at then []
    else ["boundary.attempt-ledger-not-yet-observed"] end)) | sort | unique;

def recomputed_bindings($o):
  $o.trust_context as $t | $o.observation as $s |
  [(if $s.github_app_id != $t.expected_github_app_id then "app" else empty end),
   (if $s.base != $t.expected_base then "base" else empty end),
   (if $s.change_request_id != $t.expected_change_request_id
    then "change-request" else empty end),
   (if $s.head != $t.expected_head then "head" else empty end),
   (if $s.observed_at != $t.observation_time
    then "observation-time" else empty end),
   (if $s.repository_id != $t.expected_repository_id
    then "repository" else empty end),
   (if $s.review_id != $t.expected_review_id then "review" else empty end)];

# The observation's state and reason must be what the normalizer derives from
# the snapshot, so a forged "clean" over a dismissed or open review is refused.
def expected_state($o):
  $o.observation as $s |
  if $s.status == "DISMISSED" then ["dismissed","codex.review-dismissed"]
  elif $s.status == "TIMED_OUT" then ["timeout","codex.review-timeout"]
  elif $s.status == "FAILED" then ["failed","codex.review-failed"]
  elif $s.complete == false then ["inconclusive","codex.review-incomplete"]
  elif $s.status != "COMPLETED" then ["inconclusive","codex.review-not-terminal"]
  elif ($s.reported_top_level_count + $s.reported_inline_count) > 0 then
    ["findings","codex.review-findings"]
  else ["clean","codex.review-clean"] end;
# Stale bindings are judged separately (review-stale); here only the snapshot
# facts must agree with the claimed state and reason.
def state_consistent($o):
  (recomputed_bindings($o) | length) > 0 or
  [$o.state, $o.reason_id] == expected_state($o);

def stale_reasons($o; $c):
  recomputed_bindings($o) as $bindings |
  ((if $o.state == "stale" then ["review.state-stale"] else [] end) +
   (if ($bindings | length) > 0 then ["review.bindings-stale"] else [] end) +
   (if $o.stale_bindings == $bindings then []
    else ["review.bindings-unverified"] end) +
   (if $o.trust_context.expected_head == $c.body.head and
       $o.observation.head == $c.body.head
    then [] else ["review.head-mismatch"] end) +
   (if $o.trust_context.expected_base == $c.body.base and
       $o.observation.base == $c.body.base
    then [] else ["review.base-mismatch"] end) +
   (if $o.observation.repository_id == $c.body.change_ref.repository_id and
       $o.observation.change_request_id == $c.body.change_ref.change_request_id
    then [] else ["review.change-mismatch"] end) +
   (if $o.observation.observed_at <= $c.body.observed_at then []
    else ["review.observed-after-context"] end)) | sort | unique;

def degraded_reasons($o):
  ((if $o.state == "dismissed" then ["review.dismissed"]
    elif $o.state == "failed" then ["review.failed"]
    elif $o.state == "timeout" then ["review.timeout"]
    elif $o.state == "inconclusive" then ["review.inconclusive"]
    else [] end) +
   (if $o.observation.complete then [] else ["review.incomplete"] end) +
   (if $o.observation.status == "COMPLETED" then []
    else ["review.not-completed"] end)) | sort | unique;

# A finding on a constitution or protected path is never a target for an
# autonomous fix: the roadmap keeps those paths high-risk and human-planned.
# Names are compared case-insensitively because a checkout may be.
def protected_path($p; $path):
  ($path | split("/") | map(ascii_downcase)) as $segments |
  ($p.body.protected_path_prefixes | map(ascii_downcase) | index($segments[0] + "/") != null) or
  (($segments | length) == 1 and
   ($p.body.protected_root_files | map(ascii_downcase) | index($segments[0]) != null)) or
  ($segments | any(. as $segment |
    $p.body.protected_path_segments | map(ascii_downcase) | index($segment) != null));

def severity_actionable($p; $finding):
  $p.body.actionable_severities | index($finding.provider_severity | ascii_downcase) != null;

def actionable_findings($o; $p):
  [$o.observation.inline_findings[] |
   . as $finding |
   select(severity_actionable($p; $finding) and (protected_path($p; $finding.path) | not)) |
   {finding_id:$finding.finding_id,path:$finding.path,
    provider_severity:$finding.provider_severity}] |
  sort_by(.finding_id);

def protected_findings($o; $p):
  [$o.observation.inline_findings[] |
   . as $finding |
   select(severity_actionable($p; $finding) and protected_path($p; $finding.path)) |
   {finding_id:$finding.finding_id,path:$finding.path,
    provider_severity:$finding.provider_severity}] |
  sort_by(.finding_id);

def next_attempt($led):
  (($led.body.entries | map(.attempt_number)) + [0] | max) + 1;

def fix_request($p; $o; $c; $findings; $attempt):
  {allowed_paths:($findings | map(.path) | unique),
   artifact_kind:$p.body.producer.artifact_kind,
   attempt:{limit:$p.body.max_attempts,number:$attempt},
   authority:"none",
   base:$c.body.base,
   capability_id:$p.body.producer.capability_id,
   findings:$findings,
   head:$c.body.head,
   permissions:$p.body.producer.permissions,
   push_allowed:false,
   push_allowed_reason_id:
     (if ($c.body.approvals | length) > 0 then "loop.no-push-after-approval"
      else "loop.inactive-planner" end),
   request_kind:"stage_request",
   review_ref:{change_request_id:$c.body.change_ref.change_request_id,
     repository_id:$c.body.change_ref.repository_id,
     review_id:$o.observation.review_id},
   role:$p.body.producer.role,
   target_repository_id:$c.body.head.repository_id};

def decision($p; $o; $c; $cred; $rec; $risk; $led; $shas):
  boundary_reasons($c;$cred;$rec;$risk;$led;$shas) as $boundaries |
  stale_reasons($o;$c) as $stale |
  degraded_reasons($o) as $degraded |
  [$c.body.approvals[] | select(.commit_id == $c.body.head.commit_id) |
   .approval_id] as $head_approvals |
  next_attempt($led) as $attempt |
  actionable_findings($o;$p) as $findings |
  protected_findings($o;$p) as $protected |
  if $c.body.kill_switch.state != "cleared" then
    {outcome:"refusal",reason_id:"kill-switch",
     detail_ids:[$c.body.kill_switch.reason_id]}
  elif ($boundaries | length) > 0 then
    {outcome:"refusal",reason_id:"boundaries-unproven",detail_ids:$boundaries}
  elif ($stale | length) > 0 then
    {outcome:"refusal",reason_id:"review-stale",detail_ids:$stale}
  elif ($degraded | length) > 0 then
    {outcome:"refusal",reason_id:"degraded-review",detail_ids:$degraded}
  elif ($head_approvals | length) > 0 then
    {outcome:"refusal",reason_id:"approval-present",
     detail_ids:["approval.recorded-on-head"]}
  elif $attempt > $p.body.max_attempts then
    {outcome:"refusal",reason_id:"attempt-limit",
     detail_ids:["attempt.limit-reached"]}
  elif ($findings | length) == 0 then
    {outcome:"refusal",reason_id:"no-actionable-findings",
     detail_ids:((if $o.state == "clean" then ["findings.review-clean"]
       else ["findings.none-actionable"] end) +
       (if ($protected | length) > 0 then ["findings.protected-path-excluded"] else [] end))}
  else
    {outcome:"fix-request",
     fix_request:fix_request($p;$o;$c;$findings;$attempt),
     excluded_protected_findings:$protected}
  end;

def plan($p; $o; $c; $cred; $rec; $risk; $led; $shas):
  {schema_version:1,
   kind:"review_fix_plan",
   id:$c.id,
   body:{
     activation_state:"inactive",
     attempt:{limit:$p.body.max_attempts,
       next_number:next_attempt($led),
       recorded_count:($led.body.entries | length)},
     authority:"none",
     change_ref:$c.body.change_ref,
     decision:decision($p;$o;$c;$cred;$rec;$risk;$led;$shas),
     effects:[],
     inputs:{
       attempt_ledger_ref:ref($led;$shas.ledger),
       change_context_ref:ref($c;$shas.context),
       credential_evaluation_ref:ref($cred;$shas.credential),
       observation_ref:{content_id:"loop-review-observation",
         media_type:"application/json",sha256:$shas.observation},
       policy_ref:{content_id:"loop-policy.review-fix",
         media_type:"application/vnd.ystack.loop-policy+json",
         sha256:$shas.policy},
       reconciliation_plan_ref:ref($rec;$shas.reconciliation),
       risk_gate_evaluation_ref:ref($risk;$shas.risk)},
     mode:"planning-only",
     observed_at:$c.body.observed_at,
     qualification:{state:"unavailable",reason_id:"loop.unqualified"}}};

$policy[0] as $p | $observation[0] as $o | $context[0] as $c |
$credential[0] as $cred | $reconciliation[0] as $rec | $risk[0] as $risk_doc |
$ledger[0] as $led |
{policy:$policy_sha,observation:$observation_sha,context:$context_sha,
 credential:$credential_sha,reconciliation:$reconciliation_sha,
 risk:$risk_sha,ledger:$ledger_sha} as $shas |
if input_ok($p;$o;$c;$cred;$rec;$risk_doc;$led) and state_consistent($o) then
  plan($p;$o;$c;$cred;$rec;$risk_doc;$led;$shas)
else error("E_REVIEW_FIX_INPUT")
end
