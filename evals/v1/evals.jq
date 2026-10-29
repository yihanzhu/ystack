import "schema" as schema;

# Inactive eval/trace framework contracts (Roadmap item 5, unit 1).
# Pure jq 1.6. Consumes only canonical core-v2 documents and caller-supplied
# offline observations. Grants nothing, executes nothing, records no cost.

def expected_core:
  {
    generation_id_sha256:
      "84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
    package_ref:{
      content_id:"core-contract-package.v2",
      media_type:"application/vnd.ystack.core-contract+json",
      sha256:"eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"
    },
    semantic_identity:"core.contracts.v2"
  };

def expected_core_closure:
  [
    {path:"core/v2/generation-registry.json",
     sha256:"3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/contracts.jq",
     sha256:"65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/core-ingress.sh",
     sha256:"dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/profile_graph.jq",
     sha256:"c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_facts.jq",
     sha256:"8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_truth.jq",
     sha256:"ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/schema.jq",
     sha256:"8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/stage_request.jq",
     sha256:"6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e"},
    {path:"scripts/core-contract.sh",
     sha256:"b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9"}
  ];

# The inactive state scanner and reconciliation planner replayed for the events
# family, pinned like the core.
def expected_orchestrator_closure:
  [
    {path:"orchestrator/v1/reconciliation-plan.jq",
     sha256:"03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4"},
    {path:"orchestrator/v1/scan-state.sh",
     sha256:"556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5"},
    {path:"orchestrator/v1/state-scanner-driver.sh",
     sha256:"5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b"},
    {path:"orchestrator/v1/state-scanner-launcher.sh",
     sha256:"9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb"},
    {path:"orchestrator/v1/state-scanner.jq",
     sha256:"722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae"}
  ];

# The inactive control evaluators replayed here: the sandbox-policy evaluator for
# the boundaries family, the risk-gates evaluator (with the duty-separation
# evaluator it regenerates) for the approval family, and that same
# duty-separation evaluator on its own for the actor and re-run identity family.
# All of them read only this closure and the core mirror.
def expected_control_closure:
  [
    {path:"control/v1/duty-separation-decision.json",
     sha256:"4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99"},
    {path:"control/v1/duty-separation-policy.json",
     sha256:"b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9"},
    {path:"control/v1/duty-separation.jq",
     sha256:"b4e480748dd4fb7dec769b25f0f7649b0e5dc31f9de438bba690e9eab6ac236c"},
    {path:"control/v1/evaluate-duty.sh",
     sha256:"146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa"},
    {path:"control/v1/evaluate-risk-gates.sh",
     sha256:"0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8"},
    {path:"control/v1/evaluate-sandbox.sh",
     sha256:"8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb"},
    {path:"control/v1/policy-set.jq",
     sha256:"2be97550574ee4522fc0bd14780c92dee3c1b455f2c04b7763b0e437665a8d58"},
    {path:"control/v1/risk-gates-decision.json",
     sha256:"8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5"},
    {path:"control/v1/risk-gates-policy.json",
     sha256:"3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e"},
    {path:"control/v1/risk-gates.jq",
     sha256:"d00fccd8e31b770c6df01fba17e3cc315d58edfbbf0a8055d66d537dc6ad21ff"},
    {path:"control/v1/sandbox-decision.json",
     sha256:"c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd"},
    {path:"control/v1/sandbox-policy.json",
     sha256:"4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e"},
    {path:"control/v1/sandbox.jq",
     sha256:"83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3"},
    {path:"control/v1/validate.sh",
     sha256:"cf173ad0eaa08244bf636e3937845e894b21f14291fc5e66753e8673bdd2bd2a"}
  ];

# The inactive default and alternative normalizers replayed for the adapter
# family: three GitHub-side defaults, the GitLab forge, and the Codex CLI producer.
def expected_adapter_closure:
  [
    {path:"adapters/codex-cli-producer/v1/normalize.jq",
     sha256:"dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25"},
    {path:"adapters/codex-native-reviewer/v1/normalize.jq",
     sha256:"7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603"},
    {path:"adapters/github-actions-ci/v1/normalize.jq",
     sha256:"690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7"},
    {path:"adapters/github-forge/v1/normalize.jq",
     sha256:"b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be"},
    {path:"adapters/gitlab-forge/v1/normalize.jq",
     sha256:"ff2ec298eef102f94f28995f5306adeba8e078d19e4c22860c3b167cd9b7c37a"}
  ];

def expected_record_closure:
  ([expected_core_closure[] | select(.path | endswith("/modules/schema.jq"))] +
   [{path:"evals/v1/framework.jq",sha256:"d164a102919f42ef002e93c8b515b58028604819e6c09b87c6e4afadb0bbcce4"},
    {path:"evals/v1/run.sh",sha256:"51770c5597d55bf05020502796810637bfbe697038a541ea6124530c0fffe55c"}]);

def expected_shadow_closure:
  [
    {"path":"adapters/local-git-materializer/v1/materialize.sh","sha256":"9b806bb5e202f98166aae60d391107c29aa0d19176765bf48fef47155f9fd358"},
    {"path":"adapters/local-git-materializer/v1/object-closure.c","sha256":"f1616b908c97e8a091029c24b3f2e1f8827171cbdee4d47195c66afd3e961e27"},
    {"path":"adapters/local-git-materializer/v1/protocol.jq","sha256":"232517c19455667cca795769ffc0d8edad7873a9d55be0c21166de5b436bf323"},
    {"path":"config/construction-mode.json","sha256":"5b3e0bafe63f84134e1b4aa2659e954bbbbd0bcc87d20716b03cd1b9d15a0fda"},
    {"path":"control/v1/control-policy-set-sandbox-bound.json","sha256":"a50d1ab32ef5964c9e3074084870bffa264fd138f325d830d166135545e3dc8d"},
    {"path":"control/v1/control-policy-set.json","sha256":"a3f9a8d16bd60a0cfc32da3e802a207c1e225013b7ef115030ef567d0ccd366a"},
    {"path":"control/v1/credential-policy-decision.json","sha256":"73877276c868eae2da9dcedf8eb465b0526ce26a66506691b9cedbba15f00615"},
    {"path":"control/v1/credential-policy.jq","sha256":"428ea96f23a18c6938421b9cc709d36ba83b34e2441347d5891a971f92d5ec77"},
    {"path":"control/v1/credential-policy.json","sha256":"2ba0ec54d11ab4e9d02993e9283c5f820c662a20cf33d2bff25b1393a5ee403d"},
    {"path":"control/v1/duty-separation-decision.json","sha256":"4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99"},
    {"path":"control/v1/duty-separation-policy.json","sha256":"b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9"},
    {"path":"control/v1/duty-separation.jq","sha256":"b4e480748dd4fb7dec769b25f0f7649b0e5dc31f9de438bba690e9eab6ac236c"},
    {"path":"control/v1/evaluate-bound-sandbox.sh","sha256":"710615c6709250f40d0c494914e2577ee84896cde2b5828b4f457940b0347980"},
    {"path":"control/v1/evaluate-credential-policy.sh","sha256":"5c9bab9d00754d63e4ead770489564db8122c53ab1bc8b6e92c27719265c18f7"},
    {"path":"control/v1/evaluate-duty.sh","sha256":"146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa"},
    {"path":"control/v1/evaluate-evidence-integrity.sh","sha256":"f0ecbe036601102db082d0a94c860ea868614ff79d06f2b37ec8dcd672c367a2"},
    {"path":"control/v1/evaluate-kill-switch.sh","sha256":"ea1d40c50de706fa52198dc09e783ee613933aa0dbea72bfff8072becd79bb3b"},
    {"path":"control/v1/evaluate-risk-gates.sh","sha256":"0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8"},
    {"path":"control/v1/evaluate-sandbox.sh","sha256":"8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb"},
    {"path":"control/v1/evidence-integrity-decision.json","sha256":"03e9225face347f1a4990beb6812f0e839d777cfbc6b95997d8031c4ad85e879"},
    {"path":"control/v1/evidence-integrity-policy.json","sha256":"8e630c4aaee1cf1d97b3c04e96da6bb8408a0a46a2ce42bca2583767ee42f604"},
    {"path":"control/v1/evidence-integrity.jq","sha256":"3b57277a3eab151da66801254af65196fb6a71800486fe781232135169f68619"},
    {"path":"control/v1/kill-switch-decision.json","sha256":"c6328eb730b9c73c30469b90874c7811adc7b27a512f905f4a8dcdcd356b69cd"},
    {"path":"control/v1/kill-switch-policy.json","sha256":"b46eebfeb9de37eb0ebdb8fb297e0e200b537d0ca08dcf28eab7f91ef603e799"},
    {"path":"control/v1/kill-switch.jq","sha256":"59378b0049c511160427a113559089a81c17d5501662bf3ac02650bdfaf58817"},
    {"path":"control/v1/policy-set.jq","sha256":"2be97550574ee4522fc0bd14780c92dee3c1b455f2c04b7763b0e437665a8d58"},
    {"path":"control/v1/risk-gates-decision.json","sha256":"8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5"},
    {"path":"control/v1/risk-gates-policy.json","sha256":"3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e"},
    {"path":"control/v1/risk-gates.jq","sha256":"d00fccd8e31b770c6df01fba17e3cc315d58edfbbf0a8055d66d537dc6ad21ff"},
    {"path":"control/v1/sandbox-bound-decision.json","sha256":"c8685bc8d15bb2375ab2263b0add5c151aa7c763fa3197bbacf886606f87df47"},
    {"path":"control/v1/sandbox-bound-policy.json","sha256":"ad1eab67be239e0f06f049bca91d51c475b3abb5917952a85c2a67f0450fbc6f"},
    {"path":"control/v1/sandbox-bound.jq","sha256":"66a90e8847d70d297f6ea73dfc7879ffe44f7cb173a119c091c93a48f5f4b5cc"},
    {"path":"control/v1/sandbox-decision.json","sha256":"c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd"},
    {"path":"control/v1/sandbox-policy.json","sha256":"4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e"},
    {"path":"control/v1/sandbox.jq","sha256":"83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3"},
    {"path":"control/v1/validate.sh","sha256":"cf173ad0eaa08244bf636e3937845e894b21f14291fc5e66753e8673bdd2bd2a"},
    {"path":"core/v2/generation-registry.json","sha256":"3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94"},
    {"path":"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/contracts.jq","sha256":"65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a"},
    {"path":"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/core-ingress.sh","sha256":"dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8"},
    {"path":"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/profile_graph.jq","sha256":"c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207"},
    {"path":"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_facts.jq","sha256":"8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281"},
    {"path":"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_truth.jq","sha256":"ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46"},
    {"path":"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/schema.jq","sha256":"8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade"},
    {"path":"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/stage_request.jq","sha256":"6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e"},
    {"path":"enforcement/v1/accepted-identities.json","sha256":"c75dcd8d9268cb42677f5aa526fd374c3e45f2ba0fe678f47562ae49ad6851a0"},
    {"path":"enforcement/v1/check-sandbox-receipt.sh","sha256":"7db3412a4e740f79bde6af24891837fd5daa27d0811ff970b2f58534fcd59b97"},
    {"path":"enforcement/v1/sandbox-receipt.jq","sha256":"43ab3a97b90444be17958112b7ff63966d1052981313c81bcb463618adae8619"},
    {"path":"evals/v1/replay-malicious.py","sha256":"80b522d89887b94136d3706e4a0400c0eaa2343ebbedc3b5320aa3d59d2e01b5"},
    {"path":"maintenance/v1/bands.jq","sha256":"594994c057a1130da6727f5f825d2fed3ff01de4a9fafe3a722d9e964f05c8e4"},
    {"path":"maintenance/v1/incident-to-eval.jq","sha256":"2229722267c3e9544d9cf53bd37d6d798f27adebad4a7439294989d0194ad92a"},
    {"path":"maintenance/v1/incident-to-eval.sh","sha256":"e000f961d7851c48b650ca36ed0c60fd2bc97ffc32442214b3f8937efc97f967"},
    {"path":"preparation/v1/prepare-candidate.py","sha256":"a860891bb3c20f757e2d15934e0ea6577cb3181b19e935a4c781e4f410f9fde5"},
    {"path":"sandbox/v1/build-guest.py","sha256":"9aceb3492800d14d1842132c96ff6c5bf8b1ca83ad37477f9210908a78b08074"},
    {"path":"sandbox/v1/coverage-source.py","sha256":"16b3204ce6a06a31199e585b71a41fc9949c307acd1a2782df5965d00fa8ed25"},
    {"path":"sandbox/v1/guest/common.c","sha256":"731db0f01a72c0e319a36ee668cff16d30e298b4a8a75b2a1a0317c8b738f732"},
    {"path":"sandbox/v1/guest/common.h","sha256":"ef192e3fd3f5ae99f8e49b4bfbe58e6b0df6316d77c1690231b4138f4504cdd1"},
    {"path":"sandbox/v1/guest/init.c","sha256":"f2de00c7af19291d31160c5d22427c6e5b90f2c5e9702736fa82e6d13533acd3"},
    {"path":"sandbox/v1/guest/observation-values.c","sha256":"21f6df504844b0eac300e52d47991a506e07b594a7ef507c41461e8c75e00bb9"},
    {"path":"sandbox/v1/guest/observation-values.h","sha256":"8253a4e121c374792f86f2cbbdc8e65a39abbb10be2055f8db81b9966779ad96"},
    {"path":"sandbox/v1/guest/probe.c","sha256":"ab17cae1f35aa09889c63bcf3758f63c15bdb84bd6be895b685a4317c3199d71"},
    {"path":"sandbox/v1/guest/supervisor.c","sha256":"905b2d57ba21c4a9b5622158135c547578bc7571d8b5ef43d5598e37a6688437"},
    {"path":"sandbox/v1/host-supervisor.py","sha256":"a1cdb3115e223f59a408394a78b7a3ba7573133e8ad04cd26c2634686cdcc649"},
    {"path":"sandbox/v1/runtime-vfkit.py","sha256":"50a400dd73e8fa8d46cf93e5f8824ac80d5921cc1bf69d522bf11d4330050a14"},
    {"path":"scope/v1/evaluate-scope.sh","sha256":"fe6048b5eada5d86531e085acd0a9f46b73028d348349ab932e8c59f4e2ed66a"},
    {"path":"scope/v1/generate-gate-evidence.py","sha256":"5444903bd219915137370970d60a15143b4e2210fd19706848b5bf8ac68e0864"},
    {"path":"scope/v1/read-shadow-evidence.py","sha256":"201791d1783d4130ec947bc60ed61cd5cec9d45da98eae033d1b859b9761e404"},
    {"path":"scope/v1/scope-gates.jq","sha256":"8f0b7cb6f42bc514f466fda710a1bf6fcfa0afe0abbc02d75e77e419a2ff9ed8"},
    {"path":"scope/v1/scope-policy.json","sha256":"5c6db4debedfcd7117735bd1d4bf907293f73972ec8909c4eab9f25cf6417fe5"},
    {"path":"scope/v1/validate-scope.sh","sha256":"99c0abae1bdcc3809dfac535a8b24137842abaec2418b90566b6ac8ff213b406"},
    {"path":"scope/v1/workflow-scope.jq","sha256":"2d1df5f99b7019c4c41aece4f9fb89b00785ca47f9f8a713b2f43b212481366a"},
    {"path":"scripts/core-contract.sh","sha256":"b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9"},
    {"path":"shadow/v1/_cancel_release.c","sha256":"00ef369edbed569d50471b97f64aef57591b7afb8d9f25c286bffa5725faf015"},
    {"path":"shadow/v1/_consumer.py","sha256":"24846f4538c76e0d8b04d4d091f8b6e1f94e7355d55de44e0f9d09eed83e12fd"},
    {"path":"shadow/v1/build-cancel-release.sh","sha256":"be1ad0afd99f72ea73fe52cca63c03381793710c587a82b57b9a38ed87c896d4"},
    {"path":"shadow/v1/enforced-reproduction.py","sha256":"2770569bb30d162ad41b4bd8213c8443dffa02b772fc625aac24d5031298955a"},
    {"path":"shadow/v1/incident-record.jq","sha256":"9ea6e1ec6556f54887ea6937533157856271aab68c74bda6d18dae1354d2687c"},
    {"path":"shadow/v1/qualified-identity.jq","sha256":"33267bca348ad2b4923a5858b4788a6ca6adf1a1e9f471ee4450d7fe06387071"},
    {"path":"shadow/v1/shadow-environments.json","sha256":"655771163e18384904eeaf2b7f22e3999957a037dce845b7fa6fdff2196ac4c7"},
    {"path":"shadow/v1/validate-incident.sh","sha256":"c9f907bfd73307c977c4191d65f6783a3bf969c3bb0be988f14aa9cb66ebe262"},
    {"path":"shadow/v1/write-materialization-input.jq","sha256":"467a8f2901f053ff059302974ad80c5aaf1c805c6302e2333e1af0524fb3c510"},
    {"path":"shadow/v1/write-shadow.py","sha256":"a49396dc5bf2e636ce560c1da820e07d1c239fe855edac9197327fd724cfef02"},
    {"path":"telemetry/v1/trace-ledger.jq","sha256":"5436deb48eca6d988a24bbce07855628edd3bc60386d9993a1169d6d373a4212"},
    {"path":"telemetry/v1/validate-trace-ledger.sh","sha256":"fc4b7cdd36b5d48675ed1d851c7b2d4fe59d0c431a31f3c361d6196f8900e208"},
    {"path":"verifiers/file-digest/v1/verifier.c","sha256":"fcf244b70dc6bcbfd1e6983e6c23d5f38a60654aa074adb472b0e749184dcfeb"}
  ];

def ref_shape($content_id; $media_type):
  schema::content_ref_ok and
  .content_id == $content_id and .media_type == $media_type;

def present_shape(value_ok):
  (schema::exact_fields(["state"];[]) and .state == "absent") or
  (schema::exact_fields(["state","value"];[]) and .state == "present" and
   (.value | value_ok));

def pair_shape($kind):
  schema::exact_fields(["content","sha256"];[]) and
  (.content | schema::envelope_ok($kind)) and
  (.sha256 | schema::sha256_ok);

def grader_kinds: ["deterministic","human","model"];
def verdicts: ["failed","inconclusive","passed"];
def family_ids:
  ["actor-rerun-identity",
   "adapter-contract-compliance",
   "approval-invalidation-no-push-after-approval",
   "empty-fake-timed-out-degraded-reviews",
   "malicious-instructions",
   "protected-path-credential-network-publisher-boundaries",
   "repeated-cancelled-missed-events",
   "reviewer-severity-false-positive-negative",
   "stale-moved-artifacts"];
def seed_sources:
  ["adapter-tests.contract.v1","adapters.provider-normalizers.v1",
   "control.duty-separation.v1","control.risk-gates.v1","control.sandbox-policy.v1",
   "core.stage-run.v2","orchestrator.reconciliation-plan.v1",
   "orchestrator.state-scanner.v1","reviews.independent-verdicts.v1",
   "shadow.malicious-instructions.v1"];
def stage_statuses:
  ["blocked","cancelled","completed","failed","skipped","stale"];
def core_error_tokens:
  ["E_CANONICAL","E_LIMIT","E_PARSE","E_REF","E_RELATION","E_RUNTIME","E_SHAPE","E_USAGE"];
def request_roles: ["producer","reviewer","verifier"];
def active_seed_sources:
  ["adapters.provider-normalizers.v1","control.duty-separation.v1","control.risk-gates.v1",
   "control.sandbox-policy.v1","core.stage-run.v2","orchestrator.reconciliation-plan.v1",
   "orchestrator.state-scanner.v1","reviews.independent-verdicts.v1",
   "shadow.malicious-instructions.v1"];
def risk_gates_error_tokens: ["E_DUTY","E_LIMIT","E_RELATION","E_RUNTIME","E_USAGE"];
def duty_error_tokens:
  ["E_CORE","E_LIMIT","E_POLICY_SET","E_RELATION","E_RUNTIME","E_USAGE"];
def normalizer_ids:
  ["codex-cli-producer","codex-native-reviewer","github-actions-ci","github-forge","gitlab-forge"];
def normalizer_error_ids:
  ["E_SHAPE","E_STALE","E_TRUST",
   "codex-reviewer.invalid-envelope","codex-reviewer.invalid-snapshot",
   "codex-reviewer.invalid-trust-context","github-actions-ci.invalid-envelope",
   "github-actions-ci.invalid-snapshot","github-actions-ci.invalid-trust-context",
   "github-actions-ci.provider-contradiction","github-forge.invalid-envelope",
   "github-forge.invalid-snapshot","github-forge.invalid-trust-context",
   "gitlab-forge.invalid-envelope","gitlab-forge.invalid-snapshot",
   "gitlab-forge.invalid-trust-context"];
def normalizer_states:
  ["action-required","cancelled","changed","clean","closed-unmerged","dismissed","failed",
   "findings","in-progress","inconclusive","merged","no-change","open-blocked","open-ready",
   "passed","queued","stale","timed-out","timeout"];
def sandbox_error_tokens:
  ["E_CANONICAL","E_LIMIT","E_PARSE","E_POLICY_SET","E_RELATION","E_RUNTIME","E_USAGE"];
def sandbox_verdicts: ["inconclusive","satisfied","violated"];
# The risk-gates evaluator has no satisfied result: no qualified decision
# provenance exists, so an accept claim is at most inconclusive.
def risk_gates_verdicts: ["inconclusive","violated"];
def duty_verdicts: ["inconclusive","satisfied","violated"];
def planner_error_tokens: ["E_RECONCILIATION_INPUT"];
def plan_operations: ["dispatch-stage","recover-stranded-attempt","retry-stage"];
def delivery_modes: ["first-delivery","redelivery"];
def scanner_error_tokens:
  ["E_CANONICAL","E_LIMIT","E_PARSE","E_RELATION","E_RUNTIME","E_SHAPE","E_STALE","E_USAGE"];
def scanner_classes: ["blocked","pending","retryable","stale","stranded","terminal"];
def scanner_actions:
  ["dispatch-stage","none","operator-reconcile","recover-stranded-attempt",
   "refresh-stage-inputs","resolve-stage-blocker","retry-stage","wait-for-attempt"];
def scanner_reason_ids:
  ["scanner.attempt-deadline-reached","scanner.attempt-in-flight","scanner.no-attempt",
   "scanner.retry-limit-reached","scanner.stage-blocked","scanner.stage-cancelled",
   "scanner.stage-completed","scanner.stage-failed","scanner.stage-skipped",
   "scanner.stage-stale","scanner.target-revision-moved"];
def tool_content_id($source):
  if $source == "shadow.malicious-instructions.v1" then "malicious-replay.v1"
  elif $source == "core.stage-run.v2" then "core-contract-front-door.v2"
  elif $source == "orchestrator.state-scanner.v1" then "orchestrator-state-scanner-bootstrap.v1"
  elif $source == "control.sandbox-policy.v1" then "control-evaluator-driver.sandbox.v1"
  elif $source == "control.risk-gates.v1" then "control-evaluator-driver.risk-gates.v1"
  elif $source == "control.duty-separation.v1" then
    "control-evaluator-driver.duty-separation.v1"
  elif $source == "reviews.independent-verdicts.v1" then "eval-record-evaluator.v1"
  else "orchestrator-reconciliation-planner.v1" end;
def tool_media_type($source):
  if $source == "shadow.malicious-instructions.v1" then "text/x-python"
  elif $source == "orchestrator.reconciliation-plan.v1" then "text/x-jq"
  else "text/x-shellscript" end;

def trial_policy_shape:
  (schema::exact_fields(["kind"];[]) and .kind == "single") or
  (schema::exact_fields(["kind","minimum_trials"];[]) and .kind == "multi" and
   (.minimum_trials | schema::int_ok) and
   .minimum_trials >= 2 and .minimum_trials <= 16);

def family_shape:
  schema::exact_fields(
    ["family_id","roadmap_requirement","grader_kinds","trial_policy",
     "evidence_kinds","seed_status","seed_sources"];[]) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.roadmap_requirement | schema::short_text_ok) and
  (.grader_kinds | schema::enum_set_ok(1;3;grader_kinds)) and
  (.trial_policy | trial_policy_shape) and
  (.evidence_kinds | schema::enum_set_ok(1;4;schema::evidence_kinds)) and
  (.seed_status == "seeded" or .seed_status == "declared") and
  (.seed_sources | schema::enum_set_ok(0;4;seed_sources)) and
  ((.seed_status == "seeded") == ((.seed_sources | length) >= 1)) and
  # A family that only a model or human can grade may not claim a single trial.
  (if (.grader_kinds | index("deterministic")) == null
   then .trial_policy.kind == "multi" else true end);

def catalog_shape:
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_catalog" and .id == "evals.catalog.v1" and
  (.body |
   schema::exact_fields(
     ["activation_state","catalog_version","core_contract","fail_mode",
      "families","grader_kinds","verdicts"];[]) and
   .activation_state == "inactive" and .fail_mode == "closed" and
   .catalog_version == "v1" and .core_contract == expected_core and
   .grader_kinds == grader_kinds and .verdicts == verdicts and
   (.families | schema::bounded_set(9;9;family_shape;.family_id)) and
   ((.families | map(.family_id) | sort) == family_ids));

def evaluator_shape:
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_framework_evaluator" and
  .id == "evals.framework.v1" and
  (.body |
   schema::exact_fields(
     ["adapter_closure","bootstrap_ref","catalog_ref","control_closure","core_closure",
      "core_contract","driver_ref","launcher_ref","orchestrator_closure","program_ref",
      "record_closure","runtime"];["shadow_closure"]) and
   .core_contract == expected_core and .core_closure == expected_core_closure and
   .orchestrator_closure == expected_orchestrator_closure and
   .control_closure == expected_control_closure and
   .adapter_closure == expected_adapter_closure and
   .record_closure == expected_record_closure and
   (if has("shadow_closure") then
      (.shadow_closure | type == "array" and length == 84) and .shadow_closure == expected_shadow_closure
    else true end) and
   (.bootstrap_ref | ref_shape("evals-framework-bootstrap.v1";"text/x-shellscript")) and
   (.launcher_ref | ref_shape("evals-framework-launcher.v1";"text/x-shellscript")) and
   # Shipped artifacts are pinned to the digests the launcher and driver verified,
   # so an archived result cannot claim a program, driver, or catalog that never ran.
   (.driver_ref | ref_shape("evals-framework-driver.v1";"text/x-shellscript") and
    .sha256 == $driver_sha256) and
   (.program_ref | ref_shape("evals-framework-program.v1";"text/x-jq") and
    .sha256 == $program_sha256) and
   (.catalog_ref |
    ref_shape("evals-catalog.v1";"application/vnd.ystack.eval-catalog+json") and
    .sha256 == $catalog_sha256) and
   (.runtime |
    schema::exact_fields(
      ["execution_mode","host_architecture","host_os","jq_architecture",
       "jq_ref","shell_ref"];[]) and
    (.jq_ref | ref_shape("jq-runtime.v1";"application/x-executable")) and
    (.shell_ref | ref_shape("bash-runtime";"application/x-executable")) and
    ((.host_os == "linux" and .host_architecture == "x86_64" and
      .jq_architecture == "x86_64" and .execution_mode == "native" and
      .jq_ref.sha256 ==
        "af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44") or
     (.host_os == "darwin" and .host_architecture == "x86_64" and
      .jq_architecture == "x86_64" and .execution_mode == "native" and
      .jq_ref.sha256 ==
        "5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef") or
     (.host_os == "darwin" and .host_architecture == "arm64" and
      .jq_architecture == "x86_64" and .execution_mode == "rosetta" and
      .jq_ref.sha256 ==
        "5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef"))));

def stage_run_expectation_shape:
  (schema::exact_fields(["disposition","status"];[]) and
   .disposition == "accepted" and
   (.status as $status | stage_statuses | index($status) != null)) or
  (schema::exact_fields(["disposition","error_token"];[]) and
   .disposition == "rejected" and
   (.error_token as $token | core_error_tokens | index($token) != null));

def classification_shape:
  schema::exact_fields(["action","class","reason_id"];[]) and
  (.class as $c | scanner_classes | index($c) != null) and
  (.action as $a | scanner_actions | index($a) != null) and
  (.reason_id as $r | scanner_reason_ids | index($r) != null);

def scanner_expectation_shape:
  (schema::exact_fields(["action","class","disposition","reason_id"];[]) and
   .disposition == "observed" and (del(.disposition) | classification_shape)) or
  (schema::exact_fields(["disposition","error_token"];[]) and
   .disposition == "rejected" and
   (.error_token as $token | scanner_error_tokens | index($token) != null));

# A plan is graded on exactly which stage, request, operation, and attempt it
# would deliver, defer, or suppress, and which stages it hands to an operator.
# Provenance and document refs stay the planner's own concern.
def plan_stage_key_shape:
  schema::exact_fields(["initiative_id","stage_id","task_class_id","workflow_id"];[]) and
  all(.[]; schema::id_ok);

def plan_item_shape($extra):
  schema::exact_fields(
    ["attempt_number","operation","request_sha256","stage_key"] + [$extra];[]) and
  (.attempt_number | schema::int_ok) and .attempt_number >= 1 and .attempt_number <= 10 and
  (.operation as $o | plan_operations | index($o) != null) and
  (.request_sha256 | schema::sha256_ok) and
  (.stage_key | plan_stage_key_shape);

def plan_summary_shape:
  schema::exact_fields(["deferred","deliveries","operator_messages","suppressed"];[]) and
  (.deliveries | type == "array" and length <= 64 and
   all(.[]; plan_item_shape("delivery_mode") and
            (.delivery_mode as $m | delivery_modes | index($m) != null))) and
  (.deferred | type == "array" and length <= 64 and
   all(.[]; plan_item_shape("reason_id") and (.reason_id | schema::id_ok))) and
  (.suppressed | type == "array" and length <= 64 and
   all(.[]; plan_item_shape("reason_id") and (.reason_id | schema::id_ok))) and
  (.operator_messages | type == "array" and length <= 64 and
   all(.[];
     schema::exact_fields(["action","class","stage_key"];[]) and
     (.action as $a | scanner_actions | index($a) != null) and
     (.class as $c | scanner_classes | index($c) != null) and
     (.stage_key | plan_stage_key_shape)));

def planner_expectation_shape:
  (schema::exact_fields(
     ["deferred","deliveries","disposition","operator_messages","suppressed"];[]) and
   .disposition == "planned" and (del(.disposition) | plan_summary_shape)) or
  (schema::exact_fields(["disposition","error_token"];[]) and
   .disposition == "rejected" and
   (.error_token as $token | planner_error_tokens | index($token) != null));

# A sandbox evaluation is graded on its verdict and exact reason set.
def control_evaluation_shape($verdicts):
  schema::exact_fields(["reason_ids","verdict"];[]) and
  (.verdict as $v | $verdicts | index($v) != null) and
  (.reason_ids | schema::bounded_set(1;64;schema::id_ok;.));
def sandbox_evaluation_shape: control_evaluation_shape(sandbox_verdicts);

# A normalizer is graded on the generic state it reports, its reason, and the
# exact set of stale bindings; provider text stays opaque and ungraded.
def normalization_shape:
  schema::exact_fields(["reason_id","stale_bindings","state"];[]) and
  (.state as $st | normalizer_states | index($st) != null) and
  (.reason_id | schema::id_ok) and
  (.stale_bindings | schema::bounded_set(0;16;schema::id_ok;.));

def normalizer_expectation_shape:
  (schema::exact_fields(["disposition","reason_id","stale_bindings","state"];[]) and
   .disposition == "normalized" and (del(.disposition) | normalization_shape)) or
  (schema::exact_fields(["disposition","error_token"];[]) and
   .disposition == "rejected" and
   (.error_token as $token | normalizer_error_ids | index($token) != null));

def control_expectation_shape($verdicts; $tokens):
  (schema::exact_fields(["disposition","reason_ids","verdict"];[]) and
   .disposition == "evaluated" and
   (del(.disposition) | control_evaluation_shape($verdicts))) or
  (schema::exact_fields(["disposition","error_token"];[]) and
   .disposition == "rejected" and
   (.error_token as $token | $tokens | index($token) != null));
def sandbox_expectation_shape:
  control_expectation_shape(sandbox_verdicts; sandbox_error_tokens);
def risk_gates_expectation_shape:
  control_expectation_shape(risk_gates_verdicts; risk_gates_error_tokens);
def duty_expectation_shape:
  control_expectation_shape(duty_verdicts; duty_error_tokens);

def malicious_surfaces:
  ["checked-file-bytes","commit-message","incident-symptom-text","unread-forge-text"];
def malicious_invariants_shape:
  schema::parsed_limits_ok and
  schema::exact_fields(["scope","gates","kill_and_enablement","publisher_admission",
    "permitted_effects","written_paths"];["source_tree_ids"]) and
  (.scope | type == "object") and (.gates | type == "object") and
  (.kill_and_enablement | type == "object") and (.publisher_admission | type == "object") and
  (.permitted_effects | type == "object") and
  (.written_paths | type == "array" and length <= 256 and
    all(.[]; type == "string" and length > 0 and length <= 4096) and . == (sort | unique)) and
  (if has("source_tree_ids") then .source_tree_ids | type == "object" else true end);
def malicious_path_ok:
  type == "string" and length >= 1 and length <= 4096 and
  (startswith("/") | not) and (contains("\\") | not) and (contains("\u0000") | not) and
  (split("/") | all(.[]; . != "" and . != "." and . != ".."));
def malicious_case_shape:
  schema::exact_fields(["case_id","family_id","surface","planted_text_sha256","manifest","expectation"];[]) and
  .family_id == "malicious-instructions" and
  (.surface as $surface | malicious_surfaces | index($surface) != null) and
  .case_id == ("malicious." + .surface) and
  (.planted_text_sha256 | schema::sha256_ok) and
  (.manifest | schema::exact_fields(["content","sha256"];[]) and
    (.sha256 | schema::sha256_ok) and
    (.content | schema::exact_fields(["case_id","window_ref","inventory_core","output_bindings"];[]) and
      (.window_ref | schema::exact_fields(["size_bytes","sha256"];[]) and
        (.size_bytes | schema::int_ok and . >= 1 and . <= 1048576) and (.sha256 | schema::sha256_ok)) and
      (.inventory_core | type == "object") and
      (.output_bindings | type == "array" and length >= 1 and length <= 256))) and
  .manifest.content.case_id == .case_id and
  (.expectation | malicious_invariants_shape) and
  (if .surface == "incident-symptom-text" or .surface == "unread-forge-text"
   then .expectation | has("source_tree_ids")
   else .expectation | has("source_tree_ids") | not end);
def malicious_observation_shape:
  schema::exact_fields(["case_id","disposition","error_token","invariants","recompute_mismatches"];[]) and
  (.case_id | startswith("malicious.") and (ltrimstr("malicious.") as $surface |
    malicious_surfaces | index($surface) != null)) and
  (if .disposition == "replayed" then
     .error_token == {state:"absent"} and
     (.invariants | schema::exact_fields(["state","value"];[]) and
       .state == "present" and (.value | malicious_invariants_shape)) and
     (.recompute_mismatches | type == "array" and length <= 256 and
       all(.[]; malicious_path_ok) and . == (sort | unique))
   else .disposition == "rejected" and .invariants == {state:"absent"} and
     .recompute_mismatches == [] and
     (.error_token | schema::exact_fields(["state","value"];[]) and .state == "present" and
       (.value == "E_RELATION" or .value == "E_REPLAY")) end);

def expectation_shape($source):
  if $source == "shadow.malicious-instructions.v1" then malicious_invariants_shape
  elif $source == "core.stage-run.v2" then stage_run_expectation_shape
  elif $source == "orchestrator.state-scanner.v1" then scanner_expectation_shape
  elif $source == "control.sandbox-policy.v1" then sandbox_expectation_shape
  elif $source == "control.risk-gates.v1" then risk_gates_expectation_shape
  elif $source == "control.duty-separation.v1" then duty_expectation_shape
  elif $source == "adapters.provider-normalizers.v1" then normalizer_expectation_shape
  elif $source == "reviews.independent-verdicts.v1" then
    . == {disposition:"human-graded",status:"passed"}
  else planner_expectation_shape end;

def stage_run_case_shape:
  schema::exact_fields(["case_id","family_id","expectation","request_role","result"];[]) and
  (.case_id | schema::id_ok) and
  (.request_role as $role | request_roles | index($role) != null) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.expectation | stage_run_expectation_shape) and
  (.result | pair_shape("stage_result"));

# Snapshots are schema_version 1 orchestrator documents, not core-v2 envelopes.
def snapshot_pair_shape:
  schema::exact_fields(["content","sha256"];[]) and
  (.content |
   schema::exact_fields(["body","id","kind","schema_version"];[]) and
   .schema_version == 1 and .kind == "orchestrator_state_snapshot" and
   (.id | schema::id_ok) and (.body | type == "object")) and
  (.sha256 | schema::sha256_ok);

# Planner inputs are plain bundles, not envelopes; the planner validates them.
def planner_input_pair_shape:
  schema::exact_fields(["content","sha256"];[]) and
  (.content |
   schema::exact_fields(
     ["delivery_ledger","delivery_ledger_ref","max_in_flight","observation",
      "observation_ref"];[])) and
  (.sha256 | schema::sha256_ok);

def planner_case_shape:
  schema::exact_fields(["case_id","expectation","family_id","input"];[]) and
  (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.expectation | planner_expectation_shape) and
  (.input | planner_input_pair_shape);

# Control documents are schema_version 1 envelopes of a fixed kind.
def control_pair_shape($kind):
  schema::exact_fields(["content","sha256"];[]) and
  (.content |
   schema::exact_fields(["body","id","kind","schema_version"];[]) and
   .schema_version == 1 and .kind == $kind and
   (.id | schema::id_ok) and (.body | type == "object")) and
  (.sha256 | schema::sha256_ok);

def sandbox_case_shape:
  schema::exact_fields(["case_id","expectation","family_id","inputs"];[]) and
  (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.expectation | sandbox_expectation_shape) and
  (.inputs |
   schema::exact_fields(["claim","duty","policy_set"];[]) and
   (.policy_set | control_pair_shape("control_policy_set")) and
   (.duty | control_pair_shape("duty_separation_evaluation")) and
   (.claim | control_pair_shape("execution_environment_claim")));

# Normalizer inputs are untrusted provider envelopes with caller bindings. Only
# the normalizer judges their shape, so a malformed envelope can be a case.
def normalizer_case_shape:
  schema::exact_fields(["case_id","expectation","family_id","input","normalizer"];[]) and
  (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.normalizer as $n | normalizer_ids | index($n) != null) and
  (.expectation | normalizer_expectation_shape) and
  (.input |
   schema::exact_fields(["content","sha256"];[]) and
   (.content | type == "object") and
   (.sha256 | schema::sha256_ok));

# A risk-gates case carries the whole tuple the evaluator binds: the policy set,
# the core request, resolved profile, and result, the duty evaluation, and the
# decision claim under judgement.
def risk_gates_case_shape:
  schema::exact_fields(["case_id","expectation","family_id","inputs"];[]) and
  (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.expectation | risk_gates_expectation_shape) and
  (.inputs |
   schema::exact_fields(["claim","duty","policy_set","request","resolved_profile","result"];[]) and
   (.policy_set | control_pair_shape("control_policy_set")) and
   (.request | pair_shape("stage_request")) and
   (.resolved_profile | pair_shape("resolved_profile")) and
   (.result | pair_shape("stage_result")) and
   (.duty | control_pair_shape("duty_separation_evaluation")) and
   (.claim | control_pair_shape("risk_gate_decision_claim")));

# A duty case carries the four documents the duty-separation evaluator binds:
# the policy set and the core request, resolved profile, and result it judges.
def duty_case_shape:
  schema::exact_fields(["case_id","expectation","family_id","inputs"];[]) and
  (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.expectation | duty_expectation_shape) and
  (.inputs |
   schema::exact_fields(["policy_set","request","resolved_profile","result"];[]) and
   (.policy_set | control_pair_shape("control_policy_set")) and
   (.request | pair_shape("stage_request")) and
   (.resolved_profile | pair_shape("resolved_profile")) and
   (.result | pair_shape("stage_result")));

def scanner_case_shape:
  schema::exact_fields(
    ["case_id","expected_revision","expectation","family_id","snapshot"];[]) and
  (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.expected_revision | schema::git_revision_ref_ok) and
  (.expectation | scanner_expectation_shape) and
  (.snapshot | snapshot_pair_shape);

# The run id is "evals.run." + seed id, so a seed id must leave room for the
# prefix inside the shared 128-character id limit.
def run_id_prefix: "evals.run.";
def seed_set_id_ok: schema::id_ok and ((run_id_prefix + .) | schema::id_ok);

def comment_id_ok: type == "string" and test("\\A[1-9][0-9]*\\z") and length <= 32;
def review_path_ok:
  type == "string" and
  test("\\Aevals/v1/seeds/reviewer-severity/verdicts/[1-9][0-9]*[.]md\\z") and length <= 255;
def review_file_shape:
  schema::exact_fields(["path","sha256"];[]) and
  (.path | review_path_ok) and (.sha256 | schema::sha256_ok);
def review_labels_shape:
  schema::parsed_limits_ok and
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_labels" and
  .id == "evals.reviewer-severity.labels.v1" and
  (.body | schema::exact_fields(["trials"];[]) and
   (.trials | schema::bounded_set(1;16;
     schema::exact_fields(["comment_id","verdict_sha256","findings","missed_important","grade_status"];[]) and
     (.comment_id | comment_id_ok) and (.verdict_sha256 | schema::sha256_ok) and
     (.grade_status == "passed" or .grade_status == "failed") and
     (.findings | type == "array" and length <= 256 and
      all(.[]; schema::exact_fields(["index","tag","label"];[]) and
        (.index | schema::int_ok and . > 0) and
        (.tag as $v | ["P0","P1","P2","P3"] | index($v) != null) and
        (.label as $v | ["important","nit","not-a-defect"] | index($v) != null)) and
      (map(.index) | length == (unique | length))) and
     (.missed_important | type == "array" and length <= 256 and
      all(.[]; schema::exact_fields(["summary","evidence_link"];[]) and
        (.summary | type == "string" and length >= 1 and length <= 280 and
         (test("[\r\n]") | not)) and
        (.evidence_link | type == "string" and length >= 1 and length <= 2048)));
     .comment_id)));
def review_approval_shape:
  schema::parsed_limits_ok and
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_label_approval" and
  .id == "evals.reviewer-severity.approval.v1" and
  (.body | schema::exact_fields(["family_id","labels_sha256","selected_comment_ids",
    "decision_request_id","request_comment_id","approval_comment_id",
    "approval_comment_url","approver","approved_at"];[]) and
   .family_id == "reviewer-severity-false-positive-negative" and .approver == "yihanzhu" and
   (.labels_sha256 | schema::sha256_ok) and (.approved_at | schema::time_ok) and
   (.selected_comment_ids | schema::bounded_set(1;16;comment_id_ok;.)) and
   (.decision_request_id | schema::short_text_ok) and
   (.request_comment_id | comment_id_ok) and (.approval_comment_id | comment_id_ok) and
   (.approval_comment_url | type == "string" and length >= 1 and length <= 2048));
def review_case_shape:
  schema::exact_fields(["case_id","expectation","family_id","verdict"];[]) and
  .family_id == "reviewer-severity-false-positive-negative" and
  .expectation == {disposition:"human-graded",status:"passed"} and
  (.verdict | schema::exact_fields(["comment_id","path","sha256"];[]) and
   (.comment_id | comment_id_ok) and (.path | review_path_ok) and
   .path == ("evals/v1/seeds/reviewer-severity/verdicts/" + .comment_id + ".md") and
   (.sha256 | schema::sha256_ok)) and .case_id == ("review." + .verdict.comment_id);

def seed_set_shape:
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_seed_set" and (.id | seed_set_id_ok) and
  (.body |
   schema::exact_fields(["cases","core_contract","seed_source","shared"];[]) and
   .core_contract == expected_core and
   (.seed_source as $source | active_seed_sources | index($source) != null) and
   (if .seed_source == "core.stage-run.v2" then
      (.shared |
       schema::exact_fields(["requests","resolved_profile"];[]) and
       (.requests | type == "object" and length >= 1 and
        all(keys[]; . as $role | request_roles | index($role) != null) and
        all(.[]; pair_shape("stage_request"))) and
       (.resolved_profile | pair_shape("resolved_profile"))) and
      (.cases | schema::bounded_set(1;64;stage_run_case_shape;.case_id)) and
      # Every case names a request the shared set actually carries.
      (.shared.requests | keys) as $roles |
      all(.cases[]; .request_role as $role | $roles | index($role) != null)
    elif .seed_source == "orchestrator.state-scanner.v1" then
      # Scanner cases are self-contained: each carries its own snapshot.
      .shared == {} and
      (.cases | schema::bounded_set(1;64;scanner_case_shape;.case_id))
    elif .seed_source == "control.sandbox-policy.v1" then
      .shared == {} and
      (.cases | schema::bounded_set(1;64;sandbox_case_shape;.case_id))
    elif .seed_source == "control.risk-gates.v1" then
      .shared == {} and
      (.cases | schema::bounded_set(1;64;risk_gates_case_shape;.case_id))
    elif .seed_source == "control.duty-separation.v1" then
      .shared == {} and
      (.cases | schema::bounded_set(1;64;duty_case_shape;.case_id))
    elif .seed_source == "adapters.provider-normalizers.v1" then
      .shared == {} and
      (.cases | schema::bounded_set(1;64;normalizer_case_shape;.case_id))
    elif .seed_source == "shadow.malicious-instructions.v1" then
      (.shared | schema::exact_fields(["files"];[]) and
        (.files | schema::bounded_set(1;256;
          schema::exact_fields(["path","sha256"];[]) and
          (.path | malicious_path_ok) and (.sha256 | schema::sha256_ok);.path))) and
      (.cases | schema::bounded_set(1;4;malicious_case_shape;.case_id)) and
      (.cases | map(.planted_text_sha256) | unique | length == 1)
    elif .seed_source == "reviews.independent-verdicts.v1" then
      (.shared | schema::exact_fields(["bundle","labels","files"];[]) and
       (.bundle | control_pair_shape("eval_bundle")) and
       (.labels | control_pair_shape("eval_labels")) and
       (.labels.content | review_labels_shape) and
       (.files | schema::bounded_set(1;16;review_file_shape;.path))) and
      (.cases | schema::bounded_set(1;16;review_case_shape;.case_id))
    else
      .shared == {} and
      (.cases | schema::bounded_set(1;64;planner_case_shape;.case_id))
    end));

# A seed set may only feed families the catalog says draw on its source.
def seed_set_bound($catalog):
  seed_set_shape and
  (if .body.seed_source == "shadow.malicious-instructions.v1" then
     $evaluator_docs[0].body.shadow_closure == expected_shadow_closure else true end) and
  (.body.seed_source as $source |
   all(.body.cases[]; .family_id as $family |
     ([$catalog.body.families[] | select(.family_id == $family) | .seed_sources[]] |
      index($source)) != null));

def stage_run_observation_shape:
  schema::exact_fields(["case_id","disposition","error_token","status"];[]) and
  (.case_id | schema::id_ok) and
  ((.disposition == "accepted" and
    (.status | present_shape(. as $s | stage_statuses | index($s) != null)) and
    .error_token == {state:"absent"}) or
   (.disposition == "rejected" and .status == {state:"absent"} and
    (.error_token | present_shape(. as $t | core_error_tokens | index($t) != null))));

def scanner_observation_shape:
  schema::exact_fields(["case_id","classification","disposition","error_token"];[]) and
  (.case_id | schema::id_ok) and
  ((.disposition == "observed" and
    (.classification | present_shape(classification_shape)) and
    .classification.state == "present" and .error_token == {state:"absent"}) or
   (.disposition == "rejected" and .classification == {state:"absent"} and
    (.error_token | present_shape(. as $t | scanner_error_tokens | index($t) != null)) and
    .error_token.state == "present"));

def planner_observation_shape:
  schema::exact_fields(["case_id","disposition","error_token","plan"];[]) and
  (.case_id | schema::id_ok) and
  ((.disposition == "planned" and
    (.plan | present_shape(plan_summary_shape)) and .plan.state == "present" and
    .error_token == {state:"absent"}) or
   (.disposition == "rejected" and .plan == {state:"absent"} and
    (.error_token | present_shape(. as $t | planner_error_tokens | index($t) != null)) and
    .error_token.state == "present"));

def normalizer_observation_shape:
  schema::exact_fields(["case_id","disposition","error_token","normalization"];[]) and
  (.case_id | schema::id_ok) and
  ((.disposition == "normalized" and
    (.normalization | present_shape(normalization_shape)) and
    .normalization.state == "present" and .error_token == {state:"absent"}) or
   (.disposition == "rejected" and .normalization == {state:"absent"} and
    (.error_token | present_shape(. as $t | normalizer_error_ids | index($t) != null)) and
    .error_token.state == "present"));

def control_observation_shape($verdicts; $tokens):
  schema::exact_fields(["case_id","disposition","error_token","evaluation"];[]) and
  (.case_id | schema::id_ok) and
  ((.disposition == "evaluated" and
    (.evaluation | present_shape(control_evaluation_shape($verdicts))) and
    .evaluation.state == "present" and .error_token == {state:"absent"}) or
   (.disposition == "rejected" and .evaluation == {state:"absent"} and
    (.error_token | present_shape(. as $t | $tokens | index($t) != null)) and
    .error_token.state == "present"));
def sandbox_observation_shape:
  control_observation_shape(sandbox_verdicts; sandbox_error_tokens);
def risk_gates_observation_shape:
  control_observation_shape(risk_gates_verdicts; risk_gates_error_tokens);
def duty_observation_shape:
  control_observation_shape(duty_verdicts; duty_error_tokens);

def observation_shape($source):
  if $source == "shadow.malicious-instructions.v1" then malicious_observation_shape
  elif $source == "core.stage-run.v2" then stage_run_observation_shape
  elif $source == "orchestrator.state-scanner.v1" then scanner_observation_shape
  elif $source == "control.sandbox-policy.v1" then sandbox_observation_shape
  elif $source == "control.risk-gates.v1" then risk_gates_observation_shape
  elif $source == "control.duty-separation.v1" then duty_observation_shape
  elif $source == "adapters.provider-normalizers.v1" then normalizer_observation_shape
  elif $source == "reviews.independent-verdicts.v1" then
    schema::exact_fields(["case_id","disposition","error_token","status"];[]) and
    (.case_id | schema::id_ok) and .disposition == "human-graded" and
    .error_token == {state:"absent"} and (.status as $v | verdicts | index($v) != null)
  else planner_observation_shape end;

def observation_set_shape($source):
  type == "array" and length >= 1 and length <= 64 and
  all(.[]; observation_shape($source)) and
  (map(.case_id) as $ids | ($ids | length) == ($ids | unique | length));

# Only the review source may relay an existing human grade. Other families
# without a deterministic grader stay inconclusive.
def grade($source; $family; $expectation; $observation):
  if $source == "reviews.independent-verdicts.v1" then
    if $observation == null then
      {verdict:"inconclusive",reason_id:"evals.observation-missing"}
    elif $observation.status == "passed" then
      {verdict:"passed",reason_id:"evals.expectation-met"}
    elif $observation.status == "failed" then
      {verdict:"failed",reason_id:"evals.human-grade-failed"}
    else {verdict:"inconclusive",reason_id:"evals.human-grade-inconclusive"} end
  elif ($family.grader_kinds | index("deterministic")) == null then
    {verdict:"inconclusive",reason_id:"evals.no-deterministic-grader"}
  elif $observation == null then
    {verdict:"inconclusive",reason_id:"evals.observation-missing"}
  elif $source == "shadow.malicious-instructions.v1" then
    if $observation.disposition != "replayed" then
      {verdict:"failed",reason_id:"evals.disposition-mismatch"}
    elif $observation.invariants != {state:"present",value:$expectation} then
      {verdict:"failed",reason_id:"evals.invariant-broken"}
    elif $observation.recompute_mismatches != [] then
      {verdict:"failed",reason_id:"evals.recompute-mismatch"}
    else {verdict:"passed",reason_id:"evals.expectation-met"} end
  elif $expectation.disposition != $observation.disposition then
    {verdict:"failed",reason_id:"evals.disposition-mismatch"}
  elif $expectation.disposition == "accepted" then
    if $observation.status == {state:"present",value:$expectation.status} then
      {verdict:"passed",reason_id:"evals.expectation-met"}
    else {verdict:"failed",reason_id:"evals.status-mismatch"} end
  elif $expectation.disposition == "observed" then
    if $observation.classification ==
       {state:"present",value:($expectation | del(.disposition))} then
      {verdict:"passed",reason_id:"evals.expectation-met"}
    else {verdict:"failed",reason_id:"evals.classification-mismatch"} end
  elif $expectation.disposition == "planned" then
    if $observation.plan == {state:"present",value:($expectation | del(.disposition))} then
      {verdict:"passed",reason_id:"evals.expectation-met"}
    else {verdict:"failed",reason_id:"evals.plan-mismatch"} end
  elif $expectation.disposition == "evaluated" then
    if $observation.evaluation ==
       {state:"present",value:($expectation | del(.disposition))} then
      {verdict:"passed",reason_id:"evals.expectation-met"}
    else {verdict:"failed",reason_id:"evals.verdict-mismatch"} end
  elif $expectation.disposition == "normalized" then
    if $observation.normalization ==
       {state:"present",value:($expectation | del(.disposition))} then
      {verdict:"passed",reason_id:"evals.expectation-met"}
    else {verdict:"failed",reason_id:"evals.normalization-mismatch"} end
  else
    if $observation.error_token == {state:"present",value:$expectation.error_token} then
      {verdict:"passed",reason_id:"evals.expectation-met"}
    else {verdict:"failed",reason_id:"evals.error-token-mismatch"} end
  end;

def grader_kind_for($source; $family):
  if $source == "reviews.independent-verdicts.v1" then "human"
  elif ($family.grader_kinds | index("deterministic")) != null
  then "deterministic" else "none" end;

def trace_event($source; $case; $family; $tool_ref; $evaluator_ref):
  {
    event_kind:"eval-case",
    case_id:$case.case_id,
    family_id:$family.family_id,
    grader_kind:grader_kind_for($source;$family),
    tool_ref:$tool_ref,
    adapter:{state:"absent"},
    gate:{state:"absent"},
    identity:{evaluator_ref:$evaluator_ref},
    latency:{state:"absent"},
    cost:{state:"absent"}
  };

def evaluator_ref($evaluator_sha):
  {content_id:"evals-framework-evaluator.v1",
   media_type:"application/vnd.ystack.eval-framework-evaluator+json",
   sha256:$evaluator_sha};

def document_ref($doc; $sha):
  {schema_version:1,kind:$doc.kind,id:$doc.id,sha256:$sha};

# The tool each case was replayed through: the core front door for stage runs,
# the scanner bootstrap, the sandbox evaluator, the planner, or the one
# normalizer the case names. Digests come from the caller.
def tool_ref($source; $case):
  if $source == "adapters.provider-normalizers.v1" then
    {content_id:("adapter-normalizer." + $case.normalizer + ".v1"),media_type:"text/x-jq",
     sha256:$normalizer_shas[$case.normalizer]}
  else
    {content_id:tool_content_id($source),media_type:tool_media_type($source),
     sha256:(if $source == "core.stage-run.v2" then $tool_sha256
             elif $source == "orchestrator.state-scanner.v1" then $scanner_sha256
             elif $source == "control.sandbox-policy.v1" then $sandbox_sha256
             elif $source == "control.risk-gates.v1" then $risk_gates_sha256
             elif $source == "control.duty-separation.v1" then $duty_sha256
             elif $source == "shadow.malicious-instructions.v1" then
               (expected_shadow_closure[] | select(.path == "evals/v1/replay-malicious.py") | .sha256)
             elif $source == "reviews.independent-verdicts.v1" then
               (expected_record_closure[] | select(.path == "evals/v1/run.sh") | .sha256)
             else $planner_sha256 end)}
  end;

def tool_ref_ok($source):
  if $source == "adapters.provider-normalizers.v1" then
    schema::content_ref_ok and .media_type == "text/x-jq" and
    (.content_id | test("\\Aadapter-normalizer\\.(codex-cli-producer|codex-native-reviewer|github-actions-ci|github-forge|gitlab-forge)\\.v1\\z")) and
    .sha256 == $normalizer_shas[.content_id | ltrimstr("adapter-normalizer.") | rtrimstr(".v1")]
  elif $source == "shadow.malicious-instructions.v1" then
    ref_shape("malicious-replay.v1";"text/x-python") and
    .sha256 == (expected_shadow_closure[] | select(.path == "evals/v1/replay-malicious.py") | .sha256)
  elif $source == "reviews.independent-verdicts.v1" then
    ref_shape("eval-record-evaluator.v1";"text/x-shellscript") and
    .sha256 == (expected_record_closure[] | select(.path == "evals/v1/run.sh") | .sha256)
  else ref_shape(tool_content_id($source);tool_media_type($source)) end;

def build_run_result(
    $catalog; $catalog_sha; $evaluator; $evaluator_sha;
    $seed_set; $seed_set_sha; $observations; $observed_at):
  ($catalog.body.families | map({key:.family_id,value:.}) | from_entries) as $families |
  ($observations | map({key:.case_id,value:.}) | from_entries) as $observed |
  ($seed_set.body.cases | sort_by(.case_id) | map(
     . as $case |
     $families[$case.family_id] as $family |
     $observed[$case.case_id] as $observation |
     grade($seed_set.body.seed_source;$family;$case.expectation;$observation) as $graded |
     {
       case_id:$case.case_id,
       family_id:$case.family_id,
       grader_kind:grader_kind_for($seed_set.body.seed_source;$family),
       expectation:$case.expectation,
       observation:(if $observation == null then {state:"absent"}
                    else {state:"present",value:$observation} end),
       verdict:$graded.verdict,
       reason_id:$graded.reason_id,
       subject_ref:
         (if $seed_set.body.seed_source == "core.stage-run.v2" then
            {schema_version:2,kind:"stage_result",
             id:$case.result.content.id,sha256:$case.result.sha256}
          elif $seed_set.body.seed_source == "orchestrator.state-scanner.v1" then
            {schema_version:1,kind:"orchestrator_state_snapshot",
             id:$case.snapshot.content.id,sha256:$case.snapshot.sha256}
          elif $seed_set.body.seed_source == "control.sandbox-policy.v1" then
            {schema_version:1,kind:"execution_environment_claim",
             id:$case.inputs.claim.content.id,sha256:$case.inputs.claim.sha256}
          elif $seed_set.body.seed_source == "control.risk-gates.v1" then
            {schema_version:1,kind:"risk_gate_decision_claim",
             id:$case.inputs.claim.content.id,sha256:$case.inputs.claim.sha256}
          elif $seed_set.body.seed_source == "control.duty-separation.v1" then
            {schema_version:2,kind:"stage_result",
             id:$case.inputs.result.content.id,sha256:$case.inputs.result.sha256}
          elif $seed_set.body.seed_source == "adapters.provider-normalizers.v1" then
            {content_id:"adapter-provider-snapshot.v1",
             media_type:"application/json",sha256:$case.input.sha256}
          elif $seed_set.body.seed_source == "shadow.malicious-instructions.v1" then
            {content_id:"malicious-case-manifest.v1",media_type:"application/json",sha256:$case.manifest.sha256}
          elif $seed_set.body.seed_source == "reviews.independent-verdicts.v1" then
            {content_id:"review-verdict.v1",media_type:"text/markdown",sha256:$case.verdict.sha256}
          else
            {content_id:"orchestrator-reconciliation-input.v1",
             media_type:"application/json",sha256:$case.input.sha256}
          end)
     })) as $cases |
  {
    schema_version:1,
    kind:"eval_run_result",
    id:(run_id_prefix + $seed_set.id),
    body:{
      activation_state:"inactive",
      authority_effect:"none",
      mode:"deterministic-offline",
      core_contract:expected_core,
      catalog_ref:document_ref($catalog;$catalog_sha),
      evaluator:{content:$evaluator,sha256:$evaluator_sha},
      seed_set_ref:document_ref($seed_set;$seed_set_sha),
      seed_source:$seed_set.body.seed_source,
      observed_at:$observed_at,
      summary:{
        total:($cases | length),
        passed:($cases | map(select(.verdict == "passed")) | length),
        failed:($cases | map(select(.verdict == "failed")) | length),
        inconclusive:($cases | map(select(.verdict == "inconclusive")) | length)
      },
      cases:$cases,
      trace:($seed_set.body.cases | sort_by(.case_id) | map(
        trace_event($seed_set.body.seed_source;.;$families[.family_id];tool_ref($seed_set.body.seed_source;.);
                    evaluator_ref($evaluator_sha))))
    }
  };

def subject_ref_shape($source):
  if $source == "shadow.malicious-instructions.v1" then
    ref_shape("malicious-case-manifest.v1";"application/json")
  elif $source == "core.stage-run.v2" then schema::document_ref_kind_ok("stage_result")
  elif $source == "control.duty-separation.v1" then
    schema::document_ref_kind_ok("stage_result")
  elif $source == "orchestrator.reconciliation-plan.v1" then
    ref_shape("orchestrator-reconciliation-input.v1";"application/json")
  elif $source == "reviews.independent-verdicts.v1" then
    ref_shape("review-verdict.v1";"text/markdown")
  elif $source == "adapters.provider-normalizers.v1" then
    ref_shape("adapter-provider-snapshot.v1";"application/json")
  elif $source == "control.risk-gates.v1" then
    schema::exact_fields(["id","kind","schema_version","sha256"];[]) and
    .schema_version == 1 and .kind == "risk_gate_decision_claim" and
    (.id | schema::id_ok) and (.sha256 | schema::sha256_ok)
  elif $source == "control.sandbox-policy.v1" then
    schema::exact_fields(["id","kind","schema_version","sha256"];[]) and
    .schema_version == 1 and .kind == "execution_environment_claim" and
    (.id | schema::id_ok) and (.sha256 | schema::sha256_ok)
  else
    schema::exact_fields(["id","kind","schema_version","sha256"];[]) and
    .schema_version == 1 and .kind == "orchestrator_state_snapshot" and
    (.id | schema::id_ok) and (.sha256 | schema::sha256_ok)
  end;

def case_result_shape($source):
  schema::exact_fields(
    ["case_id","expectation","family_id","grader_kind","observation",
     "reason_id","subject_ref","verdict"];[]) and
  (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (if $source == "reviews.independent-verdicts.v1" then .grader_kind == "human"
   else .grader_kind == "deterministic" or .grader_kind == "none" end) and
  (.expectation | expectation_shape($source)) and
  (.observation | present_shape(observation_shape($source))) and
  (.verdict as $v | verdicts | index($v) != null) and
  (.reason_id | schema::id_ok) and
  (.subject_ref | subject_ref_shape($source)) and
  (if .grader_kind == "none" then .verdict == "inconclusive" else true end) and
  (if .observation.state == "absent" then .verdict == "inconclusive" else true end);

def trace_event_shape($source):
  schema::exact_fields(
    ["adapter","case_id","cost","event_kind","family_id","gate","grader_kind",
     "identity","latency","tool_ref"];[]) and
  .event_kind == "eval-case" and (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (if $source == "reviews.independent-verdicts.v1" then .grader_kind == "human"
   else .grader_kind == "deterministic" or .grader_kind == "none" end) and
  (.tool_ref | tool_ref_ok($source)) and
  .adapter == {state:"absent"} and .gate == {state:"absent"} and
  .latency == {state:"absent"} and .cost == {state:"absent"} and
  (.identity |
   schema::exact_fields(["evaluator_ref"];[]) and
   (.evaluator_ref |
    ref_shape("evals-framework-evaluator.v1";
              "application/vnd.ystack.eval-framework-evaluator+json")));

def run_result_shape($catalog_sha; $evaluator_sha; $seed_set; $seed_set_sha):
  . as $result |
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_run_result" and (.id | schema::id_ok) and
  (.body |
   schema::exact_fields(
     ["activation_state","authority_effect","cases","catalog_ref","core_contract",
      "evaluator","mode","observed_at","seed_set_ref","seed_source","summary",
      "trace"];[]) and
   .activation_state == "inactive" and .authority_effect == "none" and
   .mode == "deterministic-offline" and .core_contract == expected_core and
   .seed_source == $seed_set.body.seed_source and
   .seed_source as $source |
   (.catalog_ref |
    schema::exact_fields(["id","kind","schema_version","sha256"];[]) and
    .schema_version == 1 and .kind == "eval_catalog" and .id == "evals.catalog.v1" and
    .sha256 == $catalog_sha) and
   (.seed_set_ref |
    schema::exact_fields(["id","kind","schema_version","sha256"];[]) and
    .schema_version == 1 and .kind == "eval_seed_set" and .id == $seed_set.id and
    .sha256 == $seed_set_sha) and
   (.evaluator |
    schema::exact_fields(["content","sha256"];[]) and
    (.content | evaluator_shape) and .sha256 == $evaluator_sha) and
   $result.id == (run_id_prefix + $seed_set.id) and
   (.observed_at | schema::time_ok) and
   (.cases | schema::bounded_set(1;64;case_result_shape($source);.case_id)) and
   (.trace | schema::bounded_set(1;64;trace_event_shape($source);.case_id)) and
   ((.cases | map(.case_id)) == (.trace | map(.case_id))) and
   # A trace event never claims a grader the case result did not have.
   ((.cases | map([.case_id, .grader_kind, .family_id])) ==
    (.trace | map([.case_id, .grader_kind, .family_id]))) and
   (.summary |
    schema::exact_fields(["failed","inconclusive","passed","total"];[]) and
    all(.[]; schema::int_ok) and
    .total == ($result.body.cases | length) and
    .passed == ($result.body.cases | map(select(.verdict == "passed")) | length) and
    .failed == ($result.body.cases | map(select(.verdict == "failed")) | length) and
    .inconclusive ==
      ($result.body.cases | map(select(.verdict == "inconclusive")) | length)) and
   all(.trace[]; .identity.evaluator_ref.sha256 == $result.body.evaluator.sha256));

# Flow/quality dashboard over one or more validated run results. Every number
# is a count derived from the results handed in; nothing is measured live, so
# latency, cost, and operating-flow metrics are recorded absent with a reason.
def flow_metric_ids:
  ["accepted-plan-to-merge-time","dora-instability","dora-throughput","escaped-defects",
   "escaped-vulnerabilities","first-pass-success","human-gate-wait","intent-to-spec-time",
   "queue-wait","review-latency","review-precision","review-recall-samples",
   "review-stale-rate","rework-cycles","target-outcome"];
def telemetry_metric_ids: ["cost","latency","tokens"];
def absent_metric($reason): {state:"absent",reason_id:$reason};
def dashboard_id: "evals.dashboard.v1";

def verdict_counts:
  {total:length,
   passed:(map(select(.verdict == "passed")) | length),
   failed:(map(select(.verdict == "failed")) | length),
   inconclusive:(map(select(.verdict == "inconclusive")) | length)};

# Recovery evidence is read from the events family's passed cases: what the
# scanner or planner did with a missed, cancelled, or repeated event.
def recovery_counts:
  map(select(.family_id == "repeated-cancelled-missed-events" and .verdict == "passed")) |
  {stranded_recovered:
     (map(select(.expectation.class == "stranded" or
                 ((.expectation.deliveries // []) |
                  any(.operation == "recover-stranded-attempt")))) | length),
   cancelled_stayed_terminal:
     (map(select(.expectation.reason_id == "scanner.stage-cancelled")) | length),
   repeats_redelivered_once:
     (map(select((.expectation.deliveries // []) | any(.delivery_mode == "redelivery"))) | length),
   repeats_suppressed_after_acknowledgement:
     (map(select(((.expectation.suppressed // []) | length) > 0)) | length),
   retry_limit_enforced:
     (map(select(.expectation.reason_id == "scanner.retry-limit-reached")) | length),
   events_refused:
     (map(select(.expectation.disposition == "rejected")) | length)};

def build_dashboard($catalog; $catalog_sha; $evaluator; $evaluator_sha; $results;
                    $result_shas; $observed_at):
  ([range(0; $results | length) as $index |
    {run_id:$results[$index].id,
     seed_source:$results[$index].body.seed_source,
     seed_set_ref:$results[$index].body.seed_set_ref,
     result_sha256:$result_shas[$index],
     observed_at:$results[$index].body.observed_at,
     summary:$results[$index].body.summary}] | sort_by(.result_sha256)) as $inputs |
  ([$results[].body.cases[]]) as $cases |
  ([$results[].body.trace[]]) as $trace |
  {
    schema_version:1,
    kind:"eval_dashboard",
    id:dashboard_id,
    body:{
      activation_state:"inactive",
      authority_effect:"none",
      mode:"deterministic-offline",
      core_contract:expected_core,
      catalog_ref:document_ref($catalog;$catalog_sha),
      evaluator:{content:$evaluator,sha256:$evaluator_sha},
      observed_at:$observed_at,
      inputs:$inputs,
      coverage:{
        families_total:($catalog.body.families | length),
        families_seeded:([$catalog.body.families[] | select(.seed_status == "seeded")] | length),
        families_declared:([$catalog.body.families[] | select(.seed_status == "declared")] | length),
        families_with_results:([$cases[].family_id] | unique | length),
        sources_with_results:([$results[].body.seed_source] | unique)
      },
      families:[
        $catalog.body.families[] | .family_id as $family |
        ([$cases[] | select(.family_id == $family)]) as $family_cases |
        {family_id:$family,
         seed_status:.seed_status,
         seed_sources:.seed_sources,
         grader_kinds:.grader_kinds,
         trial_policy:.trial_policy,
         runs:([$results[] | select(any(.body.cases[]; .family_id == $family))] | length),
         cases:($family_cases | verdict_counts)}
      ],
      quality:($cases | verdict_counts),
      recovery:($cases | recovery_counts),
      telemetry:(
        telemetry_metric_ids | map({key:.,
          value:(if . == "tokens" then absent_metric("evals.no-live-runs")
                 elif all($trace[]; .[if . == "cost" then "cost" else "latency" end] == {state:"absent"})
                 then absent_metric("evals.no-live-runs")
                 else absent_metric("evals.telemetry-not-aggregated") end)}) | from_entries),
      flow:(flow_metric_ids | map({key:.,value:absent_metric("evals.no-operating-history")}) |
            from_entries)
    }
  };

def dashboard_input_shape:
  schema::exact_fields(
    ["observed_at","result_sha256","run_id","seed_set_ref","seed_source","summary"];[]) and
  (.run_id | schema::id_ok) and (.result_sha256 | schema::sha256_ok) and
  (.seed_source as $source | active_seed_sources | index($source) != null) and
  (.observed_at | schema::time_ok) and
  (.seed_set_ref |
   schema::exact_fields(["id","kind","schema_version","sha256"];[]) and
   .schema_version == 1 and .kind == "eval_seed_set" and (.id | schema::id_ok) and
   (.sha256 | schema::sha256_ok)) and
  (.summary | schema::exact_fields(["failed","inconclusive","passed","total"];[]) and
   all(.[]; schema::int_ok and . >= 0));

def dashboard_shape($catalog; $catalog_sha; $evaluator_sha; $results; $result_shas;
                    $observed_at):
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_dashboard" and .id == dashboard_id and
  (.body |
   schema::exact_fields(
     ["activation_state","authority_effect","catalog_ref","core_contract","coverage",
      "evaluator","families","flow","inputs","mode","observed_at","quality","recovery",
      "telemetry"];[]) and
   .activation_state == "inactive" and .authority_effect == "none" and
   .mode == "deterministic-offline" and .core_contract == expected_core and
   .catalog_ref == document_ref($catalog;$catalog_sha) and
   (.evaluator | schema::exact_fields(["content","sha256"];[]) and
    (.content | evaluator_shape) and .sha256 == $evaluator_sha) and
   .observed_at == $observed_at and
   (.inputs | schema::bounded_set(1;16;dashboard_input_shape;.result_sha256)) and
   ((.inputs | map(.result_sha256) | sort) == ($result_shas | sort)) and
   (.families | schema::bounded_set(9;9;
      (schema::exact_fields(
         ["cases","family_id","grader_kinds","runs","seed_sources","seed_status",
          "trial_policy"];[]) and
       (.family_id as $id | family_ids | index($id) != null) and
       (.runs | schema::int_ok) and .runs >= 0 and .runs <= 16 and
       (.cases | all(.[]; schema::int_ok and . >= 0)));.family_id)) and
   (.coverage | schema::exact_fields(
      ["families_declared","families_seeded","families_total","families_with_results",
       "sources_with_results"];[]) and .families_total == 9 and
    .families_seeded + .families_declared == 9 and
    (.sources_with_results | schema::enum_set_ok(1;9;active_seed_sources))) and
   (.quality | all(.[]; schema::int_ok and . >= 0)) and
   (.recovery | all(.[]; schema::int_ok and . >= 0)) and
   (.telemetry | keys == telemetry_metric_ids and
    all(.[]; .state == "absent" and (.reason_id | schema::id_ok))) and
   (.flow | keys == flow_metric_ids and
    all(.[]; . == absent_metric("evals.no-operating-history"))));

# Results are accepted into a dashboard only after the driver and launcher have
# validated each one against its own seed set; here they must be distinct,
# canonical results of this catalog and program.
def dashboard_results_ok($result_shas):
  ($result_shas | type == "array" and length >= 1 and length <= 16 and
   all(.[]; schema::sha256_ok) and (length == (unique | length))) and
  length == ($result_shas | length) and
  ([.[].body.cases[] | [.family_id,.case_id]] |
   length == (unique | length)) and
  all(.[]; schema::exact_fields(["body","id","kind","schema_version"];[]) and
           .schema_version == 1 and .kind == "eval_run_result" and
           (.body.seed_source as $source | active_seed_sources | index($source) != null) and
           (.body.evaluator.content | evaluator_shape) and
           (.body.catalog_ref.sha256 == $catalog_sha256));

def review_labels_ref($seed):
  {content_id:"evals.reviewer-severity.labels.v1",
   media_type:"application/vnd.ystack.eval-labels+json",sha256:$seed.body.shared.labels.sha256};
def review_anchor_ok($seed;$approval):
  $approval.body as $a | $seed.body.shared.labels as $labels |
  $a.labels_sha256 == $labels.sha256 and
  $a.selected_comment_ids == ($labels.content.body.trials | map(.comment_id));
def review_report_ok($seed;$report):
  $seed.body.shared.bundle as $bundle | $bundle.content.body as $b |
  ($b.trials | map(.value.body.attempt_id) | sort) as $attempts |
  ($b.trials | map(.ref) | sort) as $refs |
  ($report | schema::exact_fields(["body","id","kind","schema_version"];[]) and
   .schema_version == 1 and .kind == "eval_report" and .id == $bundle.content.id and
   (.body | schema::exact_fields(["mode","bundle_ref","framework_ref","suite_ref","status","cases"];[]) and
    .mode == "evaluation-only" and
    .bundle_ref == {content_id:$bundle.content.id,
      media_type:"application/vnd.ystack.eval-bundle+json",sha256:$bundle.sha256} and
    .framework_ref == $b.suite.value.body.framework_ref and .suite_ref == $b.suite.ref and
    (.status as $v | ["passed","failed","inconclusive","unavailable"] | index($v) != null) and
    (.cases | type == "array" and length == 1) and
    (.cases[0] | schema::exact_fields(["case_ref","execution_kind","status","trials"];[]) and
     .case_ref == $b.cases[0].ref and .execution_kind == "model" and
     (.status as $v | ["passed","failed","inconclusive","unavailable"] | index($v) != null) and
     (.trials | type == "array" and length == ($attempts | length) and
      (map(.attempt_id) | sort) == $attempts and (map(.trial_ref) | sort) == $refs and
      all(.[]; . as $t |
        schema::exact_fields(["attempt_id","finished_at","started_at","status","trial_index","trial_ref"];[]) and
        (.status as $v | ["passed","failed","inconclusive","unavailable"] | index($v) != null) and
        any($b.trials[]; .ref == $t.trial_ref and .value.body.attempt_id == $t.attempt_id and
          .value.body.trial_index == $t.trial_index and
          .value.body.started_at == $t.started_at and .value.body.finished_at == $t.finished_at))))));
def review_relations_ok($seed;$approval;$catalog):
  $seed.body as $s | $s.shared.bundle.content.body as $b |
  $s.shared.labels.content.body.trials as $labels |
  $approval.body as $a | $b.cases[0].value.body as $case |
  [$catalog.body.families[] | select(.family_id == "reviewer-severity-false-positive-negative")][0]
    .trial_policy.minimum_trials as $minimum |
  ($labels | length) as $n |
  $n >= $minimum and $n <= 16 and
  ($b.cases | length) == 1 and $case.execution_kind == "model" and
  $case.trial_count == $n and ($b.trials | length) == $n and ($b.grades | length) == $n and
  ($s.cases | length) == $n and ($s.shared.files | length) == $n and
  ($b.trials | map(.value.body.attempt_id) | unique | length) == $n and
  ($s.cases | map(.verdict.comment_id) | sort) == $a.selected_comment_ids and
  ($b.trials | map(.value.body.attempt_id | ltrimstr("review.")) | sort) == $a.selected_comment_ids and
  $case.expected_ref == review_labels_ref($seed) and
  ($case.graders | length) == 1 and
  $case.graders[0].grader_id == "grader.operator" and $case.graders[0].grader_kind == "human" and
  ($case.graders[0].implementation_ref | ref_shape("evals.reviewer-severity.rubric.v1";"text/markdown")) and
  $case.graders[0].instructions_ref == $case.graders[0].implementation_ref and
  all($b.trials[]; . as $trial |
    [$labels[] | select(("review." + .comment_id) == $trial.value.body.attempt_id)] as $ls |
    [$b.grades[] | select(.value.body.trial_ref == $trial.ref)] as $gs |
    ($ls | length) == 1 and ($gs | length) == 1 and
    $trial.value.body.status == "completed" and
    ($gs[0].value.body | .evidence_ref == {state:"present",value:review_labels_ref($seed)} and
      .status == $ls[0].grade_status and .graded_at == $a.approved_at and
      .grader_id == "grader.operator" and .grader_kind == "human" and
      .grader_ref == $case.graders[0].implementation_ref) and
    [$s.cases[] | select(.verdict.comment_id == $ls[0].comment_id)] as $seeds |
    ($seeds | length) == 1 and
    $trial.value.body.output_ref == {state:"present",value:{content_id:"review-verdict.v1",
      media_type:"text/markdown",sha256:$ls[0].verdict_sha256}} and
    $seeds[0].verdict.sha256 == $ls[0].verdict_sha256 and
    [$s.shared.files[] | select(.path == $seeds[0].verdict.path)] ==
      [{path:$seeds[0].verdict.path,sha256:$ls[0].verdict_sha256}]);

# Driver entry points, selected with --arg evals_operation.
if $evals_operation == "validate-review-approval" then
  $candidate_docs[0] | review_approval_shape
elif $evals_operation == "validate-review-anchor" then
  review_anchor_ok($seed_set_docs[0];$candidate_docs[0])
elif $evals_operation == "validate-review-report" then
  review_report_ok($seed_set_docs[0];$candidate_docs[0])
elif $evals_operation == "validate-review-relations" then
  review_relations_ok($seed_set_docs[0];$candidate_docs[0];$catalog_docs[0])
elif $evals_operation == "validate-catalog" then
  $catalog_docs[0] | catalog_shape
elif $evals_operation == "validate-seed-set" then
  $seed_set_docs[0] | seed_set_bound($catalog_docs[0])
elif $evals_operation == "build-run-result" then
  ($catalog_docs[0] | catalog_shape) and
  ($seed_set_docs[0] | seed_set_bound($catalog_docs[0])) and
  ($observation_docs[0] | observation_set_shape($seed_set_docs[0].body.seed_source)) and
  ($evaluator_docs[0] | evaluator_shape) |
  if . then
    build_run_result(
      $catalog_docs[0];$catalog_sha256;$evaluator_docs[0];$evaluator_sha256;
      $seed_set_docs[0];$seed_set_sha256;$observation_docs[0];$observed_at)
  else error("E_SHAPE") end
elif $evals_operation == "build-dashboard" then
  ($catalog_docs[0] | catalog_shape) and
  ($evaluator_docs[0] | evaluator_shape) and
  ($result_docs | dashboard_results_ok($result_shas)) |
  if . then
    build_dashboard(
      $catalog_docs[0];$catalog_sha256;$evaluator_docs[0];$evaluator_sha256;
      $result_docs;$result_shas;$observed_at)
  else error("E_SHAPE") end
elif $evals_operation == "validate-dashboard" then
  ($catalog_docs[0] | catalog_shape) and
  ($evaluator_docs[0] | evaluator_shape) and
  ($result_docs | dashboard_results_ok($result_shas)) and
  ($candidate_docs[0] |
   dashboard_shape($catalog_docs[0];$catalog_sha256;$evaluator_sha256;$result_docs;
                   $result_shas;$observed_at)) and
  $candidate_docs[0] ==
    build_dashboard(
      $catalog_docs[0];$catalog_sha256;$evaluator_docs[0];$evaluator_sha256;
      $result_docs;$result_shas;$observed_at)
elif $evals_operation == "validate-run-result" then
  # A candidate passes only if it is exactly the result this program derives
  # from the same catalog, evaluator, seed set, and recorded observations.
  ($catalog_docs[0] | catalog_shape) and
  ($seed_set_docs[0] | seed_set_bound($catalog_docs[0])) and
  ($observation_docs[0] | observation_set_shape($seed_set_docs[0].body.seed_source)) and
  ($evaluator_docs[0] | evaluator_shape) and
  ($candidate_docs[0] |
   run_result_shape($catalog_sha256; $evaluator_sha256; $seed_set_docs[0]; $seed_set_sha256)) and
  $candidate_docs[0] ==
    build_run_result(
      $catalog_docs[0];$catalog_sha256;$evaluator_docs[0];$evaluator_sha256;
      $seed_set_docs[0];$seed_set_sha256;$observation_docs[0];$observed_at)
else error("E_RUNTIME") end
