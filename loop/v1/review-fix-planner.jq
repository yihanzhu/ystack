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
def document_ref_ok($kind):
  exact(["id","kind","schema_version","sha256"]) and .schema_version == 1 and
  .kind == $kind and (.id | id_ok) and (.sha256 | sha256_ok);
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
     "push_allowed","reference_semantics"]) and
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
  (.top_level_findings | type == "array" and length <= 256 and
   all(.[];
     exact(["body","finding_id","provider_metadata","provider_severity"]) and
     (.finding_id | finding_id_ok) and (.provider_severity | text_ok))) and
  (.inline_findings | type == "array" and length <= 256 and
   all(.[]; inline_finding_ok($snapshot.head))) and
  ((.top_level_findings + .inline_findings) | map(.finding_id) |
   length == (unique | length));
def observation_ok:
  exact(["adapter","authority","effects","kind","observation","qualification",
    "reason_id","review_mode","schema_version","stale_bindings","state",
    "trust_context"]) and
  .schema_version == 1 and .kind == "adapter_observation" and
  .adapter == {id:"adapter.codex-native-reviewer.v1",version:"v1",
    status:"inactive"} and
  .review_mode == "read-only" and .authority == "none" and .effects == [] and
  (.qualification |
   exact(["reason_id","state"]) and .state == "unavailable" and
   (.reason_id | id_ok)) and
  (.reason_id | id_ok) and
  (.state |
   IN("clean","dismissed","failed","findings","inconclusive","stale",
      "timeout")) and
  (.stale_bindings | type == "array" and length <= 16 and
   all(.[]; type == "string")) and
  (.trust_context | trust_context_ok) and (.observation | snapshot_ok);

def evaluation_ok($kind; $fields):
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == $kind and (.id | id_ok) and
  (.body |
   exact($fields) and .activation_state == "inactive" and
   .authority_effect == "none" and .evaluation_mode == "observation-only" and
   .reference_semantics == "identity-only" and
   (.verdict | IN("inconclusive","satisfied","violated")) and
   (.reason_ids | id_set_ok(64)) and (.reason_ids | length) >= 1);
def credential_ok:
  evaluation_ok("credential_policy_evaluation";
    ["activation_state","authority_effect","claim_ref","core_contract",
     "decision_ref","duty_evaluation_ref","evaluation_mode","policy_ref",
     "policy_set","qualification_effect","reason_ids","reference_semantics",
     "stage","verdict"]);
def risk_ok:
  evaluation_ok("risk_gate_evaluation";
    ["activation_state","authority_effect","classification","core_contract",
     "decision_claim_ref","decision_ref","duty_evaluation_ref",
     "evaluation_mode","policy_ref","policy_set","reason_ids",
     "reference_semantics","stage","verdict"]);
def reconciliation_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "orchestrator_reconciliation_plan" and (.id | id_ok) and
  (.body |
   exact(["activation_state","authority_effect","concurrency","deferred",
     "deliveries","delivery_ledger_ref","mode","observation_ref",
     "operator_messages","suppressed"]) and
   .activation_state == "inactive" and .authority_effect == "none" and
   .mode == "planning-only" and
   ([.deliveries,.deferred,.suppressed,.operator_messages] |
    all(.[]; type == "array" and length <= 256)));

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
   (if ($rec.body.deferred | length) == 0 and
       ($rec.body.operator_messages | length) == 0
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

def stale_reasons($o; $c):
  ((if $o.state == "stale" then ["review.state-stale"] else [] end) +
   (if ($o.stale_bindings | length) > 0 then ["review.bindings-stale"] else [] end) +
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

def actionable_findings($o; $p):
  [$o.observation.inline_findings[] |
   . as $finding |
   select($p.body.actionable_severities |
     index($finding.provider_severity | ascii_downcase) != null) |
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
     detail_ids:(if $o.state == "clean" then ["findings.review-clean"]
       else ["findings.none-actionable"] end)}
  else
    {outcome:"fix-request",
     fix_request:fix_request($p;$o;$c;$findings;$attempt)}
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
if input_ok($p;$o;$c;$cred;$rec;$risk_doc;$led) then
  plan($p;$o;$c;$cred;$rec;$risk_doc;$led;$shas)
else error("E_REVIEW_FIX_INPUT")
end
