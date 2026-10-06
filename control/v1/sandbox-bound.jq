def exact($fields): type == "object" and (keys | sort) == ($fields | sort);
def id_ok: type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");
def sha256_ok: type == "string" and test("\\A[0-9a-f]{64}\\z");
def content_ref_ok($media):
  exact(["content_id","media_type","sha256"]) and (.content_id | id_ok) and
  .media_type == $media and (.sha256 | sha256_ok);
def document_ref_ok($kind; $version):
  exact(["id","kind","schema_version","sha256"]) and .schema_version == $version and
  .kind == $kind and (.id | id_ok) and (.sha256 | sha256_ok);
def identity_ok:
  exact(["adapter_instance_id","execution_boundary_id","principal_id","role"]) and
  all(.[]; id_ok);
def path_ok:
  type == "string" and length <= 256 and test("\\A/sandbox/[a-z0-9][a-z0-9._/-]*\\z") and
  (test("//|/\\./|/\\.\\./|[?*\\[\\]{}\\\\]|[[:space:]]") | not);
def scalar_ok: type == "string" and length <= 256 and (test("[[:cntrl:]]") | not);
def truth_or_unknown: type == "boolean" or . == "unknown";
def root_ok:
  exact(["access","path","purpose"]) and
  (.access == "read-only" or .access == "read-write" or .access == "write-only") and
  (.path | path_ok) and (.purpose | id_ok);
def resource_ok:
  exact(["access","id","kind","path"]) and
  (.access == "read-only" or .access == "read-write" or .access == "write-only") and
  (.id | id_ok) and .kind == "directory" and (.path | path_ok);
def variable_ok:
  exact(["name","value"]) and (.name | test("\\A[A-Z][A-Z0-9_]{0,63}\\z")) and
  (.value | scalar_ok);
def tool_ok:
  exact(["argv","executable","network","resource_ids","sha256","tool_id"]) and
  (.argv | type == "array" and length >= 1 and length <= 32 and all(.[];scalar_ok)) and
  (.executable | path_ok) and (.network | type == "boolean") and
  (.resource_ids | type == "array" and length <= 16 and all(.[];id_ok)) and
  (.sha256 | sha256_ok) and (.tool_id | id_ok);

def claim_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "execution_environment_claim" and (.id | id_ok) and
  (.body |
    exact(["declaration_status","duty_evaluation_ref","effects","environment",
      "execution_identity","filesystem","isolation","limits","network","policy_set_ref",
      "resources","sensitive_material","stage_result_ref","tools"]) and
    (.declaration_status == "complete" or .declaration_status == "incomplete") and
    (.duty_evaluation_ref | document_ref_ok("duty_separation_evaluation";1)) and
    (.policy_set_ref | document_ref_ok("control_policy_set";1)) and
    (.stage_result_ref | document_ref_ok("stage_result";2)) and
    (.execution_identity | identity_ok) and
    (.effects | exact(["external_writes","target_writes"]) and all(.[];truth_or_unknown)) and
    (.environment | exact(["mode","variables"]) and
      (.mode == "clear-then-allowlist" or .mode == "inherit" or .mode == "unknown") and
      (.variables | type == "array" and length <= 64 and all(.[];variable_ok))) and
    (.filesystem | exact(["read_roots","write_roots"]) and
      (.read_roots | type == "array" and length <= 16 and all(.[];root_ok)) and
      (.write_roots | type == "array" and length <= 16 and all(.[];root_ok))) and
    (.isolation | exact(["candidate_only","disposable","host_access"]) and
      all(.[];truth_or_unknown)) and
    (.limits | exact(["cpu_time_ms","memory_bytes","output_bytes","process_count",
      "wall_time_ms"]) and all(.[];type == "number" and . >= 0 and floor == .)) and
    (.network | exact(["endpoints","mode"]) and
      (.mode == "allow" or .mode == "deny" or .mode == "unknown") and
      (.endpoints | type == "array" and length <= 32 and all(.[];scalar_ok))) and
    (.resources | type == "array" and length <= 32 and all(.[];resource_ok)) and
    (.sensitive_material | exact(["credential_refs","exposure","secret_refs"]) and
      (.credential_refs | type == "array" and length <= 32 and all(.[];id_ok)) and
      (.secret_refs | type == "array" and length <= 32 and all(.[];id_ok)) and
      (.exposure == "none" or .exposure == "present" or .exposure == "unknown")) and
    (.tools | type == "array" and length <= 16 and all(.[];tool_ok)));

def section_ref_ok:
  exact(["decision_ref","policy_ref","section_id"]) and (.section_id | id_ok) and
  (.policy_ref | content_ref_ok("application/vnd.ystack.control-policy+json")) and
  (.decision_ref | content_ref_ok("application/vnd.ystack.control-decision+json"));
def policy_set_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "control_policy_set" and .id == "control-policy-set.sandbox-bound.v1" and
  (.body |
    exact(["activation_state","core_contract","fail_mode","policy_version","sections"]) and
    .activation_state == "inactive" and .fail_mode == "closed" and .policy_version == "v1" and
    (.core_contract | exact(["generation_id","package_ref","semantic_identity"]) and
      .semantic_identity == "core.contracts.v2" and
      (.generation_id | test("\\Ag-[0-9a-f]{64}\\z")) and
      (.package_ref | content_ref_ok("application/vnd.ystack.core-contract+json"))) and
    (.sections | type == "array" and length == 6 and all(.[];section_ref_ok)) and
    (.sections | map(.section_id)) == ["credential-policy","duty-separation",
      "evidence-integrity","kill-switch","risk-gates","sandbox"]);
def duty_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "duty_separation_evaluation" and (.id | id_ok) and
  (.body |
    exact(["activation_state","core_contract","decision_ref","evaluation_mode","policy_ref",
      "policy_set","reason_ids","reference_semantics","stage","verdict"]) and
    .activation_state == "inactive" and .evaluation_mode == "observation-only" and
    .reference_semantics == "identity-only" and
    (.decision_ref | content_ref_ok("application/vnd.ystack.control-decision+json")) and
    (.policy_ref | content_ref_ok("application/vnd.ystack.control-policy+json")) and
    (.policy_set | exact(["id","sha256"]) and (.id | id_ok) and (.sha256 | sha256_ok)) and
    (.reason_ids | type == "array" and length >= 1 and length <= 64 and all(.[];id_ok) and
      . == (sort | unique)) and
    (.stage | exact(["request_ref","resolved_profile_ref","result_ref"]) and
      (.request_ref | document_ref_ok("stage_request";2)) and
      (.resolved_profile_ref | document_ref_ok("resolved_profile";2)) and
      (.result_ref | document_ref_ok("stage_result";2))) and
    ((.verdict == "satisfied" and .reason_ids == ["duty.satisfied"]) or
     (.verdict == "inconclusive" and .reason_ids == ["actual.capability-unclassified"]) or
     (.verdict == "violated" and
       (.reason_ids | all(. != "duty.satisfied" and . != "actual.capability-unclassified")))));
def duty_binding_ok($set; $set_sha):
  . as $duty_doc |
  ([$set.body.sections[] | select(.section_id == "duty-separation")]) as $sections |
  ($sections | length) == 1 and
  $duty_doc.body.policy_set == {id:$set.id,sha256:$set_sha} and
  $duty_doc.body.policy_ref == $sections[0].policy_ref and
  $duty_doc.body.decision_ref == $sections[0].decision_ref and
  $duty_doc.body.core_contract == $set.body.core_contract and
  $duty_doc.id == $duty_doc.body.stage.result_ref.id;

def policy_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "sandbox_policy" and .id == "control-policy.sandbox" and
  (.body |
    exact(["activation_state","environment","evaluation_mode","fail_mode","filesystem",
      "isolation","limits","network","policy_version","reference_semantics","required_role",
      "resources","sensitive_material","tools"]) and
    .activation_state == "inactive" and .evaluation_mode == "observation-only" and
    .fail_mode == "closed" and .policy_version == "v1" and
    .reference_semantics == "identity-only" and .required_role == "verifier" and
    .environment == {mode:"clear-then-allowlist",variables:[
      {name:"LANG",value:"C"},{name:"LC_ALL",value:"C"},
      {name:"PATH",value:"/sandbox/tools"},{name:"TMPDIR",value:"/sandbox/scratch"}]} and
    .filesystem == {read_roots:[
      {access:"read-only",path:"/sandbox/candidate",purpose:"candidate"},
      {access:"read-only",path:"/sandbox/tools",purpose:"toolchain"}],write_roots:[
      {access:"write-only",path:"/sandbox/evidence",purpose:"evidence"},
      {access:"read-write",path:"/sandbox/scratch",purpose:"scratch"}]} and
    .isolation == {candidate_only:true,disposable:true,host_access:false} and
    .limits == {cpu_time_ms:30000,memory_bytes:536870912,output_bytes:10485760,
      process_count:32,wall_time_ms:60000} and .network == {endpoints:[],mode:"deny"} and
    .resources == [
      {access:"read-only",id:"resource.candidate",kind:"directory",path:"/sandbox/candidate"},
      {access:"write-only",id:"resource.evidence",kind:"directory",path:"/sandbox/evidence"},
      {access:"read-write",id:"resource.scratch",kind:"directory",path:"/sandbox/scratch"},
      {access:"read-only",id:"resource.toolchain",kind:"directory",path:"/sandbox/tools"}] and
    .sensitive_material == {credential_refs:[],exposure:"none",secret_refs:[]} and
    .tools == [{argv:["verify","--candidate","/sandbox/candidate","--evidence",
      "/sandbox/evidence"],executable:"/sandbox/tools/verifier",
      identity_binding:{accepted_set_id:"sandbox.accepted-identities.v1",
        environment_source:"claim.id",slot:"verifier"},network:false,
      resource_ids:["resource.candidate","resource.evidence","resource.scratch"],
      tool_id:"tool.verifier"}]);
def observation_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "sandbox_verifier_observation" and .id == "sandbox.observation.verifier" and
  (.body | exact(["accepted_set_sha256","environment_entry_sha256","environment_id",
    "target_repository_id","verifier_sha256"]) and (.environment_id | id_ok) and
    (.target_repository_id | id_ok) and (.accepted_set_sha256 | sha256_ok) and
    (.environment_entry_sha256 | sha256_ok) and (.verifier_sha256 | sha256_ok));
def registry_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "shadow_environment_registry" and (.id | id_ok) and
  (.body | exact(["activation_state","environments","registry_version"]) and
    (.environments | type == "array" and all(.[];
      exact(["description","environment_id","evidence_scope","proof_state",
        "source_root_commit","target_repository_id"]) and (.environment_id | id_ok) and
      (.target_repository_id | id_ok) and (.source_root_commit | test("\\A[0-9a-f]{40}\\z")))));
def digest_list_ok:
  type == "array" and length >= 1 and length <= 8 and all(.[];sha256_ok) and
  all(.[];. != ("0"*64) and . != ("1"*64)) and . == (sort | unique);
def accepted_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "sandbox_accepted_identity_set" and .id == "sandbox.accepted-identities.v1" and
  (.body | exact(["activation_state","environments","set_version"]) and
    .activation_state == "inactive" and .set_version == "v1" and
    (.environments | type == "array" and all(.[];
      exact(["environment_id","identities","mechanisms","scratch_bytes"]) and
      (.environment_id | id_ok) and (.scratch_bytes | type == "number" and floor == . and . > 0) and
      (.identities | exact(["guest_init","guest_kernel","guest_kernel_config",
        "guest_supervisor","host_runtime","host_supervisor","image","toolchain",
        "verification_instructions","verifier"]) and all(.[];digest_list_ok)) and
      (.mechanisms | exact(["cpu_time_ms","memory_bytes","output_bytes","process_count",
        "scratch_bytes","wall_time_ms"]) and all(.[];
          type == "array" and length >= 1 and length <= 8 and all(.[];id_ok) and
          . == (sort | unique))))));
def entry_digest_ok:
  type == "array" and all(.[];exact(["environment_id","sha256"]) and
    (.environment_id | id_ok) and (.sha256 | sha256_ok));
def document_ref($document; $digest):
  {schema_version:$document.schema_version,kind:$document.kind,id:$document.id,sha256:$digest};

($policy[0]) as $p | ($decision[0]) as $decision_doc | ($policy_set[0]) as $set |
($duty[0]) as $duty_doc | ($claim[0]) as $claim_doc | ($observation[0]) as $observation_doc |
($registry[0]) as $registry_doc | ($accepted[0]) as $accepted_doc |
(if ($p | policy_ok) and ($set | policy_set_ok) and ($duty_doc | duty_ok) and
    ($claim_doc | claim_ok) and ($observation_doc | observation_ok) and
    ($registry_doc | registry_ok) and ($accepted_doc | accepted_ok) and
    ($entry_digests[0] | entry_digest_ok)
 then true else error("invalid-input") end) |
(if ($duty_doc | duty_binding_ok($set;$policy_set_sha)) then true else error("duty-binding") end) |
([$set.body.sections[] | select(.section_id == "sandbox")]) as $sandbox_sections |
(if ($sandbox_sections | length) == 1 and
    $sandbox_sections[0].policy_ref == $decision_doc.body.policy_ref and
    $sandbox_sections[0].decision_ref == {content_id:$decision_doc.id,
      media_type:"application/vnd.ystack.control-decision+json",sha256:$decision_sha}
 then true else error("sandbox-policy-set-binding") end) |
([$registry_doc.body.environments[] | select(.environment_id == $claim_doc.id)]) as $entries |
([$accepted_doc.body.environments[] | select(.environment_id == $claim_doc.id)]) as $accepted_entries |
([$entry_digests[0][] | select(.environment_id == $claim_doc.id)]) as $entry_hashes |
($observation_doc.body.verifier_sha256) as $d |
($p.body.tools[0] | del(.identity_binding) + {sha256:$d}) as $expected_tool |
((($entries | length) == 1) and (($accepted_entries | length) == 1) and
  (($entry_hashes | length) == 1) and $claim_doc.body.declaration_status == "complete" and
  $duty_doc.body.verdict == "satisfied" and
  $claim_doc.body.execution_identity.role == $p.body.required_role and
  $claim_doc.body.policy_set_ref == document_ref($set;$policy_set_sha) and
  $claim_doc.body.duty_evaluation_ref == document_ref($duty_doc;$duty_sha) and
  $claim_doc.body.stage_result_ref == $duty_doc.body.stage.result_ref and
  $claim_doc.body.effects == {external_writes:false,target_writes:false} and
  $claim_doc.body.environment == $p.body.environment and
  $claim_doc.body.filesystem == $p.body.filesystem and
  $claim_doc.body.isolation == $p.body.isolation and $claim_doc.body.limits == $p.body.limits and
  $claim_doc.body.network == $p.body.network and $claim_doc.body.resources == $p.body.resources and
  $claim_doc.body.sensitive_material == $p.body.sensitive_material and
  $claim_doc.body.tools == [$expected_tool] and
  $observation_doc.body.environment_id == $claim_doc.id and
  $observation_doc.body.environment_entry_sha256 == $entry_hashes[0].sha256 and
  $observation_doc.body.target_repository_id == $entries[0].target_repository_id and
  $observation_doc.body.accepted_set_sha256 == $accepted_set_sha and
  ($accepted_entries[0].identities.verifier | index($d)) != null and
  $claim_doc.body.tools[0].sha256 == $d) as $satisfied |
{
  schema_version:1,kind:"sandbox_policy_evaluation",id:$claim_doc.id,
  body:{activation_state:"inactive",authority_effect:"none",
    claim_ref:document_ref($claim_doc;$claim_sha),
    decision_ref:{content_id:$decision_doc.id,
      media_type:"application/vnd.ystack.control-decision+json",sha256:$decision_sha},
    duty_evaluation_ref:document_ref($duty_doc;$duty_sha),
    enforcement_proof:"declaration-only",evaluation_mode:"observation-only",
    policy_ref:$decision_doc.body.policy_ref,policy_set:{id:$set.id,sha256:$policy_set_sha},
    qualification_effect:"none",
    reason_ids:(if $satisfied then ["sandbox.verifier-binding-satisfied"]
      else ["sandbox.verifier-binding-refused"] end),
    verdict:(if $satisfied then "satisfied" else "inconclusive" end),
    verifier_binding:($observation_doc.body + {observation_sha256:$observation_sha})}
}
