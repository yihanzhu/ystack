#!/bin/bash
set -euo pipefail
export LC_ALL=C
umask 077

fail() { printf '%s\n' E_BUILD >&2; exit 1; }
[ "$#" -ge 3 ] && [ "$#" -le 4 ] || fail
mode=$1
python=$2
output=$3
case "$python:$output" in /*:/*) ;; *) fail ;; esac
[ -f "$python" ] && [ -x "$python" ] && [ "$(cd -P -- "${python%/*}" && printf '%s/%s' "$PWD" "${python##*/}")" = "$python" ] || fail
[ ! -e "$output" ] || fail
case "$mode:$#" in
  build:3) test_build=false; test_case=0 ;;
  test-build:4)
    test_build=true
    test_case=$4
    case "$test_case" in ''|*[!0-9]*) fail ;; esac
    [ "$test_case" -ge 1 ] && [ "$test_case" -le 11 ] || fail
    ;;
  *) fail ;;
esac

script=$(cd -P -- "${BASH_SOURCE[0]%/*}" && printf '%s/%s' "$PWD" "${BASH_SOURCE[0]##*/}")
directory=${script%/*}
source=$directory/_cancel_release.c
[ -f "$source" ] || fail
cc=$(
  "$python" -I -S -B -c 'import os; print(os.path.realpath("/usr/bin/cc"))'
)
case "$cc" in /*) ;; *) fail ;; esac
[ -f "$cc" ] && [ -x "$cc" ] || fail

metadata=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/ystack-cancel-build.XXXXXX")
argv_json=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/ystack-cancel-argv.XXXXXX")
cleanup() { /bin/rm -f -- "$metadata" "$argv_json"; }
trap cleanup EXIT
"$python" -I -S -B - "$metadata" <<'PY'
import json, os, platform, sys, sysconfig
path=sys.argv[1]
keys=("CONFIG_ARGS","Py_GIL_DISABLED","Py_DEBUG","Py_ENABLE_JIT",
      "HAVE_PTHREAD_SIGMASK","HAVE_BROKEN_PTHREAD_SIGMASK","HAVE_SIGACTION")
value={"platform":sys.platform,"architecture":platform.machine(),
 "include":os.path.realpath(sysconfig.get_config_var("INCLUDEPY") or ""),
 "config_include":os.path.realpath(sysconfig.get_config_var("CONFINCLUDEPY") or ""),
 "ext_suffix":sysconfig.get_config_var("EXT_SUFFIX"),
 "soabi":sysconfig.get_config_var("SOABI"),
 "implementation":sys.implementation.name,"version":sys.version,
 "configuration":{key:sysconfig.get_config_var(key) for key in keys}}
if (value["platform"] not in ("darwin","linux") or
    not all(isinstance(value[key],str) and value[key] for key in
            ("include","config_include","ext_suffix","soabi","implementation","version")) or
    not all(os.path.isabs(value[key]) and os.path.realpath(value[key])==value[key]
            for key in ("include","config_include"))):
 raise SystemExit(1)
with open(path,"w",encoding="utf-8",newline="\n") as out:
 json.dump(value,out,sort_keys=True,separators=(",",":"),ensure_ascii=False)
 out.write("\n")
PY

fields_file=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/ystack-cancel-fields.XXXXXX")
trap 'cleanup; /bin/rm -f -- "$fields_file"' EXIT
"$python" -I -S -B - "$metadata" > "$fields_file" <<'PY'
import json,sys
v=json.load(open(sys.argv[1],encoding="utf-8"))
for key in ("platform","architecture","include","config_include","ext_suffix","soabi","implementation","version"):
 value=v[key]
 if "\n" in value or "\r" in value: raise SystemExit(1)
 print(value)
PY
[ "$(/usr/bin/wc -l < "$fields_file" | /usr/bin/tr -d ' ')" = 8 ] || fail
platform_name=$(/usr/bin/sed -n '1p' "$fields_file")
include=$(/usr/bin/sed -n '3p' "$fields_file")
config_include=$(/usr/bin/sed -n '4p' "$fields_file")
ext_suffix=$(/usr/bin/sed -n '5p' "$fields_file")
/bin/rm -f -- "$fields_file"
trap cleanup EXIT
mkdir -m 0700 -- "$output"
extension=$output/_cancel_release$ext_suffix

argv=("$cc" -std=c11 -Wall -Wextra -Werror -O2 -fvisibility=hidden -fPIC
      -I"$include" -I"$config_include")
if [ "$test_build" = true ]; then
  argv+=("-DYSTACK_CANCEL_RELEASE_TESTING=1" "-DYSTACK_CANCEL_TEST_CASE=$test_case")
fi
case "$platform_name" in
  darwin) argv+=(-bundle -undefined dynamic_lookup) ;;
  linux) argv+=(-shared) ;;
  *) fail ;;
esac
argv+=("$source" -o "$extension")

"$python" -I -S -B - "$argv_json" "${argv[@]}" <<'PY'
import json,sys
with open(sys.argv[1],"w",encoding="utf-8",newline="\n") as out:
 json.dump(sys.argv[2:],out,sort_keys=True,separators=(",",":"),ensure_ascii=False)
 out.write("\n")
PY
"${argv[@]}"
chmod 0500 "$extension"

compiler_version=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/ystack-cancel-cc.XXXXXX")
trap 'cleanup; /bin/rm -f -- "$compiler_version"' EXIT
"$cc" --version > "$compiler_version" 2>&1
"$python" -I -S -B - "$metadata" "$argv_json" "$script" "$source" "$cc" \
  "$compiler_version" "$python" "$extension" "$output/build-record.json" \
  "$test_build" "$test_case" <<'PY'
import hashlib,json,os,pathlib,sys
(metadata_path,argv_path,script_path,source_path,cc_path,cc_version_path,
 python_path,extension_path,record_path,test_build,test_case)=sys.argv[1:]
def raw(path): return pathlib.Path(path).read_bytes()
def digest(data): return hashlib.sha256(data).hexdigest()
metadata=json.loads(raw(metadata_path));argv=json.loads(raw(argv_path))
extension=raw(extension_path)
body={"platform":metadata["platform"],"architecture":metadata["architecture"],
 "source_sha256":digest(raw(source_path)),"build_script_sha256":digest(raw(script_path)),
 "compiler_path":cc_path,"compiler_sha256":digest(raw(cc_path)),
 "compiler_version_sha256":digest(raw(cc_version_path)),"argv":argv,
 "argv_sha256":digest((json.dumps(argv,sort_keys=True,separators=(",",":"),ensure_ascii=False)+"\n").encode()),
 "python_path":python_path,"python_sha256":digest(raw(python_path)),
 "python_implementation":metadata["implementation"],"python_version":metadata["version"],
 "soabi":metadata["soabi"],"ext_suffix":metadata["ext_suffix"],
 "configuration":metadata["configuration"],"output_name":os.path.basename(extension_path),
 "output_size":len(extension),"output_sha256":digest(extension),
 "test_build":test_build=="true"}
if body["test_build"]: body["test_case"]=int(test_case)
doc={"schema_version":1,"kind":"shadow_cancel_release_build_record",
     "id":"shadow.cancel-release.build","body":body}
encoded=(json.dumps(doc,sort_keys=True,separators=(",",":"),ensure_ascii=False)+"\n").encode()
if len(encoded)>1024*1024: raise SystemExit(1)
pathlib.Path(record_path).write_bytes(encoded)
PY
chmod 0400 "$output/build-record.json"
/bin/rm -f -- "$compiler_version"
trap cleanup EXIT
[ "$(find "$output" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" = 2 ] || fail
