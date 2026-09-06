include "deploy_contracts";

def tiers_ref($document; $digest):
  {content_id:$document.id,
   media_type:"application/vnd.ystack.deploy-policy+json",sha256:$digest};

def decision_ref($document; $digest):
  {content_id:$document.id,
   media_type:"application/vnd.ystack.control-decision+json",sha256:$digest};

def decision_ok($tiers_sha):
  envelope_ok(["deploy_gates_decision"]) and
  .id == "deploy-decision.deploy-gates" and
  (.body |
    exact(["activation_state","authority","decision","evaluator","fail_mode","semantics",
      "tiers_ref"]) and
    .activation_state == "inactive" and .authority == "none" and
    .decision == "allow-observation-only-evaluation" and .fail_mode == "closed" and
    (.evaluator | exact(["contracts_ref","driver_ref","program_ref","validator_ref"]) and
      (.contracts_ref | content_ref_ok("text/x-jq")) and
      (.driver_ref | content_ref_ok("text/x-shellscript")) and
      (.program_ref | content_ref_ok("text/x-jq")) and
      (.validator_ref | content_ref_ok("text/x-shellscript"))) and
    .tiers_ref == {content_id:"deploy-policy.environment-tiers",
      media_type:"application/vnd.ystack.deploy-policy+json",sha256:$tiers_sha} and
    .semantics == {admissible_meaning:"may-be-handed-to-a-deployment-adapter-after-transition",
      authority_effect:"none",decision_values:["admissible","refused"],
      deployment_effect:"none",
      input_contract:("deploy-or-status-or-rollback-request+release-record+" +
        "deploy-authorization+rollback-rehearsal+risk-gate-evaluation+" +
        "kill-switch-evaluation.v1"),
      output_kind:"deploy_gate_evaluation",output_schema_version:1,
      qualification_effect:"none",reference_semantics:"identity-only"});

($tiers[0]) as $tier_doc |
($decision[0]) as $decision_doc |
($request[0]) as $req |
($release[0]) as $rel |
($authorization[0]) as $auth |
($rehearsal[0]) as $reh |
($risk[0]) as $risk_doc |
($kill[0]) as $kill_doc |
(if ($tier_doc | tiers_ok) then true else error("tiers-policy") end) |
(if ($decision_doc | decision_ok($tiers_sha)) then true else error("decision-record") end) |
(if ($req | envelope_ok(request_kinds)) and ($rel | envelope_ok(["release_record"])) and
    ($auth | envelope_ok(["deploy_authorization"])) and
    ($reh | envelope_ok(["rollback_rehearsal_record"])) and
    ($risk_doc | envelope_ok(["risk_gate_evaluation"])) and
    ($kill_doc | envelope_ok(["kill_switch_evaluation"]))
 then true else error("envelope") end) |
(($req | request_ok) and ($rel | release_ok) and ($auth | authorization_ok) and
 ($reh | rehearsal_ok) and ($risk_doc | risk_evaluation_ok) and
 ($kill_doc | kill_evaluation_ok)) as $shapes_ok |
(capability_of_kind($req.kind)) as $capability |
(try ($req.body.environment.tier) catch null |
 if tier_name_ok then . else "unknown" end) as $tier_name |
([$tier_doc.body.tiers[] | select(.name == $tier_name)]) as $matched |
(if $shapes_ok | not then ["deploy.malformed"] else
  ((if $req.body.release_ref == deploy_ref($rel;$release_sha) then []
    else ["deploy.release-unverified"] end) +
   (if $req.body.authorization_ref == deploy_ref($auth;$authorization_sha) then []
    else ["deploy.authorization-missing"] end) +
   (if $req.body.policy_set == $risk_doc.body.policy_set and
       $req.body.policy_set == $kill_doc.body.policy_set then []
    else ["deploy.malformed"] end) +
   (if ($matched | length) == 1 then [] else ["deploy.tier-unknown"] end) +
   (if $auth.body.decision == "authorized" then []
    else ["deploy.authorization-missing"] end) +
   (if $auth.body.release_ref == $req.body.release_ref and
       $auth.body.issued_at <= $req.body.requested_at and
       $req.body.requested_at < $auth.body.expires_at then []
    else ["deploy.authorization-stale"] end) +
   (if ($matched | length) == 1 and
       ($auth.body.environment.tier != $tier_name or
        $auth.body.authorization_kind != $matched[0].authorization_kind)
    then ["deploy.authorization-wrong-tier"] else [] end) +
   (if $rel.body.verification.status == "verified" and
       $rel.body.verification.verified_commit_id == $rel.body.source.commit_id and
       $rel.body.verification.verified_tree_id == $rel.body.source.tree_id and
       $rel.body.evidence.verifier.stage_result_ref ==
         $rel.body.verification.verifier_result_ref then []
    else ["deploy.release-unverified"] end) +
   (if $capability == "rollback" and $req.body.actor_ref.role != "operator" and
       ($req.body.rehearsal_ref != deploy_ref($reh;$rehearsal_sha) or
        $reh.body.outcome != "rehearsed" or
        $reh.body.environment.tier != $tier_name or
        $reh.body.from_release_ref != $req.body.release_ref or
        $reh.body.to_release_ref != $req.body.rollback_to_release_ref or
        # A rehearsal must precede the request it licenses; one dated after
        # the request rehearsed nothing this request can rely on.
        $reh.body.rehearsed_at > $req.body.requested_at)
    then ["deploy.rollback-unrehearsed"] else [] end) +
   (if $kill_doc.body.verdict == "satisfied" then [] else ["deploy.kill-switch"] end) +
   # A violated risk-gate verdict refuses on its own, whatever produced it, and
   # alongside any duty violation its reasons also carry.
   (if $risk_doc.body.verdict == "violated" or
       $risk_doc.body.classification.minimum_tier == "unknown"
    then ["deploy.risk-gate-violated"] else [] end) +
   (if ($tier_doc.body.requester_roles[$capability] |
        index($req.body.actor_ref.role)) == null or
       ($risk_doc.body.reason_ids | any(.[]; startswith("duty.")))
    then ["deploy.duty-violation"] else [] end) +
   (if ($matched | length) == 1 and $matched[0].operator_named and
       ($auth.body.authorization_kind != "named-operator" or
        $auth.body.operator.role != "operator" or
        $auth.body.decision != "authorized" or
        $auth.body.environment.tier != $tier_name)
    then ["deploy.authorization-wrong-tier"] else [] end))
 end | sort | unique) as $reasons |
{
  schema_version:1,
  kind:"deploy_gate_evaluation",
  id:$req.id,
  body:{
    activation_state:"inactive",
    authority:"none",
    authorization_ref:deploy_ref($auth;$authorization_sha),
    decision:(if ($reasons | length) == 0 then "admissible" else "refused" end),
    decision_ref:decision_ref($decision_doc;$decision_sha),
    evaluation_mode:"observation-only",
    kill_switch_evaluation_ref:deploy_ref($kill_doc;$kill_sha),
    qualification:unavailable_qualification,
    reason_ids:(if ($reasons | length) == 0 then ["deploy.admissible"] else $reasons end),
    reference_semantics:"identity-only",
    rehearsal_ref:deploy_ref($reh;$rehearsal_sha),
    release_ref:deploy_ref($rel;$release_sha),
    request_ref:deploy_ref($req;$request_sha),
    requested_capability:$capability,
    risk_evaluation_ref:deploy_ref($risk_doc;$risk_sha),
    tier:$tier_name,
    tiers_ref:tiers_ref($tier_doc;$tiers_sha)
  }
}
