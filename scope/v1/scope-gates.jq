def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");

def count_ok:
  type == "number" and . == floor and . >= 0 and . <= 2147483647;

def document_ref($doc; $sha):
  {schema_version: $doc.schema_version, kind: $doc.kind, id: $doc.id, sha256: $sha};

def content_ref($content_id; $media_type; $sha):
  {content_id: $content_id, media_type: $media_type, sha256: $sha};

def evaluation_ok($kind):
  type == "object" and .schema_version == 1 and .kind == $kind and (.id | id_ok) and
  (.body | type == "object") and .body.activation_state == "inactive" and
  (.body.verdict |
   type == "string" and
   (. as $verdict |
    ["inconclusive", "satisfied", "violated"] | index($verdict) != null));

def shadow_record_ok:
  type == "object" and .schema_version == 1 and
  .kind == "shadow_reproduction_record" and (.id | id_ok) and
  (.body | type == "object") and .body.activation_state == "inactive" and
  .body.authority == "none" and .body.shadow == true and
  (.body.qualification | type == "object") and
  .body.qualification.state == "unavailable" and
  (.body.outcome | type == "string") and
  (.body.target_repository_id | id_ok) and
  (.body.environment | type == "object") and
  (.body.environment.environment_id | id_ok);

$policy[0].body as $p |
$scope[0] as $scope_doc |
$scope_doc.body as $s |
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
($dash | type == "object" and .schema_version == 1 and .kind == "eval_dashboard" and
 (.id | id_ok) and (.body | type == "object") and
 .body.activation_state == "inactive" and
 (.body.families |
  type == "array" and length == 9 and
  (map(.family_id) | length == (unique | length)) and
  all(.[];
      type == "object" and (.family_id | type == "string") and
      (.seed_status | type == "string") and
      (.cases |
       type == "object" and (.total | count_ok) and (.failed | count_ok) and
       (.inconclusive | count_ok))))) as $dash_ok |
(($risk_doc | evaluation_ok("risk_gate_evaluation")) and
 ($risk_doc.body.classification |
  type == "object" and (.declared_tier | type == "string") and
  (.minimum_tier | type == "string"))) as $risk_ok |
($kill_doc | evaluation_ok("kill_switch_evaluation")) as $kill_ok |
($duty_doc | evaluation_ok("duty_separation_evaluation")) as $duty_ok |
($mode_doc | type == "object" and (.status | type == "string")) as $mode_ok |

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
     target_repository_id: $record.body.target_repository_id}] |
   sort_by(.sha256)
 else [] end) as $records |

# The scope names the shadow records it claims as its own, by id and by digest.
# A supplied record counts only when one of those refs names it exactly, so a
# record produced for another workflow or task class never qualifies this scope.
# Records nobody claimed are ignored and reported by digest; a ref that names no
# supplied record leaves the claim unmet.
($s.shadow_evidence_refs // []) as $refs |
def claimed_by_scope($refs): . as $record |
  $refs | any(.id == $record.id and .sha256 == $record.sha256);
($records | map(select(claimed_by_scope($refs)))) as $claimed |
($records | map(select(claimed_by_scope($refs) | not) | .sha256) |
 sort | unique) as $unclaimed |
($refs |
 all(. as $ref |
     $records | any(.id == $ref.id and .sha256 == $ref.sha256))) as $refs_resolved |
($claimed | map(select(.target_repository_id == $s.target_repository_id))) as $mine |

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
      ($segments[0:-1] | any(test("[*?]")))) |
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
    elif $entry.cases.total < 1 or $entry.cases.failed > 0 or
         $entry.cases.inconclusive > 0 then
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
     $mode_ok
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
