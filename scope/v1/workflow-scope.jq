def exact($required):
  type == "object" and (keys | sort) == ($required | sort);

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

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

def shape_ok:
  exact(["body", "id", "kind", "schema_version"]) and
  .schema_version == 1 and .kind == "workflow_scope" and (.id | id_ok) and
  (.body |
   exact(["activation_state", "allowed_paths", "authority", "enabled",
     "max_attempts", "push_allowed", "required_eval_families",
     "required_proof_kinds", "required_shadow_environments", "risk_tier",
     "scope_version", "target_repository_id", "task_class", "workflow_id"]) and
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
