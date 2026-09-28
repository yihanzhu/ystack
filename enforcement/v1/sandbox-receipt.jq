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

# The program interface fixed in PR 1: the five fixed documents and
# `entry_digests` are accepted here but not yet read (PR 2 binds them).
($receipt[0]) as $r |
($expectation[0]) as $e |
($policy[0]) as $fixed_policy |
($decision[0]) as $fixed_decision |
($policy_set[0]) as $fixed_policy_set |
($registry[0]) as $fixed_registry |
($accepted[0]) as $fixed_accepted |
($entry_digests[0]) as $fixed_entry_digests |
(if ($r | is_declaration_only) then ["receipt.declaration-only"]
 elif ($r | is_kind_unsupported) then ["receipt.kind-unsupported"]
 elif (($r | receipt_shape_ok) and ($e | expectation_shape_ok) | not)
   then ["receipt.malformed"]
 else
   (((if ($r | has_placeholder_identity) or ($e | has_placeholder_identity)
      then ["receipt.placeholder-identity"] else [] end) +
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
