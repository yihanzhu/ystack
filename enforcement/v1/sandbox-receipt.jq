def exact($fields):
  type == "object" and (keys | sort) == ($fields | sort);

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");

def all_ones_sha: "1" * 64;
def all_zeros_sha: "0" * 64;

def timing_ok:
  type == "string" and
  test("\\A[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z\\z");

def oid_ok($algorithm):
  type == "string" and
  (if $algorithm == "sha1" then test("\\A[0-9a-f]{40}\\z")
   elif $algorithm == "sha256" then test("\\A[0-9a-f]{64}\\z")
   else false end);

def identity_slots:
  ["guest_init","guest_kernel","guest_kernel_config","guest_supervisor",
   "host_runtime","host_supervisor","image","toolchain",
   "verification_instructions","verifier"];

def limit_rows: ["cpu_time_ms","memory_bytes","output_bytes","process_count",
  "scratch_bytes","wall_time_ms"];

def limit_reason($row_key):
  {cpu_time_ms:"limit.cpu-time-reached",wall_time_ms:"limit.wall-time-reached",
   memory_bytes:"limit.memory-reached",output_bytes:"limit.output-reached",
   process_count:"limit.process-count-reached",
   scratch_bytes:"limit.scratch-reached"}[$row_key];

# R3.2 origin (content claims only; R2 proves the channel, not this shape).
def origin_ok:
  exact(["accepted_set_sha256","producer_role","store_id"]) and
  .producer_role == "host-supervisor" and (.store_id | id_ok) and
  (.accepted_set_sha256 | sha256_ok);

# R3.3 attempt.
def attempt_ok:
  exact(["attempt_id","attempt_number","launch_request_sha256"]) and
  (.attempt_id | id_ok) and
  (.attempt_number | type == "number" and floor == . and . >= 1 and . <= 1024) and
  (.launch_request_sha256 | sha256_ok);

# R3.4 control.
def control_ok:
  exact(["decision_sha256","evaluator_driver_sha256","evaluator_program_sha256",
    "policy_sha256","policy_set_sha256","sandbox_evaluation_sha256"]) and
  all(.[];sha256_ok);

# R3.5 subject: source and candidate revisions.
def revision_ok:
  exact(["commit_id","hash_algorithm","repository_id","tree_id"]) and
  (.repository_id | id_ok) and
  (.hash_algorithm == "sha1" or .hash_algorithm == "sha256") and
  (.hash_algorithm as $alg | .commit_id | oid_ok($alg)) and
  (.hash_algorithm as $alg | .tree_id | oid_ok($alg));

def candidate_ok($hash_algorithm):
  exact(["commit_id","manifest_sha256","preparation_record_sha256","tree_id"]) and
  (.preparation_record_sha256 | sha256_ok) and (.manifest_sha256 | sha256_ok) and
  (.commit_id | oid_ok($hash_algorithm)) and (.tree_id | oid_ok($hash_algorithm));

def subject_ok:
  exact(["candidate","environment_entry_sha256","environment_id","incident_sha256",
    "source","target_repository_id"]) and
  (.environment_id | id_ok) and (.environment_entry_sha256 | sha256_ok) and
  (.target_repository_id | id_ok) and (.incident_sha256 | sha256_ok) and
  (.source | revision_ok) and
  (.source.hash_algorithm as $alg | .candidate | candidate_ok($alg));

# R3.6 identities: ten observed-or-unobserved slots.
def identity_slot_ok:
  type == "object" and
  ((exact(["sha256","state"]) and .state == "observed" and (.sha256 | sha256_ok)) or
   (exact(["reason_id","state"]) and .state == "unobserved" and (.reason_id | id_ok)));

def identities_ok:
  exact(identity_slots) and
  ([identity_slots[] as $slot | .[$slot] | identity_slot_ok] | all);

# R3.7 limits: exactly the six R6 rows.
def row_ok:
  exact(["bound","enforcement","mechanism_id","observation","observed","reached",
    "resolution","observer"]) and
  (.bound | type == "number" and floor == . and . >= 0) and
  (.resolution | type == "number" and floor == . and . >= 0) and
  (.observation == "complete" or .observation == "partial" or
    .observation == "unavailable") and
  (.enforcement == "hard" or .enforcement == "none" or .enforcement == "unknown") and
  (.reached | type == "boolean") and
  (.mechanism_id | id_ok) and
  (.observer == "host-supervisor" or .observer == "guest-supervisor") and
  (if .observation == "unavailable" then .observed == null
   else (.observed | type == "number" and floor == . and . >= 0) end) and
  (if .observation != "unavailable" and .observed >= .bound
   then .reached == true else true end);

def limits_ok:
  exact(limit_rows) and
  ([limit_rows[] as $row | .[$row] | row_ok] | all);

# R3.8 teardown and lifecycle.
def teardown_ok:
  exact(["state","storage_destroyed","tree_terminated"]) and
  (.state == "confirmed" or .state == "failed" or .state == "unconfirmed") and
  (.tree_terminated | type == "boolean") and
  (.storage_destroyed | type == "boolean") and
  (if .state == "confirmed" then .tree_terminated == true and .storage_destroyed == true
   else true end);

def lifecycle_ok:
  exact(["admission","control_deadline","runtime"]) and
  (.admission == "admitted" or .admission == "refused") and
  (.runtime == "completed" or .runtime == "error") and
  (.control_deadline == "met" or .control_deadline == "exceeded");

# R3.9 payload.
def payload_ok:
  exact(["evidence_manifest_sha256","exit_code","exit_state","stderr_sha256",
    "stdout_sha256"]) and
  (.stdout_sha256 | sha256_ok) and (.stderr_sha256 | sha256_ok) and
  (.evidence_manifest_sha256 | sha256_ok) and
  (.exit_state == "exited" or .exit_state == "signaled" or .exit_state == "not-started") and
  (if .exit_state == "exited"
   then (.exit_code | type == "number" and floor == . and . >= 0 and . <= 255)
   else .exit_code == null end);

# R3.10 timing.
def timing_shape_ok:
  exact(["admitted_at","terminated_at"]) and
  (.admitted_at | timing_ok) and (.terminated_at | timing_ok) and
  (.admitted_at <= .terminated_at);

# R3.11 outcome shape (R8 governs its content; see derive_outcome below).
def outcome_shape_ok:
  exact(["reason_ids","verdict"]) and
  (.verdict == "satisfied" or .verdict == "violated" or .verdict == "failed") and
  (.reason_ids | type == "array" and length >= 1 and all(.[];id_ok) and
    . == (sort | unique));

# R3.1 envelope and full body shape, plus the two R3.8 consistency rules.
def body_shape_ok:
  exact(["attempt","contract_version","control","identities","lifecycle","limits",
    "origin","outcome","payload","subject","teardown","timing"]) and
  .contract_version == "v1" and
  (.origin | origin_ok) and
  (.attempt | attempt_ok) and
  (.control | control_ok) and
  (.subject | subject_ok) and
  (.identities | identities_ok) and
  (.limits | limits_ok) and
  (.teardown | teardown_ok) and
  (.lifecycle | lifecycle_ok) and
  (.payload | payload_ok) and
  (.timing | timing_shape_ok) and
  (.outcome | outcome_shape_ok) and
  (if .payload.exit_state == "not-started"
   then .lifecycle.admission == "refused" or .lifecycle.runtime == "error" else true end) and
  (if .lifecycle.admission == "refused"
   then .payload.exit_state == "not-started" else true end);

def receipt_shape_ok:
  exact(["body","id","kind","schema_version"]) and
  .kind == "sandbox_enforcement_receipt" and .schema_version == 1 and
  (.id | id_ok) and (.body | body_shape_ok);

# R4.1 expectation shape.
def expectation_body_shape_ok:
  exact(["attempt","control","store_id","subject"]) and
  (.store_id | id_ok) and
  (.attempt | attempt_ok) and
  (.control | control_ok) and
  (.subject | subject_ok);

def expectation_shape_ok:
  exact(["body","id","kind","schema_version"]) and
  .kind == "sandbox_receipt_expectation" and .schema_version == 1 and
  (.id | id_ok) and (.body | expectation_body_shape_ok);

# R7.4 exclusive precedence, evaluated on the raw (possibly malformed) input.
def safe_field($k):
  if (type == "object") then (.[$k] // null) else null end;

def is_declaration_only:
  (safe_field("kind")) == "sandbox_policy_evaluation";

def is_kind_unsupported:
  (safe_field("kind")) != "sandbox_enforcement_receipt" or
  (safe_field("schema_version")) != 1 or
  (((safe_field("body") | type) == "object") and
    ((safe_field("body")).contract_version != "v1"));

# R7.4 receipt.placeholder-identity: every `*_sha256` field and observed `sha256`,
# scanned in both receipt and expectation.
def sha_leaf_values:
  [.. | objects | to_entries[] | select((.key | test("_sha256$")) or .key == "sha256") |
    .value];

def has_placeholder_identity:
  sha_leaf_values | any(.[]; . == all_ones_sha or . == all_zeros_sha);

# R8 outcome derivation, from recorded fields only.
def failure_set:
  ((if .lifecycle.admission == "refused" then ["failure.launch-refused"] else [] end) +
   (if .lifecycle.runtime == "error" then ["failure.runtime"] else [] end) +
   (if .lifecycle.control_deadline == "exceeded"
     then ["failure.supervisor-timeout"] else [] end) +
   (if .teardown.state != "confirmed" then ["failure.teardown"] else [] end) +
   (if ([identity_slots[] as $slot | .identities[$slot].state] |
        any(. == "unobserved")) or
       ([limit_rows[] as $row | .limits[$row].observation] |
        any(. == "partial" or . == "unavailable"))
     then ["failure.observation-unavailable"] else [] end) +
   (if ([limit_rows[] as $row | .limits[$row].enforcement] |
        any(. == "none" or . == "unknown"))
     then ["failure.enforcement-unavailable"] else [] end)
  ) | sort | unique;

def reached_reasons:
  ([limit_rows[] as $row | select(.limits[$row].reached == true) | limit_reason($row)]) |
  sort | unique;

def derive_outcome:
  (failure_set) as $failures |
  if ($failures | length) > 0 then {verdict:"failed",reason_ids:$failures}
  elif (reached_reasons | length) > 0
    then {verdict:"violated",reason_ids:reached_reasons}
  else {verdict:"satisfied",reason_ids:["enforcement.satisfied"]} end;

def is_outcome_inconsistent:
  .outcome != (. | derive_outcome);

# Shape checks of the five fixed documents/entry_digests: a mismatch is a
# repository/caller integrity error, so it's a jq `error` (E_RELATION), not a
# `reason_id`. `shape($s)` below is the one generic combinator: an object
# schema recurses each key (exact key set), a one-elem array schema recurses
# every element, else it's a leaf/constraint kind.
def num_ok: type == "number" and floor == . and . >= 0;

def get($doc; $path):
  reduce $path[] as $k ($doc; if (type == "object") then (.[$k] // null) else null end);

def body_ok($fields): (.body | exact($fields));

def str_ok: type == "string"; def bool_ok: type == "boolean";

def leaf_ok($kind):
  if $kind == "string" then str_ok
  elif $kind == "bool" then bool_ok
  elif $kind == "number" then type == "number"
  elif $kind == "posint" then num_ok
  elif $kind == "hex64" then sha256_ok
  elif $kind == "hex40" then type == "string" and test("\\A[0-9a-f]{40}\\z")
  elif $kind == "id" then id_ok
  else false end;

def literal($v): {"$kind":"literal",value:$v};
def enum($vs): {"$kind":"enum",values:$vs}; def media($v): literal($v);
def exact_set($key;$ids): {"$kind":"exact_set",key:$key,ids:$ids};
def pattern($re): {"$kind":"pattern",re:$re};

def constraint_ok($c):
  if $c["$kind"] == "literal" then . == $c.value
  elif $c["$kind"] == "enum" then (. as $v | ($c.values | index($v))) != null
  elif $c["$kind"] == "pattern" then type == "string" and test($c.re)
  else false end;

def shape($s):
  if ($s | type) == "object" and ($s | has("$kind")) then constraint_ok($s)
  elif ($s | type) == "object" then
    type == "object" and (keys | sort) == ($s | keys | sort) and
    (. as $doc | $s | to_entries | all(.[]; .key as $k | .value as $sub | ($doc[$k] | shape($sub))))
  elif ($s | type) == "array" then
    ($s[0]) as $elem | ($s[1]) as $constraint |
    type == "array" and (. as $arr | $arr | all(.[];shape($elem))) and
    (if $constraint == null then true
     else ([.[] | .[$constraint.key]]) as $vals |
       (($vals | sort) == ($constraint.ids | sort)) and (($vals|length) == ($vals|unique|length))
     end)
  else leaf_ok($s) end;

def content_ref_schema($media): {content_id:"id",media_type:media($media),sha256:"hex64"};
def document_ref_schema($kind;$version):
  {schema_version:literal($version),kind:literal($kind),id:"id",sha256:"hex64"};

# Mirrors control/v1/sandbox.jq policy_ok's `==` checks; round summary has the mapping.
def legacy_policy_body_schema:
  {activation_state:literal("inactive"),
   environment:literal({mode:"clear-then-allowlist",variables:[
     {name:"LANG",value:"C"},{name:"LC_ALL",value:"C"},
     {name:"PATH",value:"/sandbox/tools"},{name:"TMPDIR",value:"/sandbox/scratch"}]}),
   evaluation_mode:literal("observation-only"),fail_mode:literal("closed"),
   filesystem:literal({read_roots:[
     {access:"read-only",path:"/sandbox/candidate",purpose:"candidate"},
     {access:"read-only",path:"/sandbox/tools",purpose:"toolchain"}],write_roots:[
     {access:"write-only",path:"/sandbox/evidence",purpose:"evidence"},
     {access:"read-write",path:"/sandbox/scratch",purpose:"scratch"}]}),
   isolation:literal({candidate_only:true,disposable:true,host_access:false}),
   limits:{cpu_time_ms:literal(30000),memory_bytes:literal(536870912),
     output_bytes:literal(10485760),process_count:literal(32),wall_time_ms:literal(60000)},
   network:literal({endpoints:[],mode:"deny"}),
   policy_version:literal("v1"),reference_semantics:literal("identity-only"),
   required_role:literal("verifier"),
   resources:literal([
     {access:"read-only",id:"resource.candidate",kind:"directory",path:"/sandbox/candidate"},
     {access:"write-only",id:"resource.evidence",kind:"directory",path:"/sandbox/evidence"},
     {access:"read-write",id:"resource.scratch",kind:"directory",path:"/sandbox/scratch"},
     {access:"read-only",id:"resource.toolchain",kind:"directory",path:"/sandbox/tools"}]),
   sensitive_material:literal({credential_refs:[],exposure:"none",secret_refs:[]}),
   tools:literal([{argv:["verify","--candidate","/sandbox/candidate","--evidence",
     "/sandbox/evidence"],executable:"/sandbox/tools/verifier",network:false,
     resource_ids:["resource.candidate","resource.evidence","resource.scratch"],
     sha256:("1"*64),tool_id:"tool.verifier"}])};

def bound_policy_body_schema:
  (legacy_policy_body_schema | .tools = literal([{
    argv:["verify","--candidate","/sandbox/candidate","--evidence","/sandbox/evidence"],
    executable:"/sandbox/tools/verifier",
    identity_binding:{accepted_set_id:"sandbox.accepted-identities.v1",
      environment_source:"claim.id",slot:"verifier"},network:false,
    resource_ids:["resource.candidate","resource.evidence","resource.scratch"],
    tool_id:"tool.verifier"}]));

def fixed_policy_shape_ok:
  ($policy[0]) as $p |
  ($p | exact(["body","id","kind","schema_version"])) and $p.kind == "sandbox_policy" and
  $p.schema_version == 1 and $p.id == "control-policy.sandbox" and
  ($p.body | shape(if $mode == "bound" then bound_policy_body_schema
    else legacy_policy_body_schema end));

# output_schema_version stays posint (not literal 1): a future bump should
# not need this file edited.
def decision_body_schema($contract):
  {activation_state:literal("inactive"),decision:literal("allow-observation-only-evaluation"),
   evaluator:{driver_ref:content_ref_schema("text/x-shellscript"),
     program_ref:content_ref_schema("text/x-jq"),
     policy_set_validator:{driver_ref:content_ref_schema("text/x-shellscript"),
       program_ref:content_ref_schema("text/x-jq")}},
   fail_mode:enum(["closed"]),
   policy_ref:content_ref_schema("application/vnd.ystack.control-policy+json"),
   semantics:{authority_effect:literal("none"),enforcement_proof:literal("declaration-only"),
     input_contract:literal($contract),
     output_kind:literal("sandbox_policy_evaluation"),output_schema_version:"posint",
     qualification_effect:literal("none"),reference_semantics:literal("identity-only"),
     verdicts:literal(["inconclusive","satisfied","violated"])}};

def fixed_decision_shape_ok:
  ($decision[0]) as $d |
  ($d | exact(["body","id","kind","schema_version"])) and $d.kind == "sandbox_decision" and
  $d.schema_version == 1 and $d.id == "control-decision.sandbox" and
  ($d.body | shape(decision_body_schema(if $mode == "bound" then
    "control-policy-set+duty-evaluation+execution-environment-claim+verifier-observation.v1"
    else "control-policy-set+duty-evaluation+execution-environment-claim.v1" end)));

# policy-set.jq shape_ok/relations_ok (round summary has the mapping);
# semantic_identity mirrors its own pattern (:54), not a literal.
def policy_set_body_schema:
  {activation_state:literal("inactive"),
   core_contract:{generation_id:pattern("\\Ag-[0-9a-f]{64}\\z"),
     package_ref:content_ref_schema("application/vnd.ystack.core-contract+json"),
     semantic_identity:pattern("\\Acore\\.contracts\\.v[1-9][0-9]*\\z")},
   fail_mode:literal("closed"),policy_version:literal("v1"),
   sections:[{section_id:"id",
       policy_ref:content_ref_schema("application/vnd.ystack.control-policy+json"),
       decision_ref:content_ref_schema("application/vnd.ystack.control-decision+json")},
     exact_set("section_id";["credential-policy","duty-separation","evidence-integrity",
       "kill-switch","risk-gates","sandbox"])]};

def fixed_policy_set_shape_ok:
  ($policy_set[0]) as $s |
  ($s | exact(["body","id","kind","schema_version"])) and $s.kind == "control_policy_set" and
  $s.schema_version == 1 and ($s.id | id_ok) and ($s.body | shape(policy_set_body_schema));

# registry has no constraint from sandbox.jq/validate.sh. proof_state stays
# bare `string`: R5.5 forbids reading it, and one environment qualifying
# must never abort an unrelated receipt check.
def registry_body_schema:
  {activation_state:"string",
   environments:[{description:"string",environment_id:"id",evidence_scope:"string",
     proof_state:"string",source_root_commit:"hex40",target_repository_id:"id"}],
   registry_version:"string"};

def fixed_registry_shape_ok:
  ($registry[0]) as $g |
  ($g | exact(["body","id","kind","schema_version"])) and
  $g.kind == "shadow_environment_registry" and $g.schema_version == 1 and ($g.id | id_ok) and
  ($g.body | shape(registry_body_schema));

def digest_list_ok:
  type == "array" and length >= 1 and length <= 8 and all(.[];sha256_ok) and
  all(.[]; . != all_ones_sha and . != all_zeros_sha) and . == (sort | unique);

def id_list_ok:
  type == "array" and length >= 1 and length <= 8 and all(.[];id_ok) and
  . == (sort | unique);

def accepted_entry_shape_ok:
  exact(["environment_id","identities","mechanisms","scratch_bytes"]) and
  (.environment_id | id_ok) and (.scratch_bytes | type == "number" and floor == . and . > 0) and
  (.identities | exact(identity_slots) and
    ([identity_slots[] as $slot | .[$slot]] | all(.[];digest_list_ok))) and
  (.mechanisms | exact(limit_rows) and
    ([limit_rows[] as $row | .[$row]] | all(.[];id_list_ok)));

def fixed_accepted_shape_ok:
  ($accepted[0]) as $a |
  ($a | exact(["body","id","kind","schema_version"])) and
  $a.kind == "sandbox_accepted_identity_set" and $a.schema_version == 1 and
  $a.id == "sandbox.accepted-identities.v1" and
  ($a | body_ok(["activation_state","environments","set_version"])) and
  $a.body.activation_state == "inactive" and $a.body.set_version == "v1" and
  ($a.body.environments | type == "array" and all(.[];accepted_entry_shape_ok));

def entry_digest_item_ok:
  exact(["environment_id","sha256"]) and (.environment_id | id_ok) and (.sha256 | sha256_ok);

def fixed_entry_digests_shape_ok:
  ($entry_digests[0] | type == "array" and all(.[];entry_digest_item_ok));

def entry_digests_match_registry:
  ($registry[0].body.environments | map(.environment_id)) as $reg_ids |
  ($entry_digests[0] | map(.environment_id)) as $ed_ids |
  $reg_ids == $ed_ids;

# Cross-document, complete references (content_id+media_type, not sha256
# alone): the decision, and the policy set's own "sandbox" section, must
# each reference the same policy/decision bytes under the same name.
def sandbox_section:
  $policy_set[0].body.sections | map(select(.section_id == "sandbox")) | .[0];

def expected_policy_ref:
  {content_id:$policy[0].id,media_type:"application/vnd.ystack.control-policy+json",
   sha256:$policy_sha};
def expected_decision_ref:
  {content_id:$decision[0].id,media_type:"application/vnd.ystack.control-decision+json",
   sha256:$decision_sha};

def cross_document_ok:
  ($decision[0].body.policy_ref == expected_policy_ref) and
  (sandbox_section != null) and (sandbox_section.policy_ref == expected_policy_ref) and
  (sandbox_section.decision_ref == expected_decision_ref);

# Defense by identity (spec.md:227): pinned by digest, not just schema.
def policy_pin:
  if $mode == "bound" then "ad1eab67be239e0f06f049bca91d51c475b3abb5917952a85c2a67f0450fbc6f"
  else "4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e" end;
def decision_pin:
  if $mode == "bound" then "c1ef076c8e9c9879ee39c46a0c0d6f6062c3e102fbbaeadbcc6453dc95b35ddc"
  else "c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd" end;
def policy_set_pin:
  if $mode == "bound" then "9b88e2807c736cddbe54b025af0c4aa267807f37c45f232d315f3af0b64e2edf"
  else "3fff018a4a7cbd9d8c69339ce1cd20c7f940b7af8080b12afe36e57961757eb8" end;

def pinned_files_ok:
  (if $policy_sha != policy_pin then error("fixed-file-identity:policy") else true end) and
  (if $decision_sha != decision_pin then error("fixed-file-identity:decision") else true end) and
  (if $policy_set_sha != policy_set_pin then error("fixed-file-identity:policy_set") else true end);

def fixed_files_ok:
  ($mode == "legacy" or $mode == "bound") and
  fixed_policy_shape_ok and fixed_decision_shape_ok and fixed_policy_set_shape_ok and
  fixed_registry_shape_ok and fixed_accepted_shape_ok and fixed_entry_digests_shape_ok and
  entry_digests_match_registry and cross_document_ok and pinned_files_ok;

# Lookups against the fixed registry/accepted set/entry digests (read only
# after fixed_files_ok, so shapes are already sound).
def registry_entries_for($env_id):
  $registry[0].body.environments | map(select(.environment_id == $env_id));
def entry_digests_for($env_id):
  $entry_digests[0] | map(select(.environment_id == $env_id));
def accepted_entries_for($env_id):
  $accepted[0].body.environments | map(select(.environment_id == $env_id));
def registry_entry_for($env_id):
  registry_entries_for($env_id) | .[0];

def entry_digest_for($env_id):
  entry_digests_for($env_id) | .[0].sha256;

def accepted_entry_for($env_id):
  accepted_entries_for($env_id) | .[0];

def row_observer($row):
  {cpu_time_ms:"guest-supervisor",wall_time_ms:"host-supervisor",memory_bytes:"guest-supervisor",
   output_bytes:"guest-supervisor",process_count:"guest-supervisor",
   scratch_bytes:"guest-supervisor"}[$row];

def is_origin_mismatch:
  $receipt[0].body.origin.store_id != $expectation[0].body.store_id;

def is_replayed:
  $receipt[0].body.attempt != $expectation[0].body.attempt;

def is_subject_mismatch:
  $receipt[0].body.subject != $expectation[0].body.subject;

def is_control_mismatch:
  ($receipt[0].body.control) as $c | ($expectation[0].body.control) as $ec |
  ($c != $ec) or ($c.policy_sha256 != $policy_sha) or ($c.decision_sha256 != $decision_sha) or
  ($c.policy_set_sha256 != $policy_set_sha) or
  ($c.evaluator_driver_sha256 != (if $mode == "bound" then $evaluator_driver_sha
    else $decision[0].body.evaluator.driver_ref.sha256 end)) or
  ($c.evaluator_program_sha256 != (if $mode == "bound" then $evaluator_program_sha
    else $decision[0].body.evaluator.program_ref.sha256 end)) or
  ($c.sandbox_evaluation_sha256 != $evaluation_sha) or
  (if $mode == "bound" then
    $decision[0].body.evaluator.driver_ref != {content_id:"control-evaluator-driver.sandbox-bound.v1",
      media_type:"text/x-shellscript",sha256:$evaluator_driver_sha} or
    $decision[0].body.evaluator.program_ref != {content_id:"control-evaluator-program.sandbox-bound.v1",
      media_type:"text/x-jq",sha256:$evaluator_program_sha}
   else false end);

def bound_evaluation_ok:
  ($evaluation[0]) as $v |
  ($v | exact(["body","id","kind","schema_version"])) and
  $v.schema_version == 1 and $v.kind == "sandbox_policy_evaluation" and
  ($v.body | shape({activation_state:literal("inactive"),authority_effect:literal("none"),
    claim_ref:document_ref_schema("execution_environment_claim";1),
    decision_ref:content_ref_schema("application/vnd.ystack.control-decision+json"),
    duty_evaluation_ref:document_ref_schema("duty_separation_evaluation";1),
    enforcement_proof:literal("declaration-only"),evaluation_mode:literal("observation-only"),
    policy_ref:content_ref_schema("application/vnd.ystack.control-policy+json"),
    policy_set:{id:"id",sha256:"hex64"},qualification_effect:literal("none"),
    reason_ids:literal(["sandbox.verifier-binding-satisfied"]),verdict:literal("satisfied"),
    verifier_binding:{accepted_set_sha256:"hex64",environment_entry_sha256:"hex64",
      environment_id:"id",observation_sha256:"hex64",target_repository_id:"id",
      verifier_sha256:"hex64"}})) and
  $v.body.policy_ref == expected_policy_ref and
  $v.body.decision_ref == expected_decision_ref and
  $v.body.policy_set == {id:$policy_set[0].id,sha256:$policy_set_sha} and
  $v.id == $observation[0].body.environment_id and
  $v.body.claim_ref.id == $observation[0].body.environment_id;

def bound_binding_mismatch:
  ($receipt[0].body.subject) as $subject |
  ($observation[0]) as $observed |
  ($evaluation[0].body.verifier_binding) as $binding |
  ($observed.body.verifier_sha256) as $d |
  ($observed | exact(["body","id","kind","schema_version"]) | not) or
  $observed.schema_version != 1 or $observed.kind != "sandbox_verifier_observation" or
  $observed.id != "sandbox.observation.verifier" or
  ($observed.body | exact(["accepted_set_sha256","environment_entry_sha256",
    "environment_id","target_repository_id","verifier_sha256"]) | not) or
  (registry_entries_for($subject.environment_id) | length) != 1 or
  (accepted_entries_for($subject.environment_id) | length) != 1 or
  (entry_digests_for($subject.environment_id) | length) != 1 or
  $binding != ($observed.body + {observation_sha256:$observation_sha}) or
  $observed.body.environment_id != $subject.environment_id or
  $observed.body.environment_entry_sha256 != $subject.environment_entry_sha256 or
  $observed.body.target_repository_id != $subject.target_repository_id or
  $observed.body.accepted_set_sha256 != $accepted_set_sha or
  $receipt[0].body.identities.verifier != {state:"observed",sha256:$d} or
  ((accepted_entry_for($subject.environment_id).identities.verifier // []) | index($d)) == null;

# The evaluation is a caller input, not a fixed file: a bad shape here refuses
# rather than errors.
def is_evaluation_not_satisfied:
  ($receipt[0].body.control) as $c |
  ((get($evaluation[0];["kind"]) == "sandbox_policy_evaluation") and
   (get($evaluation[0];["schema_version"]) == 1) and
   (get($evaluation[0];["body","verdict"]) == "satisfied") and
   (get($evaluation[0];["body","policy_set","sha256"]) == $c.policy_set_sha256) and
   (get($evaluation[0];["body","policy_ref","sha256"]) == $c.policy_sha256) and
   (get($evaluation[0];["body","decision_ref","sha256"]) == $c.decision_sha256) and
   (if $mode == "bound" then
      bound_evaluation_ok and (bound_binding_mismatch | not)
    else true end)) | not;

def is_environment_unlisted:
  ($receipt[0].body.subject) as $s |
  (if $mode == "bound" then
    (registry_entries_for($s.environment_id) | length) != 1 or
    (accepted_entries_for($s.environment_id) | length) != 1 or
    (entry_digests_for($s.environment_id) | length) != 1
   else false end) or
  (registry_entry_for($s.environment_id) == null) or
  (accepted_entry_for($s.environment_id) == null) or
  ($s.environment_entry_sha256 != entry_digest_for($s.environment_id)) or
  ($s.target_repository_id != (registry_entry_for($s.environment_id).target_repository_id // null));

def is_stale:
  $receipt[0].body.origin.accepted_set_sha256 != $accepted_set_sha;

def is_identity_unaccepted:
  ($receipt[0].body) as $b |
  (accepted_entry_for($b.subject.environment_id)) as $ae |
  ($ae == null) or
  ([identity_slots[] as $slot | ($b.identities[$slot]) as $i |
     select($i.state == "observed" and $i.sha256 != all_ones_sha and $i.sha256 != all_zeros_sha) |
     select(($ae.identities[$slot] | index($i.sha256)) == null)] | length > 0) or
  ([limit_rows[] as $row | ($b.limits[$row].mechanism_id) as $m |
     select(($ae.mechanisms[$row] | index($m)) == null)] | length > 0);

def is_limit_mismatch:
  ($receipt[0].body) as $b |
  (accepted_entry_for($b.subject.environment_id)) as $ae |
  ([limit_rows[] as $row | ($b.limits[$row]) as $row_val |
     (if $row == "scratch_bytes" then
        ($ae.scratch_bytes) as $bound |
        (if $bound == null then false else $row_val.bound != $bound end)
      else $row_val.bound != $policy[0].body.limits[$row] end) or
     ($row_val.observer != row_observer($row))
   ] | any);

($receipt[0]) as $r |
($expectation[0]) as $e |
(if fixed_files_ok then true else error("fixed-file-relation") end) as $fixed_ok |
(if ($r | is_declaration_only) then ["receipt.declaration-only"]
 elif ($r | is_kind_unsupported) then ["receipt.kind-unsupported"]
 elif (($r | receipt_shape_ok) and ($e | expectation_shape_ok) | not)
   then ["receipt.malformed"]
 else
   (((if ($r | has_placeholder_identity) or ($e | has_placeholder_identity)
      then ["receipt.placeholder-identity"] else [] end) +
     (if is_origin_mismatch then ["receipt.origin-mismatch"] else [] end) +
     (if is_replayed then ["receipt.replayed"] else [] end) +
     (if is_subject_mismatch then ["receipt.subject-mismatch"] else [] end) +
     (if is_control_mismatch or ($mode == "bound" and bound_binding_mismatch)
      then ["receipt.control-mismatch"] else [] end) +
     (if is_evaluation_not_satisfied then ["receipt.evaluation-not-satisfied"] else [] end) +
     (if is_environment_unlisted then ["receipt.environment-unlisted"] else [] end) +
     (if is_stale then ["receipt.stale"] else [] end) +
     (if is_identity_unaccepted then ["receipt.identity-unaccepted"] else [] end) +
     (if is_limit_mismatch then ["receipt.limit-mismatch"] else [] end) +
     (if ($r.body | is_outcome_inconsistent) then ["receipt.outcome-inconsistent"]
      else [] end)) | sort | unique)
 end) as $reasons |
(if ($reasons | length) == 0 then ($r.body | derive_outcome) else null end) as $derived |
{
  schema_version:1,
  kind:"sandbox_receipt_check",
  id:("receipt-check." + $receipt_sha),
  body:{
    activation_state:"inactive",
    authority_effect:"none",
    qualification_effect:"none",
    origin_check:"not-performed",
    check_verdict:(if ($reasons | length) == 0 then "valid" else "refused" end),
    enforcement_verdict:(if ($reasons | length) == 0 then $derived.verdict else "none" end),
    reason_ids:(if ($reasons | length) == 0 then ["receipt.valid"] else $reasons end),
    receipt_sha256:$receipt_sha,
    expectation_sha256:$expectation_sha,
    evaluation_sha256:$evaluation_sha,
    accepted_set_sha256:$accepted_set_sha
  }
}
