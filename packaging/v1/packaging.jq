def rows($text): [$text | split("\n")[] | select(length > 0) | split("\t")];

def path_ok: type == "string" and length > 0 and length <= 160 and
  test("\\A(profiles/[a-z0-9][a-z0-9-]*/v1/|adapters/[a-z0-9][a-z0-9-]*/v1/|core/v2/generations/g-[0-9a-f]{64}/)[A-Za-z0-9][A-Za-z0-9._/-]*\\z|\\Ascripts/core-contract\\.sh\\z") and
  (test("(\\A|/)\\.|\\.\\.|//|/\\z") | not);

def profile_id_ok: type == "string" and
  test("\\Aprofile\\.[a-z0-9][a-z0-9-]{0,30}\\.v1\\z");

def file_entry_ok: type == "object" and (keys == ["mode","object_id","path","sha256"]) and
  (.path | path_ok) and (.mode | IN("100644","100755")) and
  (.object_id | test("\\A[0-9a-f]{40}\\z")) and (.sha256 | test("\\A[0-9a-f]{64}\\z"));

def sorted_unique($list): ($list | sort) == $list and ($list | unique | length) == ($list | length);

def profile_name($profile_id): $profile_id | ltrimstr("profile.") | rtrimstr(".v1");

# The core files every packaged profile carries. build-release.sh asks for this
# list instead of repeating it, so the builder and the manifest check cannot drift.
def core_paths($generation):
  (["scripts/core-contract.sh",
    "core/v2/generations/\($generation)/contracts.jq",
    "core/v2/generations/\($generation)/core-ingress.sh"] +
   (["profile_graph","result_facts","result_truth","schema","stage_request"] |
     map("core/v2/generations/\($generation)/modules/\(.).jq"))) | sort;

# A profile's packaged set is derived here, not taken on trust: it carries the core
# files for the manifest's own generation, its own profile directory (profile.json,
# producer-config.json, and its six adapter manifests), and nothing from another
# profile or another generation. Everything else it names is an adapter payload,
# which only the release commit can settle.
def profile_set_ok($generation):
  profile_name(.profile_id) as $name |
  "profiles/\($name)/v1/" as $own |
  .files as $files |
  ((core_paths($generation) - $files) | length) == 0 and
  ((["\($own)profile.json", "\($own)producer-config.json"] - $files) | length) == 0 and
  ([$files[] | select(startswith("\($own)manifests/"))] | length) == 6 and
  ($files | map(select(startswith("profiles/")) | startswith($own)) | all) and
  ($files | map(select(startswith("core/")) |
    startswith("core/v2/generations/\($generation)/")) | all);

def release_body($files; $profiles; $commit; $generation):
  ($files | map({mode: .[1], object_id: .[2], path: .[0], sha256: .[3]}) | sort_by(.path)) as $entries |
  ($entries | map(.path)) as $paths |
  ($profiles | group_by(.[0]) |
    map({files: (map(.[1]) | sort | unique), profile_id: .[0][0]}) | sort_by(.profile_id)) as $sets |
  if ($entries | length) < 1 or ($entries | length) > 128 then error("file-count")
  elif ($entries | map(file_entry_ok) | all | not) then error("file-entry")
  elif (sorted_unique($paths) | not) then error("file-paths")
  elif ($sets | length) < 1 or ($sets | length) > 4 then error("profile-count")
  elif ($sets | map(.profile_id | profile_id_ok) | all | not) then error("profile-id")
  elif ($sets | map(.files | length > 0 and (. - $paths | length) == 0) | all | not) then error("profile-files")
  elif ($commit | test("\\A[0-9a-f]{40}\\z") | not) then error("commit")
  elif ($generation | test("\\Ag-[0-9a-f]{64}\\z") | not) then error("generation")
  else
    {activation: "none", authority: "none",
     core_contract: {generation_id: $generation, schema_major: 2},
     files: $entries, package_version: "v1", profiles: $sets,
     qualification: {state: "unavailable"},
     source: {commit_id: $commit, hash_algorithm: "sha1", repository_id: "repo.ystack"}}
  end;

def manifest_ok:
  (keys == ["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "release_manifest" and (.id | test("\\Arelease\\.[0-9a-f]{64}\\z")) and
  # The release id is the SHA-256 of the canonical body, recomputed by the caller.
  # A hand-edited id no longer passes just because it is the right shape.
  ($body_sha | test("\\A[0-9a-f]{64}\\z")) and .id == "release.\($body_sha)" and
  (.body | type == "object" and
    (keys == ["activation","authority","core_contract","files","package_version",
              "profiles","qualification","source"]) and
    .activation == "none" and .authority == "none" and .package_version == "v1" and
    .qualification == {state: "unavailable"} and
    (.core_contract | keys == ["generation_id","schema_major"] and .schema_major == 2 and
      (.generation_id | test("\\Ag-[0-9a-f]{64}\\z"))) and
    (.source | keys == ["commit_id","hash_algorithm","repository_id"] and
      .hash_algorithm == "sha1" and (.commit_id | test("\\A[0-9a-f]{40}\\z")) and
      .repository_id == "repo.ystack") and
    (.files | type == "array" and length >= 1 and length <= 128 and
      (map(file_entry_ok) | all) and sorted_unique(map(.path))) and
    (.core_contract.generation_id as $generation_id | .profiles |
      type == "array" and length >= 1 and length <= 4 and
      (map(type == "object" and keys == ["files","profile_id"] and
        (.profile_id | profile_id_ok) and
        (.files | type == "array" and length >= 1 and sorted_unique(.))) | all) and
      sorted_unique(map(.profile_id)) and
      (map(profile_set_ok($generation_id)) | all)) and
    ([.profiles[].files[]] - [.files[].path] | length) == 0 and
    # No packaged file may sit in the release that no profile claims.
    ([.files[].path] - [.profiles[].files[]] | length) == 0);

def install_body($files; $profile_id; $release_id; $manifest_sha; $commit; $north_star_sha):
  ($files | map({mode: .[1], path: .[0], sha256: .[2]}) | sort_by(.path)) as $entries |
  if ($entries | map(type == "object" and (.sha256 | test("\\A[0-9a-f]{64}\\z"))) | all | not)
  then error("installed-entry")
  elif (sorted_unique($entries | map(.path)) | not) then error("installed-paths")
  elif ($profile_id | profile_id_ok | not) then error("profile-id")
  else
    {activation: "none", authority: "none", install_version: "v1", installed: $entries,
     north_star: {owner: "target", path: ".ystack/north-star.md",
       sha256: $north_star_sha, state: "placeholder-unset"},
     profile_id: $profile_id, qualification: {state: "unavailable"},
     release_ref: {content_id: $release_id,
       media_type: "application/vnd.ystack.release-manifest+json", sha256: $manifest_sha},
     source: {commit_id: $commit, hash_algorithm: "sha1", repository_id: "repo.ystack"}}
  end;

if $operation == "release" then
  release_body(rows($files); rows($profiles); $commit; $generation)
elif $operation == "core-paths" then
  (if ($generation | test("\\Ag-[0-9a-f]{64}\\z")) then core_paths($generation) | join("\n")
   else error("generation") end)
elif $operation == "manifest-shape" then
  (if manifest_ok then "" else "E_SHAPE" end)
elif $operation == "profile-files" then
  (if manifest_ok | not then error("shape")
   else ([.body.profiles[] | select(.profile_id == $profile_id)]) as $set |
     if ($set | length) != 1 then error("profile")
     else ([$set[0].files[]] | sort | unique) as $wanted |
       [.body.files[] | select(.path | IN($wanted[]))] |
       if (length != ($wanted | length)) then error("profile-files")
       else map([.path, .mode, .object_id, .sha256] | @tsv) | join("\n") end
     end
   end)
elif $operation == "install-record" then
  install_body(rows($files); $profile_id; $release_id; $manifest_sha; $commit; $north_star_sha)
else error("operation") end
