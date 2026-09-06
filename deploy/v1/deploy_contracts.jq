def exact($fields):
  type == "object" and (keys | sort) == ($fields | sort);

def id_ok: type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");
def sha256_ok: type == "string" and test("\\A[0-9a-f]{64}\\z");
def git_oid_ok:
  type == "string" and (test("\\A[0-9a-f]{40}\\z") or test("\\A[0-9a-f]{64}\\z"));
def tier_name_ok: type == "string" and test("\\A[a-z][a-z0-9-]{0,31}\\z");
# A timestamp must be a real instant, not only a well-formed string: month,
# day (leap years included), hour, minute, and second are all range-checked,
# because stale and expiry decisions are made by comparing these values.
def timestamp_ok:
  type == "string" and
  test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z") and
  (capture("\\A(?<y>[0-9]{4})-(?<mo>[0-9]{2})-(?<d>[0-9]{2})T(?<h>[0-9]{2}):(?<mi>[0-9]{2}):(?<se>[0-9]{2})Z\\z") as $t |
   ($t.y | tonumber) as $y | ($t.mo | tonumber) as $mo | ($t.d | tonumber) as $d |
   ($t.h | tonumber) as $h | ($t.mi | tonumber) as $mi | ($t.se | tonumber) as $se |
   ($y % 4 == 0 and ($y % 100 != 0 or $y % 400 == 0)) as $leap |
   [31,(if $leap then 29 else 28 end),31,30,31,30,31,31,30,31,30,31] as $days |
   $mo >= 1 and $mo <= 12 and $d >= 1 and $d <= $days[$mo - 1] and
   $h <= 23 and $mi <= 59 and $se <= 59);
def label_ok: type == "string" and utf8bytelength >= 1 and utf8bytelength <= 256;

def content_ref_ok($media):
  exact(["content_id","media_type","sha256"]) and (.content_id | id_ok) and
  .media_type == $media and (.sha256 | sha256_ok);

def document_ref_ok($schema_version; $kind):
  exact(["id","kind","schema_version","sha256"]) and
  .schema_version == $schema_version and .kind == $kind and (.id | id_ok) and
  (.sha256 | sha256_ok);

def core_document_ref_ok($kind): document_ref_ok(2; $kind);

def deploy_document_ref_ok($kind): document_ref_ok(1; $kind);

def control_document_ref_ok($kind): document_ref_ok(1; $kind);

def core_contract_ok:
  exact(["generation_id","package_ref","semantic_identity"]) and
  (.semantic_identity | id_ok) and
  (.generation_id | type == "string" and test("\\Ag-[0-9a-f]{64}\\z")) and
  (.package_ref | content_ref_ok("application/vnd.ystack.core-contract+json"));

def evidence_ref_ok:
  exact(["evidence_id","stage_result_ref"]) and (.evidence_id | id_ok) and
  (.stage_result_ref | core_document_ref_ok("stage_result"));

def actor_ref_ok:
  (exact(["adapter_instance_id","execution_boundary_id","implementation_id",
    "implementation_version","principal_id","role"]) or
   exact(["adapter_instance_id","authority_ref","execution_boundary_id",
     "implementation_id","implementation_version","principal_id","role"])) and
  (.adapter_instance_id | id_ok) and (.execution_boundary_id | id_ok) and
  (.implementation_id | id_ok) and (.implementation_version | id_ok) and
  (.principal_id | id_ok) and (.role | id_ok) and
  ((has("authority_ref") | not) or (.authority_ref | id_ok));

def policy_set_ref_ok:
  exact(["id","sha256"]) and (.id | id_ok) and (.sha256 | sha256_ok);

def unavailable_qualification:
  {reason:"no-deployment-adapter-exists",state:"unavailable"};

def envelope_ok($kinds):
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  (.kind as $kind | $kinds | index($kind) != null) and (.id | id_ok) and
  (.body | type == "object");

def request_kinds: ["deploy_request","rollback_request","status_request"];

def capability_of_kind($kind):
  if $kind == "deploy_request" then "deploy"
  elif $kind == "rollback_request" then "rollback"
  else "status" end;

def tier_ok:
  exact(["authorization_kind","name","operator_named","risk_tier",
    "rollback_rehearsal_required"]) and
  (.name | tier_name_ok) and
  (.authorization_kind == "named-operator" or .authorization_kind == "routine-gate") and
  (.operator_named | type == "boolean") and
  (.risk_tier == "high" or .risk_tier == "routine") and
  .rollback_rehearsal_required == true and
  (.operator_named == (.authorization_kind == "named-operator"));

def tiers_ok:
  envelope_ok(["deploy_environment_tiers"]) and
  .id == "deploy-policy.environment-tiers" and
  (.body |
    exact(["activation_state","authority","evaluation_mode","fail_mode","policy_version",
      "qualification","reference_semantics","requester_roles","tiers"]) and
    .activation_state == "inactive" and .authority == "none" and
    .evaluation_mode == "observation-only" and .fail_mode == "closed" and
    .policy_version == "v1" and .reference_semantics == "identity-only" and
    .qualification == unavailable_qualification and
    (.requester_roles | exact(["deploy","rollback","status"]) and
      all(.[]; type == "array" and length >= 1 and length <= 8 and
        all(.[]; id_ok) and . == (sort | unique))) and
    (.tiers | type == "array" and length == 3 and all(.[]; tier_ok) and
      map(.name) == ["dev","staging","production"]));

def release_ok:
  envelope_ok(["release_record"]) and
  (.id as $id | .body |
    exact(["activation_state","authority","evidence","qualification","release_id",
      "source","verification"]) and
    .activation_state == "inactive" and .authority == "none" and
    .qualification == unavailable_qualification and
    (.release_id | id_ok) and .release_id == $id and
    (.source | exact(["commit_id","hash_algorithm","repository_id","tree_id"]) and
      (.repository_id | id_ok) and
      (.hash_algorithm == "sha1" or .hash_algorithm == "sha256") and
      ((.hash_algorithm == "sha1") as $short |
        ([.commit_id,.tree_id] | all(.[];
          git_oid_ok and (if $short then length == 40 else length == 64 end))))) and
    (.verification | exact(["status","verified_commit_id","verified_tree_id",
      "verifier_result_ref"]) and
      (.status == "unverified" or .status == "verified") and
      (.verified_commit_id | git_oid_ok) and (.verified_tree_id | git_oid_ok) and
      (.verifier_result_ref | core_document_ref_ok("stage_result"))) and
    (.evidence | exact(["ci","independent_review","packaging_release_manifest","verifier"]) and
      (.ci | evidence_ref_ok) and (.independent_review | evidence_ref_ok) and
      (.verifier | evidence_ref_ok) and
      (.packaging_release_manifest == null or
       (.packaging_release_manifest |
         content_ref_ok("application/vnd.ystack.release-manifest+json")))));

def request_shared_ok($capability):
  .activation_state == "inactive" and .authority == "none" and
  .requested_capability == $capability and
  (.environment | exact(["tier"]) and (.tier | tier_name_ok)) and
  (.actor_ref | actor_ref_ok) and
  (.authorization_ref | deploy_document_ref_ok("deploy_authorization")) and
  (.release_ref | deploy_document_ref_ok("release_record")) and
  (.policy_set | policy_set_ref_ok) and (.requested_at | timestamp_ok);

def request_ok:
  envelope_ok(request_kinds) and
  (.kind as $kind | .body |
    if $kind == "rollback_request" then
      exact(["activation_state","actor_ref","authority","authorization_ref","environment",
        "policy_set","rehearsal_ref","release_ref","requested_at","requested_capability",
        "rollback_to_release_ref"]) and
      request_shared_ok("rollback") and
      (.rehearsal_ref | deploy_document_ref_ok("rollback_rehearsal_record")) and
      (.rollback_to_release_ref | deploy_document_ref_ok("release_record"))
    else
      exact(["activation_state","actor_ref","authority","authorization_ref","environment",
        "policy_set","release_ref","requested_at","requested_capability"]) and
      request_shared_ok(capability_of_kind($kind))
    end);

def authorization_ok:
  envelope_ok(["deploy_authorization"]) and
  (.body |
    exact(["activation_state","authority","authorization_kind","decision","environment",
      "expires_at","issued_at","operator","release_ref"]) and
    .activation_state == "inactive" and .authority == "none" and
    (.authorization_kind == "named-operator" or .authorization_kind == "routine-gate") and
    (.decision == "authorized" or .decision == "withheld") and
    (.environment | exact(["tier"]) and (.tier | tier_name_ok)) and
    (.expires_at | timestamp_ok) and (.issued_at | timestamp_ok) and
    .issued_at < .expires_at and
    (.operator | exact(["display_name","principal_id","role"]) and
      (.principal_id | id_ok) and (.role | id_ok) and (.display_name | label_ok)) and
    (.release_ref | deploy_document_ref_ok("release_record")));

def rehearsal_ok:
  envelope_ok(["rollback_rehearsal_record"]) and
  (.body |
    exact(["activation_state","authority","environment","evidence","from_release_ref",
      "outcome","rehearsed_at","to_release_ref"]) and
    .activation_state == "inactive" and .authority == "none" and
    (.environment | exact(["tier"]) and (.tier | tier_name_ok)) and
    (.evidence | evidence_ref_ok) and
    (.from_release_ref | deploy_document_ref_ok("release_record")) and
    (.to_release_ref | deploy_document_ref_ok("release_record")) and
    .from_release_ref != .to_release_ref and
    (.outcome == "failed" or .outcome == "rehearsed") and
    (.rehearsed_at | timestamp_ok));

def control_markers_ok($verdicts):
  .activation_state == "inactive" and .authority_effect == "none" and
  .evaluation_mode == "observation-only" and .reference_semantics == "identity-only" and
  (.policy_set | policy_set_ref_ok) and
  (.verdict as $verdict | $verdicts | index($verdict) != null) and
  (.reason_ids | type == "array" and length >= 1 and length <= 64 and
    all(.[]; id_ok) and . == (sort | unique));

# The two control evaluations are accepted only in the exact shape their own
# evaluators emit, so a three-field stub cannot stand in for a real evaluation.
def risk_evaluation_ok:
  envelope_ok(["risk_gate_evaluation"]) and
  (.body |
    exact(["activation_state","authority_effect","classification","core_contract",
      "decision_claim_ref","decision_ref","duty_evaluation_ref","evaluation_mode",
      "policy_ref","policy_set","reason_ids","reference_semantics","stage","verdict"]) and
    control_markers_ok(["inconclusive","violated"]) and
    (.classification | exact(["declared_tier","minimum_tier"]) and
      (.declared_tier | id_ok) and
      (.minimum_tier as $tier |
        ["bootstrap","high","routine","unknown"] | index($tier) != null)) and
    (.core_contract | core_contract_ok) and
    (.decision_claim_ref |
      content_ref_ok("application/vnd.ystack.risk-gate-decision-claim+json")) and
    (.decision_ref | content_ref_ok("application/vnd.ystack.control-decision+json")) and
    (.duty_evaluation_ref |
      content_ref_ok("application/vnd.ystack.duty-separation-evaluation+json")) and
    (.policy_ref | content_ref_ok("application/vnd.ystack.control-policy+json")) and
    (.stage | exact(["request_ref","resolved_profile_ref","result_ref"]) and
      (.request_ref | core_document_ref_ok("stage_request")) and
      (.resolved_profile_ref | core_document_ref_ok("resolved_profile")) and
      (.result_ref | core_document_ref_ok("stage_result"))));

def kill_evaluation_ok:
  envelope_ok(["kill_switch_evaluation"]) and
  (.body |
    exact(["activation_state","attempt_ref","authority_effect","decision_ref",
      "duty_decision_ref","duty_evaluation_ref","evaluation_mode","policy_ref",
      "policy_set","reason_ids","reference_semantics","state_ref","verdict"]) and
    control_markers_ok(["inconclusive","satisfied","violated"]) and
    (.decision_ref | content_ref_ok("application/vnd.ystack.control-decision+json")) and
    (.duty_decision_ref |
      content_ref_ok("application/vnd.ystack.control-decision+json")) and
    (.policy_ref | content_ref_ok("application/vnd.ystack.control-policy+json")) and
    (.state_ref | control_document_ref_ok("kill_switch_state")) and
    (.attempt_ref | control_document_ref_ok("kill_switch_attempt")) and
    (.duty_evaluation_ref | control_document_ref_ok("duty_separation_evaluation")));

def document_ok($kind):
  if $kind == "deploy_environment_tiers" then tiers_ok
  elif $kind == "release_record" then release_ok
  elif $kind == "deploy_authorization" then authorization_ok
  elif $kind == "rollback_rehearsal_record" then rehearsal_ok
  elif $kind == "risk_gate_evaluation" then risk_evaluation_ok
  elif $kind == "kill_switch_evaluation" then kill_evaluation_ok
  elif (request_kinds | index($kind)) != null then request_ok and .kind == $kind
  else false end;

def deploy_ref($document; $digest):
  {schema_version:$document.schema_version,kind:$document.kind,id:$document.id,
   sha256:$digest};
