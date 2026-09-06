#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077
[ "$#" -eq 2 ] || exit 64
[ -z "${GH_TOKEN-}${GITHUB_TOKEN-}${AWS_SECRET_ACCESS_KEY-}${SSH_AUTH_SOCK-}" ] || exit 70
evaluation=$1 jq_bin=$2
[ -f "$evaluation" ] && [ ! -L "$evaluation" ] || exit 66
[ -f "$jq_bin" ] && [ -x "$jq_bin" ] && [ ! -L "$jq_bin" ] || exit 66
[ "$("$jq_bin" --version 2>/dev/null)" = jq-1.6 ] || exit 66
"$jq_bin" -e '
  (keys | sort) == ["body","id","kind","schema_version"] and
  .schema_version == 1 and .kind == "deploy_gate_evaluation" and
  .body.activation_state == "inactive" and .body.authority == "none" and
  .body.decision == "admissible" and .body.reason_ids == ["deploy.admissible"]
' "$evaluation" >/dev/null || exit 65
evaluation_sha=$(/usr/bin/shasum -a 256 "$evaluation" | /usr/bin/awk '{print $1}')
"$jq_bin" -S -c --arg evaluation_sha "$evaluation_sha" '
  {schema_version:1,kind:"adapter_receipt",
   adapter:{id:"fake.deploy-dormant.v1",version:"v1",status:"inactive"},
   mode:"observation-only",reference_semantics:"identity-only",
   evaluation_ref:{schema_version:.schema_version,kind:.kind,id:.id,sha256:$evaluation_sha},
   request_ref:.body.request_ref,release_ref:.body.release_ref,
   requested_capability:.body.requested_capability,tier:.body.tier,
   outcome:"refused",reason_id:"deploy.dormant",
   message:"dormant: deployment disabled in construction mode",
   authority:"none",qualification:{state:"unavailable",reason_id:"adapter.unqualified"},
   capability:{state:"unavailable",reason_id:"deploy.dormant"},
   capabilities:[],permissions:[],tools:[],effects:[]}
' "$evaluation"
