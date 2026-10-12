import "profile_graph" as graph;
import "stage_request" as stage;

def require($condition): if $condition then . else error("E_RELATION") end;
def scope($old; $decision; $subject):
  $old | .ref.decision_record_ref.sha256=$decision |
  .ref.subject_ref.value.value.sha256=$subject | .ref.scope_sha256=$decision;
def request($original; $m):
  $original.stage_request.content |
  .id=("request.shadow-write."+$m.suffix) |
  .body.initiative_id="initiative.shadow-consumer-integration" |
  .body.workflow_id="workflow.shadow-evidence-commit" |
  .body.task_class_id="task.commit-shadow-evidence" |
  .body.stage_id="stage.materialize" |
  .body.environment_ref={environment_id:$m.environment_id,fingerprint_sha256:$m.claim_sha256} |
  .body.prior_evidence_refs=[] | .body.gate_decision_refs=[] |
  .body.risk={tier:{namespace:"core",name:"routine"},
    reason_ids:["shadow.evidence.candidate-only"],required_gate_refs:[],
    policy_ref:($original.stage_request.content.body.risk.policy_ref |
      .decision_record_ref.sha256=$m.policy | .subject_ref.value.value.sha256=$m.policy |
      .scope_sha256=$m.policy)} |
  .body.finish_condition=scope(.body.finish_condition;$m.finish;$m.finish) |
  .body.verification_instruction=scope(.body.verification_instruction;$m.verify;$m.verify) |
  .body.operation.arguments.materialization_contract=
    scope(.body.operation.arguments.materialization_contract;$m.output_contract;$m.contract) |
  .body.inputs |= (map(if .input_id=="input.finish" then .value.value.value.sha256=$m.finish
    elif .input_id=="input.verify" then .value.value.value.sha256=$m.verify
    elif .input_id=="input.materialize" then .value.value.value.sha256=$m.contract
    elif .input_id=="input.producer-patch" then .value.value.value.sha256=$m.patch
    else . end) | sort_by(.input_id));

($metadata | require(length==1) | .[0]) as $m |
require(($contract|fromjson) == {schema_version:1,kind:"local_git_materialization_contract",
  allowed_paths:$m.allowed_paths,max_patch_bytes:1048576,max_changed_paths:32,
  allowed_modes:["100644","100755"],allow_binary_patch:false,allow_symlinks:false,
  allow_submodules:false,candidate_repository_kind:"bare"}) |
if $phase=="stage-request" then
  . as $original |
  require(graph::profile_set_ok(.profile;.resolved_profile;.manifests)) |
  require(.stage_request.content | stage::document_self_ok) |
  {original:$original,stage_request:request($original;$m)}
elif $phase=="final-input" then
  require(.stage_request == request(.original;$m)) |
  . as $first | .original |
  .attempt={attempt_id:$m.attempt_id,attempt_number:1,result_id:("result.shadow-write."+$m.suffix),
    started_at:$first.stage_request.body.requested_at,
    finished_at:$first.stage_request.body.requested_at,
    recorded_at:$first.stage_request.body.requested_at} |
  .stage_request={content:$first.stage_request,sha256:$m.stage_request_sha256} |
  .payloads=[{input_id:"input.materialize",media_type:"application/json",data:$contract},
    {input_id:"input.producer-patch",media_type:"text/x-diff",data:$patch}] |
  .trust_context.verified_payloads=[{input_id:"input.materialize",sha256:$m.contract,
      content:{media_type:"application/json",data:$contract}},
    {input_id:"input.producer-patch",sha256:$m.patch,
      content:{media_type:"text/x-diff",data:$patch}}]
else error("E_RELATION") end
