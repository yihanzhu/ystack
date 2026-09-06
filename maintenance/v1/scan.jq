include "bands";

def bands_media: "application/vnd.ystack.maintenance-control-bands+json";
def dashboard_media: "application/vnd.ystack.eval-dashboard+json";
def ledger_media: "application/vnd.ystack.telemetry-trace-ledger+json";
def kill_switch_media: "application/vnd.ystack.control-evaluation+json";
def finding_media: "application/vnd.ystack.maintenance-scan-finding+json";
def rehearsal_media: "application/vnd.ystack.rollback-rehearsal-record+json";

def pair_ok(shape):
  exact(["document","sha256"]) and (.sha256 | sha256_ok) and (.document | shape);

def bundle_ok:
  exact(["bands","dashboard","findings","kill_switch","ledger","rehearsals"]) and
  (.bands | pair_ok(bands_ok)) and (.dashboard | pair_ok(dashboard_ok)) and
  (.ledger | pair_ok(ledger_ok)) and (.kill_switch | pair_ok(kill_switch_ok)) and
  (.findings | type == "array" and length <= 32 and all(.[]; pair_ok(finding_ok))) and
  (.rehearsals | type == "array" and length <= 32 and all(.[]; pair_ok(rehearsal_ok)));

def bands_ref: content_ref("maintenance-control-bands"; bands_media; .bands.sha256);
def dashboard_ref: content_ref("evals-dashboard"; dashboard_media; .dashboard.sha256);
def ledger_ref: content_ref("maintenance-trace-ledger"; ledger_media; .ledger.sha256);
def kill_switch_ref:
  content_ref("maintenance-kill-switch-evaluation"; kill_switch_media; .kill_switch.sha256);
def finding_refs:
  [.findings[] |
   content_ref("maintenance-scan-finding." + .document.id; finding_media; .sha256)] |
  sort_by(.sha256);
def rehearsal_refs:
  [.rehearsals[] |
   content_ref("maintenance-rollback-rehearsal." + .document.id; rehearsal_media; .sha256)] |
  sort_by(.sha256);

def comparison_phrase($comparison):
  if $comparison == "at-most" then "at most" else "at least" end;

def triage_sections($problem; $proposed; $affected; $questions):
  {problem:$problem,
   proposed_outcome:$proposed,
   affected_users_and_systems:$affected,
   constraints:("This record is a document for a human owner. It files no issue, " +
     "opens no change request, deploys nothing, activates nothing, and grants no " +
     "authority."),
   open_questions:$questions};

def intent_document($id; $title; $risk_tier; $observed_at; $source; $sections; $evidence):
  {schema_version:1,
   kind:"maintenance_intent",
   id:$id,
   body:{
     activation_state:"inactive",
     authority:"none",
     deploy_authority:"none",
     evaluation_mode:"observation-only",
     filing_effect:"none",
     qualification:{state:"unavailable",reason_id:"maintenance.no-adapter-exists"},
     owner:"unassigned",
     triage_state:"pending",
     risk_tier_guess:$risk_tier,
     observed_at:$observed_at,
     title:$title,
     source:$source,
     sections:$sections,
     evidence_refs:$evidence}};

def band_intent($bundle; $observation):
  intent_document(
    "maintenance-intent.band." + $observation.band_id;
    "Control band " + $observation.band_id + " is out of band";
    $observation.risk_tier;
    $bundle.dashboard.document.body.observed_at;
    {kind:"control-band",id:$observation.band_id,reason_id:$observation.reason_id};
    triage_sections(
      $observation.description + " The band allows " +
        comparison_phrase($observation.comparison) + " " +
        ($observation.threshold | tostring) + " for " + $observation.metric_id +
        ", and this scan " +
        (if $observation.value == null then "could not measure it from the documents it was given."
         else "measured " + ($observation.value | tostring) + "." end);
      "A service owner reads this record, decides whether the band or the behaviour behind it is wrong, and starts the normal intent, spec, and plan chain when work is needed.";
      "The maintenance loop and whoever owns the checks behind " +
        $observation.metric_id + ".";
      ["Is this threshold still the right one?",
       "Which service owner takes this?"]);
    ($bundle | [bands_ref,dashboard_ref,ledger_ref] + rehearsal_refs));

def finding_intent($bundle; $finding):
  $finding.document.body as $body |
  intent_document(
    "maintenance-intent.finding." + $finding.document.id;
    "Security scan finding " + $finding.document.id + " needs triage";
    "high";
    $bundle.dashboard.document.body.observed_at;
    {kind:"security-scan-finding",id:$finding.document.id,
     reason_id:"maintenance.high-severity-finding"};
    triage_sections(
      "Scanner " + $body.scanner_id + " reported rule " + $body.rule_id +
        " at " + $body.severity + " severity on " + $body.path +
        ". The scanner recorded its evidence under digest " + $body.evidence_sha256 +
        ", observed at " + $body.observed_at + ".";
      "A service owner confirms or dismisses the finding against the named path and starts the normal intent, spec, and plan chain when work is needed.";
      "Whoever owns " + $body.path + ".";
      ["Is this a real problem at this path, or a scanner false positive?",
       "Which service owner takes this?"]);
    ($bundle | [bands_ref,dashboard_ref]) +
    [content_ref("maintenance-scan-finding." + $finding.document.id; finding_media;
      $finding.sha256)]);

def scan_record($bundle; $observations; $findings; $intents; $engaged):
  {schema_version:1,
   kind:"maintenance_scan",
   id:"maintenance.scan",
   body:{
     activation_state:"inactive",
     authority:"none",
     deploy_authority:"none",
     evaluation_mode:"observation-only",
     filing_effect:"none",
     qualification:{state:"unavailable",reason_id:"maintenance.no-adapter-exists"},
     observed_at:$bundle.dashboard.document.body.observed_at,
     reason_id:(if $engaged then "maintenance.kill-switch-engaged"
                else "maintenance.scan-completed" end),
     kill_switch:{engaged:$engaged,
       verdict:$bundle.kill_switch.document.body.verdict,
       reason_ids:$bundle.kill_switch.document.body.reason_ids,
       evaluation_ref:($bundle | kill_switch_ref)},
     bands_ref:($bundle | bands_ref),
     evidence:{dashboard_ref:($bundle | dashboard_ref),
       trace_ledger_ref:($bundle | ledger_ref),
       finding_refs:($bundle | finding_refs),
       rehearsal_refs:($bundle | rehearsal_refs)},
     bands:$observations,
     findings:$findings,
     intents:$intents,
     summary:{bands_total:($observations | length),
       bands_in_band:([$observations[] | select(.state == "in-band")] | length),
       bands_out_of_band:([$observations[] | select(.state == "out-of-band")] | length),
       findings_total:($findings | length),
       findings_high_severity:([$findings[] | select(.high_severity)] | length),
       intents_written:($intents | length)}}};

. as $bundle |
if ($bundle | bundle_ok | not) then "E_SHAPE"
elif (([$bundle.findings[].document.id] | length != ([$bundle.findings[].document.id] | unique | length)) or
      ([$bundle.rehearsals[].document.id] | length != ([$bundle.rehearsals[].document.id] | unique | length)))
then "E_RELATION"
elif $operation == "shape" then empty
elif $operation != "scan" then "E_RUNTIME"
else
  ($bundle.kill_switch.document.body.verdict != "satisfied") as $engaged |
  evaluate_bands($bundle.bands.document; $bundle.dashboard.document;
    $bundle.ledger.document; [$bundle.rehearsals[].document]) as $observations |
  ([$bundle.findings[] |
    {finding_id:.document.id,
     scanner_id:.document.body.scanner_id,
     rule_id:.document.body.rule_id,
     severity:.document.body.severity,
     path:.document.body.path,
     evidence_sha256:.document.body.evidence_sha256,
     observed_at:.document.body.observed_at,
     finding_sha256:.sha256,
     high_severity:(.document.body.severity as $severity |
       (high_severities | index($severity)) != null)}] |
   sort_by(.finding_id)) as $findings |
  (if $engaged then []
   else
     ([$observations[] | select(.state == "out-of-band") |
       {file_name:("intent-band-" + .band_id + ".json"),
        source:{kind:"control-band",id:.band_id},
        risk_tier_guess:.risk_tier,
        document:band_intent($bundle; .)}] +
      [$bundle.findings[] |
       select(.document.body.severity as $severity |
         (high_severities | index($severity)) != null) |
       {file_name:("intent-finding-" + .document.id + ".json"),
        source:{kind:"security-scan-finding",id:.document.id},
        risk_tier_guess:"high",
        document:finding_intent($bundle; .)}]) |
     sort_by(.file_name)
   end) as $written |
  ([$written[] |
    {file_name:.file_name,intent_id:.document.id,source:.source,
     risk_tier_guess:.risk_tier_guess}]) as $intents |
  {scan:scan_record($bundle; $observations; $findings; $intents; $engaged),
   intents:$written}
end
