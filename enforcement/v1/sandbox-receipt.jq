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

# PR 2: shape checks of the five fixed documents and entry_digests. A mismatch
# here is a repository/caller integrity failure, not a refusal, so it is a jq
# `error` (the driver maps it to E_RELATION), never a `reason_id`.
def num_ok: type == "number" and floor == . and . >= 0;

def get($doc; $path):
  reduce $path[] as $k ($doc; if (type == "object") then (.[$k] // null) else null end);

# Every fixed document's own body must have exactly its required top-level
# keys before any field of it is read: a document whose body is `null`, the
# wrong type, or missing a required key is never merely "unread", it fails
# the shape check outright (a body a program never inspects is still a
# document a corrupted repository could hand it, so its presence must be
# enumerated, not inferred from what happens to be used).
def body_ok($fields): (.body | exact($fields));

# Shared nested shapes: a `{content_id,media_type,sha256}` content reference
# and one policy `tool` entry, so a null/wrong-typed nested value fails here.
def content_ref_ok:
  exact(["content_id","media_type","sha256"]) and (.content_id | id_ok) and
  (.media_type | type == "string") and (.sha256 | sha256_ok);

def tool_shape_ok:
  type == "object" and (.tool_id | id_ok) and (.sha256 | sha256_ok) and
  (.executable | type == "string") and (.argv | type == "array") and
  (.network | type == "boolean") and (.resource_ids | type == "array");

def fixed_policy_shape_ok:
  ($policy[0]) as $p |
  ($p | exact(["body","id","kind","schema_version"])) and $p.kind == "sandbox_policy" and
  $p.schema_version == 1 and ($p.id | id_ok) and
  ($p | body_ok(["activation_state","environment","evaluation_mode","fail_mode",
    "filesystem","isolation","limits","network","policy_version","reference_semantics",
    "required_role","resources","sensitive_material","tools"])) and
  ($p.body.limits | type == "object") and
  ($p.body.limits.cpu_time_ms | num_ok) and ($p.body.limits.wall_time_ms | num_ok) and
  ($p.body.limits.memory_bytes | num_ok) and ($p.body.limits.output_bytes | num_ok) and
  ($p.body.limits.process_count | num_ok) and
  ($p.body.tools | type == "array" and all(.[];tool_shape_ok));

def fixed_decision_shape_ok:
  ($decision[0]) as $d |
  ($d | exact(["body","id","kind","schema_version"])) and $d.kind == "sandbox_decision" and
  $d.schema_version == 1 and ($d.id | id_ok) and
  ($d | body_ok(["activation_state","decision","evaluator","fail_mode","policy_ref",
    "semantics"])) and
  ($d.body.policy_ref | content_ref_ok) and
  ($d.body.evaluator.driver_ref.sha256 | sha256_ok) and
  ($d.body.evaluator.program_ref.sha256 | sha256_ok);

def section_shape_ok:
  exact(["section_id","policy_ref","decision_ref"]) and (.section_id | id_ok) and
  (.policy_ref | content_ref_ok) and (.decision_ref | content_ref_ok);

def fixed_policy_set_shape_ok:
  ($policy_set[0]) as $s |
  ($s | exact(["body","id","kind","schema_version"])) and $s.kind == "control_policy_set" and
  $s.schema_version == 1 and ($s.id | id_ok) and
  ($s | body_ok(["activation_state","core_contract","fail_mode","policy_version",
    "sections"])) and
  ($s.body.sections | type == "array" and all(.[];section_shape_ok));

def registry_entry_shape_ok:
  type == "object" and (.environment_id | id_ok) and (.target_repository_id | id_ok);

def fixed_registry_shape_ok:
  ($registry[0]) as $g |
  ($g | exact(["body","id","kind","schema_version"])) and
  $g.kind == "shadow_environment_registry" and $g.schema_version == 1 and
  ($g | body_ok(["activation_state","environments","registry_version"])) and
  ($g.body.environments | type == "array" and all(.[];registry_entry_shape_ok));

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

def fixed_files_ok:
  fixed_policy_shape_ok and fixed_decision_shape_ok and fixed_policy_set_shape_ok and
  fixed_registry_shape_ok and fixed_accepted_shape_ok and fixed_entry_digests_shape_ok and
  entry_digests_match_registry;

# PR 2: lookups against the fixed registry, accepted set and entry digests
# (all read only after `fixed_files_ok`, so their shapes are already sound).
def registry_entry_for($env_id):
  $registry[0].body.environments | map(select(.environment_id == $env_id)) | .[0];

def entry_digest_for($env_id):
  $entry_digests[0] | map(select(.environment_id == $env_id)) | .[0].sha256;

def accepted_entry_for($env_id):
  $accepted[0].body.environments | map(select(.environment_id == $env_id)) | .[0];

def row_observer($row):
  {cpu_time_ms:"guest-supervisor",wall_time_ms:"host-supervisor",memory_bytes:"guest-supervisor",
   output_bytes:"guest-supervisor",process_count:"guest-supervisor",
   scratch_bytes:"guest-supervisor"}[$row];

# PR 2: the nine remaining R7.4 reasons.
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
  ($c.evaluator_driver_sha256 != $decision[0].body.evaluator.driver_ref.sha256) or
  ($c.evaluator_program_sha256 != $decision[0].body.evaluator.program_ref.sha256) or
  ($c.sandbox_evaluation_sha256 != $evaluation_sha);

# The evaluation is a caller input, not a fixed file: a bad shape here refuses
# rather than errors.
def is_evaluation_not_satisfied:
  ($receipt[0].body.control) as $c |
  ((get($evaluation[0];["kind"]) == "sandbox_policy_evaluation") and
   (get($evaluation[0];["schema_version"]) == 1) and
   (get($evaluation[0];["body","verdict"]) == "satisfied") and
   (get($evaluation[0];["body","policy_set","sha256"]) == $c.policy_set_sha256) and
   (get($evaluation[0];["body","policy_ref","sha256"]) == $c.policy_sha256) and
   (get($evaluation[0];["body","decision_ref","sha256"]) == $c.decision_sha256)) | not;

def is_environment_unlisted:
  ($receipt[0].body.subject) as $s |
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

# The program interface fixed in PR 1, extended in PR 2 to read the five
# fixed documents and `entry_digests`.
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
     (if is_control_mismatch then ["receipt.control-mismatch"] else [] end) +
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
