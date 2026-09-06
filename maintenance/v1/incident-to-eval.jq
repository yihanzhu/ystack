include "bands";

def incident_media: "application/vnd.ystack.shadow-incident-record+json";
def shadow_media: "application/vnd.ystack.shadow-reproduction-record+json";
def catalog_media: "application/vnd.ystack.eval-catalog+json";
def seed_set_media: "application/vnd.ystack.eval-seed-set+json";

def failing_check_ok:
  (exact(["expected_sha256","kind","path"]) and .kind == "file-digest" and
   (.path | repo_path_ok) and (.expected_sha256 | sha256_ok)) or
  (exact(["check_id","kind"]) and .kind == "named-check" and (.check_id | id_ok));

def incident_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  # The incident id must leave room for the "incident." prefix the generated
  # case id carries, so every skeleton is a valid seed case id as emitted.
  .kind == "shadow_incident_record" and (.id | id_ok and (("incident." + .) | id_ok)) and
  (.body |
   exact(["deploy_authority","failing_check","git_revision_ref","observed_at",
     "observed_symptom","reporter_actor_ref","target_repository_id"]) and
   .deploy_authority == "none" and (.target_repository_id | id_ok) and
   (.git_revision_ref | type == "object") and (.failing_check | failing_check_ok) and
   (.observed_symptom | text_ok) and (.reporter_actor_ref | id_ok) and
   (.observed_at | time_ok));

def shadow_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "shadow_reproduction_record" and (.id | id_ok) and
  (.body | type == "object" and .activation_state == "inactive" and
   .authority == "none" and .deploy_authority == "none" and .shadow == true and
   .evaluation_mode == "observation-only" and
   (.outcome as $o | ["inconclusive","no-change","reproduced"] | index($o) != null) and
   (.reason_id | id_ok) and (.observed_at | time_ok) and
   (.target_repository_id | id_ok) and (.git_revision_ref | type == "object") and
   (.incident_ref | content_ref_ok(incident_media)) and
   (.check | exact(["execution","failing_check"]) and
    (.failing_check | failing_check_ok) and (.execution | type == "object")));

def catalog_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "eval_catalog" and (.id | id_ok) and
  (.body | type == "object" and
   (.families | type == "array" and length >= 1 and length <= 32 and
    all(.[]; type == "object" and (.family_id | id_ok) and
      (.seed_status == "seeded" or .seed_status == "declared") and
      (.seed_sources | type == "array" and all(.[]; id_ok)))));

def seed_set_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "eval_seed_set" and (.id | id_ok) and
  (.body | type == "object" and (.seed_source | id_ok) and
   (.cases | type == "array" and length >= 1 and length <= 128 and
    all(.[]; type == "object" and (.case_id | id_ok) and (.family_id | id_ok) and
      (.expectation | type == "object"))));

# The failing check an incident names decides which eval family the case joins.
# The map is closed: an unmapped check is refused, never guessed at.
def family_for_check($check):
  if $check.kind == "file-digest" then "stale-moved-artifacts" else null end;

# A reproduced failure becomes a stale-artifact expectation; a run that found
# nothing becomes the passing baseline. An inconclusive run proves nothing.
def expectation_for_outcome($outcome):
  if $outcome == "reproduced" then {disposition:"accepted",status:"stale"}
  elif $outcome == "no-change" then {disposition:"accepted",status:"completed"}
  else null end;

def skeleton($incident; $shadow; $catalog; $seed_set; $family; $expectation;
             $request_role; $required_fields; $digests):
  ($required_fields - ["case_id","expectation","family_id","request_role"]) as $pending |
  {schema_version:1,
   kind:"maintenance_eval_seed_skeleton",
   id:("maintenance-eval-seed." + $family),
   body:{
     activation_state:"inactive",
     authority:"none",
     deploy_authority:"none",
     evaluation_mode:"observation-only",
     seed_set_effect:"none",
     qualification:{state:"unavailable",reason_id:"maintenance.no-adapter-exists"},
     family_id:$family,
     seed_source:$seed_set.body.seed_source,
     catalog_ref:content_ref("evals-eval-catalog"; catalog_media; $digests.catalog),
     seed_set_ref:content_ref("evals-seed-set"; seed_set_media; $digests.seed_set),
     case_shape:{required_fields:$required_fields,
       filled_fields:(["case_id","expectation","family_id","request_role"] |
         map(select(. as $field | $required_fields | index($field) != null)) | sort),
       pending_fields:($pending | sort)},
     case:{case_id:("incident." + $incident.id),
       family_id:$family,
       expectation:$expectation,
       request_role:$request_role},
     provenance:{
       incident_ref:content_ref("shadow-incident-record"; incident_media;
         $digests.incident),
       shadow_record_ref:content_ref("shadow-reproduction-record"; shadow_media;
         $digests.shadow),
       shadow_outcome:$shadow.body.outcome,
       shadow_reason_id:$shadow.body.reason_id,
       failing_check:$incident.body.failing_check,
       git_revision_ref:$incident.body.git_revision_ref,
       target_repository_id:$incident.body.target_repository_id,
       observed_at:$shadow.body.observed_at}}};

. as $input |
if ($input |
    exact(["catalog","digests","incident","seed_set","shadow"]) and
    (.incident | incident_ok) and (.shadow | shadow_ok) and
    (.catalog | catalog_ok) and (.seed_set | seed_set_ok) and
    (.digests | exact(["catalog","incident","seed_set","shadow"]) and
     all(.[]; sha256_ok)) | not)
then "E_SHAPE"
elif $input.shadow.body.incident_ref.sha256 != $input.digests.incident or
     $input.shadow.id != $input.incident.id or
     $input.shadow.body.check.failing_check != $input.incident.body.failing_check or
     $input.shadow.body.git_revision_ref != $input.incident.body.git_revision_ref or
     $input.shadow.body.target_repository_id != $input.incident.body.target_repository_id
then "E_RELATION"
elif (family_for_check($input.incident.body.failing_check)) == null then "E_FAMILY"
else
  family_for_check($input.incident.body.failing_check) as $family |
  ([$input.catalog.body.families[] | select(.family_id == $family)]) as $declared |
  ([$input.seed_set.body.cases[] | select(.family_id == $family)]) as $family_cases |
  (expectation_for_outcome($input.shadow.body.outcome)) as $expectation |
  ($family_cases | map(keys) | unique) as $shapes |
  ($family_cases | map(.request_role) | unique) as $roles |
  if ($declared | length) != 1 or $declared[0].seed_status != "seeded" or
     (($declared[0].seed_sources | index($input.seed_set.body.seed_source)) == null)
  then "E_FAMILY"
  elif ($family_cases | length) < 1 or ($shapes | length) != 1 or
       ($roles | length) != 1 or ($roles[0] | type) != "string"
  then "E_RELATION"
  elif $expectation == null then "E_RELATION"
  elif ($family_cases | map(.expectation) | index($expectation)) == null
  then "E_RELATION"
  elif $operation == "shape" then empty
  elif $operation != "convert" then "E_RUNTIME"
  else skeleton($input.incident; $input.shadow; $input.catalog; $input.seed_set;
    $family; $expectation; $roles[0]; $shapes[0]; $input.digests)
  end
end
