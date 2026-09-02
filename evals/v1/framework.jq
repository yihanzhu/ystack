import "schema" as schema;

def record_media_type: "application/vnd.ystack.eval-record+json";
def bundle_media_type: "application/vnd.ystack.eval-bundle+json";

def present_ref_ok:
  (schema::exact_fields(["state"];[]) and .state == "absent") or
  (schema::exact_fields(["state","value"];[]) and .state == "present" and
   (.value | schema::content_ref_ok));

def present_reason_ok:
  (schema::exact_fields(["state"];[]) and .state == "absent") or
  (schema::exact_fields(["state","value"];[]) and .state == "present" and
   (.value | schema::id_ok));

def envelope_ok($kind):
  schema::exact_fields(["schema_version","kind","id","body"];[]) and
  .schema_version == 1 and .kind == $kind and
  (.id | schema::id_ok) and (.body | type == "object");

def grader_ok:
  schema::exact_fields(
    ["grader_id","grader_kind","implementation_ref","instructions_ref"];[]) and
  (.grader_id | schema::id_ok) and
  (.grader_kind == "deterministic" or .grader_kind == "model" or
   .grader_kind == "human") and
  (.implementation_ref | schema::content_ref_ok) and
  (.instructions_ref | schema::content_ref_ok);

def scope_ok:
  schema::exact_fields(
    ["scope_id","scope_version","definition_ref","scope_sha256"];[]) and
  (.scope_id | schema::id_ok) and (.scope_version | schema::version_ok) and
  (.definition_ref | schema::content_ref_ok) and
  (.scope_sha256 | schema::sha256_ok) and
  .scope_sha256 == .definition_ref.sha256;

def suite_ok:
  envelope_ok("eval_suite") and
  (.body |
   schema::exact_fields(
     ["suite_version","framework_ref","scope","case_ids"];[]) and
   .suite_version == "v1" and
   (.framework_ref | schema::content_ref_ok) and
   (.scope | scope_ok) and
   (.case_ids | schema::bounded_set(1;32;schema::id_ok;.)));

def case_ok:
  envelope_ok("eval_case") and
  (.body |
   schema::exact_fields(
     ["case_version","suite_ref","execution_kind","input_ref","expected_ref",
      "trial_count","trial_ids","graders"];[]) and
   .case_version == "v1" and
   (.suite_ref | schema::content_ref_ok) and
   (.execution_kind == "deterministic" or .execution_kind == "model") and
   (.input_ref | schema::content_ref_ok) and
   (.expected_ref | schema::content_ref_ok) and
   (.trial_count | schema::int_ok) and .trial_count >= 1 and .trial_count <= 16 and
   (if .execution_kind == "model" then .trial_count >= 2 else true end) and
   (.trial_ids | schema::bounded_set(1;16;schema::id_ok;.)) and
   .trial_count == (.trial_ids | length) and
   (.graders | schema::bounded_set(1;8;grader_ok;.grader_id)));

def trial_ok:
  envelope_ok("eval_trial") and
  (.body |
   schema::exact_fields(
     ["trial_version","case_ref","trial_index","status","output_ref","reason"];[]) and
   .trial_version == "v1" and
   (.case_ref | schema::content_ref_ok) and
   (.trial_index | schema::int_ok) and .trial_index >= 1 and .trial_index <= 16 and
   (.output_ref | present_ref_ok) and (.reason | present_reason_ok) and
   ((.status == "completed" and .output_ref.state == "present" and
     .reason.state == "absent") or
    (.status == "unavailable" and .output_ref.state == "absent" and
     .reason.state == "present")));

def grade_ok:
  envelope_ok("eval_grade") and
  (.body |
   schema::exact_fields(
     ["grade_version","trial_ref","grader_id","grader_kind","grader_ref",
      "status","evidence_ref","reason"];[]) and
   .grade_version == "v1" and
   (.trial_ref | schema::content_ref_ok) and
   (.grader_id | schema::id_ok) and
   (.grader_kind == "deterministic" or .grader_kind == "model" or
    .grader_kind == "human") and
   (.grader_ref | schema::content_ref_ok) and
   (.evidence_ref | present_ref_ok) and (.reason | present_reason_ok) and
   (((.status == "passed" or .status == "failed") and
     .evidence_ref.state == "present" and .reason.state == "absent") or
    (.status == "inconclusive" and .reason.state == "present") or
    (.status == "unavailable" and .evidence_ref.state == "absent" and
     .reason.state == "present")));

def measured_sha($section;$index):
  [$measured_docs[0][] | select(.section == $section and .index == $index)] |
  if length == 1 then .[0].sha256 else null end;

def wrapper_shape_ok(value_ok):
  schema::exact_fields(["ref","value"];[]) and
  (.ref | schema::content_ref_ok) and .ref.media_type == record_media_type and
  (.value | value_ok) and .ref.content_id == .value.id;

def wrapper_hash_ok($section;$index):
  .ref.sha256 == measured_sha($section;$index);

def bundle_shape_ok:
  . as $bundle |
  schema::parsed_limits_ok and
  schema::exact_fields(["schema_version","kind","id","body"];[]) and
  .schema_version == 1 and .kind == "eval_bundle" and (.id | schema::id_ok) and
  (.body | schema::exact_fields(["suite","cases","trials","grades"];[])) and
  ($bundle.body.suite | wrapper_shape_ok(suite_ok)) and
  ($bundle.body.cases | type == "array" and length >= 1 and length <= 32) and
  all($bundle.body.cases[]; wrapper_shape_ok(case_ok)) and
  ($bundle.body.trials | type == "array" and length >= 1 and length <= 128) and
  all($bundle.body.trials[]; wrapper_shape_ok(trial_ok)) and
  ($bundle.body.grades | type == "array" and length >= 1 and length <= 256) and
  all($bundle.body.grades[]; wrapper_shape_ok(grade_ok));

def bundle_hashes_ok($program_sha256):
  . as $bundle |
  ($bundle.body.suite | wrapper_hash_ok("suite";0)) and
  all(range(0;($bundle.body.cases | length)); . as $index |
      $bundle.body.cases[$index] | wrapper_hash_ok("cases";$index)) and
  all(range(0;($bundle.body.trials | length)); . as $index |
      $bundle.body.trials[$index] | wrapper_hash_ok("trials";$index)) and
  all(range(0;($bundle.body.grades | length)); . as $index |
      $bundle.body.grades[$index] | wrapper_hash_ok("grades";$index)) and
  $bundle.body.suite.value.body.framework_ref == {
    content_id:"eval-framework.v1",
    media_type:"application/vnd.ystack.eval-framework+jq",
    sha256:$program_sha256
  };

def bundle_order_ok:
  .body as $body |
  ([$body.suite] + $body.cases + $body.trials + $body.grades |
   map(.value.id)) as $all_ids |
  ($all_ids | length) == ($all_ids | unique | length) and
  ($body.cases | map(.value.id)) as $case_ids |
  $case_ids == ($case_ids | sort) and
  ($body.trials | map([.value.body.case_ref.content_id,.value.body.trial_index])) as $trial_keys |
  $trial_keys == ($trial_keys | sort) and
  ($trial_keys | length) == ($trial_keys | unique | length) and
  ($body.grades | map([.value.body.trial_ref.content_id,.value.body.grader_id])) as $grade_keys |
  $grade_keys == ($grade_keys | sort) and
  ($grade_keys | length) == ($grade_keys | unique | length);

def bundle_relations_ok:
  .body as $body |
  $body.suite.ref as $suite_ref |
  ($body.cases | map(.value.id)) as $case_ids |
  $body.suite.value.body.case_ids == $case_ids and
  all($body.cases[]; .value.body.suite_ref == $suite_ref) and
  all($body.cases[]; . as $case |
    [$body.trials[] | select(.value.body.case_ref == $case.ref)] as $trials |
    ($trials | map(.value.id)) == $case.value.body.trial_ids and
    ($trials | map(.value.body.trial_index)) ==
      [range(1;($case.value.body.trial_count + 1))]) and
  all($body.trials[]; . as $trial |
    [$body.cases[] | select(.ref == $trial.value.body.case_ref)] as $cases |
    ($cases | length) == 1 and
    ($cases[0].value.body.graders) as $graders |
    [$body.grades[] | select(.value.body.trial_ref == $trial.ref)] as $grades |
    ($grades | map(.value.body.grader_id)) == ($graders | map(.grader_id)) and
    all($grades[]; . as $grade |
      [$graders[] | select(.grader_id == $grade.value.body.grader_id)] as $matches |
      ($matches | length) == 1 and
      $grade.value.body.grader_kind == $matches[0].grader_kind and
      $grade.value.body.grader_ref == $matches[0].implementation_ref)) and
  all($body.grades[]; . as $grade |
    any($body.trials[]; .ref == $grade.value.body.trial_ref));

def fold_status($statuses):
  if any($statuses[]; . == "failed") then "failed"
  elif any($statuses[]; . == "unavailable") then "unavailable"
  elif any($statuses[]; . == "inconclusive") then "inconclusive"
  else "passed"
  end;

def trial_summary($body;$trial):
  [$body.grades[] | select(.value.body.trial_ref == $trial.ref) |
   .value.body.status] as $grade_statuses |
  (if $trial.value.body.status == "unavailable" then "unavailable"
   else fold_status($grade_statuses)
   end) as $status |
  {trial_ref:$trial.ref,trial_index:$trial.value.body.trial_index,status:$status};

def case_summary($body;$case):
  [$body.trials[] | select(.value.body.case_ref == $case.ref) |
   trial_summary($body;.)] as $trials |
  {case_ref:$case.ref,execution_kind:$case.value.body.execution_kind,
   status:fold_status($trials | map(.status)),trials:$trials};

def build_report($bundle_sha256):
  . as $bundle |
  [$bundle.body.cases[] | case_summary($bundle.body;.)] as $cases |
  {
    schema_version:1,
    kind:"eval_report",
    id:$bundle.id,
    body:{
      mode:"evaluation-only",
      bundle_ref:{content_id:$bundle.id,media_type:bundle_media_type,sha256:$bundle_sha256},
      framework_ref:$bundle.body.suite.value.body.framework_ref,
      suite_ref:$bundle.body.suite.ref,
      status:fold_status($cases | map(.status)),
      cases:$cases
    }
  };

. as $input |
if ($input | bundle_shape_ok | not) then error("E_SHAPE")
elif ($input | bundle_hashes_ok($program_sha256) | not) then error("E_STALE")
elif ($input | bundle_order_ok | not) then error("E_RELATION")
elif ($input | bundle_relations_ok | not) then error("E_RELATION")
else $input | build_report($bundle_sha256)
end
