# pinned from profiles/default/v1 at 4965175d0edeeec8ba746609e585b053be03e075
# Digests of the bytes as committed. Requirement 3 (yihanzhu/ystack#262) pins
# these so a look-alike default profile is refused by bytes, not by name.
def profile_pin: "4562888df59cd52feb6e9c9d29e2345579815695ec3af0aec833891f7f608a74";
def producer_config_pin:
  "ea076206d7f721aa4796c2a0830e95b3c7006703addc717240447c64ad589b61";
def manifest_pins:
  {ci:      "a5cf4b1b94e32d850e3d056024fa2d2c3977b977fb08323e99b89f8c159baff3",
   forge:   "47c5884ca83597a09f1122467c9c0dfd3ea5b4e0256d2d52ae648167349bffe5",
   producer:"ada221fd7186544a53ceb2f10e0bbe863eb0ef6ef54b407c65f58d7f21881bb3",
   publisher:"e780e0ceb0a305928d6c1fec127cfc6db0140cf2e48b3921e23e59d942419029",
   reviewer:"2f1ceaacd455e6cadc09f2762c6735eab48b91890240b6031af3db744a1175c4",
   verifier:"58f65eeac7dc8292e48adf6e1d0e8235d5a19c92521993c74b7b3368bb3f36fe"};
def pinned_digests: [profile_pin,producer_config_pin] + (manifest_pins | [.[]]);

# Fixed decision-record texts this component owns (requirement 6). Each is
# committed as its own output file and its digest is the real SHA-256 of the
# bytes `-r` on that string plus jq's own trailing newline produces; the
# constants below were computed once against that exact byte form and are not
# recomputed at run time, the way requirement 3's pins are not either.
def finish_text:
  "This attempt is finished once the assembler has produced and committed the materialization input to the caller's output directory.";
def finish_sha256:
  "961fbe945304d152c593ff020b05e1a3b920d0c5bfd316784a3ddc20a28316a0";
def verify_text:
  "Validate the committed input.json against adapters/local-git-materializer/v1/protocol.jq under the pinned jq before it is handed to the driver.";
def verify_sha256:
  "4e6169fc14cee55871718dfd3524b733827f3f9ee084b09368f61cc5dabb4af7";
def output_contract_text:
  "The materialization contract restricts this reproduction to a single unwritten path with a zero-byte patch, so no repository write is possible.";
def output_contract_sha256:
  "9af73fc3474f64165ffb93fc560f2f31d85a46a7fefb8d2af09ea6d8218e3ac0";
def policy_text:
  "This request is routine dependency assembly for a read-only shadow reproduction: it grants no write capability and it denies network access.";
def policy_sha256:
  "ddc0cfd18c6034f004d350e36d3e2b99ff5192e446450b3ba796b7a2b8960221";

# The materialization contract (requirement 5): the smallest values the
# protocol accepts, so inertness comes from the empty patch and not from the
# path list. Fixed, so its canonical text and digest are fixed too.
# Ends in a newline: it is stored the way `jq -S -c` writes a file (a
# trailing newline), which is the byte form its digest below is taken of —
# the same convention the fixture builder's `--rawfile` reads back.
def contract_text:
  "{\"allow_binary_patch\":false,\"allow_submodules\":false,\"allow_symlinks\":false,\"allowed_modes\":[\"100644\",\"100755\"],\"allowed_paths\":[\".ystack/never-written\"],\"candidate_repository_kind\":\"bare\",\"kind\":\"local_git_materialization_contract\",\"max_changed_paths\":1,\"max_patch_bytes\":1,\"schema_version\":1}\n";
def contract_sha256:
  "d28bbdb8af7207b2fb0c1002891a89ddecea9a68989b5f48efc4555dad5bed92";
def empty_sha256:
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

def content($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
def ok_value($v): {ok:true,value:$v};
def refuse($id): {ok:false,error:$id};

def revision: {repository_id:$repository_id,hash_algorithm:$hash_algorithm,commit_id:$commit_id};
def source_tree_ref:
  {revision:revision,location:{kind:"root"},object_type:"tree",object_id:$tree_id,
   mode:"040000"};

def manifest_slots:
  [{role:"ci",doc:$manifest_ci[0]},{role:"forge",doc:$manifest_forge[0]},
   {role:"producer",doc:$manifest_producer[0]},
   {role:"publisher",doc:$manifest_publisher[0]},
   {role:"reviewer",doc:$manifest_reviewer[0]},
   {role:"verifier",doc:$manifest_verifier[0]}];
def manifest_pairs:
  manifest_slots | map({content:.doc,sha256:$manifest_sha256[.role]}) |
  sort_by(.content.id);

def digest_checks_ok:
  $profile_sha256 == profile_pin and
  $producer_config_sha256 == producer_config_pin and
  ($manifest_sha256.ci == manifest_pins.ci) and
  ($manifest_sha256.forge == manifest_pins.forge) and
  ($manifest_sha256.producer == manifest_pins.producer) and
  ($manifest_sha256.publisher == manifest_pins.publisher) and
  ($manifest_sha256.reviewer == manifest_pins.reviewer) and
  ($manifest_sha256.verifier == manifest_pins.verifier);

# Requirement 16: every present config_source in the supplied resolved
# profile — each binding's own and every tool_sources[].config_source — must
# carry one of requirement 3's pinned digests. Today exactly one is present
# (the producer's, pinned to producer-config.json), but the rule is general.
def present_config_source_digests:
  ([$resolved_profile[0].body.bindings[] | .config_source] +
   [$resolved_profile[0].body.bindings[] | .tool_sources[]? | .config_source]) |
  map(select(.state == "present") | .value.value_sha256);
def config_pins_ok:
  present_config_source_digests | all(.[]; . as $d | pinned_digests | index($d) != null);

def claim_kind_ok: $claim[0].kind == "execution_environment_claim";
def claim_id_ok:
  ($claim[0].id | type == "string" and
   test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z"));

def forge_binding:
  [$resolved_profile[0].body.bindings[] | select(.binding.role == "forge")] | .[0];

def requested_by($binding):
  {role:$binding.binding.role,
   implementation_id:$binding.adapter_implementation.id,
   implementation_version:$binding.adapter_implementation.version,
   adapter_instance_id:$binding.binding.adapter_instance_id,
   principal_id:$binding.binding.principal_id,
   execution_boundary_id:$binding.binding.execution_boundary_id} +
  (if $binding.binding | has("authority_ref")
   then {authority_ref:$binding.binding.authority_ref} else {} end);

def finish_condition_scope:
  {ref:{purpose:"finish-condition",
        decision_record_ref:content("decision-finish";"text/plain";finish_sha256),
        subject_ref:{type:"artifact",
          value:{type:"content",value:content("payload-finish";"text/plain";finish_sha256)}},
        scope_sha256:finish_sha256},
   input_id:"input.finish"};
def verification_instruction_scope:
  {ref:{purpose:"verification-instructions",
        decision_record_ref:content("decision-verify";"text/plain";verify_sha256),
        subject_ref:{type:"artifact",
          value:{type:"content",value:content("payload-verify";"text/plain";verify_sha256)}},
        scope_sha256:verify_sha256},
   input_id:"input.verify"};
def materialization_contract_scope:
  {ref:{purpose:"output-contract",
        decision_record_ref:
          content("decision-output-contract";"text/plain";output_contract_sha256),
        subject_ref:{type:"artifact",
          value:{type:"content",value:content("payload-materialize";"application/json";contract_sha256)}},
        scope_sha256:output_contract_sha256},
   input_id:"input.materialize"};
def policy_scope:
  {purpose:"policy",
   decision_record_ref:content("decision-policy";"text/plain";policy_sha256),
   subject_ref:{type:"artifact",
     value:{type:"content",value:content("payload-policy";"text/plain";policy_sha256)}},
   scope_sha256:policy_sha256};

def inputs_list:
  [
    {input_id:"input.finish",
     value:{type:"artifact",value:{type:"content",value:content("payload-finish";"text/plain";finish_sha256)}}},
    {input_id:"input.materialize",
     value:{type:"artifact",value:{type:"content",value:content("payload-materialize";"application/json";contract_sha256)}}},
    {input_id:"input.producer-patch",
     value:{type:"artifact",value:{type:"content",value:content("producer.patch";"text/x-diff";empty_sha256)}}},
    {input_id:"input.source-tree",
     value:{type:"artifact",value:{type:"git-object",value:source_tree_ref}}},
    {input_id:"input.verify",
     value:{type:"artifact",value:{type:"content",value:content("payload-verify";"text/plain";verify_sha256)}}}
  ] | sort_by(.input_id);

def operation($binding):
  {role:"forge",
   binding_id:$binding.binding.binding_id,
   capability_id:"core.forge.materialize-candidate.v2",
   permissions:["core.perm.candidate-repository.write.v2","core.perm.evidence.write.v1",
     "core.perm.scratch.write.v1","core.perm.target.read.v1"],
   arguments:{
     source_tree_input_id:"input.source-tree",
     candidate_output_id:"candidate.repository",
     materialization_contract:materialization_contract_scope,
     network_mode:"deny"}};

def request_body($binding):
  {initiative_id:"initiative.shadow-input-assembler",
   workflow_id:"workflow.shadow-reproduction",
   stage_id:"stage.materialize",
   task_class_id:"task.local-git-materialize",
   requested_by:requested_by($binding),
   target_repository_id:$repository_id,
   target_revision:{state:"present",value:revision},
   source:{state:"present",value:{type:"git-object",value:source_tree_ref}},
   base:{state:"present",value:revision},
   inputs:inputs_list,
   prior_evidence_refs:[],
   risk:{tier:{namespace:"core",name:"routine"},
     reason_ids:["shadow.reproduction.read-only"],
     policy_ref:policy_scope,required_gate_refs:[]},
   resolved_profile_ref:
     {schema_version:2,kind:"resolved_profile",id:$resolved_profile[0].id,
      sha256:$resolved_profile_sha256},
   selection_ref:$resolved_profile[0].body.selection_ref,
   repository_context_ref:$resolved_profile[0].body.repository_context_ref,
   gate_decision_refs:[],
   environment_ref:{environment_id:$claim[0].id,fingerprint_sha256:$claim_sha256},
   operation:operation($binding),
   finish_condition:finish_condition_scope,
   verification_instruction:verification_instruction_scope,
   required_evidence_kinds:["deterministic"],
   requested_at:$requested_at};

def request_document:
  if ($profile[0].id != "profile.default.v1") then refuse("E_PROFILE")
  elif (digest_checks_ok | not) then refuse("E_PROFILE")
  elif (config_pins_ok | not) then refuse("E_PROFILE")
  elif (claim_kind_ok | not) then refuse("E_SHAPE")
  elif (claim_id_ok | not) then refuse("E_SHAPE")
  else
    forge_binding as $binding |
    ok_value({schema_version:2,kind:"stage_request",
      id:"request.shadow-input-assembler",body:request_body($binding)})
  end;

def payloads_list:
  [{input_id:"input.materialize",media_type:"application/json",data:contract_text},
   {input_id:"input.producer-patch",media_type:"text/x-diff",data:""}] |
  sort_by(.input_id);
def verified_payloads_list:
  [{input_id:"input.materialize",
    content:{media_type:"application/json",data:contract_text},sha256:contract_sha256},
   {input_id:"input.producer-patch",
    content:{media_type:"text/x-diff",data:""},sha256:empty_sha256}] |
  sort_by(.input_id);

def input_document:
  {schema_version:1,kind:"local_git_materialization_input",
   attempt:{attempt_id:"attempt.assemble",attempt_number:1,result_id:"result.assemble",
     started_at:$requested_at,finished_at:$requested_at,recorded_at:$requested_at},
   profile:{content:$profile[0],sha256:$profile_sha256},
   resolved_profile:{content:$resolved_profile[0],sha256:$resolved_profile_sha256},
   manifests:manifest_pairs,
   stage_request:{content:$stage_request[0],sha256:$stage_request_sha256},
   payloads:payloads_list,
   trust_context:{verified_payloads:verified_payloads_list}};

def decision_texts:
  {finish:finish_text,verify:verify_text,output_contract:output_contract_text,
   policy:policy_text};
def pair_refs:
  {stage_request_ref:
     {schema_version:2,kind:"stage_request",id:$stage_request[0].id,
      sha256:$stage_request_sha256},
   resolved_profile_ref:
     {schema_version:2,kind:"resolved_profile",id:$resolved_profile[0].id,
      sha256:$resolved_profile_sha256}};

if $phase == "request" then request_document
elif $phase == "input" then
  ok_value({input:input_document,decision_texts:decision_texts,
    pair_refs:pair_refs})
else refuse("E_RUNTIME")
end
