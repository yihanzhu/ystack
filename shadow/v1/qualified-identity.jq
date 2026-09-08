# The qualified identity a shadow run was performed under: the resolved profile,
# the adapter configs, the model request, the prompt and skill versions, the
# stage request, the verification instructions, and the exact target revision.
# A shadow record that carries this can be bound to one workflow scope's own
# recorded identity; a record without it says only which repository and revision
# it ran against, which any other scope on the same target could also claim.
#
# Copied verbatim from scope/v1/workflow-scope.jq at
# 72dce421a8bf0896d5b19b60572caed856533b47 (origin/main) — keep in sync. The
# shape rules below are that file's `qualified_identity_ok` and every helper it
# uses, byte for byte, so the identity this slice records is the identity that
# component validates. Nothing is relaxed here: the copy is a copy so a shadow
# record can never carry an identity the scope side would refuse.
def exact($required):
  type == "object" and (keys | sort) == ($required | sort);

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");

def bounded_set($min; $max; check):
  type == "array" and length >= $min and length <= $max and
  all(.[]; check) and . == (sort | unique);

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

def qualified_identity_ok($repository_id):
  exact(["adapter_config_refs", "model_request", "prompt_refs",
    "resolved_profile_ref", "skill_refs", "stage_request_ref", "target_revision",
    "verification_instructions_ref"]) and
  (.resolved_profile_ref | document_ref_ok(2; "resolved_profile")) and
  (.stage_request_ref | document_ref_ok(2; "stage_request")) and
  (.adapter_config_refs | bounded_set(1; 8; content_ref_ok)) and
  (.model_request | model_request_ok) and
  (.prompt_refs | bounded_set(1; 8; versioned_artifact_ref_ok)) and
  (.skill_refs | bounded_set(0; 8; versioned_artifact_ref_ok)) and
  (.verification_instructions_ref | content_ref_ok) and
  (.target_revision |
   git_revision_ref_ok and .repository_id == $repository_id);
# End of the copied workflow-scope shape.

def document_ok:
  exact(["body", "id", "kind", "schema_version"]) and
  .schema_version == 1 and .kind == "qualified_identity" and (.id | id_ok) and
  (.body | qualified_identity_ok($repository_id));

# The identity has to be the identity of this incident's own target version. An
# identity naming another revision describes a run this record is not about, so
# it is a relation failure rather than a shape one.
def relations_ok:
  .body.target_revision ==
    {repository_id: $repository_id, hash_algorithm: $hash_algorithm,
     commit_id: $commit_id};

if (document_ok | not) then "E_SHAPE"
elif (relations_ok | not) then "E_RELATION"
else empty
end
