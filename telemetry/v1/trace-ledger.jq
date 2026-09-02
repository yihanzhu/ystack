def exact($fields):
  type == "object" and (keys | sort) == ($fields | sort);

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

def content_id_ok:
  id_ok and (contains(":") | not) and (contains("/") | not);

def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");

def int_ok:
  type == "number" and . == floor and . >= 0 and . <= 2147483647 and
  tostring != "-0";

def time_ok:
  type == "string" and
  test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z") and
  (capture("\\A(?<year>[0-9]{4})-(?<month>[0-9]{2})-(?<day>[0-9]{2})T(?<hour>[0-9]{2}):(?<minute>[0-9]{2}):(?<second>[0-9]{2})Z\\z") as $p |
   ($p.year | tonumber) as $year | ($p.month | tonumber) as $month |
   ($p.day | tonumber) as $day | ($p.hour | tonumber) as $hour |
   ($p.minute | tonumber) as $minute | ($p.second | tonumber) as $second |
   ($year % 4 == 0 and ($year % 100 != 0 or $year % 400 == 0)) as $leap |
   [31,(if $leap then 29 else 28 end),31,30,31,30,31,31,30,31,30,31] as $days |
   $month >= 1 and $month <= 12 and $day >= 1 and $day <= $days[$month - 1] and
   $hour >= 0 and $hour <= 23 and $minute >= 0 and $minute <= 59 and
   $second >= 0 and $second <= 59);

def media_type_ok:
  type == "string" and utf8bytelength <= 127 and
  test("\\A[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*\\z");

def content_ref_ok:
  exact(["content_id","media_type","sha256"]) and
  (.content_id | content_id_ok) and (.media_type | media_type_ok) and
  (.sha256 | sha256_ok);

def fact_ok(value_ok):
  (exact(["source_ref","state","value"]) and
   (.state == "recorded" or .state == "computed") and
   (.source_ref | content_ref_ok) and (.value | value_ok)) or
  (exact(["reason_id","state"]) and .state == "unavailable" and
   (.reason_id | id_ok)) or
  (exact(["state"]) and .state == "not-applicable");

def facts_ok:
  exact(["adapter","cost_microunits","execution_environment","gate","identity",
    "initiative","latency_ms","result","stage","status","task_class","tool",
    "workflow"]) and
  (.adapter | fact_ok(id_ok)) and (.cost_microunits | fact_ok(int_ok)) and
  (.execution_environment | fact_ok(id_ok)) and (.gate | fact_ok(id_ok)) and
  (.identity | fact_ok(id_ok)) and (.initiative | fact_ok(id_ok)) and
  (.latency_ms | fact_ok(int_ok)) and (.result | fact_ok(id_ok)) and
  (.stage | fact_ok(id_ok)) and (.status | fact_ok(id_ok)) and
  (.task_class | fact_ok(id_ok)) and (.tool | fact_ok(id_ok)) and
  (.workflow | fact_ok(id_ok));

def event_ok:
  exact(["event_type","facts","id","kind","occurred_at","prior_digest",
    "record_digest","schema_version","sequence","session_id","trace_id"]) and
  .schema_version == 1 and .kind == "telemetry_trace_event" and
  (.id | id_ok) and (.event_type | id_ok) and (.occurred_at | time_ok) and
  (.sequence | int_ok) and (.session_id | id_ok) and (.trace_id | id_ok) and
  ((.prior_digest == null) or (.prior_digest | sha256_ok)) and
  (.record_digest | sha256_ok) and (.facts | facts_ok);

def seal_ok:
  exact(["algorithm","canonicalization","event_count","final_digest",
    "first_digest"]) and .algorithm == "sha256" and
  .canonicalization == "jq-1.6-sort-compact-line" and
  (.event_count | int_ok) and (.first_digest | sha256_ok) and
  (.final_digest | sha256_ok);

def ledger_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "telemetry_trace_ledger" and (.id | content_id_ok) and
  (.body |
    exact(["events","session_id","trace_ids","seal"]) and
    (.session_id | id_ok) and
    (.trace_ids | type == "array" and length >= 1 and length <= 32 and
      all(.[];id_ok) and . == (sort | unique)) and
    (.events | type == "array" and length >= 1 and length <= 256 and
      all(.[];event_ok)) and (.seal | seal_ok));

def relations_ok($digests):
  . as $ledger |
  $ledger.body.events as $events |
  ($events | length) as $count |
  ($digests | type == "array" and length == $count and all(.[];sha256_ok)) and
  (($events | map(.id)) | length == (unique | length)) and
  all(range(0;$count);$events[.].sequence == .) and
  all($events[];.session_id == $ledger.body.session_id) and
  $ledger.body.trace_ids == ($events | map(.trace_id) | sort | unique) and
  all(range(1;$count);$events[. - 1].occurred_at <= $events[.].occurred_at) and
  all(range(0;$count);$events[.].record_digest == $digests[.]) and
  $events[0].prior_digest == null and
  all(range(1;$count);$events[.].prior_digest == $digests[. - 1]) and
  $ledger.body.seal.event_count == $count and
  $ledger.body.seal.first_digest == $digests[0] and
  $ledger.body.seal.final_digest == $digests[$count - 1];

def receipt($ledger_sha):
  {schema_version:1,kind:"telemetry_trace_ledger_validation",id:.id,
   body:{activation_state:"inactive",authority_effect:"none",storage_effect:"none",
     session_id:.body.session_id,trace_ids:.body.trace_ids,
     event_count:.body.seal.event_count,first_digest:.body.seal.first_digest,
     final_digest:.body.seal.final_digest,
     ledger_ref:{content_id:.id,
       media_type:"application/vnd.ystack.telemetry-trace-ledger+json",
       sha256:$ledger_sha}}};

if $operation == "shape" then
  if ledger_ok then empty else "E_SHAPE" end
elif $operation == "validate" then
  if (ledger_ok | not) then "E_SHAPE"
  elif (relations_ok($event_digests) | not) then "E_RELATION"
  else receipt($ledger_sha)
  end
else "E_RUNTIME"
end
