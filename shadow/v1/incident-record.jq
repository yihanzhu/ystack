def exact($fields):
  type == "object" and (keys | sort) == ($fields | sort);

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");

def oid_ok($algorithm):
  type == "string" and
  (if $algorithm == "sha256" then test("\\A[0-9a-f]{64}\\z")
   else test("\\A[0-9a-f]{40}\\z") end);

def time_ok:
  type == "string" and
  (capture("\\A(?<year>[0-9]{4})-(?<month>[0-9]{2})-(?<day>[0-9]{2})T(?<hour>[0-9]{2}):(?<minute>[0-9]{2}):(?<second>[0-9]{2})Z\\z") as $p |
   ($p.year | tonumber) as $year | ($p.month | tonumber) as $month |
   ($p.day | tonumber) as $day |
   ($year % 4 == 0 and ($year % 100 != 0 or $year % 400 == 0)) as $leap |
   [31,(if $leap then 29 else 28 end),31,30,31,30,31,31,30,31,30,31] as $days |
   $month >= 1 and $month <= 12 and $day >= 1 and $day <= $days[$month - 1] and
   ($p.hour | tonumber) <= 23 and ($p.minute | tonumber) <= 59 and
   ($p.second | tonumber) <= 59) // false;

def text_ok:
  type == "string" and utf8bytelength >= 1 and utf8bytelength <= 256 and
  (test("[[:cntrl:]]") | not);

def repo_path_ok:
  type == "string" and utf8bytelength >= 1 and utf8bytelength <= 4096 and
  (test("[[:cntrl:]]") | not) and (contains("\\") | not) and
  (startswith("/") | not) and
  (split("/") |
   length <= 64 and
   all(.[];
       . != "" and . != "." and . != ".." and (ascii_downcase != ".git") and
       (endswith(".") | not) and (endswith(" ") | not)));

def revision_ok($repository_id):
  . as $revision |
  exact(["commit_id","hash_algorithm","repository_id"]) and
  $revision.repository_id == $repository_id and
  ($revision.hash_algorithm == "sha1" or $revision.hash_algorithm == "sha256") and
  ($revision.commit_id | oid_ok($revision.hash_algorithm));

def failing_check_ok:
  (exact(["expected_sha256","kind","path"]) and .kind == "file-digest" and
   (.path | repo_path_ok) and (.expected_sha256 | sha256_ok)) or
  (exact(["check_id","kind"]) and .kind == "named-check" and
   (.check_id | id_ok));

def record_ok:
  exact(["body","id","kind","schema_version"]) and
  .schema_version == 1 and .kind == "shadow_incident_record" and (.id | id_ok) and
  (.body as $body |
   ($body |
    exact(["deploy_authority","failing_check","git_revision_ref","observed_at",
      "observed_symptom","reporter_actor_ref","target_repository_id"])) and
   $body.deploy_authority == "none" and
   ($body.target_repository_id | id_ok) and
   ($body.git_revision_ref | revision_ok($body.target_repository_id)) and
   ($body.failing_check | failing_check_ok) and
   ($body.observed_symptom | text_ok) and
   ($body.reporter_actor_ref | id_ok) and
   ($body.observed_at | time_ok));

def receipt($record_sha):
  {
    schema_version:1,
    kind:"shadow_incident_validation",
    id:.id,
    body:{
      activation_state:"inactive",
      authority_effect:"none",
      deploy_authority:"none",
      forge_effect:"none",
      incident_ref:{
        content_id:"shadow-incident-record",
        media_type:"application/vnd.ystack.shadow-incident-record+json",
        sha256:$record_sha
      },
      summary:{
        failing_check:.body.failing_check,
        git_revision_ref:.body.git_revision_ref,
        observed_at:.body.observed_at,
        observed_symptom:.body.observed_symptom,
        reporter_actor_ref:.body.reporter_actor_ref,
        target_repository_id:.body.target_repository_id
      }
    }
  };

if $operation == "shape" then
  if record_ok then empty else "E_SHAPE" end
elif $operation == "receipt" then
  if (record_ok | not) then "E_SHAPE"
  elif ($record_sha | sha256_ok | not) then "E_RUNTIME"
  else receipt($record_sha)
  end
else "E_RUNTIME"
end
