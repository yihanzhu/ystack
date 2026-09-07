def exact($required):
  type == "object" and (keys | sort) == ($required | sort);

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");

def member_of($allowed):
  type == "string" and (. as $value | $allowed | index($value) != null);

def bounded_set($min; $max; check):
  type == "array" and length >= $min and length <= $max and
  all(.[]; check) and . == (sort | unique);

# A repo-relative glob. No absolute path, no traversal, no backslash, no `**`,
# and no wildcard in the first segment: a wildcard there could expand into any
# top-level directory, so the protected-path check could not bound it.
def glob_ok:
  type == "string" and utf8bytelength >= 1 and utf8bytelength <= 512 and
  test("\\A[A-Za-z0-9._/*?-]+\\z") and (contains("**") | not) and
  (startswith("/") | not) and
  (split("/") |
   length >= 1 and length <= 32 and
   all(.[];
       . != "" and . != "." and . != ".." and (ascii_downcase != ".git") and
       (endswith(".") | not)) and
   (.[0] | test("[*?]") | not));

def proof_kinds:
  ["architecture", "behavioral", "deterministic", "independent-review"];

def eval_family_ids:
  ["actor-rerun-identity", "adapter-contract-compliance",
   "approval-invalidation-no-push-after-approval",
   "empty-fake-timed-out-degraded-reviews", "malicious-instructions",
   "protected-path-credential-network-publisher-boundaries",
   "repeated-cancelled-missed-events",
   "reviewer-severity-false-positive-negative", "stale-moved-artifacts"];

def risk_tiers: ["bootstrap", "high", "routine"];

# A scope names its own shadow evidence: each ref is a document ref to one
# shadow reproduction record, by id and by the digest of that record's canonical
# bytes. The evaluator counts a supplied record only when a ref names it, so
# evidence produced for some other scope can never qualify this one.
def shadow_evidence_ref_ok:
  exact(["id", "kind", "schema_version", "sha256"]) and
  .schema_version == 1 and .kind == "shadow_reproduction_record" and
  (.id | id_ok) and (.sha256 | sha256_ok);

def oid_ok($algorithm):
  type == "string" and
  (if $algorithm == "sha256" then test("\\A[0-9a-f]{64}\\z")
   else test("\\A[0-9a-f]{40}\\z") end);

def media_type_ok:
  type == "string" and length <= 127 and
  test("\\A[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*\\z");

# The core v2 content ref: one named piece of content, bound by digest.
def content_ref_ok:
  exact(["content_id", "media_type", "sha256"]) and
  (.content_id | id_ok and (contains(":") | not) and (contains("/") | not)) and
  (.media_type | media_type_ok) and (.sha256 | sha256_ok);

def repo_path_ok:
  type == "string" and utf8bytelength >= 1 and utf8bytelength <= 4096 and
  (test("[[:cntrl:]]") | not) and (contains("\\") | not) and
  (startswith("/") | not) and
  (split("/") |
   length <= 64 and
   all(.[];
       . != "" and . != "." and . != ".." and (ascii_downcase != ".git") and
       (endswith(".") | not) and (endswith(" ") | not)));

def git_revision_ref_ok:
  . as $revision |
  exact(["commit_id", "hash_algorithm", "repository_id"]) and
  ($revision.repository_id | id_ok) and
  ($revision.hash_algorithm == "sha1" or $revision.hash_algorithm == "sha256") and
  ($revision.commit_id | oid_ok($revision.hash_algorithm));

def git_location_ok:
  (exact(["kind"]) and .kind == "root") or
  (exact(["kind", "value"]) and .kind == "path" and (.value | repo_path_ok));

# The core v2 git object ref, the shape the default profile uses for a prompt or
# a skill: one object inside one exact revision of one repository.
def git_object_ref_ok:
  . as $ref |
  exact(["location", "mode", "object_id", "object_type", "revision"]) and
  ($ref.revision | git_revision_ref_ok) and
  ($ref.location | git_location_ok) and
  ($ref.object_type == "blob" or $ref.object_type == "tree") and
  ($ref.object_id | oid_ok($ref.revision.hash_algorithm)) and
  (if $ref.location.kind == "root" then $ref.object_type == "tree" else true end) and
  (if $ref.object_type == "tree" then $ref.mode == "040000"
   else ($ref.mode == "100644" or $ref.mode == "100755") end);

# A profile names a prompt or a skill either as a git object or as content, so a
# scope records whichever of those two shapes its profile used.
def versioned_artifact_ref_ok: git_object_ref_ok or content_ref_ok;

def document_ref_ok($schema_version; $kind):
  exact(["id", "kind", "schema_version", "sha256"]) and
  .schema_version == $schema_version and .kind == $kind and
  (.id | id_ok) and (.sha256 | sha256_ok);

def model_request_ok:
  exact(["effort_id", "model_id", "provider_id"]) and
  (.effort_id | id_ok) and (.model_id | id_ok) and (.provider_id | id_ok);

# Qualification is authority attached to one exact recorded workflow scope, so
# the record has to carry the identities that authority is attached to: the
# resolved profile, the adapter configs it runs with, the model and effort, the
# prompt and skill versions, the verification instructions, and the target
# revision. Change any of them and this is a different scope, which has to earn
# its own evidence rather than inherit this one's.
def qualified_identity_ok($repository_id):
  exact(["adapter_config_refs", "model_request", "prompt_refs",
    "resolved_profile_ref", "skill_refs", "target_revision",
    "verification_instructions_ref"]) and
  (.resolved_profile_ref | document_ref_ok(2; "resolved_profile")) and
  (.adapter_config_refs | bounded_set(1; 8; content_ref_ok)) and
  (.model_request | model_request_ok) and
  (.prompt_refs | bounded_set(1; 8; versioned_artifact_ref_ok)) and
  (.skill_refs | bounded_set(0; 8; versioned_artifact_ref_ok)) and
  (.verification_instructions_ref | content_ref_ok) and
  (.target_revision |
   git_revision_ref_ok and .repository_id == $repository_id);

# A scope names the gate evaluations it was qualified against the same way it
# names its shadow evidence: by kind, id, and the digest of that evaluation's
# canonical bytes. The evaluator measures each supplied document and refuses one
# that is not the document this scope named.
def gate_evidence_refs_ok:
  exact(["duty_separation_evaluation_ref", "kill_switch_evaluation_ref",
    "risk_gate_evaluation_ref"]) and
  (.risk_gate_evaluation_ref | document_ref_ok(1; "risk_gate_evaluation")) and
  (.kill_switch_evaluation_ref | document_ref_ok(1; "kill_switch_evaluation")) and
  (.duty_separation_evaluation_ref |
   document_ref_ok(1; "duty_separation_evaluation"));

def shape_ok:
  exact(["body", "id", "kind", "schema_version"]) and
  .schema_version == 1 and .kind == "workflow_scope" and (.id | id_ok) and
  (.body |
   . as $body |
   exact(["activation_state", "allowed_paths", "authority", "enabled",
     "gate_evidence_refs", "max_attempts", "push_allowed",
     "qualified_identity", "required_eval_families",
     "required_proof_kinds", "required_shadow_environments", "risk_tier",
     "scope_version", "shadow_evidence_refs", "target_repository_id",
     "task_class", "workflow_id"]) and
   (.activation_state | type == "string") and
   (.authority | type == "string") and
   (.scope_version | type == "string") and
   (.enabled | type == "boolean") and
   (.push_allowed | type == "boolean") and
   (.target_repository_id | id_ok) and
   (.workflow_id | id_ok) and
   (.task_class | id_ok) and
   (.risk_tier | member_of(risk_tiers)) and
   (.allowed_paths | bounded_set(1; 32; glob_ok)) and
   (.required_proof_kinds | bounded_set(1; 4; member_of(proof_kinds))) and
   (.required_eval_families | bounded_set(1; 9; member_of(eval_family_ids))) and
   (.required_shadow_environments | bounded_set(1; 8; id_ok)) and
   (.shadow_evidence_refs | bounded_set(1; 16; shadow_evidence_ref_ok)) and
   (.qualified_identity |
    qualified_identity_ok($body.target_repository_id)) and
   (.gate_evidence_refs | gate_evidence_refs_ok) and
   (.max_attempts |
    type == "number" and . == floor and . >= 1 and . <= 8));

def relations_ok:
  .body as $body |
  $body.activation_state == "inactive" and
  $body.authority == "none" and
  $body.enabled == false and
  $body.push_allowed == false and
  $body.scope_version == "v1" and
  ($body.workflow_id | startswith("workflow.")) and
  ($body.task_class | startswith("task."));

if (shape_ok | not) then "E_SHAPE"
elif (relations_ok | not) then "E_RELATION"
else empty
end
