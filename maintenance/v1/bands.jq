def exact($fields):
  type == "object" and (keys | sort) == ($fields | sort);

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

def file_safe_id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9-]{0,63}\\z");

def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");

def int_ok:
  type == "number" and . == floor and . >= 0 and . <= 2147483647 and
  tostring != "-0";

def text_ok:
  type == "string" and utf8bytelength >= 1 and utf8bytelength <= 512 and
  (test("[[:cntrl:]]") | not);

def time_ok:
  type == "string" and
  ((capture("\\A(?<year>[0-9]{4})-(?<month>[0-9]{2})-(?<day>[0-9]{2})T(?<hour>[0-9]{2}):(?<minute>[0-9]{2}):(?<second>[0-9]{2})Z\\z") as $p |
    ($p.year | tonumber) as $year | ($p.month | tonumber) as $month |
    ($p.day | tonumber) as $day |
    ($year % 4 == 0 and ($year % 100 != 0 or $year % 400 == 0)) as $leap |
    [31,(if $leap then 29 else 28 end),31,30,31,30,31,31,30,31,30,31] as $days |
    $month >= 1 and $month <= 12 and $day >= 1 and $day <= $days[$month - 1] and
    ($p.hour | tonumber) <= 23 and ($p.minute | tonumber) <= 59 and
    ($p.second | tonumber) <= 59) // false);

def repo_path_ok:
  type == "string" and utf8bytelength >= 1 and utf8bytelength <= 1024 and
  (test("[[:cntrl:]]") | not) and (contains("\\") | not) and
  (startswith("/") | not) and
  (split("/") |
   length <= 64 and
   all(.[]; . != "" and . != "." and . != ".." and (endswith(".") | not) and
       (endswith(" ") | not)));

def content_ref_ok($media):
  exact(["content_id","media_type","sha256"]) and (.content_id | id_ok) and
  .media_type == $media and (.sha256 | sha256_ok);

def content_ref($content_id; $media; $sha):
  {content_id:$content_id,media_type:$media,sha256:$sha};

# Whole days since 1970-01-01 for a "YYYY-MM-DDTHH:MM:SSZ" stamp, so band ages
# are arithmetic over the supplied documents and never read a host clock.
def day_number:
  capture("\\A(?<y>[0-9]{4})-(?<m>[0-9]{2})-(?<d>[0-9]{2})T") as $p |
  ($p.y | tonumber) as $y | ($p.m | tonumber) as $m | ($p.d | tonumber) as $d |
  (if $m <= 2 then $y - 1 else $y end) as $shifted |
  (($shifted / 400) | floor) as $era |
  ($shifted - $era * 400) as $year_of_era |
  ((((153 * (if $m > 2 then $m - 3 else $m + 9 end) + 2) / 5) | floor) + $d - 1) as $day_of_year |
  ($year_of_era * 365 + (($year_of_era / 4) | floor) -
   (($year_of_era / 100) | floor) + $day_of_year) as $day_of_era |
  $era * 146097 + $day_of_era - 719468;

def severities: ["critical","high","low","medium"];
def high_severities: ["critical","high"];
def risk_tiers: ["high","routine"];
def comparisons: ["at-least","at-most"];
def metric_ids:
  ["deploy.rollback-rehearsal-age-days","eval.cases-failed","eval.cases-inconclusive",
   "eval.repeats-suppressed","eval.stale-family-unresolved-permille",
   "eval.stranded-recovered","telemetry.refused-events"];
def stale_family_id: "stale-moved-artifacts";

def band_ok:
  exact(["band_id","comparison","description","metric_id","risk_tier","threshold"]) and
  (.band_id | file_safe_id_ok) and (.description | text_ok) and
  (.metric_id as $m | metric_ids | index($m) != null) and
  (.comparison as $c | comparisons | index($c) != null) and
  (.risk_tier as $t | risk_tiers | index($t) != null) and
  (.threshold | int_ok);

def bands_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "maintenance_control_bands" and .id == "maintenance-policy.control-bands" and
  (.body |
   exact(["activation_state","authority","bands","deploy_authority","evaluation_mode",
     "fail_mode","policy_version","qualification"]) and
   .activation_state == "inactive" and .authority == "none" and
   .deploy_authority == "none" and .evaluation_mode == "observation-only" and
   .fail_mode == "closed" and .policy_version == "v1" and
   .qualification == {reason_id:"maintenance.no-adapter-exists",state:"unavailable"} and
   (.bands | type == "array" and length >= 6 and length <= 8 and
    all(.[]; band_ok) and (map(.band_id) | . == (sort | unique)) and
    (map(.metric_id) | (length == (unique | length)))));

def dashboard_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "eval_dashboard" and (.id | id_ok) and
  (.body | type == "object" and .activation_state == "inactive" and
   .authority_effect == "none" and .mode == "deterministic-offline" and
   (.observed_at | time_ok) and
   (.quality | exact(["failed","inconclusive","passed","total"]) and all(.[]; int_ok)) and
   (.recovery |
    exact(["cancelled_stayed_terminal","events_refused","repeats_redelivered_once",
      "repeats_suppressed_after_acknowledgement","retry_limit_enforced",
      "stranded_recovered"]) and all(.[]; int_ok)) and
   (.families | type == "array" and length >= 1 and length <= 32 and
    all(.[]; type == "object" and (.family_id | id_ok) and
      (.cases | exact(["failed","inconclusive","passed","total"]) and
       all(.[]; int_ok))) and (map(.family_id) | . == (sort | unique))));

# The seal itself is proved by the telemetry validator before this filter runs;
# here the ledger is only read for the facts the bands count.
def ledger_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "telemetry_trace_ledger" and (.id | id_ok) and
  (.body | type == "object" and
   (.events | type == "array" and length >= 1 and length <= 256 and
    all(.[]; type == "object" and (.id | id_ok) and
      (.facts | type == "object") and
      (.facts.result | type == "object" and
       (.state as $s | ["not-applicable","recorded","unavailable"] | index($s) != null) and
       ((.state != "recorded") or (.value | id_ok))))));

def kill_switch_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "kill_switch_evaluation" and (.id | id_ok) and
  (.body | type == "object" and .activation_state == "inactive" and
   .authority_effect == "none" and .evaluation_mode == "observation-only" and
   (.verdict as $v | ["inconclusive","satisfied","violated"] | index($v) != null) and
   (.reason_ids | type == "array" and length >= 1 and length <= 64 and
    all(.[]; id_ok) and . == (sort | unique)));

def rehearsal_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "rollback_rehearsal_record" and (.id | id_ok) and
  (.body |
   exact(["activation_state","authority","environment","evidence","from_release_ref",
     "outcome","rehearsed_at","to_release_ref"]) and
   .activation_state == "inactive" and .authority == "none" and
   (.environment | exact(["tier"]) and
    (.tier | type == "string" and test("\\A[a-z][a-z0-9-]{0,31}\\z"))) and
   (.evidence | type == "object") and (.from_release_ref | type == "object") and
   (.to_release_ref | type == "object") and
   (.outcome == "failed" or .outcome == "rehearsed") and (.rehearsed_at | time_ok));

def finding_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "maintenance_scan_finding" and (.id | file_safe_id_ok) and
  (.body |
   exact(["activation_state","authority","evidence_sha256","observed_at","path",
     "rule_id","scanner_id","severity"]) and
   .activation_state == "inactive" and .authority == "none" and
   (.scanner_id | id_ok) and (.rule_id | id_ok) and
   (.severity as $s | severities | index($s) != null) and
   (.path | repo_path_ok) and (.evidence_sha256 | sha256_ok) and
   (.observed_at | time_ok));

# Every metric is a count or an age over the documents handed in. A metric that
# cannot be counted returns null, and a null is out of band: the loop fails closed.
def metric_value($metric_id; $dashboard; $ledger; $rehearsals):
  if $metric_id == "eval.cases-failed" then $dashboard.body.quality.failed
  elif $metric_id == "eval.cases-inconclusive" then $dashboard.body.quality.inconclusive
  elif $metric_id == "eval.stranded-recovered" then
    $dashboard.body.recovery.stranded_recovered
  elif $metric_id == "eval.repeats-suppressed" then
    $dashboard.body.recovery.repeats_suppressed_after_acknowledgement
  elif $metric_id == "eval.stale-family-unresolved-permille" then
    ([$dashboard.body.families[] | select(.family_id == stale_family_id)]) as $family |
    (if ($family | length) != 1 or $family[0].cases.total == 0 then null
     else ((1000 * ($family[0].cases.total - $family[0].cases.passed)) /
           $family[0].cases.total | floor) end)
  elif $metric_id == "telemetry.refused-events" then
    ([$ledger.body.events[] |
      select(.facts.result.state == "recorded" and
             (.facts.result.value | test("refused")))] | length)
  elif $metric_id == "deploy.rollback-rehearsal-age-days" then
    ([$rehearsals[] | select(.body.outcome == "rehearsed") | .body.rehearsed_at] |
     max) as $latest |
    (if $latest == null then null
     else (($dashboard.body.observed_at | day_number) - ($latest | day_number)) as $age |
       (if $age < 0 then null else $age end) end)
  else null end;

def evaluate_band($band; $dashboard; $ledger; $rehearsals):
  metric_value($band.metric_id; $dashboard; $ledger; $rehearsals) as $value |
  (if $value == null then false
   elif $band.comparison == "at-most" then $value <= $band.threshold
   else $value >= $band.threshold end) as $in_band |
  {band_id:$band.band_id,
   comparison:$band.comparison,
   description:$band.description,
   metric_id:$band.metric_id,
   risk_tier:$band.risk_tier,
   state:(if $in_band then "in-band" else "out-of-band" end),
   threshold:$band.threshold,
   value:$value,
   reason_id:(if $in_band then "maintenance.band-held"
              elif $value == null then "maintenance.metric-unmeasurable"
              else "maintenance.band-crossed" end)};

def evaluate_bands($bands; $dashboard; $ledger; $rehearsals):
  [$bands.body.bands[] | evaluate_band(.; $dashboard; $ledger; $rehearsals)] |
  sort_by(.band_id);
