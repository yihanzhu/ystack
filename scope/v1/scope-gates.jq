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

def shadow_record_ok:
  . as $record |
  type == "object" and .schema_version == 1 and
  .kind == "shadow_reproduction_record" and (.id | id_ok) and
  (.body | type == "object") and .body.activation_state == "inactive" and
  .body.authority == "none" and .body.shadow == true and
  (.body.qualification | type == "object") and
  .body.qualification.state == "unavailable" and
  # The slice records the exact revision it reproduced at, so the scope can be
  # bound to it; a record that does not say which revision it ran against is not
  # a record this evaluator can attach qualification to.
  (.body.git_revision_ref | revision_ok($record.body.target_repository_id)) and
  # The shadow slice's closed outcome vocabulary; anything else is not a
  # shadow record this evaluator understands, so the set is malformed.
  (.body.outcome as $outcome |
   ($policy[0].body.accepted_shadow_outcomes + $policy[0].body.refused_shadow_outcomes) |
   index($outcome) != null) and
  (.body.target_repository_id | id_ok) and
  (.body.environment | type == "object") and
  (.body.environment.environment_id | id_ok);

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
 # The risk and kill evaluations must name this duty evaluation by digest, not
 # only by id: outputs computed over different duty bytes never combine.
 $risk_doc.body.duty_evaluation_ref.content_id == $duty_doc.id and
 $risk_doc.body.duty_evaluation_ref.sha256 == $duty_sha and
 $kill_doc.body.duty_evaluation_ref.id == $duty_doc.id and
 $kill_doc.body.duty_evaluation_ref.sha256 == $duty_sha) as $gates_bound |

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
     $mode_ok and $gates_bound
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
