#!/bin/bash
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-shadow-consumer.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() { /bin/chmod -R u+w -- "$tmp" 2>/dev/null || true; /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT
sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
case "$(/usr/bin/uname -s):$(/usr/bin/uname -m)" in
  Darwin:*) jq_asset=jq-osx-amd64 ;;
  Linux:x86_64) jq_asset=jq-linux64 ;;
  *) /usr/bin/printf 'unsupported test host\n' >&2; exit 1 ;;
esac
jq_bin="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset"
[ -x "$jq_bin" ] || { /usr/bin/printf 'missing pinned jq\n' >&2; exit 1; }
jq_bin=$(CDPATH='' cd -P -- "${jq_bin%/*}" && /usr/bin/printf '%s/%s' "$PWD" "${jq_bin##*/}")
if [ -x /opt/homebrew/bin/python3.14 ]; then
  python_bin=/opt/homebrew/bin/python3.14
elif [ -x /usr/local/bin/python3.14 ]; then
  python_bin=/usr/local/bin/python3.14
else
  python_bin=$(command -v python3.14 2>/dev/null || command -v python3)
fi
case "$python_bin" in /*) ;; *) /usr/bin/printf 'missing physical python\n' >&2; exit 1 ;; esac
python_bin=$("$python_bin" -I -S -B -c 'import os,sys; print(os.path.realpath(sys.executable))')
case "$python_bin" in /*) ;; *) /usr/bin/printf 'missing resolved physical python\n' >&2; exit 1 ;; esac
native_out="$tmp/native-release"
/bin/bash -p "$root/shadow/v1/build-cancel-release.sh" build "$python_bin" "$native_out"
native_binary=$(/usr/bin/find "$native_out" -mindepth 1 -maxdepth 1 -type f ! -name build-record.json -print)
[ -n "$native_binary" ] && [ -f "$native_binary" ] || fail 'native release build output'
for native_case in 1 2 5 6 7 8 9 10 12 13 33 36 37 38 39 40 41 42 43 44 45 46 47 48; do
  /bin/bash -p "$root/shadow/v1/build-cancel-release.sh" test-build "$python_bin" \
    "$tmp/native-case-$native_case" "$native_case"
done
native_control_binary=$(/usr/bin/find "$tmp/native-case-33" -mindepth 1 -maxdepth 1 \
  -type f ! -name build-record.json -print)
[ -n "$native_control_binary" ] && [ -f "$native_control_binary" ] || fail 'native child control output'
"$python_bin" -I -S -B - "$native_out/build-record.json" "$tmp" \
  "$root/shadow/v1/_cancel_release.c" <<'PY'
import hashlib,json,pathlib,subprocess,sys
record=json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["body"]
base=list(record["argv"]);temporary=pathlib.Path(sys.argv[2]);source=str(pathlib.Path(sys.argv[3]))
if source not in base:raise SystemExit("native child test source is not in the build argv")
index={}
cases=(*range(21,35),*((35,) if sys.platform=="linux" else ()))
for case in cases:
 directory=temporary/("native-child-case-%d"%case);directory.mkdir(mode=0o700)
 output=directory/record["output_name"];argv=[]
 for value in base:
  if value==source:argv.extend(("-DYSTACK_CANCEL_RELEASE_TESTING=1","-DYSTACK_CANCEL_TEST_CASE=%d"%case,value))
  elif value.endswith(record["output_name"]):argv.append(str(output))
  else:argv.append(value)
 result=subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=False)
 (directory/"stdout").write_bytes(result.stdout);(directory/"stderr").write_bytes(result.stderr)
 if result.returncode:raise SystemExit("native child test build %d failed"%case)
 output.chmod(0o500);encoded=(json.dumps(argv,separators=(",",":"),ensure_ascii=False)+"\n").encode()
 (directory/"argv.json").write_bytes(encoded)
 index[str(case)]={"argv_sha256":hashlib.sha256(encoded).hexdigest(),"output_sha256":hashlib.sha256(output.read_bytes()).hexdigest()}
(temporary/"native-child-build-index.json").write_text(json.dumps(index,sort_keys=True,separators=(",",":"))+"\n",encoding="utf-8")
PY
cat > "$tmp/native-owner-case.py" <<'PY'
import importlib.util,os,pathlib,signal,sys
case=int(sys.argv[1]);binary=pathlib.Path(sys.argv[2]);directory=pathlib.Path(sys.argv[3]);directory.mkdir()
spec=importlib.util.spec_from_file_location("_cancel_release",binary)
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);state=module.prepare_state()
initial=signal.pthread_sigmask(signal.SIG_BLOCK,set());delivered=[]
old={sent:signal.signal(sent,lambda value,_frame:delivered.append(value)) for sent in (signal.SIGHUP,signal.SIGINT,signal.SIGTERM)}
def outcome():return state.outcome()
try:
 state.block_entry()
 if outcome()=="native-release.pending":state.arm_consumer()
 if outcome()=="native-release.pending" and case in (39,40):state.checkpoint()
 if outcome()=="native-release.pending" and case not in (1,36,37,38,39,40):
  fd=os.open(directory,os.O_RDONLY|os.O_DIRECTORY);state.hold_completion(fd);os.close(fd)
  if outcome()=="native-release.pending" and case in (9,10):os.kill(os.getpid(),signal.SIGTERM)
  if outcome()=="native-release.pending":state.block_final()
  if outcome()=="native-release.pending":state.commit_completion(b'{"complete":true}\n')
 if outcome()=="native-release.pending":state.abort_release()
 result=outcome()
finally:
 for sent,value in old.items():signal.signal(sent,value)
 current=signal.pthread_sigmask(signal.SIG_BLOCK,set())
 if current!=initial:signal.pthread_sigmask(signal.SIG_SETMASK,initial)
print(case,result,int((directory/"bundle.json").exists()),int(current==initial),len(delivered))
PY
checks=0
for native_case in 1 2 5 6 7 8 9 10 12 13 36 37 38 39 40 41 42 43 44 45 46 47; do
  case_binary=$(/usr/bin/find "$tmp/native-case-$native_case" -mindepth 1 -maxdepth 1 -type f ! -name build-record.json -print)
  "$python_bin" -I -S -B "$tmp/native-owner-case.py" "$native_case" "$case_binary" "$tmp/native-owner-result-$native_case" > "$tmp/native-owner-case-$native_case.raw"
  /usr/bin/grep -Eq "^$native_case native-release.failure [01] [01] [0-9]+$" "$tmp/native-owner-case-$native_case.raw" || fail "native owner fault $native_case"
  checks=$((checks+1)); /usr/bin/printf 'ok native-%d - simulated owner fault %d is authoritative\n' "$checks" "$native_case"
done
"$python_bin" -I -S -B - "$native_binary" "$tmp/native-positive" <<'PY'
import importlib.util,os,pathlib,signal,sys
binary=pathlib.Path(sys.argv[1]);directory=pathlib.Path(sys.argv[2]);directory.mkdir()
spec=importlib.util.spec_from_file_location("_cancel_release",binary)
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);state=module.prepare_state()
initial=signal.pthread_sigmask(signal.SIG_BLOCK,set());old={sent:signal.getsignal(sent) for sent in (signal.SIGHUP,signal.SIGINT,signal.SIGTERM)}
state.block_entry();state.arm_consumer();assert state.checkpoint()=="native-checkpoint.clear"
fd=os.open(directory,os.O_RDONLY|os.O_DIRECTORY);state.hold_completion(fd);os.close(fd)
state.block_final();payload=b'{"complete":true}\n';assert state.commit_completion(payload)=="native-release.success"
assert state.outcome()=="native-release.success" and (directory/"bundle.json").read_bytes()==payload
assert signal.pthread_sigmask(signal.SIG_BLOCK,set())==initial and all(signal.getsignal(sent)==old[sent] for sent in old)
print("shadow-enforced-native-positive: exact bytes, action and mask restoration passed")
PY
cat > "$tmp/native-pending.py" <<'PY'
import importlib.util,os,pathlib,signal,sys
binary=pathlib.Path(sys.argv[1]);directory=pathlib.Path(sys.argv[2]);directory.mkdir()
spec=importlib.util.spec_from_file_location("_cancel_release",binary)
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);state=module.prepare_state()
seen=[];old=signal.signal(signal.SIGTERM,lambda sent,_frame:seen.append(sent))
try:
 state.block_entry();state.arm_consumer();os.kill(os.getpid(),signal.SIGTERM)
 assert state.checkpoint()=="native-checkpoint.cancelled" and signal.SIGTERM in signal.sigpending()
 state.abort_release();assert state.outcome()=="native-release.failure" and not (directory/"bundle.json").exists()
finally:signal.signal(signal.SIGTERM,old)
print("shadow-enforced-native-pending: nonconsuming sticky pending passed",len(seen))
PY
"$python_bin" -I -S -B "$tmp/native-pending.py" "$native_binary" "$tmp/native-pending"
cat > "$tmp/native-disposition.py" <<'PY'
import importlib.util,os,pathlib,signal,sys
mode,binary,directory=sys.argv[1],pathlib.Path(sys.argv[2]),pathlib.Path(sys.argv[3]);directory.mkdir()
seen=[];prior_mask=signal.pthread_sigmask(signal.SIG_BLOCK,set())
if mode=="default":prior_action=signal.signal(signal.SIGTERM,signal.SIG_DFL)
elif mode=="ignore":prior_action=signal.signal(signal.SIGTERM,signal.SIG_IGN)
else:
 prior_action=signal.signal(signal.SIGTERM,lambda sent,_frame:seen.append(sent))
 if mode=="blocked":signal.pthread_sigmask(signal.SIG_BLOCK,{signal.SIGTERM})
spec=importlib.util.spec_from_file_location("_cancel_release",binary)
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);state=module.prepare_state()
try:
 state.block_entry();state.arm_consumer()
 fd=os.open(directory,os.O_RDONLY|os.O_DIRECTORY);state.hold_completion(fd);os.close(fd)
 state.block_final();os.kill(os.getpid(),signal.SIGTERM)
 result=state.commit_completion(b'{"complete":true}\n')
 assert result=="native-release.failure" and not (directory/"bundle.json").exists()
 current=signal.pthread_sigmask(signal.SIG_BLOCK,set())
 if mode=="ignore":assert signal.getsignal(signal.SIGTERM)==signal.SIG_IGN and signal.SIGTERM not in signal.sigpending()
 elif mode=="blocked":assert signal.SIGTERM in current and signal.SIGTERM in signal.sigpending() and not seen
 else:assert mode=="returning" and seen==[signal.SIGTERM] and signal.SIGTERM not in current
 print(mode,result,len(seen),int(signal.SIGTERM in current),int(signal.SIGTERM in signal.sigpending()))
finally:
 signal.pthread_sigmask(signal.SIG_SETMASK,prior_mask);signal.signal(signal.SIGTERM,prior_action)
PY
for disposition in ignore blocked returning; do
  "$python_bin" -I -S -B "$tmp/native-disposition.py" "$disposition" "$native_binary" \
    "$tmp/native-disposition-$disposition"
done
default_result=0
"$python_bin" -I -S -B "$tmp/native-disposition.py" default "$native_binary" \
  "$tmp/native-disposition-default" || default_result=$?
[ "$default_result" -eq 143 ] || fail 'default pending signal did not terminate after rollback'
[ ! -e "$tmp/native-disposition-default/bundle.json" ] || fail 'default pending rollback left marker'
/usr/bin/printf 'shadow-enforced-native-dispositions: returning, ignored, blocked and default controls passed\n'
"$python_bin" -I -S -B - "$native_binary" <<'PY'
import importlib.util,sys
spec=importlib.util.spec_from_file_location("_cancel_release",sys.argv[1])
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
state=module.prepare_state();state.block_entry();state.arm_consumer()
try:
 state.prepare_child((12,b"/usr/bin/true",(b"/usr/bin/true",),
  (b"LANG=C",b"LC_ALL=C",b"PATH=/usr/bin:/bin")))
except RuntimeError as exc:
 assert str(exc)=="native child platform contract is unavailable"
 assert state.child_status()[0]==0
else:raise AssertionError("production child platform admitted without complete proof")
print("shadow-enforced-native-child-admission: unknown platform contract refused before effect")
PY
cat > "$tmp/native-child-state.py" <<'PY'
import errno,importlib.util,os,signal,sys,time
case=int(sys.argv[1]);binary=sys.argv[2]
spec=importlib.util.spec_from_file_location("_cancel_release",binary)
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
state=module.prepare_state();state.block_entry();state.arm_consumer()
environment=(b"LANG=C",b"LC_ALL=C",b"PATH=/usr/bin:/bin")
def status():
 value=state.child_status();assert type(value) is tuple and len(value)==49 and all(type(item) is int for item in value);return value
def prepare(argv=(b"/usr/bin/true",)):state.prepare_child((12,argv[0],argv,environment))
def refuses(call):
 try:call()
 except (MemoryError,OSError,RuntimeError):return
 raise AssertionError("operation did not refuse")
def close_pipes():state.close_child_stdin();state.close_child_stdout();state.close_child_stderr()
def observe(lost=False):
 deadline=time.monotonic()+3
 while True:
  try:state.observe_child_exit()
  except RuntimeError:
   if lost and status()[11]:return
   raise
  if status()[11]:return
  assert time.monotonic()<deadline;time.sleep(.01)
if 21<=case<=26 or case==35:
 refuses(prepare);value=status();assert value[0] in (0,2) and value[1]==0 and value[19]==1 and value[23]==26;print("prepare-failure",case,value[25:43])
elif case==27:
 prepare();state.spawn_child();value=status();assert value[0]==2 and value[3]==1 and value[4]!=0 and value[19]==1 and value[23]==27;refuses(state.child_fds);print("spawn-nonzero",value[:6])
elif case==28:
 prepare();refuses(state.spawn_child);value=status();assert value[0]==3 and value[1]>0 and value[3:5]==(1,0) and value[23]==0;close_pipes();observe();state.reap_child();state.check_child_group();value=status();assert value[17:20]==(1,1,1) and value[24]==1;print("spawn-lost-return",value[24])
elif case==29:
 prepare();state.spawn_child();close_pipes();time.sleep(.05);observe(True);value=status();assert value[11]==1;refuses(state.observe_child_exit);state.reap_child();state.check_child_group();assert status()[24]==1;print("observe-lost-return")
elif case==30:
 prepare();state.spawn_child();close_pipes();observe();refuses(state.reap_child);value=status();assert value[17]==1;refuses(state.reap_child);state.check_child_group();assert status()[24]==1;print("reap-lost-return")
elif case==31:
 prepare();state.spawn_child();close_pipes();state.observe_child_exit();value=status();assert value[6:9]==(1,-1,5) and value[11]==0 and value[23]==31;refuses(state.observe_child_exit);print("observe-unknown")
elif case==32:
 prepare();state.spawn_child();state.close_child_stdin();value=status();assert value[28:31]==(1,-1,5) and value[23]==28;refuses(state.close_child_stdin);print("close-failure")
elif case==33:
 prepare((b"/bin/sh",b"-c",b'trap "exit 0" TERM; while :; do :; done'));state.spawn_child();close_pipes();state.term_child_group();observe();state.kill_child_group();value=status();assert value[20:22]==(1,1) and value[45:47]==(-1,errno.ESRCH);state.reap_child();state.check_child_group();assert status()[24]==1;print("term-leader-kill")
elif case==34:
 prepare();state.spawn_child();close_pipes();observe();state.reap_child();before=status();assert before[12:15]==(1,-1,errno.EIO) and before[17]==0 and before[23]==35;refuses(state.reap_child);assert status()==before;print("unknown-reap")
else:raise AssertionError(case)
PY
native_child_cases="21 22 23 24 25 26 27 28 29 30 31 32 33 34"
[ "$(uname -s)" != Linux ] || native_child_cases="$native_child_cases 35"
for native_case in $native_child_cases; do
  child_binary=$(/usr/bin/find "$tmp/native-child-case-$native_case" -mindepth 1 -maxdepth 1 -type f -name '_cancel_release*.so' -print)
  "$python_bin" -I -S -B "$tmp/native-child-state.py" "$native_case" "$child_binary"
done
cat > "$tmp/runtime-dependency-collector.py" <<'PY'
import os
startup_environment_keys=tuple(sorted(os.environ))
forbidden_startup_keys=tuple(key for key in startup_environment_keys if
 key.startswith(("MallocStackLogging","OBJC_","LD_","DYLD_")) or
 key=="POSIX_SPAWN_FILTERING_RULES_PATH")
if forbidden_startup_keys:raise SystemExit("forbidden startup environment")
import ctypes,hashlib,importlib.machinery,importlib.util,json,pathlib,re,struct,subprocess,sys,sysconfig,tempfile,uuid
root=pathlib.Path(sys.argv[1]);native_binary=os.path.realpath(sys.argv[2])
gate_binary=os.path.realpath(sys.argv[3]);gate_record=pathlib.Path(sys.argv[4]);driver=root/"shadow/v1/enforced-reproduction.py"
spec=importlib.util.spec_from_file_location("shadow_runtime_diagnostic",driver)
module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
native_spec=importlib.util.spec_from_file_location("_cancel_release",native_binary)
native_module=importlib.util.module_from_spec(native_spec);native_spec.loader.exec_module(native_module)
def digest(path):
 size=os.stat(path).st_size
 if size>256*1024*1024: return {"status":"unavailable","reason":"file-size-limit","size":size}
 measured=hashlib.sha256();seen=0
 with open(path,"rb") as source:
  while chunk:=source.read(1024*1024):measured.update(chunk);seen+=len(chunk)
 return {"status":"ok","sha256":measured.hexdigest(),"size":seen}
def command(argv,limit=32768):
 try:
  result=subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
   check=False,timeout=10,env={"PATH":"/usr/bin:/bin","LC_ALL":"C","LANG":"C"})
 except (OSError,subprocess.SubprocessError) as error:
  return {"status":"unavailable","reason":type(error).__name__}
 raw=result.stdout
 return {"status":"ok" if result.returncode==0 else "failed","exit":result.returncode,
  "stdout":raw[:limit].decode("utf-8","replace"),"truncated":len(raw)>limit}
def dpkg(path):
 owner=command(["/usr/bin/dpkg-query","-S",path],4096)
 if owner["status"]!="ok":return {"status":"unavailable","owner_query":owner,"packages":[]}
 answer={"status":"ok","packages":[]}
 names=sorted({line.rsplit(": ",1)[0] for line in owner["stdout"].splitlines() if ": " in line})
 if len(names)>8:return {"owner_query":owner,"packages":[],"status":"unavailable","reason":"owner-count-limit"}
 for name in names:
  query=command(["/usr/bin/dpkg-query","-W","-f=${binary:Package}\\t${Version}\\t${source:Package}\\t${source:Version}\\n",name],4096)
  item={"status":"unavailable","query":query}
  if query["status"]=="ok":
   fields=query["stdout"].rstrip("\n").split("\t")
   if len(fields)==4:item={"status":"ok",**dict(zip(
    ("binary_package","binary_version","source_package","source_version"),(field or None for field in fields)))}
  answer["packages"].append(item)
 return answer
def build_id(path):
 result=command(["/usr/bin/readelf","-n",path])
 matches=re.findall(r"Build ID: ([0-9a-fA-F]+)",result.get("stdout",""))
 return {"status":"ok","value":matches[0].lower()} if result["status"]=="ok" and len(matches)==1 else {
  "status":"unavailable","reason":"missing-or-ambiguous","readelf":result}
def interpreter(path):
 result=command(["/usr/bin/readelf","-l",path])
 matches=re.findall(r"Requesting program interpreter: ([^]]+)",result.get("stdout",""))
 return {"status":"ok","requested":matches[0],"resolved":os.path.realpath(matches[0])} \
  if result["status"]=="ok" and len(matches)==1 else {
   "status":"unavailable","reason":"missing-or-ambiguous","readelf":result}
def soname(path):
 result=command(["/usr/bin/readelf","-d",path])
 matches=re.findall(r"\(SONAME\).*\[([^]]+)\]",result.get("stdout",""))
 if result["status"]=="ok" and len(matches)==1:return {"status":"ok","value":matches[0]}
 if result["status"]=="ok" and not matches:return {"status":"missing"}
 return {"status":"unavailable","reason":"failed-or-ambiguous","readelf":result}
def function_bodies(path):
 objdump="/usr/bin/objdump";readelf="/usr/bin/readelf"
 symbols=("posix_spawn","posix_spawn_file_actions_addclosefrom_np",
  "posix_spawn_file_actions_adddup2","posix_spawn_file_actions_addclose","setsid",
  "posix_spawnattr_setflags","posix_spawnattr_setsigmask","posix_spawnattr_setsigdefault",
  "waitid","kill","pthread_sigmask","sigpending","sigaction","sigismember","openat","read",
  "write","fsync","close","unlinkat","fstat")
 answer={"tools":{},"image":path,"functions":[],"internal_functions":[]}
 for name,tool in (("objdump",objdump),("readelf",readelf)):
  answer["tools"][name]={"path":tool,"identity":digest(tool) if os.path.isfile(tool) else
   {"status":"unavailable","reason":"missing"}}
 if any(row["identity"]["status"]!="ok" for row in answer["tools"].values()):
  answer["status"]="unavailable";answer["reason"]="missing-tool";return answer
 source_before={"identity":digest(path),"build_id":build_id(path)}
 answer["source_before"]=source_before
 recorded=0
 def metadata(argv,feed):
  with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
   try:
    process=subprocess.Popen(argv,stdout=stdout,stderr=stderr,
     env={"PATH":"/usr/bin:/bin","LC_ALL":"C","LANG":"C"})
    try:exit_code=process.wait(timeout=10);reason=None
    except subprocess.TimeoutExpired:
     process.kill();process.wait();exit_code=process.returncode;reason="timeout"
   except OSError as error:
    return {"argv":argv,"status":"unavailable","reason":type(error).__name__}
   stdout.seek(0);stdout_hash=hashlib.sha256();stdout_bytes=0
   for raw in stdout:
    stdout_hash.update(raw);stdout_bytes+=len(raw);feed(raw)
   stderr.seek(0);stderr_hash=hashlib.sha256();stderr_bytes=0;stderr_kept=bytearray()
   while chunk:=stderr.read(65536):
    stderr_hash.update(chunk);stderr_bytes+=len(chunk)
    if len(stderr_kept)<=8192:stderr_kept.extend(chunk[:8193-len(stderr_kept)])
   status="ok" if exit_code==0 and reason is None and stderr_bytes<=8192 else "unavailable"
   return {"argv":argv,"status":status,"reason":reason if reason else
    (None if status=="ok" else "exit-or-stderr-limit"),"exit":exit_code,
    "stdout_bytes":stdout_bytes,"stdout_sha256":stdout_hash.hexdigest(),
    "stdout_truncated":False,"stderr_bytes":stderr_bytes,
    "stderr_sha256":stderr_hash.hexdigest(),"stderr_truncated":stderr_bytes>8192,
    "stderr":bytes(stderr_kept[:8192]).decode("utf-8","replace")}
 def symbols_from(image,label):
  entries=[]
  def feed(raw):
   text=raw.decode("utf-8","replace").rstrip("\n");fields=text.split(None,7)
   if len(fields)!=8 or not fields[0].endswith(":") or not re.fullmatch(r"[0-9a-fA-F]+",fields[1]):return
   token=fields[7].split()[0]
   if "@@" in token:base,version=token.split("@@",1)
   elif "@" in token:base,version=token.split("@",1)
   else:base,version=token,None
   try:value=int(fields[1],16);size=int(fields[2])
   except ValueError:return
   entries.append({"base":base,"version":version,"value":value,"size":size,
    "type":fields[3],"bind":fields[4],"visibility":fields[5],"section":fields[6],"line":text})
  status=metadata([readelf,"--dyn-syms","--wide",image],feed)
  status["image_role"]=label
  return entries,status
 production_record_path=pathlib.Path(native_binary).parent/"build-record.json"
 production_record_before=digest(production_record_path);gate_record_before=digest(gate_record)
 gate_identity_before=digest(gate_binary)
 native_entries,native_status=symbols_from(native_binary,"native-release")
 gate_before={"identity":gate_identity_before,"build_id":build_id(gate_binary)}
 gate_entries,gate_status=symbols_from(gate_binary,"gate-only-case-48")
 provider_entries,provider_status=symbols_from(path,"libc")
 answer["symbol_metadata"]={"native":native_status,"gate_only":gate_status,"provider":provider_status}
 def canonical_record(record_path):
  try:
   raw=record_path.read_bytes()
   if len(raw)>1024*1024:return None,"record-size-limit"
   value=json.loads(raw)
   if raw!=(json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False)+"\n").encode():
    return None,"record-not-canonical"
   return value,None
  except (OSError,ValueError,TypeError):return None,"record-unavailable"
 production_record,production_error=canonical_record(production_record_path)
 gate_record_value,gate_error=canonical_record(gate_record)
 answer["build_records"]={"production":production_record if production_error is None else
  {"status":"unavailable","reason":production_error},"gate_only":gate_record_value if gate_error is None else
  {"status":"unavailable","reason":gate_error}}
 def build_relation():
  if production_error or gate_error:return {"status":"unavailable","reason":production_error or gate_error}
  if production_record.get("kind")!="shadow_cancel_release_build_record" or gate_record_value.get("kind")!="shadow_cancel_release_build_record":
   return {"status":"unavailable","reason":"record-kind"}
  production=production_record.get("body",{});gate=gate_record_value.get("body",{})
  required=("platform","architecture","source_sha256","build_script_sha256","compiler_path",
   "compiler_sha256","compiler_version_sha256","argv","argv_sha256","python_path","python_sha256",
   "python_implementation","python_version","soabi","ext_suffix","configuration","output_name",
   "output_size","output_sha256","test_build")
  if any(name not in production or production[name] is None or name not in gate or gate[name] is None for name in required):
   return {"status":"unavailable","reason":"build-field-missing"}
  if production.get("test_build") is not False or gate.get("test_build") is not True or gate.get("test_case")!=48:
   return {"status":"unavailable","reason":"build-role"}
  shared=("platform","architecture","source_sha256","build_script_sha256","compiler_path",
   "compiler_sha256","compiler_version_sha256","python_path","python_sha256","python_implementation",
   "python_version","soabi","ext_suffix","configuration")
  if any(production.get(name)!=gate.get(name) for name in shared):
   return {"status":"unavailable","reason":"source-recipe-runtime-mismatch"}
  if not isinstance(production["argv"],list) or not isinstance(gate["argv"],list):
   return {"status":"unavailable","reason":"argv-shape"}
  production_argv=list(production["argv"]);gate_argv=list(gate["argv"])
  defines=("-DYSTACK_CANCEL_RELEASE_TESTING=1","-DYSTACK_CANCEL_TEST_CASE=48")
  if any(gate_argv.count(value)!=1 for value in defines) or any(value in production_argv for value in defines):
   return {"status":"unavailable","reason":"testing-defines"}
  def actual_inputs(body,argv):
   sources=[pathlib.Path(value) for value in argv if value.endswith("/_cancel_release.c")]
   if len(sources)!=1:return {"status":"unavailable","reason":"source-path-count"}
   checks=((sources[0],"source_sha256"),(sources[0].with_name("build-cancel-release.sh"),"build_script_sha256"),
    (pathlib.Path(body["compiler_path"]),"compiler_sha256"),(pathlib.Path(body["python_path"]),"python_sha256"))
   rows=[]
   for actual,field in checks:
    measured=digest(actual)
    if measured.get("status")!="ok" or measured.get("sha256")!=body[field]:
     return {"status":"unavailable","reason":"actual-input-mismatch","field":field,"actual":str(actual)}
    rows.append({"field":field,"path":str(actual),"identity":measured})
   return {"status":"ok","inputs":rows}
  production_inputs=actual_inputs(production,production_argv);gate_inputs=actual_inputs(gate,gate_argv)
  if production_inputs["status"]!="ok" or gate_inputs["status"]!="ok":
   return {"status":"unavailable","reason":"actual-inputs","production":production_inputs,"gate":gate_inputs}
  reduced=[value for value in gate_argv if value not in defines]
  try:
   production_output=production_argv.index("-o")+1;gate_output=reduced.index("-o")+1
  except ValueError:return {"status":"unavailable","reason":"output-argument"}
  production_argv[production_output]="<output>";reduced[gate_output]="<output>"
  production_argv=["<source>" if value.endswith("/_cancel_release.c") else value for value in production_argv]
  reduced=["<source>" if value.endswith("/_cancel_release.c") else value for value in reduced]
  if production_argv!=reduced:return {"status":"unavailable","reason":"argv-difference"}
  if (gate["output_sha256"]!=gate_before["identity"].get("sha256") or
      gate["output_size"]!=gate_before["identity"].get("size") or
      production["output_sha256"]!=digest(native_binary).get("sha256") or
      production["output_size"]!=digest(native_binary).get("size")):
   return {"status":"unavailable","reason":"output-binding"}
  return {"status":"ok","origin":"gate-only-case-48","differences":[*defines,"source-path","output-path"],
   "production_record_sha256":production_record_before.get("sha256"),
   "gate_record_sha256":gate_record_before.get("sha256"),"production_inputs":production_inputs,
   "gate_inputs":gate_inputs,"shared_fields":list(shared)}
 answer["gate_only_provenance"]=build_relation()
 build_record_bytes=sum(row.get("size",786433) for row in (production_record_before,gate_record_before))
 if answer["gate_only_provenance"]["status"]=="ok":
  if recorded+build_record_bytes<=786432:recorded+=build_record_bytes
  else:answer["gate_only_provenance"]={"status":"unavailable","reason":"metadata-output-limit"}
 gate_after=None
 logical_families={"openat":("openat","openat64"),"fstat":("fstat","fstat64")}
 gate_symbols={"posix_spawn_file_actions_addclosefrom_np","posix_spawn_file_actions_adddup2",
  "posix_spawn_file_actions_addclose","posix_spawnattr_setflags","posix_spawnattr_setsigmask",
  "posix_spawnattr_setsigdefault"}
 def selected_function(logical,entries,status,role):
  if status["status"]!="ok" or provider_status["status"]!="ok":return {"symbol":logical,
   "status":"unavailable","reason":"symbol-metadata-incomplete","origin_role":role}
  family=logical_families.get(logical,(logical,))
  imports=[entry for entry in entries if entry["base"] in family and entry["section"]=="UND"]
  if len(imports)!=1:return {"symbol":logical,"status":"unavailable","reason":"native-symbol-count",
   "count":len(imports),"origin_role":role,"metadata_lines":[entry["line"] for entry in imports]}
  required=imports[0]
  provider=[entry for entry in provider_entries if entry["base"]==required["base"] and
   entry["version"]==required["version"] and entry["section"]!="UND" and entry["type"]=="FUNC"]
  locations={(entry["value"],entry["size"]) for entry in provider}
  if not provider or len(locations)!=1 or provider[0]["size"]<=0:
   return {"symbol":logical,"imported_symbol":required["base"],"required_version":required["version"],
    "status":"unavailable","reason":"provider-symbol-count-or-shape","count":len(provider),
    "origin_role":role,"metadata_lines":[required["line"],*(entry["line"] for entry in provider)]}
  selected=provider[0];aliases=[entry["line"] for entry in provider_entries if
   entry["section"]!="UND" and entry["type"]=="FUNC" and
   (entry["value"],entry["size"])==(selected["value"],selected["size"])]
  metadata_lines=list(dict.fromkeys([required["line"],selected["line"],*aliases]))
  return {"symbol":logical,"imported_symbol":required["base"],"required_version":required["version"],
   "origin_role":role,"selected":selected,"metadata_lines":metadata_lines}
 def range_body(label,start,end):
  nonlocal recorded
  if not (0<=start<end and end-start<=65536):return {"status":"unavailable","reason":"invalid-range"}
  argv=[objdump,"-d","--start-address=0x%x"%start,"--stop-address=0x%x"%end,path]
  if recorded>=786432:return {"label":label,"argv":argv,"status":"unavailable","reason":"recorded-total-limit"}
  try:
   result=subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=False,
    timeout=10,env={"PATH":"/usr/bin:/bin","LC_ALL":"C","LANG":"C"})
  except (OSError,subprocess.SubprocessError) as error:
   return {"label":label,"argv":argv,"status":"unavailable","reason":type(error).__name__}
  raw=result.stdout;error_raw=result.stderr
  row={"label":label,"argv":argv,"start":start,"end":end,"exit":result.returncode,"body_bytes":len(raw),
   "body_sha256":hashlib.sha256(raw).hexdigest(),"stderr_bytes":len(error_raw),
   "stderr_sha256":hashlib.sha256(error_raw).hexdigest()}
  has_instructions=bool(re.search(rb"(?m)^\s*[0-9a-f]+:\s+[0-9a-f][0-9a-f ]+\s+",raw))
  if len(raw)>65536 or len(error_raw)>8192 or recorded+len(raw)+len(error_raw)>786432:
   row.update({"status":"unavailable","reason":"output-limit"})
  else:
   row.update({"status":"ok" if result.returncode==0 and has_instructions else "unavailable",
    "reason":None if result.returncode==0 and has_instructions else "failed-or-no-instructions",
    "body":raw.decode("utf-8","replace"),"stderr":error_raw.decode("utf-8","replace")})
   if row["status"]=="ok":recorded+=len(raw)+len(error_raw)
  return row
 for symbol in symbols:
  if symbol=="setsid":
   answer["functions"].append({"symbol":symbol,"status":"unavailable",
    "reason":"spawn-child-entry-unresolved","origin_role":"spawn-child"});continue
  role="gate-only-case-48" if symbol in gate_symbols else "production-native"
  selected_row=selected_function(symbol,gate_entries if symbol in gate_symbols else native_entries,
   gate_status if symbol in gate_symbols else native_status,role)
  if role=="gate-only-case-48" and answer["gate_only_provenance"]["status"]!="ok":
   selected_row={"symbol":symbol,"status":"unavailable","reason":"gate-only-provenance",
    "origin_role":role,"provenance":answer["gate_only_provenance"]}
  if "selected" not in selected_row:
   answer["functions"].append(selected_row)
   continue
  selected=selected_row.pop("selected");metadata_lines=selected_row["metadata_lines"]
  metadata_bytes=sum(len(line.encode("utf-8"))+1 for line in metadata_lines)
  if recorded+metadata_bytes>786432:
   selected_row.update({"status":"unavailable","reason":"metadata-output-limit"})
   answer["functions"].append(selected_row)
   continue
  recorded+=metadata_bytes
  row=range_body(symbol,selected["value"],selected["value"]+selected["size"])
  row.update(selected_row);row.update({"metadata_lines":metadata_lines,
   "provider_type":selected["type"],"provider_bind":selected["bind"],
   "provider_visibility":selected["visibility"],"provider_section":selected["section"]})
  answer["functions"].append(row)
 image_identity=source_before["identity"];image_build_id=source_before["build_id"]
 answer["image_identity"]=image_identity;answer["image_build_id"]=image_build_id
 fixed_identity=(image_identity.get("sha256")=="3a15d66867d83762c7f2f1e37359cb8f6c5743edb369c65285cb0b1c4f7498bf" and
  image_build_id.get("value")=="a4a7992a8e66555c8141ab2a08a8465ff6e0ea65")
 internal=(0x10ffc0,0x98630,0x986b0,0x10f200,0x10f260,0x10f520,0x45340)
 if fixed_identity:
  targets={address:[] for address in internal};fde_ranges=[];current=None
  def flush_frame():
   nonlocal current
   if current is None:return
   start,end,lines=current
   for target in internal:
    if start<=target<end:targets[target].append((start,end,"".join(lines)))
   current=None
  def frames(raw):
   nonlocal current
   text=raw.decode("utf-8","replace")
   header=re.search(r"\b(CIE|FDE)\b",text)
   match=re.search(r"\bFDE\b.*\bpc=([0-9a-fA-F]+)\.\.([0-9a-fA-F]+)",text)
   if match:
    flush_frame()
    start,end=(int(value,16) for value in match.groups())
    fde_ranges.append((start,end))
    current=(start,end,[text]) if any(start<=target<end for target in internal) else None
   elif header:flush_frame()
   elif current is not None:current[2].append(text)
   if current is not None and text.strip()=="":flush_frame()
  frame_status=metadata([readelf,"--debug-dump=frames-interp",path],frames)
  flush_frame()
  answer["frame_metadata"]=frame_status
  for target in internal:
   if frame_status["status"]!="ok":
    answer["internal_functions"].append({"entry":target,"status":"unavailable",
     "reason":"frame-metadata-incomplete"});continue
   choices=targets[target]
   if len(choices)!=1:
    answer["internal_functions"].append({"entry":target,"status":"unavailable",
     "reason":"fde-count","count":len(choices)});continue
   start,end,block=choices[0];block_bytes=len(block.encode("utf-8"))
   if recorded+block_bytes>786432:
    answer["internal_functions"].append({"entry":target,"status":"unavailable",
     "reason":"metadata-output-limit"});continue
   recorded+=block_bytes;row=range_body("internal-0x%x"%target,start,end)
   row.update({"entry":target,"fde":block});answer["internal_functions"].append(row)
  callers=((0x10ffc0,0x10f520,"call"),("sigaction",0x45340,"jmp"))
  for source,target,opcode in callers:
   parent=next((row for row in (answer["functions"] if isinstance(source,str) else answer["internal_functions"])
    if row.get("symbol")==source or row.get("entry")==source),None)
   child=next((row for row in answer["internal_functions"] if row.get("entry")==target),None)
   lines=[] if parent is None or parent.get("status")!="ok" else [line for line in parent["body"].splitlines()
    if re.search(r"\b%s\w*\s+(?:0x)?%x\b"%(opcode,target),line)]
   if child is not None:child["caller"]={"source":source,"opcode":opcode,"lines":lines,
    "status":"ok" if len(lines)==1 else "unavailable"}
  parent=next((row for row in answer["internal_functions"] if row.get("entry")==0x10f520),None)
  references=[]
  if parent is not None and parent.get("status")=="ok":
   pattern=re.compile(r"^\s*[0-9a-f]+:\s+(?:[0-9a-f]{2}\s+)+(?:lea|mov)\w*\s+[^#\n]*\(%rip\),%r\w+\s+#\s*([0-9a-f]+)\b")
   for line in parent["body"].splitlines():
    match=pattern.match(line)
    if match:
     target=int(match.group(1),16);covering=[bounds for bounds in fde_ranges if bounds[0]<=target<bounds[1]]
     if len(covering)==1 and covering[0][0]==target:references.append((line,target,covering[0]))
  if len(references)==1:
   instruction,target,bounds=references[0];blocks=[];selected_block=None
   def candidate_frames(raw):
    nonlocal selected_block
    text=raw.decode("utf-8","replace");header=re.search(r"\b(CIE|FDE)\b",text)
    match=re.search(r"\bFDE\b.*\bpc=([0-9a-fA-F]+)\.\.([0-9a-fA-F]+)",text)
    if match:
     if selected_block is not None:blocks.append("".join(selected_block))
     selected_block=[text] if tuple(int(value,16) for value in match.groups())==bounds else None
    elif header:
     if selected_block is not None:blocks.append("".join(selected_block));selected_block=None
    elif selected_block is not None:selected_block.append(text)
    if selected_block is not None and text.strip()=="":blocks.append("".join(selected_block));selected_block=None
   candidate_status=metadata([readelf,"--debug-dump=frames-interp",path],candidate_frames)
   if selected_block is not None:blocks.append("".join(selected_block))
   answer["spawn_child_candidate_metadata"]=candidate_status
   if candidate_status["status"]=="ok" and len(blocks)==1:
    block=blocks[0];block_bytes=len(block.encode())
    if recorded+block_bytes<=786432:
     recorded+=block_bytes;candidate=range_body("spawn-child-codepointer-candidate",*bounds)
     candidate.update({"semantic_binding":"unresolved","candidate_kind":"codepointer-candidate",
      "parent_entry":0x10f520,"parent_instruction":instruction,"referenced_entry":target,"fde":block})
     answer["spawn_child_candidate"]=candidate
    else:answer["spawn_child_candidate"]={"status":"unavailable","reason":"metadata-output-limit",
     "semantic_binding":"unresolved","parent_entry":0x10f520,"parent_instruction":instruction}
   else:answer["spawn_child_candidate"]={"status":"unavailable","reason":"candidate-fde-count-or-metadata",
    "semantic_binding":"unresolved","parent_entry":0x10f520,"parent_instruction":instruction,
    "count":len(blocks)}
  else:answer["spawn_child_candidate"]={"status":"unavailable","reason":"codepointer-candidate-count",
   "semantic_binding":"unresolved","parent_entry":0x10f520,"count":len(references)}
 else:
  answer["frame_metadata"]={"status":"unavailable","reason":"fixed-libc-identity-mismatch",
   "identity":image_identity,"build_id":image_build_id}
  for target in internal:answer["internal_functions"].append({"entry":target,"status":"unavailable",
   "reason":"fixed-libc-identity-mismatch"})
 if "spawn_child_candidate" not in answer:
  answer["spawn_child_candidate"]={"status":"unavailable","reason":"fixed-libc-identity-mismatch",
   "semantic_binding":"unresolved"}
 answer["recorded_bytes"]=recorded;answer["limits"]={"public_functions":len(symbols),
  "internal_functions":len(internal),"body_each":65536,"stderr_each":8192,
  "recorded_total":786432,"timeout_seconds_each":10}
 source_after={"identity":digest(path),"build_id":build_id(path)}
 gate_after={"identity":digest(gate_binary),"build_id":build_id(gate_binary)}
 production_record_after=digest(production_record_path);gate_record_after=digest(gate_record)
 tools_after={name:digest(row["path"]) for name,row in answer["tools"].items()}
 answer["source_after"]=source_after;answer["gate_before"]=gate_before
 answer["gate_after"]=gate_after;answer["production_record_before"]=production_record_before
 answer["production_record_after"]=production_record_after;answer["gate_record_before"]=gate_record_before
 answer["gate_record_after"]=gate_record_after;answer["tools_after"]=tools_after
 source_valid=all((source_before["identity"].get("status")=="ok",
  bool(source_before["identity"].get("sha256")),source_before["build_id"].get("status")=="ok",
  bool(source_before["build_id"].get("value")),source_after["identity"].get("status")=="ok",
  bool(source_after["identity"].get("sha256")),source_after["build_id"].get("status")=="ok",
  bool(source_after["build_id"].get("value"))))
 tools_valid=all(answer["tools"][name]["identity"].get("status")=="ok" and
  answer["tools"][name]["identity"].get("sha256") and tools_after[name].get("status")=="ok" and
  tools_after[name].get("sha256") for name in answer["tools"])
 gate_valid=all((gate_before["identity"].get("status")=="ok",bool(gate_before["identity"].get("sha256")),
  gate_before["build_id"].get("status")=="ok",bool(gate_before["build_id"].get("value")),
  gate_after["identity"].get("status")=="ok",bool(gate_after["identity"].get("sha256")),
  gate_after["build_id"].get("status")=="ok",bool(gate_after["build_id"].get("value"))))
 records_valid=all(row.get("status")=="ok" and row.get("sha256") for row in
  (production_record_before,production_record_after,gate_record_before,gate_record_after))
 binding_ok=source_valid and gate_valid and tools_valid and records_valid and source_before==source_after and gate_before==gate_after and production_record_before==production_record_after and gate_record_before==gate_record_after and all(
  answer["tools"][name]["identity"]==tools_after[name] for name in answer["tools"])
 answer["evidence_binding"]={"status":"ok" if binding_ok else "unavailable",
  "reason":None if binding_ok else "source-or-tool-identity-missing-or-changed"}
 if answer["evidence_binding"]["status"]!="ok":answer["status"]="unavailable";answer["reason"]="binding-changed"
 return answer
def jit():
 api=getattr(sys,"_jit",None)
 if api is None:return {"status":"missing"}
 answer={"status":"present"}
 for name in ("is_available","is_enabled","is_active"):
  call=getattr(api,name,None)
  if call is None:answer[name]={"status":"missing"}
  else:
   try:answer[name]={"status":"ok","value":call()}
   except Exception as error:answer[name]={"status":"unavailable","reason":type(error).__name__}
 return answer
executable=os.path.realpath(sys.executable);suffixes=tuple(importlib.machinery.EXTENSION_SUFFIXES)
origins=[]
for loaded in tuple(sys.modules.values()):
 origin=getattr(getattr(loaded,"__spec__",None),"origin",None)
 if origin in (None,"built-in","frozen"):origin=getattr(loaded,"__file__",None)
 if origin and os.path.isabs(origin) and os.path.isfile(origin):origins.append(os.path.realpath(origin))
origins=sorted(set(origins));assert len(origins)<=256
build_jit=sysconfig.get_config_var("Py_ENABLE_JIT")
body={"platform":sys.platform,"executable":executable,"executable_identity":digest(executable),
 "flags":{"isolated":sys.flags.isolated,"no_site":sys.flags.no_site,
 "dont_write_bytecode":sys.flags.dont_write_bytecode},"jit":jit(),
 "preexec_environment":{"observed_keys":startup_environment_keys,"forbidden_keys":forbidden_startup_keys},
 "loaded_origins":[{"path":path,"identity":digest(path)} for path in origins],
 "soabi":sysconfig.get_config_var("SOABI"),"stdlib":os.path.realpath(sysconfig.get_path("stdlib")),
 "version":sys.version,"build_configuration":{"Py_ENABLE_JIT":{"status":"missing"} if build_jit is None
  else {"status":"present","value":build_jit}}}
if sys.platform=="linux":
 maps=pathlib.Path("/proc/self/maps").read_bytes();assert len(maps)<=1024*1024
 paths=[];map_gaps=[]
 for line in maps.decode("utf-8","strict").splitlines():
  fields=line.split(None,5)
  if len(fields)==6 and fields[5].startswith("/"):
   if fields[5].endswith(" (deleted)"):
    map_gaps.append({"path":fields[5],"status":"unavailable","reason":"deleted-mapping"});continue
   path=os.path.realpath(fields[5])
   if not os.path.isfile(path):
    map_gaps.append({"path":path,"status":"unavailable","reason":"missing-mapped-file"});continue
   with open(path,"rb") as image:header=image.read(4)
   if header==b"\x7fELF":paths.append(path)
 paths=sorted(set(paths));assert 1<=len(paths)<=64 and len(map_gaps)<=16
 elf_interpreter=interpreter(executable)
 interpreter_path=elf_interpreter.get("resolved")
 images=[]
 for path in paths:
  image_soname=soname(path);roles=[]
  if path==executable:roles.append("python-executable")
  if path==native_binary:roles.append("native-release")
  if path==interpreter_path:roles.append("elf-interpreter")
  if image_soname.get("value")=="libc.so.6":roles.append("libc")
  images.append({"path":path,"roles":roles,"identity":digest(path),"build_id":build_id(path),
   "soname":image_soname,"package":dpkg(path)})
 libc_paths=[image["path"] for image in images if "libc" in image["roles"]]
 body.update({"executable_build_id":build_id(executable),"elf_interpreter":elf_interpreter,
  "elf_images":images,"mapped_file_gaps":map_gaps,
  "libc_function_bodies":function_bodies(libc_paths[0]) if len(libc_paths)==1 else
   {"status":"unavailable","reason":"libc-role-count","count":len(libc_paths)},
  "required_roles":{role:sum(role in image["roles"] for image in images)
   for role in ("python-executable","native-release","elf-interpreter","libc")}})
else:
 native=sorted({executable,native_binary,*(path for path in origins if path.endswith(suffixes))})
 parts=pathlib.Path(executable).parts
 dyld=ctypes.CDLL(None)
 dyld._dyld_image_count.restype=ctypes.c_uint32
 dyld._dyld_get_image_header.argtypes=[ctypes.c_uint32];dyld._dyld_get_image_header.restype=ctypes.c_void_p
 dyld._dyld_get_image_name.argtypes=[ctypes.c_uint32];dyld._dyld_get_image_name.restype=ctypes.c_char_p
 def mapped_identity(address):
  header=ctypes.string_at(address,32);magic,cputype,cpusubtype,_filetype,ncmds,sizeofcmds,_flags,_reserved=struct.unpack("<8I",header)
  assert magic==0xfeedfacf and ncmds<=4096 and sizeofcmds<=4*1024*1024
  commands=ctypes.string_at(address+32,sizeofcmds);offset=0;values=[]
  for _ in range(ncmds):
   cmd,size=struct.unpack_from("<II",commands,offset);assert size>=8 and offset+size<=len(commands)
   if cmd==0x1b:assert size==24;values.append(str(uuid.UUID(bytes=commands[offset+8:offset+24])))
   offset+=size
  assert offset==len(commands) and len(values)==1
  return {"cpu_type":cputype,"cpu_subtype":cpusubtype,"uuid":values[0]}
 images=[]
 for index in range(dyld._dyld_image_count()):
  address=dyld._dyld_get_image_header(index);name=dyld._dyld_get_image_name(index)
  assert address and name
  images.append({"path":os.path.realpath(os.fsdecode(name)),"identity":mapped_identity(address)})
 class DlInfo(ctypes.Structure):
  _fields_=[("name",ctypes.c_char_p),("base",ctypes.c_void_p),("symbol",ctypes.c_char_p),("address",ctypes.c_void_p)]
 dyld.dladdr.argtypes=[ctypes.c_void_p,ctypes.POINTER(DlInfo)];dyld.dladdr.restype=ctypes.c_int
 bindings=[]
 for symbol in ("pthread_sigmask","fcntl","close","fstat","unlinkat","fsync"):
  function=getattr(dyld,symbol);info=DlInfo();assert dyld.dladdr(ctypes.cast(function,ctypes.c_void_p),ctypes.byref(info))==1
  identity=mapped_identity(info.base);locator=os.path.realpath(os.fsdecode(info.name))
  bindings.append({"symbol":symbol,"mapped_image":locator,"mapped_identity":identity,
   "locator_identity":command(["/usr/bin/dyld_info","-uuid",locator],4096)})
 cache=(ctypes.c_ubyte*16)();dyld._dyld_get_shared_cache_uuid.argtypes=[ctypes.POINTER(ctypes.c_ubyte)]
 dyld._dyld_get_shared_cache_uuid.restype=ctypes.c_bool;assert dyld._dyld_get_shared_cache_uuid(cache)
 body.update({"build_id":command(["/usr/bin/dwarfdump","--uuid",executable]),
  "native_dependencies":{path:command(["/usr/bin/otool","-L",path]) for path in native},
  "darwin_mapped_images":images,"darwin_release_symbol_bindings":bindings,
  "darwin_shared_cache_uuid":{"status":"ok","value":str(uuid.UUID(bytes=bytes(cache)))},
  "package":{"kind":"homebrew-cellar" if "Cellar" in parts else "system",
   "formula":parts[parts.index("Cellar")+1] if "Cellar" in parts else None,
   "version":parts[parts.index("Cellar")+2] if "Cellar" in parts else None}})
facts={"schema_version":1,"kind":"shadow_runtime_dependency_record",
 "id":"shadow.runtime-dependency","body":body}
encoded=(json.dumps(facts,sort_keys=True,separators=(",",":"),ensure_ascii=False)+"\n").encode()
assert len(encoded)<=1024*1024
sys.stdout.buffer.write(encoded)
PY
/bin/chmod 0400 "$tmp/runtime-dependency-collector.py"
cat > "$tmp/parent-input-helper.py" <<'PY'
import errno,hashlib,json,os,pathlib,re,stat,sys,sysconfig
FIXED_ENV={"LANG":"C","LC_ALL":"C","PATH":"/usr/bin:/bin"}
def startup_environment():
 environment=dict(os.environ);base={key:environment.pop(key,None) for key in FIXED_ENV}
 if base!=FIXED_ENV:raise OSError(errno.EACCES,"startup environment")
 if sys.platform=="darwin":
  value=environment.pop("__CF_USER_TEXT_ENCODING",None)
  match=re.fullmatch(r"0x([0-9A-Fa-f]+):0x([0-9A-Fa-f]+):0x([0-9A-Fa-f]+)",value or "")
  if match is None or int(match.group(1),16)!=os.getuid():raise OSError(errno.EACCES,"startup environment")
 if environment:raise OSError(errno.EACCES,"startup environment")
 return tuple(sorted(os.environ))
def pairs(values):
 result={}
 for key,value in values:
  if key in result:raise ValueError("duplicate key")
  result[key]=value
 return result
def canonical(raw):
 value=json.loads(raw,object_pairs_hook=pairs)
 if raw!=(json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False)+"\n").encode():raise ValueError("canonical")
 return value
def identity(value):return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_gid,value.st_nlink,value.st_size,value.st_mtime_ns,value.st_ctime_ns)
class ParentInputs:
 def __init__(self,package,physical_python,native_binary,build_record,dependency_record):
  self.environment_keys=startup_environment();self._fds=[None]*16;self._count=0;self._rows=[];self.package=pathlib.Path(package)
  self.physical_python=os.path.realpath(physical_python);self.native_binary=os.path.realpath(native_binary)
  try:self._prepare(pathlib.Path(build_record),pathlib.Path(dependency_record))
  except BaseException:
   try:self.close()
   except OSError:pass
   raise
 def hold(self,path,limit):
  path=pathlib.Path(path)
  if self._count>=len(self._fds):raise OSError(errno.E2BIG,"held inputs")
  fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC);index=self._count
  self._fds[index]=fd;self._count=index+1
  if os.get_inheritable(fd):raise OSError(errno.EIO,"inheritable input")
  before=os.fstat(fd)
  if not stat.S_ISREG(before.st_mode) or before.st_size>limit:raise OSError(errno.EFBIG,"input shape")
  raw=bytearray();remaining=before.st_size
  while remaining:
   chunk=os.read(fd,min(remaining,1024*1024))
   if not chunk:raise OSError(errno.EIO,"short input")
   raw.extend(chunk);remaining-=len(chunk)
  after=os.fstat(fd);named=os.lstat(path)
  if identity(before)!=identity(after) or (named.st_dev,named.st_ino)!=(after.st_dev,after.st_ino):raise OSError(errno.EIO,"input changed")
  row={"path":str(path),"identity":identity(after),"sha256":hashlib.sha256(raw).hexdigest(),"size":len(raw)}
  self._rows.append(row);return bytes(raw),row
 def _prepare(self,build_path,dependency_path):
  source=self.package/"shadow/v1/_cancel_release.c";script=self.package/"shadow/v1/build-cancel-release.sh"
  driver=self.package/"shadow/v1/enforced-reproduction.py";consumer=self.package/"shadow/v1/_consumer.py"
  python_raw,python_row=self.hold(self.physical_python,256*1024*1024)
  source_raw,source_row=self.hold(source,1024*1024);script_raw,script_row=self.hold(script,1024*1024)
  driver_raw,driver_row=self.hold(driver,4*1024*1024);consumer_raw,consumer_row=self.hold(consumer,1024*1024)
  native_raw,native_row=self.hold(self.native_binary,256*1024*1024)
  build_raw,_=self.hold(build_path,1024*1024);dependency_raw,_=self.hold(dependency_path,1024*1024)
  build=canonical(build_raw);dependency=canonical(dependency_raw)
  if set(build)!={"schema_version","kind","id","body"} or (build["schema_version"],build["kind"],build["id"])!=(1,"shadow_cancel_release_build_record","shadow.cancel-release.build"):raise ValueError("build envelope")
  body=build["body"];required=("platform","source_sha256","build_script_sha256","compiler_path","compiler_sha256","python_path","python_sha256","output_sha256","output_size","test_build","argv")
  build_keys={"platform","architecture","source_sha256","build_script_sha256","compiler_path","compiler_sha256","compiler_version_sha256","argv","argv_sha256","python_path","python_sha256","python_implementation","python_version","soabi","ext_suffix","configuration","output_name","output_size","output_sha256","test_build"}
  if not isinstance(body,dict) or set(body)!=build_keys or any(name not in body for name in required) or body["test_build"] is not False:raise ValueError("build body")
  compiler_raw,compiler_row=self.hold(body["compiler_path"],256*1024*1024)
  if (body["source_sha256"]!=source_row["sha256"] or body["build_script_sha256"]!=script_row["sha256"] or os.path.realpath(body["python_path"])!=self.physical_python or body["python_sha256"]!=python_row["sha256"] or body["compiler_sha256"]!=compiler_row["sha256"] or body["output_sha256"]!=native_row["sha256"] or body["output_size"]!=native_row["size"]):raise ValueError("build relation")
  if set(dependency)!={"schema_version","kind","id","body"} or (dependency["schema_version"],dependency["kind"],dependency["id"])!=(1,"shadow_runtime_dependency_record","shadow.runtime-dependency"):raise ValueError("dependency envelope")
  facts=dependency["body"]
  if not isinstance(facts,dict) or facts.get("platform")!=body["platform"] or os.path.realpath(facts.get("executable",""))!=self.physical_python:raise ValueError("runtime relation")
  common={"platform","executable","executable_identity","flags","jit","preexec_environment","loaded_origins","soabi","stdlib","version","build_configuration"}
  platform_keys={"executable_build_id","elf_interpreter","elf_images","mapped_file_gaps","libc_function_bodies","required_roles"} if facts["platform"]=="linux" else {"build_id","native_dependencies","darwin_mapped_images","darwin_release_symbol_bindings","darwin_shared_cache_uuid","package"}
  if set(facts)!=common|platform_keys:raise ValueError("dependency body")
  if facts.get("executable_identity")!={"status":"ok","sha256":python_row["sha256"],"size":python_row["size"]}:raise ValueError("runtime P")
  if facts.get("flags")!={"isolated":1,"no_site":1,"dont_write_bytecode":1} or facts.get("preexec_environment")!={"observed_keys":list(self.environment_keys),"forbidden_keys":[]}:raise ValueError("runtime startup")
  if facts.get("soabi")!=sysconfig.get_config_var("SOABI") or os.path.realpath(facts.get("stdlib",""))!=os.path.realpath(sysconfig.get_path("stdlib")) or facts.get("version")!=sys.version:raise ValueError("runtime metadata")
  origins=facts.get("loaded_origins")
  if not isinstance(origins,list):raise ValueError("origins")
  for item in origins:
   if set(item)!={"path","identity"} or not os.path.isabs(item["path"]):raise ValueError("origin shape")
   value=item["identity"]
   if set(value)!={"status","sha256","size"} or value["status"]!="ok" or not isinstance(value["sha256"],str) or len(value["sha256"])!=64 or not isinstance(value["size"],int) or value["size"]<0:raise ValueError("origin identity")
  for path,row in ((driver,driver_row),(consumer,consumer_row),(pathlib.Path(self.native_binary),native_row)):
   matches=[item for item in origins if os.path.realpath(item.get("path",""))==os.path.realpath(path)]
   if len(matches)!=1 or matches[0].get("identity")!={"status":"ok","sha256":row["sha256"],"size":row["size"]}:raise ValueError("origin relation")
  if facts["platform"]=="linux":
   images=facts.get("elf_images");roles=("python-executable","native-release","elf-interpreter","libc")
   if not isinstance(images,list) or facts.get("required_roles")!={role:1 for role in roles}:raise ValueError("ELF roles")
   native=[item for item in images if "native-release" in item.get("roles",[])]
   if len(native)!=1 or os.path.realpath(native[0].get("path",""))!=self.native_binary or native[0].get("identity")!={"status":"ok","sha256":native_row["sha256"],"size":native_row["size"]}:raise ValueError("ELF native")
   for role in ("elf-interpreter","libc"):
    item=next(item for item in images if role in item.get("roles",[]));self.hold(item["path"],256*1024*1024)
  elif facts["platform"]!="darwin":raise ValueError("platform")
  self.build=build;self.dependency=dependency;self.build_sha256=hashlib.sha256(build_raw).hexdigest();self.dependency_sha256=hashlib.sha256(dependency_raw).hexdigest();self.rows=tuple(self._rows)
 def recheck(self):
  for index,row in enumerate(self._rows):
   fd=self._fds[index];value=os.fstat(fd);named=os.lstat(row["path"])
   if identity(value)!=row["identity"] or (named.st_dev,named.st_ino)!=(value.st_dev,value.st_ino):raise OSError(errno.EIO,"input identity changed")
   os.lseek(fd,0,os.SEEK_SET);measured=hashlib.sha256();remaining=row["size"]
   while remaining:
    chunk=os.read(fd,min(remaining,1024*1024))
    if not chunk:raise OSError(errno.EIO,"input shortened")
    measured.update(chunk);remaining-=len(chunk)
   if measured.hexdigest()!=row["sha256"]:raise OSError(errno.EIO,"input bytes changed")
 def close(self):
  failure=None
  while self._count:
   index=self._count-1;fd=self._fds[index];self._fds[index]=None;self._count=index
   try:os.close(fd)
   except OSError as exc:
    if failure is None:failure=exc
  if failure is not None:raise failure
PY
/bin/chmod 0400 "$tmp/parent-input-helper.py"
native_actual_child_binary=$(/usr/bin/find "$tmp/native-case-48" -mindepth 1 -maxdepth 1 \
  -type f ! -name build-record.json -print)
[ -n "$native_actual_child_binary" ] && [ -f "$native_actual_child_binary" ] || fail 'native actual child output'
native_actual_child_record="$tmp/native-case-48/build-record.json"
for polluted_key in MallocStackLogging OBJC_PRINT_IMAGES LD_YSTACK_FIXTURE DYLD_YSTACK_FIXTURE \
  POSIX_SPAWN_FILTERING_RULES_PATH; do
  if /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C "$polluted_key=fixture" \
    "$python_bin" -I -S -B "$tmp/runtime-dependency-collector.py" "$root" "$native_binary" \
      "$native_actual_child_binary" "$native_actual_child_record" \
    > "$tmp/preexec-$polluted_key.stdout" 2> "$tmp/preexec-$polluted_key.stderr"; then
    fail "runtime dependency accepted $polluted_key"
  fi
  [ ! -s "$tmp/preexec-$polluted_key.stdout" ] || fail "runtime dependency wrote polluted output"
  /usr/bin/grep -Fx 'forbidden startup environment' "$tmp/preexec-$polluted_key.stderr" >/dev/null \
    || fail "runtime dependency returned wrong polluted refusal"
done
/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C \
  "$python_bin" -I -S -B "$tmp/runtime-dependency-collector.py" "$root" "$native_binary" \
    "$native_actual_child_binary" "$native_actual_child_record" \
  > "$tmp/runtime-dependency-record.json"
/usr/bin/printf 'shadow-runtime-preexec-environment: fixed clean startup and 5 polluted starts refused\n'
"$python_bin" -I -S -B - "$native_out/build-record.json" \
  "$tmp/runtime-dependency-record.json" <<'PY'
import hashlib,json,pathlib,sys
for kind,name,path in (("shadow_cancel_release_build_evidence","shadow.cancel-release.build-evidence",sys.argv[1]),
 ("shadow_runtime_dependency_evidence","shadow.runtime-dependency-evidence",sys.argv[2])):
 raw=pathlib.Path(path).read_bytes();assert len(raw)<=1024*1024
 record=json.loads(raw);assert raw==(json.dumps(record,sort_keys=True,separators=(",",":"),ensure_ascii=False)+"\n").encode()
 evidence={"schema_version":1,"kind":kind,"id":name,
  "body":{"record_sha256":hashlib.sha256(raw).hexdigest(),"record":record}}
 print(json.dumps(evidence,sort_keys=True,separators=(",",":"),ensure_ascii=False))
PY
for parent_env_case in lang path extra; do
  case "$parent_env_case" in
    lang) parent_env_args=(PATH=/usr/bin:/bin LC_ALL=C LANG=wrong) ;;
    path) parent_env_args=(PATH=/bin LC_ALL=C LANG=C) ;;
    extra) parent_env_args=(PATH=/usr/bin:/bin LC_ALL=C LANG=C EXTRA=wrong) ;;
  esac
  /usr/bin/env -i "${parent_env_args[@]}" "$python_bin" -I -S -B - \
    "$tmp/parent-input-helper.py" "$root" "$python_bin" "$native_binary" \
    "$native_out/build-record.json" "$tmp/runtime-dependency-record.json" \
    > "$tmp/parent-input-$parent_env_case.stdout" \
    2> "$tmp/parent-input-$parent_env_case.stderr" <<'PY'
import errno,importlib.util,pathlib,sys
path=pathlib.Path(sys.argv[1]);spec=importlib.util.spec_from_file_location("parent_input_helper",path)
helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
try:helper.ParentInputs(*sys.argv[2:])
except OSError as exc:
 assert exc.errno==errno.EACCES and str(exc)=="[Errno 13] startup environment"
 print("startup-environment-refused")
else:raise AssertionError("accepted altered startup environment")
PY
  [ ! -s "$tmp/parent-input-$parent_env_case.stderr" ] || fail "parent input $parent_env_case stderr"
  /usr/bin/grep -Fx 'startup-environment-refused' "$tmp/parent-input-$parent_env_case.stdout" \
    >/dev/null || fail "parent input accepted $parent_env_case"
done
/usr/bin/printf 'shadow-parent-input-environment: LANG/PATH value changes and an extra key refused\n'
/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C "$python_bin" -I -S -B - \
  "$tmp/parent-input-helper.py" "$root" "$python_bin" "$native_binary" \
  "$native_out/build-record.json" "$tmp/runtime-dependency-record.json" <<'PY'
import importlib.util,json,pathlib,sys
path=pathlib.Path(sys.argv[1]);spec=importlib.util.spec_from_file_location("parent_input_helper",path)
helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper);held=helper.ParentInputs(*sys.argv[2:])
try:
 held.recheck();print(json.dumps({"kind":"shadow_parent_input_mechanical_record",
  "build_sha256":held.build_sha256,"dependency_sha256":held.dependency_sha256,
  "environment_keys":held.environment_keys,"held_files":len(held.rows)},sort_keys=True,separators=(",",":")))
finally:held.close()
PY
"$python_bin" -I -S -B - "$root" "$native_actual_child_binary" <<'PY'
import atexit,errno,fcntl,importlib.util,json,os,pathlib,select,signal,stat,sys,time,types
root,binary=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2])
consumer_spec=importlib.util.spec_from_file_location("filter_parent_consumer",root/"shadow/v1/_consumer.py")
c=importlib.util.module_from_spec(consumer_spec);sys.modules[consumer_spec.name]=c;consumer_spec.loader.exec_module(c)
environment=(b"LANG=C",b"LC_ALL=C",b"PATH=/usr/bin:/bin")
def owner():
 spec=importlib.util.spec_from_file_location("_cancel_release",binary)
 module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
 state=module.prepare_state();state.block_entry();state.arm_consumer();return state
def observe(state):
 deadline=time.monotonic()+5
 while not state.child_status()[11]:
  state.observe_child_exit();assert time.monotonic()<deadline;time.sleep(.01)
def close_at_eof(state,fd,close):
 deadline=time.monotonic()+5
 while True:
  readable,_,_=select.select([fd],[],[],max(0,deadline-time.monotonic()))
  assert readable
  if not os.read(fd,4096):break
 close()

class MissingFilterComponent(Exception):pass
class DefaultFilterHold:
 def __init__(self,open_fn=os.open,metadata_fn=c._metadata,named_fn=c._named_metadata,
              acl_fn=None,free_fn=None,close_fn=os.close,inheritable_fn=os.get_inheritable,
              rows_factory=list):
  self._open,self._metadata,self._named=open_fn,metadata_fn,named_fn
  self._acl,self._free,self._close,self._inheritable=acl_fn,free_fn,close_fn,inheritable_fn
  self._owners=[None,None,None,None];self._owner_count=0
  self._rows=rows_factory();self._missing=None;self._acl_results=[]
  try:self._prepare()
  except BaseException:
   try:self.close()
   except OSError:pass
   raise
 def _identity(self,value):return c._identity(value)
 def _protected(self,value):
  return stat.S_ISDIR(value.st_mode) and value.st_uid==0 and not stat.S_IMODE(value.st_mode)&0o022
 def _no_acl(self,fd):
  pointer,error=self._acl(fd)
  if pointer:
   released=None
   try:pass
   finally:
    released=self._free(pointer);self._acl_results.append((fd,True,error,released))
    if released!=0:raise OSError(errno.EIO,"acl_free")
   raise OSError(errno.EACCES,"extended ACL property")
  self._acl_results.append((fd,False,error,None))
  if error!=errno.ENOENT:raise OSError(error or errno.EIO,"acl_get_fd_np")
 def _take(self,name,parent):
  flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC
  if self._owner_count>=len(self._owners):raise OSError(errno.E2BIG,"filter parent count")
  try:fd=self._open(name,flags) if parent is None else self._open(name,flags,dir_fd=parent)
  except OSError as exc:
   if parent is not None and exc.errno==errno.ENOENT:raise MissingFilterComponent from None
   raise
  self._owners[self._owner_count]=fd;self._owner_count+=1
  if self._inheritable(fd):raise OSError(errno.EIO,"inheritable filter parent")
  value=self._metadata(fd)
  if not self._protected(value):raise OSError(errno.EACCES,"unprotected filter parent")
  if parent is not None and self._identity(self._named(name,parent))!=self._identity(value):
   raise OSError(errno.EIO,"filter parent name mismatch")
  self._no_acl(fd);self._rows.append((fd,name,self._identity(value)))
  return fd
 def _absent(self,name,parent):
  try:self._named(name,parent)
  except OSError as exc:
   if exc.errno==errno.ENOENT:return
   raise
  raise OSError(errno.EEXIST,"filter component appeared")
 def _prepare(self):
  parent=self._take("/",None)
  for name in ("usr","local","share"):
   try:parent=self._take(name,parent)
   except MissingFilterComponent:
    self._missing=(parent,name);self._absent(name,parent);return
  self._missing=(parent,"posix_spawn_filtering_rules");self._absent(self._missing[1],parent)
 def recheck(self):
  for index,(fd,name,before) in enumerate(self._rows):
   value=self._metadata(fd)
   if not self._protected(value) or self._identity(value)!=before:raise OSError(errno.EIO,"filter parent changed")
   if index and self._identity(self._named(name,self._rows[index-1][0]))!=before:
    raise OSError(errno.EIO,"filter parent name changed")
   self._no_acl(fd)
  self._absent(self._missing[1],self._missing[0])
 def close(self):
  failure=None
  while self._owner_count:
   index=self._owner_count-1;fd=self._owners[index]
   self._owners[index]=None;self._owner_count=index
   try:self._close(fd)
   except OSError as exc:
    if failure is None:failure=exc
  if failure is not None:raise failure

class FakeFilter:
 def __init__(self,missing="share"):
  self.nodes={"/":self.meta(ino=1)}
  if missing!="usr":self.nodes["/usr"]=self.meta(ino=2)
  if missing not in ("usr","local"):self.nodes["/usr/local"]=self.meta(ino=3)
  if missing not in ("usr","local","share"):self.nodes["/usr/local/share"]=self.meta(ino=4)
  self.fds={};self.next=20;self.closed=[];self.acl={};self.freed=[];self.close_error=set();self.open_error={}
 def meta(self,uid=0,mode=stat.S_IFDIR|0o755,ino=1):
  return types.SimpleNamespace(st_dev=1,st_ino=ino,st_mode=mode,st_uid=uid,st_gid=0,st_nlink=1,
   st_size=0,st_mtime_ns=1,st_ctime_ns=1)
 def open(self,name,flags,dir_fd=None):
  parent="" if dir_fd is None else self.fds[dir_fd].rstrip("/");path="/" if name=="/" else parent+"/"+name
  if path in self.open_error:raise OSError(self.open_error[path],"open refusal")
  if path not in self.nodes:raise OSError(errno.ENOENT,"missing")
  assert flags&(os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC)==os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC
  fd=self.next;self.next+=1;self.fds[fd]=path;return fd
 def metadata(self,fd):return self.nodes[self.fds[fd]]
 def named(self,name,parent):
  path=self.fds[parent].rstrip("/")+"/"+name
  if path not in self.nodes:raise OSError(errno.ENOENT,"missing")
  return self.nodes[path]
 def capture(self,fd):return self.acl.get(self.fds[fd],(None,errno.ENOENT))
 def free(self,pointer):self.freed.append(pointer);return -1 if pointer=="free-fails" else 0
 def close(self,fd):
  self.closed.append(fd)
  if fd in self.close_error:raise OSError(errno.EIO,"close")
def fake_hold(fake):
 return DefaultFilterHold(fake.open,fake.metadata,fake.named,fake.capture,fake.free,fake.close,lambda _fd:False)
for missing,count in (("usr",1),("local",2),("share",3),("rule",4)):
 fake=FakeFilter(missing);hold=fake_hold(fake);hold.recheck();hold.close();assert len(fake.closed)==count and len(set(fake.closed))==count
for failure in (errno.ELOOP,errno.ENOTDIR,errno.EACCES):
 fake=FakeFilter();fake.open_error["/usr"]=failure
 try:fake_hold(fake)
 except OSError as exc:assert exc.errno==failure
 else:raise AssertionError("accepted filter open refusal")
 assert len(fake.closed)==1
for change in (lambda f:f.nodes.__setitem__("/usr",f.meta(uid=1)),
               lambda f:f.nodes.__setitem__("/usr",f.meta(mode=stat.S_IFDIR|0o775)),
               lambda f:f.nodes.__setitem__("/usr",f.meta(mode=stat.S_IFREG|0o755))):
 fake=FakeFilter();change(fake)
 try:fake_hold(fake)
 except OSError:pass
 else:raise AssertionError("accepted unprotected filter parent")
 assert len(fake.closed)==len(set(fake.closed))
for result in ((None,0),(None,errno.EACCES),("nonempty",0),("empty",0),("free-fails",0)):
 fake=FakeFilter();fake.acl["/"]=result
 try:fake_hold(fake)
 except OSError:pass
 else:raise AssertionError("accepted filter ACL refusal")
 assert len(fake.freed)==(1 if result[0] else 0) and len(fake.closed)==len(set(fake.closed))
fake=FakeFilter();hold=fake_hold(fake);fake.nodes["/usr/local/share"]=fake.meta()
try:hold.recheck()
except OSError:pass
else:raise AssertionError("accepted appeared filter component")
hold.close()
fake=FakeFilter();hold=fake_hold(fake);fake.nodes["/usr/local"].st_ctime_ns=2
try:hold.recheck()
except OSError:pass
else:raise AssertionError("accepted changed filter parent")
hold.close()
fake=FakeFilter();hold=fake_hold(fake);fake.nodes["/usr/local"]=fake.meta(ino=99)
try:hold.recheck()
except OSError:pass
else:raise AssertionError("accepted replaced filter parent name")
hold.close()
fake=FakeFilter();hold=fake_hold(fake);fake.close_error.add(hold._owners[hold._owner_count-1])
try:hold.close()
except OSError:pass
else:raise AssertionError("ignored filter parent close failure")
assert len(fake.closed)==len(set(fake.closed));hold.close();assert len(fake.closed)==len(set(fake.closed))
fake=FakeFilter()
try:DefaultFilterHold(fake.open,fake.metadata,fake.named,fake.capture,fake.free,fake.close,
                       lambda _fd:(_ for _ in ()).throw(MemoryError()))
except MemoryError:pass
else:raise AssertionError("accepted post-open owner interruption")
assert len(fake.closed)==1
class FailingRows(list):
 def append(self,_value):raise MemoryError()
fake=FakeFilter()
try:DefaultFilterHold(fake.open,fake.metadata,fake.named,fake.capture,fake.free,fake.close,
                       lambda _fd:False,FailingRows)
except MemoryError:pass
else:raise AssertionError("accepted late row interruption")
assert len(fake.closed)==1
class StopClose(BaseException):pass
fake=FakeFilter();hold=fake_hold(fake);first=hold._owners[hold._owner_count-1]
def stop_close(fd):
 fake.closed.append(fd)
 if fd==first:raise StopClose()
hold._close=stop_close
try:hold.close()
except StopClose:pass
else:raise AssertionError("lost close interruption")
assert fake.closed==[first] and hold._owner_count==2 and first not in hold._owners
hold._close=fake.close;hold.close();assert len(fake.closed)==3 and len(set(fake.closed))==3
print("default-filter-parent-fixture: fixed path, ACL refusal, identity and owner controls passed")

actual_filter=None
if sys.platform=="darwin":
 lib=c._DARWIN_ACL_FUNCTIONS.library
 def actual_acl(fd):
  import ctypes
  ctypes.set_errno(0);pointer=lib.acl_get_fd_np(fd,0x100);return pointer,ctypes.get_errno()
 actual_filter=DefaultFilterHold(acl_fn=actual_acl,free_fn=lib.acl_free)
 def actual_filter_final():
  try:actual_filter.recheck()
  finally:actual_filter.close()
 atexit.register(actual_filter_final)
 actual_filter.recheck()

# The positive keeps the leader waitable while a same-group descendant ignores TERM.
state=owner()
inherited=os.open("/dev/null",os.O_RDONLY);high=fcntl.fcntl(inherited,fcntl.F_DUPFD,200)
os.set_inheritable(inherited,True);os.set_inheritable(high,True)
filter_fds=tuple(actual_filter._owners[:actual_filter._owner_count]) if actual_filter is not None else ()
program=(b'''import errno,json,os,signal
def absent(fd):
 try:os.fstat(fd)
 except OSError as exc:return exc.errno==errno.EBADF
 return False
def finish(_sent,_frame):raise SystemExit(0)
signal.signal(signal.SIGTERM,finish);leader=os.getpid();ready_r,ready_w=os.pipe();reaper=os.fork()
if reaper==0:
 os.close(ready_r);os.setpgid(0,0);child=os.fork()
 if child==0:
  os.close(ready_w);os.setpgid(0,leader);signal.signal(signal.SIGTERM,signal.SIG_IGN)
  os.write(1,(json.dumps({"kind":"descendant","pid":os.getpid(),"pgid":os.getpgrp(),"uid":os.getuid()},sort_keys=True,separators=(",",":"))+"\\n").encode())
  while True:signal.pause()
 os.write(ready_w,(str(child)+"\\n").encode());os.close(ready_w);os.waitpid(child,0);os._exit(0)
os.close(ready_w);child=int(os.read(ready_r,32));os.close(ready_r)
os.write(1,(json.dumps({"kind":"leader","pid":leader,"pgid":os.getpgrp(),"uid":os.getuid(),"descendant":child,"inherited_absent":absent(%d),"high_absent":absent(%d),"filter_absent":all(absent(fd) for fd in %r)},sort_keys=True,separators=(",",":"))+"\\n").encode())
while True:signal.pause()
''' % (inherited,high,filter_fds))
argv=(sys.executable.encode(),b"-I",b"-S",b"-B",b"-c",program)
state.prepare_child((12,argv[0],argv,environment));state.spawn_child()
stdin_fd,stdout_fd,stderr_fd=state.child_fds();state.close_child_stdin()
records=[];buffer=b"";deadline=time.monotonic()+5
while len(records)<2:
 readable,_,_=select.select([stdout_fd],[],[],max(0,deadline-time.monotonic()));assert readable
 chunk=os.read(stdout_fd,4096);assert chunk;buffer+=chunk
 while b"\n" in buffer:
  line,buffer=buffer.split(b"\n",1);records.append(json.loads(line))
leader=next(item for item in records if item["kind"]=="leader")
descendant=next(item for item in records if item["kind"]=="descendant")
assert leader["pid"]==leader["pgid"]==descendant["pgid"]
assert leader["descendant"]==descendant["pid"] and leader["uid"]==descendant["uid"]==os.getuid()
assert leader["inherited_absent"] and leader["high_absent"] and leader["filter_absent"]
os.close(high);os.close(inherited)
state.term_child_group();observe(state);before=state.child_status();assert before[17]==0
state.kill_child_group();after_kill=state.child_status();assert after_kill[45:47]==(0,0)
close_at_eof(state,stdout_fd,state.close_child_stdout);close_at_eof(state,stderr_fd,state.close_child_stderr)
state.reap_child();state.check_child_group();final=state.child_status()
print("actual-descendant-final",sys.platform,final,flush=True)
assert final[17:20]==(1,1,1) and final[24]==1 and final[47:49]==(-1,errno.ESRCH)
print("actual-descendant-group",leader,descendant,final[17:25])
state.abort_release();assert state.outcome()=="native-release.failure"

# A separate State gets a real Darwin UNKNOWN last, because it must not be reused.
state=owner();argv=(sys.executable.encode(),b"-I",b"-S",b"-B",b"-c",b"import signal;signal.pause()")
state.prepare_child((12,argv[0],argv,environment));state.spawn_child()
state.close_child_stdin();state.close_child_stdout();state.close_child_stderr()
state.term_child_group();observe(state);state.kill_child_group();negative=state.child_status()
if sys.platform=="darwin":
 assert negative[45:47]==(-1,errno.EPERM) and negative[23]==33 and not negative[24]
 try:state.reap_child()
 except RuntimeError:pass
 else:raise AssertionError("unknown group duty allowed reap")
 state.check_child_group();negative=state.child_status()
 assert negative[47:49]==(-1,errno.EPERM) and not negative[17] and not negative[24]
else:
 assert negative[45:47]==(0,0)
 state.reap_child();state.check_child_group();negative=state.child_status()
 assert negative[17:20]==(1,1,1) and negative[24]==1 and negative[47:49]==(-1,errno.ESRCH)
 state.abort_release();assert state.outcome()=="native-release.failure"
print("actual-single-leader",sys.platform,negative[45:49],negative[23:25])
if actual_filter is not None:
 actual_filter_final();atexit.unregister(actual_filter_final)
 print("actual-default-filter-parent",[(name,identity) for _fd,name,identity in actual_filter._rows],
  actual_filter._missing[1],actual_filter._acl_results)
PY
"$python_bin" -I -S -B - "$root" "$native_control_binary" <<'PY'
import importlib.util,pathlib,sys,types
root=pathlib.Path(sys.argv[1]);binary=sys.argv[2]
driver_spec=importlib.util.spec_from_file_location("prepare_owner",root/"shadow/v1/enforced-reproduction.py")
e=importlib.util.module_from_spec(driver_spec);sys.modules[driver_spec.name]=e;driver_spec.loader.exec_module(e)
native_spec=importlib.util.spec_from_file_location("_cancel_release",binary)
module=importlib.util.module_from_spec(native_spec);native_spec.loader.exec_module(module)
state=module.prepare_state();state.block_entry();state.arm_consumer()
class LostPrepareReturn:
 def __getattr__(self,name):return getattr(state,name)
 def prepare_child(self,value):state.prepare_child(value);raise RuntimeError("lost prepare return")
e.CancellationSignals.active=types.SimpleNamespace(native=LostPrepareReturn())
env={"PATH":"/usr/bin:/bin","LC_ALL":"C","LANG":"C"}
try:e.spawn_bounded("helper-version",[sys.executable,"-I","-S","-B","-c","pass"],b"",16,16,1,env)
except RuntimeError as exc:assert str(exc)=="lost prepare return"
else:raise AssertionError("lost prepare return accepted")
before=state.child_status();assert before[0]==1 and before[1]==0 and before[19]==0
state.abort_release();after=state.child_status()
assert after[0]==0 and after[1]==0 and after[19]==1
assert all(after[index]==1 for index in (25,28,31,34,37,40))
print("shadow-enforced-native-prepare-owner: lost return released six owned fds without child effect")
PY
! /usr/bin/grep -Eq 'ptrauth|malloc_zone|observe_allocator|resume_consumer' "$root/shadow/v1/_cancel_release.c" || fail 'obsolete allocator/PAC owner remains'
! /usr/bin/grep -q -- '-fptrauth-' "$native_out/build-record.json" || fail 'obsolete PAC flags remain'
native_test_binary=$(/usr/bin/find "$tmp/native-case-1" -mindepth 1 -maxdepth 1 -type f ! -name build-record.json -print)
"$python_bin" -I -S -B - "$root" "$native_test_binary" "$tmp/native-case-1/build-record.json" \
  "$native_binary" "$native_out/build-record.json" "$tmp" <<'PY'
import hashlib,importlib.util,json,os,pathlib,shutil,sys,sysconfig,types
root,binary,record,production,production_record,base=map(pathlib.Path,sys.argv[1:])
spec=importlib.util.spec_from_file_location("test_build_refusal",root/"shadow/v1/enforced-reproduction.py")
e=importlib.util.module_from_spec(spec);sys.modules[spec.name]=e;spec.loader.exec_module(e)
sha=lambda raw:hashlib.sha256(raw).hexdigest()
executable=e.stable_file(pathlib.Path(e.sys.executable))
admission=e._StartupAdmission(e._STARTUP_KEY,e.sys.executable,executable.sha256,e.sys.version,
 tuple(e.sys.version_info[:2]),e._runtime_module_origins(),object());executable.close()
context={"native_release":{"source_sha256":sha((root/"shadow/v1/_cancel_release.c").read_bytes()),
 "build_script_sha256":sha((root/"shadow/v1/build-cancel-release.sh").read_bytes()),
 "build_record_sha256":sha(record.read_bytes()),"binary_path":str(binary),
 "binary_size":binary.stat().st_size,"binary_sha256":sha(binary.read_bytes()),
 "python_path":os.path.realpath(sys.executable),"python_sha256":sha(pathlib.Path(sys.executable).read_bytes()),
 "python_abi":sysconfig.get_config_var("SOABI"),"dependency_record_sha256":"0"*64,
 "loader_mode":"rtld-now-local.v1"}}
try:e._NativeRelease(context,admission)
except e.Refusal as exc:assert exc.code=="E_DEPENDENCY" and "_cancel_release" not in sys.modules
else:raise AssertionError("test-only native binary received production admission")
print("shadow-enforced-native-admission: test build refused before import")
original=json.loads(production_record.read_bytes())
production_native=dict(context["native_release"],
 build_record_sha256=sha(production_record.read_bytes()),binary_path=str(production),
 binary_size=production.stat().st_size,binary_sha256=sha(production.read_bytes()))
def outcome_binding_case(outcome):
 class NativeState:
  def __init__(self):self.calls=[]
  def __getattr__(self,name):
   if name=="outcome":return lambda:self.calls.append("outcome") or outcome
   if name=="child_status":return lambda:self.calls.append("child_status") or ((0,)*49)
   return lambda:None
 state=NativeState()
 class Loader:
  @staticmethod
  def exec_module(_module):return None
 fake_spec=types.SimpleNamespace(loader=Loader())
 fake_module=types.SimpleNamespace(prepare_state=lambda:state)
 original_spec=e.importlib.util.spec_from_file_location
 original_module=e.importlib.util.module_from_spec
 original_origin=e._NATIVE_ORIGIN
 e.importlib.util.spec_from_file_location=lambda *_args,**_kwargs:fake_spec
 e.importlib.util.module_from_spec=lambda _spec:fake_module
 e._NATIVE_ORIGIN=None
 try:
  try:native=e._NativeRelease({"native_release":production_native},admission)
  except e.Refusal as exc:
   assert outcome!="native-release.pending" and exc.code=="E_RUNTIME"
   assert state.calls==["outcome"]
   return "refused"
  assert outcome=="native-release.pending" and state.calls==["outcome"]
  native.close();return "accepted"
 finally:
  e.importlib.util.spec_from_file_location=original_spec
  e.importlib.util.module_from_spec=original_module
  e._NATIVE_ORIGIN=original_origin
  sys.modules.pop("_cancel_release",None)
assert outcome_binding_case("native-release.pending")=="accepted"
assert outcome_binding_case("native-release.failure")=="refused"
print("shadow-enforced-native-outcome: simulated pending accepted and non-pending refused")
class Census:
 def observe(self):pass
class ExitNative:
 def __init__(self,native_outcome="native-release.success",commit_error=None,getter_error=None):
  self.native_outcome="native-release.pending";self.commit_outcome=native_outcome;self.commit_error=commit_error
  self.getter_error=getter_error;self.committed=False;self.aborted=False
 def block_final(self):pass
 def commit_completion(self,_payload):
  self.committed=True;self.native_outcome=self.commit_outcome
  if self.commit_error is not None:raise self.commit_error
 def abort_release(self):self.aborted=True;self.native_outcome="native-release.failure"
 def outcome(self):
  if self.getter_error is not None and (self.committed or self.aborted):
   error=self.getter_error;self.getter_error=None;raise error
  return self.native_outcome
class PreEntryNative(ExitNative):
 def __init__(self,commit_error,abort_error=None):
  super().__init__(commit_error=commit_error);self.abort_error=abort_error;self.abort_calls=0
 def commit_completion(self,_payload):raise self.commit_error
 def abort_release(self):
  self.abort_calls+=1;self.aborted=True;self.native_outcome="native-release.failure"
  if self.abort_error is not None:raise self.abort_error
def exit_owner(native):
 owner=e.CancellationSignals();owner.native=native
 owner.admission=types.SimpleNamespace(census=Census())
 owner.completion_confirmed=True;owner.completion_payload=b"{}\n"
 e.CancellationSignals.active=owner
 return owner
caller=RuntimeError("post-L caller")
try:exit_owner(ExitNative(commit_error=caller)).__exit__(None,None,None)
except RuntimeError as exc:assert exc is caller
else:raise AssertionError("post-L caller interruption hidden")
native_failure=RuntimeError("native commit return")
try:exit_owner(ExitNative("native-release.failure",native_failure)).__exit__(None,None,None)
except e.Refusal as exc:assert exc.code=="E_RUNTIME" and exc.__cause__ is native_failure
else:raise AssertionError("native failure lost authoritative priority")
commit_interrupt=RuntimeError("commit return")
getter_interrupt=RuntimeError("outcome observation")
getter_owner=exit_owner(ExitNative(commit_error=commit_interrupt,getter_error=getter_interrupt))
try:getter_owner.__exit__(None,None,None)
except RuntimeError as exc:assert exc is getter_interrupt and exc.__cause__ is commit_interrupt and getter_owner.caller_exception is exc
else:raise AssertionError("outcome observation interruption hidden")
not_run=RuntimeError("commit did not enter native")
not_run_native=PreEntryNative(not_run)
try:exit_owner(not_run_native).__exit__(None,None,None)
except RuntimeError as exc:assert exc is not_run and not_run_native.abort_calls==1 and not_run_native.aborted
else:raise AssertionError("pending commit interruption skipped native abort")
late_abort=RuntimeError("abort return interruption")
lost_abort_native=PreEntryNative(not_run,late_abort)
try:exit_owner(lost_abort_native).__exit__(None,None,None)
except RuntimeError as exc:
 assert exc is late_abort and exc.__cause__ is not_run and lost_abort_native.abort_calls==1
else:raise AssertionError("late abort interruption hidden")
earlier=ValueError("earlier body")
later=RuntimeError("later outcome observation")
later_owner=exit_owner(ExitNative("native-release.failure",getter_error=later))
try:later_owner.__exit__(ValueError,earlier,None)
except RuntimeError as exc:assert exc is later and exc.__cause__ is earlier and later_owner.caller_exception is exc
else:raise AssertionError("new outcome observation did not cross the outer boundary")
observation_errors=(ValueError("value observation"),OSError(e.errno.EIO,"os observation"),
 e.Refusal("E_RUNTIME"),e.c.Refusal("E_RUNTIME"),e.Cancelled(),RuntimeError("runtime observation"))
for observation_error in observation_errors:
 observation_owner=exit_owner(ExitNative(getter_error=observation_error))
 try:observation_owner.__exit__(None,None,None)
 except BaseException as exc:assert exc is observation_error and observation_owner.caller_exception is exc
 else:raise AssertionError("observation exception class was hidden")
e.CancellationSignals.active=None
class OuterNative:
 def __init__(self):self.close_calls=0
 def close(self):self.close_calls+=1
class OuterOwner:
 def __init__(self,error):self.error=error;self.caller_exception=None
 def __enter__(self):return self
 def __exit__(self,*_args):self.caller_exception=self.error;raise self.error
original_release=e._NativeRelease;original_owner=e.CancellationSignals
original_capture=e.c.capture_parent_context;original_reproduce=e.reproduce
try:
 for observation_error in observation_errors:
  outer_native=OuterNative();outer_owner=OuterOwner(observation_error)
  e._NativeRelease=lambda *_args,native=outer_native,**_kwargs:native
  e.CancellationSignals=lambda *_args,owner=outer_owner,**_kwargs:owner
  e.c.capture_parent_context=lambda:{};e.reproduce=lambda *_args,**_kwargs:None
  try:e.main(["driver","reproduce","request","work","output"],admission)
  except BaseException as exc:assert exc is observation_error and outer_native.close_calls==1
  else:raise AssertionError("outer main fabricated an observation result")
finally:
 e._NativeRelease=original_release;e.CancellationSignals=original_owner
 e.c.capture_parent_context=original_capture;e.reproduce=original_reproduce
print("shadow-enforced-native-outcome-events: simulated authority and caller ordering passed")
expected=[os.path.realpath("/usr/bin/cc"),"-std=gnu11" if sys.platform=="darwin" else "-std=c11",
 "-Wall","-Wextra","-Werror","-O2","-fvisibility=hidden","-fPIC",
 "-I"+os.path.realpath(sysconfig.get_config_var("INCLUDEPY")),
 "-I"+os.path.realpath(sysconfig.get_config_var("CONFINCLUDEPY"))]
expected += (["-bundle","-undefined","dynamic_lookup"]
             if sys.platform=="darwin" else ["-shared"])
expected += [str(root/"shadow/v1/_cancel_release.c"),"-o",str(production)]
assert original["body"]["argv"]==expected
def mutation(name,change):
 directory=base/("native-record-"+name);directory.mkdir()
 target=directory/production.name;shutil.copyfile(production,target);target.chmod(0o500)
 document=json.loads(production_record.read_bytes());change(document["body"]["argv"])
 document["body"]["argv_sha256"]=sha(e.canonical(document["body"]["argv"]))
 changed=directory/"build-record.json";changed.write_bytes(e.canonical(document));changed.chmod(0o400)
 native=dict(context["native_release"],build_record_sha256=sha(changed.read_bytes()),
  binary_path=str(target),binary_size=target.stat().st_size,binary_sha256=sha(target.read_bytes()))
 try:e._NativeRelease({"native_release":native},admission)
 except e.Refusal as exc:assert exc.code=="E_DEPENDENCY" and "_cancel_release" not in sys.modules
 else:raise AssertionError("accepted native argv mutation "+name)
mutation("missing-link-mode",lambda a:a.remove("-bundle") if sys.platform=="darwin" else a.remove("-shared"))
mutation("repeated-link-mode",lambda a:a.insert(a.index("-bundle") if sys.platform=="darwin" else a.index("-shared"),
 "-bundle" if sys.platform=="darwin" else "-shared"))
mutation("reordered-link-mode",lambda a:a.__setitem__(slice(a.index("-bundle"),a.index("dynamic_lookup")+1),
 ["-undefined","dynamic_lookup","-bundle"]) if sys.platform=="darwin" else a.reverse())
print("shadow-enforced-native-argv: exact recipe and three mutations checked")
PY
/usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 \
  "$root/adapters/local-git-materializer/v1/object-closure.c" -o "$tmp/object-closure"
/bin/chmod 0555 "$tmp/object-closure"

/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C \
  "$python_bin" -I -S -B - "$root" "$tmp" "$tmp/object-closure" "$jq_bin" \
  "$native_binary" "$native_out/build-record.json" "$tmp/runtime-dependency-record.json" <<'PY'
import os
startup_environment_keys=tuple(sorted(os.environ))
import hashlib, importlib.util, json, pathlib, shutil, stat, sys, sysconfig, tempfile, types

root, base, helper, jq, native_binary, native_record, dependency_record = map(pathlib.Path, sys.argv[1:])
dependency_document=json.loads(dependency_record.read_bytes())
assert tuple(dependency_document["body"]["preexec_environment"]["observed_keys"])==startup_environment_keys
dependency_work = base / "dependency-work"; dependency_work.mkdir()
spec = importlib.util.spec_from_file_location("shadow_consumer", root / "shadow/v1/_consumer.py")
c = importlib.util.module_from_spec(spec); sys.modules[spec.name] = c; spec.loader.exec_module(c)
checks = 0
def ok(value, message):
    global checks
    assert value, message; checks += 1
def refuses(code, call):
    global checks
    try: call()
    except c.Refusal as exc:
        assert exc.code == code, (exc.code, code); checks += 1; return
    raise AssertionError("accepted " + code)
def write(path, raw, mode=0o440):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists(): path.chmod(0o640)
    path.write_bytes(raw); path.chmod(mode)
def sha(raw): return hashlib.sha256(raw).hexdigest()
def document(kind, identifier, body, schema=1):
    return c.canonical({"schema_version": schema, "kind": kind, "id": identifier, "body": body})
def parent_doc(path, raw):
    return document("shadow_consumer_parent_context", "shadow.parent", {
        "helper_source_sha256": c.HELPER_SOURCE_SHA256, "helper_build_record_sha256": "2" * 64,
        "helper_executable_sha256": sha(raw), "helper_executable_size": len(raw),
        "helper_path": str(path), "native_release": {
            "source_sha256": sha((root/"shadow/v1/_cancel_release.c").read_bytes()),
            "build_script_sha256": sha((root/"shadow/v1/build-cancel-release.sh").read_bytes()),
            "build_record_sha256": sha(native_record.read_bytes()),
            "binary_path": str(native_binary), "binary_size": native_binary.stat().st_size,
            "binary_sha256": sha(native_binary.read_bytes()),
            "python_path": os.path.realpath(sys.executable),
            "python_sha256": sha(pathlib.Path(sys.executable).read_bytes()),
            "python_abi": sysconfig.get_config_var("SOABI"),
            "dependency_record_sha256": sha(dependency_record.read_bytes()),
            "loader_mode": "rtld-now-local.v1"}}, schema=2)

# Parallel shards share TMPDIR. Stabilize only change metadata for ancestors outside this
# fixture; every object at or below the owned fixture root keeps real OS observations.
raw_metadata, raw_named = c._metadata, c._named_metadata
host_is_darwin = sys.platform == "darwin"
external = {}
external_ancestors = set()
cursor = base.parent
while True:
    external_ancestors.add(str(cursor))
    if cursor == cursor.parent: break
    cursor = cursor.parent
def fd_path(fd):
    if host_is_darwin:
        raw = c.fcntl.fcntl(fd, 50, b"\0" * 1024)
        return raw.split(b"\0", 1)[0].decode()
    return os.path.realpath("/proc/self/fd/" + str(fd))
def stable_external(value, path):
    if path not in external_ancestors or not stat.S_ISDIR(value.st_mode):
        return value
    key = (value.st_dev, value.st_ino)
    first = external.setdefault(key, (value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns))
    return types.SimpleNamespace(st_dev=value.st_dev, st_ino=value.st_ino, st_mode=value.st_mode,
        st_uid=value.st_uid, st_gid=value.st_gid, st_nlink=first[0],
        st_size=first[1], st_mtime_ns=first[2], st_ctime_ns=first[3])
def stable_metadata(fd): return stable_external(raw_metadata(fd), fd_path(fd))
def stable_named(name, parent_fd):
    path = os.path.normpath(os.path.join(fd_path(parent_fd), name))
    return stable_external(raw_named(name, parent_fd), path)
c._metadata, c._named_metadata = stable_metadata, stable_named

c.verify_helper_source()
physical_python = os.path.realpath(c.sys.executable); c.sys.executable = physical_python
ok(c.isolated_python_argv()[1:4] == ["-I", "-S", "-B"], "isolated Python argv")
context = base / "context"; helper_raw = helper.read_bytes(); write(context, parent_doc(helper, helper_raw), 0o400)
body = c.capture_parent_context(os.open(context, os.O_RDONLY))
ok(body["helper_executable_sha256"] == sha(helper_raw), "trusted parent context")
for boundary in (1, c.EXECUTABLE_LIMIT):
    bounded = json.loads(parent_doc(helper, helper_raw)); bounded["body"]["native_release"]["binary_size"] = boundary
    write(context, c.canonical(bounded), 0o400)
    ok(c.capture_parent_context(os.open(context, os.O_RDONLY))["native_release"]["binary_size"] == boundary,
       "native binary size accepts bounded positive endpoint %d" % boundary)
for invalid in (0, c.EXECUTABLE_LIMIT + 1, True):
    bounded = json.loads(parent_doc(helper, helper_raw)); bounded["body"]["native_release"]["binary_size"] = invalid
    write(context, c.canonical(bounded), 0o400)
    refuses("E_PARENT_CONTEXT", lambda: c.capture_parent_context(os.open(context, os.O_RDONLY)))
absent_effect = base / "absent-context-effect"
refuses("E_PARENT_CONTEXT", lambda: c.capture_parent_context(-1))
ok(not absent_effect.exists(), "absent parent context has no later effect")
context.chmod(0o600); refuses("E_PARENT_CONTEXT", lambda: c.capture_parent_context(os.open(context, os.O_RDWR)))
write(context, parent_doc(helper, helper_raw).replace(b'"shadow.parent"', b'"changed"'), 0o400)
refuses("E_PARENT_CONTEXT", lambda: c.capture_parent_context(os.open(context, os.O_RDONLY)))

dep = c.snapshot_dependency(str(helper), sha(helper_raw), len(helper_raw), str(dependency_work / "helper"), "helper")
concurrent = pathlib.Path(tempfile.mkdtemp(prefix="ystack-concurrent-", dir=base.parent))
c.probe_dependency(dep, ["version"], b"ystack-object-closure-v1\n")
shutil.rmtree(concurrent)
ok(True, "external temp churn does not weaken owned fixture checks")
ok(stat.S_IMODE(os.stat(dependency_work / "helper").st_mode) == 0o500, "helper private snapshot")
helper.chmod(0o755); helper.write_bytes(helper_raw + b"\n")
refuses("E_DEPENDENCY", dep.recheck); dep.close(); helper.write_bytes(helper_raw); helper.chmod(0o555)
jq_dep = c.snapshot_jq(str(jq), str(dependency_work / "jq"))
c.probe_dependency(jq_dep, ["--version"], b"jq-1.6\n"); jq_dep.close(); ok(True, "pinned jq admitted and run")
original_jq_pin = c.JQ_SHA256[c.sys.platform]
c.JQ_SHA256[c.sys.platform] = "0" * 64
refuses("E_DEPENDENCY", lambda: c.snapshot_jq(str(jq), str(dependency_work / "wrong-jq")))
c.JQ_SHA256[c.sys.platform] = original_jq_pin
marker = base / "marker"
malicious = base / "malicious"; write(malicious, ("#!/bin/sh\ntouch '%s'\n" % marker).encode(), 0o555)
refuses("E_DEPENDENCY", lambda: c.snapshot_dependency(str(malicious), "0" * 64,
        malicious.stat().st_size, str(dependency_work / "bad"), "helper"))
ok(not marker.exists(), "unapproved executable never ran")

# A helper whose bytes initially match is still checked at the real invocation boundary.
raced_marker = base / "raced-marker"
raced_helper = base / "raced-helper"
raced_raw = ("#!/bin/sh\ntouch '%s'\nprintf 'ystack-object-closure-v1\\n'\n" % raced_marker).encode()
write(raced_helper, raced_raw, 0o555)
raced = c.snapshot_dependency(str(raced_helper), sha(raced_raw), len(raced_raw),
                              str(dependency_work / "raced"), "helper")
raced_helper.chmod(0o755)
raced_helper.write_bytes(raced_raw + b"# replaced\n")
refuses("E_DEPENDENCY", lambda: c.probe_dependency(
    raced, ["version"], b"ystack-object-closure-v1\n"))
ok(not raced_marker.exists(), "raced helper refused before version execution")
raced.close()

# The parent's accepted result is an input. A request-selected digest cannot replace it.
wrong_context = base / "wrong-context"
wrong = json.loads(parent_doc(helper, helper_raw))
wrong["body"]["helper_executable_sha256"] = "3" * 64
write(wrong_context, c.canonical(wrong), 0o400)
wrong_body = c.capture_parent_context(os.open(wrong_context, os.O_RDONLY))
refuses("E_DEPENDENCY", lambda: c.snapshot_dependency(
    str(helper), wrong_body["helper_executable_sha256"], wrong_body["helper_executable_size"],
    str(dependency_work / "wrong-result"), "helper"))
ok(not raced_marker.exists(), "wrong accepted result has no helper effect")

# The bounded reader catches a leaf mutation that happens during its own read.
leaf = base / "leaf-race"
write(leaf, b"stable", 0o600)
leaf_held = c._open_held(str(leaf), False, lambda *_: True, "E_DEPENDENCY")
real_read, changed = c.os.read, [False]
def racing_read(fd, count):
    raw = real_read(fd, count)
    if fd == leaf_held.fd and raw and not changed[0]:
        changed[0] = True
        leaf.write_bytes(b"changed")
    return raw
c.os.read = racing_read
refuses("E_DEPENDENCY", lambda: leaf_held.read(32, "E_DEPENDENCY"))
c.os.read = real_read
leaf_held.close()

walk = base / "walk"; write(walk / "ancestor/input", b"stable", 0o400)
held = c._open_held(str(walk / "ancestor/input"), False, lambda *_: True, "E_DEPENDENCY")
(walk / "ancestor").rename(walk / "moved"); (walk / "ancestor").mkdir(); write(walk / "ancestor/input", b"new", 0o400)
refuses("E_DEPENDENCY", lambda: held.recheck("E_DEPENDENCY")); held.close()
held = c._open_held(str(walk / "moved/input"), False, lambda *_: True, "E_DEPENDENCY")
(walk / "moved").chmod(0o777); refuses("E_DEPENDENCY", lambda: held.recheck("E_DEPENDENCY")); held.close()
fifo = base / "fifo"; os.mkfifo(fifo)
refuses("E_DEPENDENCY", lambda: c._open_held(str(fifo), False, lambda *_: True, "E_DEPENDENCY"))
parent = c._open_held(str(base), True, lambda *_: True, "E_DEPENDENCY")
refuses("E_DEPENDENCY", lambda: c._open_child(parent, "fifo", False, lambda *_: True, "E_DEPENDENCY")); parent.close()

fd = os.open(base, os.O_RDONLY); real_acl, real_platform = c._acl_state, c.sys.platform
root_state = types.SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o555)
installed_state = types.SimpleNamespace(st_uid=123, st_mode=stat.S_IFDIR | 0o555)
acl_calls = [0]
def acl_value(value):
    def observe(_fd, _resolver=None): acl_calls[0] += 1; return value
    return observe
c.sys.platform = "linux"
c._acl_state = acl_value(([(0x02, 4, 123)], None))
ok(not c._installed_rule(123)(fd, installed_state, False) and acl_calls[0] == 1,
   "Linux named-user ACL reached and refused")
acl_calls[0] = 0; c._acl_state = acl_value((None, [(0x10, 2, 0)]))
ok(not c._root_rule()(fd, root_state, False) and acl_calls[0] == 1,
   "Linux default write ACL reached and refused")

class Call:
    def __init__(self, function): self.function = function
    def __call__(self, *args): return self.function(*args)
class FakeAclLib:
    def __init__(self, failure=None):
        self.failure, self.entries = failure, 0
        self.calls = {"entry": 0, "permission": 0, "qualifier": 0}
        self.freed = []
        self.guid = c.ctypes.create_string_buffer(16)
        self.acl_get_fd_np = Call(lambda *_args: 1)
        self.acl_get_entry = Call(self.get_entry)
        self.acl_get_tag_type = Call(self.get_tag)
        self.acl_get_qualifier = Call(self.get_qualifier)
        self.acl_get_permset = Call(self.get_permset)
        self.acl_get_perm_np = Call(self.get_perm)
        self.acl_free = Call(self.free)
    def get_entry(self, _acl, _selector, _entry):
        self.calls["entry"] += 1
        if self.failure == "acl-memory": raise MemoryError("after ACL ownership")
        if self.failure == "entry": c.ctypes.set_errno(13); return -1
        self.entries += 1
        if self.entries == 1: return 0
        c.ctypes.set_errno(0); return -1
    def get_tag(self, _entry, output): output._obj.value = 1; return 0
    def get_permset(self, _entry, output): output._obj.value = 1; return 0
    def get_perm(self, _perms, bit):
        self.calls["permission"] += 1
        if self.failure == "permission": c.ctypes.set_errno(5); return -1
        return int(bit == 1 << 1)
    def get_qualifier(self, _entry):
        self.calls["qualifier"] += 1
        if self.failure == "qualifier": c.ctypes.set_errno(5); return 0
        return c.ctypes.addressof(self.guid)
    def free(self, value): self.freed.append(value); return 0
class FixedResolver(c._DarwinUUIDResolver):
    def __init__(self, rows=None): self.rows, self.calls = rows, []
    def resolve(self, uuids):
        self.calls.append(list(uuids))
        return self.rows if self.rows is not None else [
            {"uuid": uuid, "status": "resolved", "kind": "user", "id": 0}
            for uuid in uuids]
real_functions = c._DARWIN_ACL_FUNCTIONS
c.sys.platform = "darwin"; c._acl_state = real_acl
def darwin_rule(failure, installed=False):
    fake = FakeAclLib(failure)
    c._DARWIN_ACL_FUNCTIONS = types.SimpleNamespace(library=fake)
    resolver = FixedResolver()
    rule = c._installed_rule(123, resolver) if installed else c._root_rule(resolver)
    state = installed_state if installed else root_state
    return rule(fd, state, False), fake, resolver
for installed in (False, True):
    accepted_acl, fake, resolver = darwin_rule(None, installed)
    ok(accepted_acl and fake.entries == 2 and resolver.calls == [["00" * 16]],
       "Darwin capture sends only positional UUID bytes to fixed resolver")
    ok(fake.freed == [c.ctypes.addressof(fake.guid), 1],
       "Darwin capture frees the exact qualifier then ACL once")
    for failure in ("entry", "permission", "qualifier"):
        accepted_acl, fake, resolver = darwin_rule(failure, installed)
        ok(not accepted_acl and fake.calls[failure] > 0, "Darwin %s error reached and refused" % failure)
fake = FakeAclLib(); c._DARWIN_ACL_FUNCTIONS = types.SimpleNamespace(library=fake)
refuses("E_ACL", lambda: c._darwin_acl(fd, None))
ok(fake.calls["entry"] == 0, "missing Darwin resolver refuses before ACL capture")
fake = FakeAclLib("acl-memory"); resolver = FixedResolver()
c._DARWIN_ACL_FUNCTIONS = types.SimpleNamespace(library=fake)
try: c._darwin_acl(fd, resolver)
except MemoryError: pass
else: raise AssertionError("post-ACL MemoryError propagated")
ok(fake.freed == [1] and resolver.calls == [],
   "post-ACL MemoryError frees exact ACL once without resolver use")
fake = FakeAclLib(); resolver = FixedResolver(); real_string_at = c.ctypes.string_at
c._DARWIN_ACL_FUNCTIONS = types.SimpleNamespace(library=fake)
def qualifier_memory(_pointer, _length): raise MemoryError("during qualifier copy")
c.ctypes.string_at = qualifier_memory
try:
    try: c._darwin_acl(fd, resolver)
    except MemoryError: pass
    else: raise AssertionError("qualifier-copy MemoryError propagated")
finally: c.ctypes.string_at = real_string_at
ok(fake.freed == [c.ctypes.addressof(fake.guid), 1] and resolver.calls == [],
   "qualifier-copy MemoryError frees exact qualifier then ACL once without resolver use")
mutation = base / "acl-resolver-mutation"; write(mutation, b"x", 0o400)
mutation_fd = os.open(mutation, os.O_RDONLY)
class MutatingResolver(FixedResolver):
    def resolve(self, uuids):
        mutation.chmod(0o600)
        return super().resolve(uuids)
mutating = MutatingResolver(); fake = FakeAclLib()
c._DARWIN_ACL_FUNCTIONS = types.SimpleNamespace(library=fake)
component = c.HeldComponent(mutation_fd, None, c._metadata(mutation_fd),
    lambda held_fd, _state, _ancestor: bool(c._darwin_acl(held_fd, mutating)), False)
held_mutation = c.HeldPath(str(mutation), [component])
refuses("E_ACL", lambda: held_mutation.recheck("E_ACL"))
ok(mutating.calls == [["00" * 16]], "metadata mutation after delayed resolver reply refuses")
held_mutation.close()
c._DARWIN_ACL_FUNCTIONS = real_functions
c._acl_state = acl_value(([(1, 456, 1 << 2)], None)); acl_calls[0] = 0
ok(not c._root_rule(FixedResolver())(fd, root_state, False) and acl_calls[0] == 1,
   "Darwin other-principal ACL reached and refused")

c.sys.platform = "linux"
c._acl_state = lambda _fd, _resolver=None: (None, None)
store_state = types.SimpleNamespace(st_mode=stat.S_IFDIR | 0o750, st_uid=123, st_gid=456)
ok(c._store_rule(123, 456, 0o750, True)(fd, store_state, False), "Linux no-ACL store control")
c._acl_state = lambda _fd, _resolver=None: ([(0x10, 0, 0)], None)
ok(not c._store_rule(123, 456, 0o750, True)(fd, store_state, False), "store rejects any ACL")
c._acl_state = lambda _fd, _resolver=None: (None, None)
wrong_owner = types.SimpleNamespace(st_mode=stat.S_IFDIR | 0o750, st_uid=124, st_gid=456)
wrong_group = types.SimpleNamespace(st_mode=stat.S_IFDIR | 0o750, st_uid=123, st_gid=457)
wrong_mode = types.SimpleNamespace(st_mode=stat.S_IFDIR | 0o770, st_uid=123, st_gid=456)
ok(not c._store_rule(123, 456, 0o750, True)(fd, wrong_owner, False), "store owner exact")
ok(not c._store_rule(123, 456, 0o750, True)(fd, wrong_group, False), "store group exact")
ok(not c._store_rule(123, 456, 0o750, True)(fd, wrong_mode, False), "store mode exact")
c._acl_state, c.sys.platform = real_acl, real_platform; os.close(fd)

source = base / "source"; install = base / "install"; anchor_path = base / "anchor"
for role, relative in c.INSTALLED_SOURCES.items():
    target = source / relative; target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / relative, target)
env_id, target_id, verifier_raw = "env.fixture", "repo.fixture", b"verifier.fixture"
registry = document("shadow_environment_registry", "shadow.environments.v1", {
    "activation_state": "inactive", "registry_version": "v1", "environments": [{
        "description": "fixture", "environment_id": env_id, "evidence_scope": "fixtures-only",
        "proof_state": "unproven", "source_root_commit": "1" * 40,
        "target_repository_id": target_id}]})
identity = {name: [sha(verifier_raw)] for name in c.IDENTITY_SLOTS}
identity["verifier"] = sorted([sha(verifier_raw), sha(b"second accepted verifier")])
accepted = document("sandbox_accepted_identity_set", "sandbox.accepted-identities.v1", {
    "activation_state": "inactive", "set_version": "v1", "environments": [{
        "environment_id": env_id, "identities": identity,
        "mechanisms": {name: ["mechanism." + name] for name in c.MECHANISMS},
        "scratch_bytes": 16777216}]})
ok(c._id("attempt:valid") and not c._id("Attempt") and not c._id("é"),
   "identifier domain is lowercase ASCII with colon")
registry_bool = json.loads(registry); registry_bool["schema_version"] = True
refuses("E_INSTALL", lambda: c._parse_registry(c.canonical(registry_bool)))
accepted_bool = json.loads(accepted); accepted_bool["schema_version"] = True
refuses("E_INSTALL", lambda: c._parse_accepted(c.canonical(accepted_bool)))
write(source / c.INSTALLED_SOURCES["registry"], registry)
write(source / c.INSTALLED_SOURCES["accepted_set"], accepted)
installed = {}
for role, relative in c.INSTALLED_SOURCES.items():
    installed[role] = str(install / role); write(pathlib.Path(installed[role]), (source / relative).read_bytes())
identity_paths = {}
for name in c.IDENTITY_KEYS - {"dyld_cache_files"}:
    identity_paths[name] = str(install / ("identity-" + name)); write(pathlib.Path(identity_paths[name]),
        verifier_raw if name == "verifier" else name.encode())
cache = install / "cache"; write(cache, b"cache"); identity_paths["dyld_cache_files"] = [str(cache)]
store = base / "store"; store.mkdir(mode=0o750); store.chmod(0o750)
config_body = {"consumer_gid": os.getgid(), "environment_id": env_id,
    "identity_paths": identity_paths, "installed_files": installed, "principal_uid": 54321,
    "runtime": {"driver": identity_paths["host_runtime"], "vfkit": identity_paths["vm_service"]},
    "store_id": "store.fixture", "store_root": str(store), "work_root": str(base / "work")}
config = document("sandbox_host_config", "host.fixture", config_body)
write(anchor_path / "host-config.json", config); write(anchor_path / "host-supervisor.py", b"supervisor")

real_metadata, real_named, real_source, real_acl = c._metadata, c._named_metadata, c._source_root, c._acl_state
store_nodes = set()
def remember_store():
    store_nodes.clear()
    for path, dirs, files in os.walk(store):
        for name in [path, *[os.path.join(path, item) for item in dirs + files]]:
            value = os.lstat(name); store_nodes.add((value.st_dev, value.st_ino))
def observed_value(value):
    owned = (value.st_dev, value.st_ino) in store_nodes
    mode = value.st_mode if owned else stat.S_IFMT(value.st_mode) | (0o555 if stat.S_ISDIR(value.st_mode) else 0o444)
    return types.SimpleNamespace(st_dev=value.st_dev, st_ino=value.st_ino, st_mode=mode,
        st_uid=54321 if owned else 0, st_gid=os.getgid(), st_nlink=value.st_nlink,
        st_size=value.st_size, st_mtime_ns=value.st_mtime_ns, st_ctime_ns=value.st_ctime_ns)
def observed(fd): return observed_value(real_metadata(fd))
def observed_named(name, parent_fd): return observed_value(real_named(name, parent_fd))
c._metadata, c._named_metadata = observed, observed_named; c._source_root = lambda: str(source)
c._acl_state = lambda _fd, _resolver=None: ([], None) if c.sys.platform == "darwin" else (None, None)
def fixture_anchor():
    return c.load_anchor(FixedResolver() if c.sys.platform == "darwin" else None)
c.ANCHOR = str(anchor_path); c.sys.executable = identity_paths["toolchain"]
helper_source = source / c.HELPER_SOURCE
helper_source.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / c.HELPER_SOURCE, helper_source)
c.verify_helper_source()
source_bytes = helper_source.read_bytes()
write(helper_source, source_bytes + b"\n")
refuses("E_DEPENDENCY", c.verify_helper_source)
write(helper_source, source_bytes)
remember_store(); anchor = fixture_anchor()
observation = json.loads(c.verifier_observation(anchor, env_id, target_id))
ok(set(observation) == {"schema_version", "kind", "id", "body"}
   and observation["schema_version"] == 1
   and observation["kind"] == "sandbox_verifier_observation"
   and observation["id"] == "sandbox.observation.verifier", "closed verifier observation envelope")
ok(set(observation["body"]) == {"environment_id", "environment_entry_sha256",
   "target_repository_id", "accepted_set_sha256", "verifier_sha256"},
   "closed verifier observation body")
ok(observation["body"]["verifier_sha256"] == sha(verifier_raw), "verifier bound to reviewed sets")
ok(observation["body"]["accepted_set_sha256"] == sha(accepted), "accepted-set bytes bound")
ok(observation["body"]["environment_entry_sha256"] == sha(c.canonical(json.loads(registry)["body"]["environments"][0])),
   "selected registry entry digest bound")
refuses("E_RELATION", lambda: c.verifier_observation(anchor, env_id, "repo.other"))
anchor.close()

for role in sorted(c.INSTALLED_SOURCES):
    path = pathlib.Path(installed[role]); original = path.read_bytes(); path.chmod(0o640); path.write_bytes(original + b"x")
    refuses("E_INSTALL", fixture_anchor); path.write_bytes(original); path.chmod(0o440)
ok(True, "every installed role is byte-bound")

# A changed reviewed snapshot does not bless independently unchanged installed bytes.
policy_source = source / c.INSTALLED_SOURCES["control_policy"]
policy_original = policy_source.read_bytes()
write(policy_source, policy_original + b"x")
refuses("E_INSTALL", fixture_anchor)
write(policy_source, policy_original)

# Missing and ambiguous registry/accepted relationships fail closed after exact byte binding.
duplicate_registry = json.loads(registry)
duplicate_registry["body"]["environments"].append(
    dict(duplicate_registry["body"]["environments"][0]))
duplicate_registry_raw = c.canonical(duplicate_registry)
write(source / c.INSTALLED_SOURCES["registry"], duplicate_registry_raw)
write(pathlib.Path(installed["registry"]), duplicate_registry_raw)
ambiguous = fixture_anchor()
refuses("E_RELATION", lambda: c.verifier_observation(ambiguous, env_id, target_id))
ambiguous.close()
write(source / c.INSTALLED_SOURCES["registry"], registry)
write(pathlib.Path(installed["registry"]), registry)

duplicate_accepted = json.loads(accepted)
duplicate_accepted["body"]["environments"].append(
    json.loads(json.dumps(duplicate_accepted["body"]["environments"][0])))
duplicate_accepted_raw = c.canonical(duplicate_accepted)
write(source / c.INSTALLED_SOURCES["accepted_set"], duplicate_accepted_raw)
write(pathlib.Path(installed["accepted_set"]), duplicate_accepted_raw)
ambiguous = fixture_anchor()
refuses("E_RELATION", lambda: c.verifier_observation(ambiguous, env_id, target_id))
ambiguous.close()
write(source / c.INSTALLED_SOURCES["accepted_set"], accepted)
write(pathlib.Path(installed["accepted_set"]), accepted)

malformed_accepted = json.loads(accepted)
malformed_accepted["body"]["environments"][0]["identities"]["verifier"] = ["a" * 64, "a" * 64]
malformed_raw = c.canonical(malformed_accepted)
write(source / c.INSTALLED_SOURCES["accepted_set"], malformed_raw)
write(pathlib.Path(installed["accepted_set"]), malformed_raw)
refuses("E_INSTALL", fixture_anchor)
write(source / c.INSTALLED_SOURCES["accepted_set"], accepted)
write(pathlib.Path(installed["accepted_set"]), accepted)

wrong = json.loads(accepted); wrong["body"]["environments"][0]["identities"]["verifier"] = [sha(b"wrong")]
wrong_raw = c.canonical(wrong)
write(source / c.INSTALLED_SOURCES["accepted_set"], wrong_raw); write(pathlib.Path(installed["accepted_set"]), wrong_raw)
cross = fixture_anchor(); refuses("E_RELATION", lambda: c.verifier_observation(cross, env_id, target_id)); cross.close()
write(source / c.INSTALLED_SOURCES["accepted_set"], accepted); write(pathlib.Path(installed["accepted_set"]), accepted)
empty = json.loads(accepted); empty["body"]["environments"] = []; empty_raw = c.canonical(empty)
write(source / c.INSTALLED_SOURCES["accepted_set"], empty_raw); write(pathlib.Path(installed["accepted_set"]), empty_raw)
empty_anchor = fixture_anchor(); refuses("E_RELATION", lambda: c.verifier_observation(empty_anchor, env_id, target_id)); empty_anchor.close()
write(source / c.INSTALLED_SOURCES["accepted_set"], accepted); write(pathlib.Path(installed["accepted_set"]), accepted)
bad_config = json.loads(config); bad_config["body"]["principal_uid"] = True
refuses("E_CONFIG", lambda: c._parse_config(c.canonical(bad_config)))
bad_config = json.loads(config); bad_config["body"]["store_root"] = "/sandbox/store"
refuses("E_CONFIG", lambda: c._parse_config(c.canonical(bad_config)))
bad_config = json.loads(config); bad_config["body"]["work_root"] = "/sandbox"
refuses("E_CONFIG", lambda: c._parse_config(c.canonical(bad_config)))
bad_config = json.loads(config); bad_config["body"]["consumer_gid"] = False
refuses("E_CONFIG", lambda: c._parse_config(c.canonical(bad_config)))
bad_config = json.loads(config); bad_config["body"]["runtime"]["driver"] = "relative"
refuses("E_CONFIG", lambda: c._parse_config(c.canonical(bad_config)))
bad_config = json.loads(config); bad_config["body"]["identity_paths"]["dyld_cache_files"] = []
refuses("E_CONFIG", lambda: c._parse_config(c.canonical(bad_config)))
bad_config = json.loads(config)
bad_config["body"]["installed_files"]["registry"] = bad_config["body"]["installed_files"]["accepted_set"]
refuses("E_CONFIG", lambda: c._parse_config(c.canonical(bad_config)))
saved = pathlib.Path(installed["registry"]); saved.rename(saved.with_suffix(".missing"))
before = len(os.listdir("/dev/fd")); refuses("E_INSTALL", fixture_anchor)
ok(len(os.listdir("/dev/fd")) == before, "partial anchor failure closes descriptors")
saved.with_suffix(".missing").rename(saved)

old_python = c.sys.executable
c.sys.executable = str(install / "missing-interpreter")
before = len(os.listdir("/dev/fd")); refuses("E_INSTALL", fixture_anchor)
ok(len(os.listdir("/dev/fd")) == before, "late interpreter failure closes descriptors")
c.sys.executable = old_python

before = len(os.listdir("/dev/fd")); anchor = fixture_anchor(); anchor.close()
ok(len(os.listdir("/dev/fd")) == before, "successful anchor ownership closes cleanly")
anchor = fixture_anchor()

def make_attempt(attempt_id="attempt.fixture", evidence_raw=b"proof", name_hex="70726f6f66"):
    attempt = store / attempt_id; payload = attempt / "payload"; payload.mkdir(parents=True, mode=0o750)
    attempt.chmod(0o750); payload.chmod(0o750)
    rows = []
    if evidence_raw is not None:
        rows = [{"name_hex": name_hex, "sha256": sha(evidence_raw), "size_bytes": len(evidence_raw)}]
        (payload / "evidence").mkdir(mode=0o750); (payload / "evidence").chmod(0o750)
        write(payload / "evidence/0000", evidence_raw)
    manifest = document("sandbox_evidence_manifest", "evidence-manifest", {"files": rows})
    for name, raw in (("stdout", b"out"), ("stderr", b"err"), ("evidence-manifest.json", manifest)):
        write(payload / name, raw)
    write(attempt / "receipt.json", document("fixture_receipt", attempt_id, {})); remember_store()
    return attempt, payload

aggregate_attempt = store / "attempt.aggregate"
aggregate_payload = aggregate_attempt / "payload"
aggregate_evidence = aggregate_payload / "evidence"
aggregate_evidence.mkdir(parents=True, mode=0o750)
for directory in (aggregate_attempt, aggregate_payload, aggregate_evidence): directory.chmod(0o750)
aggregate_rows, aggregate_nodes = [], set()
for index in range(3):
    raw = bytes([index]) * (4 * 1024 * 1024)
    path = aggregate_evidence / ("%04d" % index); write(path, raw)
    aggregate_rows.append({"name_hex": "%02x" % index, "sha256": sha(raw), "size_bytes": len(raw)})
for name, raw in (("stdout", b""), ("stderr", b""),
                  ("evidence-manifest.json", document("sandbox_evidence_manifest",
                   "evidence-manifest", {"files": aggregate_rows}))):
    write(aggregate_payload / name, raw)
write(aggregate_attempt / "receipt.json", document("fixture_receipt", "attempt.aggregate", {}))
for path in [aggregate_payload / "stdout", aggregate_payload / "stderr",
             *[aggregate_evidence / ("%04d" % index) for index in range(3)]]:
    value = path.stat(); aggregate_nodes.add((value.st_dev, value.st_ino))
remember_store(); real_output_read, aggregate_bytes = c.os.read, [0]
def count_output_read(fd, count):
    raw = real_output_read(fd, count)
    value = os.fstat(fd)
    if (value.st_dev, value.st_ino) in aggregate_nodes: aggregate_bytes[0] += len(raw)
    return raw
c.os.read = count_output_read
try: refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.aggregate"))
finally: c.os.read = real_output_read
ok(aggregate_bytes[0] == 0, "aggregate limit refuses before output allocation")

attempt, payload = make_attempt()
snapshots, origin = c.read_store_attempt(anchor, "attempt.fixture")
entries = json.loads(origin)["body"]["entries"]
ok(set(snapshots) == {"receipt.json", "payload/stdout", "payload/stderr",
    "payload/evidence-manifest.json", "payload/evidence/0000"}, "closed store inventory")
ok(sum(row["kind"] == "directory" for row in entries) == 4, "directory provenance retained")
ok(all(row["metadata_before"] == row["metadata_after"] for row in entries),
   "origin metadata stable across snapshots")
ok(c._hex_name("2f") and c._hex_name("00") and c._hex_name("ab" * 255),
   "evidence names retain the exact lowercase frame-name domain")
ok(not c._hex_name("") and not c._hex_name("a")
   and not c._hex_name("AB") and not c._hex_name("ab" * 256),
   "evidence name length and encoding are closed")
colon_attempt, _colon_payload = make_attempt("attempt:valid", None)
colon_snapshots, _colon_origin = c.read_store_attempt(anchor, "attempt:valid")
ok("receipt.json" in colon_snapshots, "colon attempt id reaches controlled store")
manifest_path = payload / "evidence-manifest.json"
manifest_original = manifest_path.read_bytes(); manifest_bool = json.loads(manifest_original)
manifest_bool["schema_version"] = True; write(manifest_path, c.canonical(manifest_bool)); remember_store()
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.fixture"))
write(manifest_path, manifest_original); remember_store()
write(attempt / "extra", b"x"); remember_store(); refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.fixture")); (attempt / "extra").unlink()
manifest_path = payload / "evidence-manifest.json"; malformed = json.loads(manifest_path.read_bytes())
malformed["body"]["files"][0]["name_hex"] = "not-hex"; write(manifest_path, c.canonical(malformed)); remember_store()
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.fixture"))

# The expected name itself cannot alias another payload object.
shutil.rmtree(attempt)
attempt, payload = make_attempt("attempt.alias", None)
(payload / "stderr").unlink()
os.link(payload / "stdout", payload / "stderr")
remember_store()
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.alias"))

# Manifest errors are independently targeted with internally consistent bytes.
shutil.rmtree(attempt)
attempt, payload = make_attempt("attempt.digest", b"proof")
manifest_path = payload / "evidence-manifest.json"
bad_digest = json.loads(manifest_path.read_bytes())
bad_digest["body"]["files"][0]["sha256"] = "4" * 64
write(manifest_path, c.canonical(bad_digest)); remember_store()
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.digest"))

shutil.rmtree(attempt)
attempt, payload = make_attempt("attempt.size", b"proof")
manifest_path = payload / "evidence-manifest.json"
bad_size = json.loads(manifest_path.read_bytes())
bad_size["body"]["files"][0]["size_bytes"] += 1
write(manifest_path, c.canonical(bad_size)); remember_store()
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.size"))

shutil.rmtree(attempt)
attempt, payload = make_attempt("attempt.uppercase", b"proof", "AA")
remember_store()
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.uppercase"))

shutil.rmtree(attempt)
attempt, payload = make_attempt("attempt.missing", b"proof")
(payload / "evidence/0000").unlink(); remember_store()
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.missing"))

# An inventory race after the first list cannot produce an authenticated observation.
shutil.rmtree(attempt)
attempt, payload = make_attempt("attempt.race", None)
real_listdir, calls = c.os.listdir, [0]
def racing_listdir(fd):
    names = real_listdir(fd)
    calls[0] += 1
    if calls[0] == 2:
        write(attempt / "late-extra", b"x")
        remember_store()
    return names
c.os.listdir = racing_listdir
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.race"))
c.os.listdir = real_listdir

shutil.rmtree(attempt); attempt, payload = make_attempt("attempt.large", b"x" * (5 * 1024 * 1024))
write(payload / "stdout", b"x" * (5 * 1024 * 1024 + 1)); remember_store()
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.large"))
payload.chmod(0o777); remember_store(); refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.large"))

anchor.close(); c._metadata, c._named_metadata = real_metadata, real_named
c._source_root, c._acl_state = real_source, real_acl
print("shadow-enforced: %d checks passed" % checks)
PY

# Slice 3 keeps launch substitution private while exercising the production
# framing, durable-request, payload, record, inventory and bounded-child code.
"$python_bin" -I -S -B - "$root" "$tmp/slice3" "$jq_bin" "$tmp/native-case-33" <<'PY'
import errno, hashlib, importlib.util, inspect, json, os, pathlib, shutil, signal, stat, subprocess, sys, time, types
root, base, jq_bin, native_dir = map(pathlib.Path,sys.argv[1:]); base.mkdir(mode=0o700)
spec = importlib.util.spec_from_file_location("enforced", root / "shadow/v1/enforced-reproduction.py")
e = importlib.util.module_from_spec(spec); sys.modules[spec.name] = e; spec.loader.exec_module(e)
native_path=next(native_dir.glob("_cancel_release*.so"))
native_spec=importlib.util.spec_from_file_location("_cancel_release",native_path)
native_module=importlib.util.module_from_spec(native_spec);native_spec.loader.exec_module(native_module)
native_state=native_module.prepare_state();native_state.block_entry();native_state.arm_consumer()
parent_owner=e.CancellationSignals();parent_owner.native=native_state
e.CancellationSignals.active=parent_owner
checks = 0
def ok(value, message):
    global checks
    if not value: raise AssertionError(message)
    checks += 1; print("ok slice3-%d - %s" % (checks, message))
def refuses(code, action, message):
    try: action()
    except e.Refusal as exc: ok(exc.code == code, message); return
    raise AssertionError("accepted: " + message)
def doc(kind, identity, body):
    return {"schema_version": 1, "kind": kind, "id": identity, "body": body}
def write(path, raw):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_bytes(raw); path.chmod(0o400)
def sha(raw): return hashlib.sha256(raw).hexdigest()

# The frame proof uses an independent parser. It checks every byte in the
# header/content digest, ordered records and the terminal digest record.
def decode(frame):
    ok(frame[:8] == b"YSFRAME1", "frame magic")
    measured = hashlib.sha256(frame[:8]); at = 8; records = []
    while True:
        n = frame[at]; name = frame[at + 1:at + 1 + n]
        size = int.from_bytes(frame[at + 1 + n:at + 9 + n], "big")
        header = frame[at:at + 9 + n]; at += 9 + n
        content = frame[at:at + size]; at += size
        if name == b"end":
            ok(size == 32 and content == measured.digest() and at == len(frame), "frame terminal digest")
            return records
        measured.update(header); measured.update(content); records.append((name, content))
records = [(b"request.json", b"r\n"), (b"evaluation.json", b"e\n"),
           (b"incident.json", b"i\n"), (b"record.json", b"p\n"),
           (b"manifest.json", b"m\n"), (b"instruction", b"x\n"),
           (b"candidate/00000", b"candidate\n")]
frame = e.frame_write(records)
ok(decode(frame) == records, "frame records preserve order and bytes")
refuses("E_LIMIT", lambda: e.frame_write([(b"x" * 256, b"")]), "oversize frame name refused")
refuses("E_LIMIT", lambda: e.frame_write([(b"end", b"")]), "reserved end name refused")
old_limit = e.FRAME_LIMIT; e.FRAME_LIMIT = 30
refuses("E_LIMIT", lambda: e.frame_write([(b"x", b"a" * 40)]), "complete frame ceiling enforced")
exact=8+1+1+8+7+44;e.FRAME_LIMIT=exact
ok(len(e.frame_write([(b"x",b"a"*7)]))==exact,"frame exact cap accepted")
e.FRAME_LIMIT=exact-1
refuses("E_LIMIT",lambda:e.frame_write([(b"x",b"a"*7)]),"frame cap-minus-one refuses before append")
e.FRAME_LIMIT = old_limit

# Bounded children get a clean explicit environment and process group. A
# timeout is failure; truncated stdout/stderr can never be accepted.
env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"}
out = e.run_bounded("helper-version", [sys.executable, "-I", "-S", "-B", "-c", "print('fixed')"], env=env)
ok(out == b"fixed\n", "bounded child success")
mask_code = "import signal;print(bool(signal.pthread_sigmask(signal.SIG_BLOCK,set())&{signal.SIGTERM,signal.SIGHUP,signal.SIGINT}))"
ok(e.run_bounded("helper-version", [sys.executable, "-I", "-S", "-B", "-c", mask_code], env=env) == b"False\n",
   "bounded child inherits the caller's unblocked termination mask")
prior_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
try:
    inherited = e.run_bounded("helper-version", [sys.executable, "-I", "-S", "-B", "-c", mask_code], env=env)
finally:
    signal.pthread_sigmask(signal.SIG_SETMASK, prior_mask)
ok(inherited == b"False\n", "bounded child uses the native owner's saved original caller mask")
refuses("E_RUNTIME", lambda: e.run_bounded("helper-version", [sys.executable, "-I", "-S", "-B", "-c",
    "import time;time.sleep(2)"], timeout=.05, env=env), "bounded child timeout is failure")
refuses("E_LIMIT", lambda: e.run_bounded("helper-version", [sys.executable, "-I", "-S", "-B", "-c",
    "import sys,time;sys.stdout.write('x'*100);sys.stdout.flush();time.sleep(30)"],
    output_limit=8, env=env), "bounded stdout refuses instead of truncating")
refuses("E_LIMIT", lambda: e.run_bounded("helper-version", [sys.executable, "-I", "-S", "-B", "-c",
    "import sys,time;sys.stderr.write('x'*70000);sys.stderr.flush();time.sleep(30)"], env=env),
    "bounded stderr refuses instead of truncating")
refuses("E_RUNTIME", lambda: e.run_bounded("helper-version", [sys.executable, "-I", "-S", "-B", "-c",
    "raise SystemExit(3)"], env=env), "nonzero component exit refuses")

# The ACL resolver is one concrete adapter with fixed P/S/role, environment and caps.
python_snapshot=e.stable_file(pathlib.Path(sys.executable))
consumer_snapshot=e.stable_file(root/"shadow/v1/_consumer.py")
resolver_ledger=[]
def resolver_record(role,argv,executable_sha256,component_sha256):
 resolver_ledger.append({"role":role,"argv_sha256":e.sha(e.canonical(argv)),
  "executable_sha256":executable_sha256,"component_sha256":component_sha256})
resolver=e._DarwinUUIDResolver(python_snapshot,consumer_snapshot,time.monotonic()+30,resolver_record)
uuid_values=["0123456789abcdef0123456789abcdef","00"*16,"00"*16]
resolver_rows=[{"uuid":uuid_values[0],"status":"resolved","kind":"user","id":501},
 {"uuid":uuid_values[1],"status":"resolved","kind":"group","id":20},
 {"uuid":uuid_values[2],"status":"unresolved","kind":None,"id":None}]
original_run=e.run_bounded; resolver_calls=[]
def resolver_refuses(action,message):
 try:action()
 except (e.Refusal,e.c.Refusal) as exc:ok(exc.code=="E_ACL",message);return
 raise AssertionError("accepted: "+message)
def resolver_run(role,argv,**options):
 resolver_calls.append((role,argv,options))
 return e.c.canonical(resolver_rows)
e.run_bounded=resolver_run
ok(resolver.resolve(uuid_values)==resolver_rows,"fixed resolver preserves user/group/unresolved order")
ok([row["role"] for row in resolver_ledger]==["darwin-acl-uuid-resolution"],
   "nonempty resolver batch appends one command-ledger row")
role,argv,options=resolver_calls[0]
ok(role=="darwin-acl-uuid-resolution" and
 argv==[sys.executable,"-I","-S","-B",str(root/"shadow/v1/_consumer.py"),"_resolve-darwin-uuids"]
 and options["stdin"]==e.c.canonical(uuid_values) and options["timeout"]==10
 and options["output_limit"]==32*1024
 and options["env"]=={"PATH":"/usr/bin:/bin","LC_ALL":"C","LANG":"C"},
 "resolver argv environment input and caps are fixed")
for bad,message in [
 (b'[{"uuid":"00"}]\n',"malformed resolver row refused"),
 (e.c.canonical(resolver_rows[:-1]),"missing resolver row refused"),
 (e.c.canonical(list(reversed(resolver_rows))),"reordered resolver row refused"),
 (b'[{"id":501,"id":501,"kind":"user","status":"resolved","uuid":"0123456789abcdef0123456789abcdef"}]\n',"duplicate resolver key refused"),
 (b'[{"id":501,"kind":"user","status":"resolved","uuid":"0123456789abcdef0123456789abcdef","x":1}]\n',"extra resolver field refused"),
 (e.c.canonical(resolver_rows)+b"x","trailing resolver data refused"),
 (b" "*(32*1024+1),"resolver output byte cap enforced")]:
 e.run_bounded=lambda *_args,bad=bad,**_options:bad
 resolver_refuses(lambda:resolver.resolve(uuid_values),message)
e.run_bounded=original_run
resolver_refuses(lambda:resolver.resolve(["A"*32]),"noncanonical resolver UUID refused")
resolver_refuses(lambda:resolver.resolve(["00"*16]*129),"resolver count cap enforced")
before_empty=len(resolver_ledger);ok(resolver.resolve([])==[] and len(resolver_ledger)==before_empty,
 "empty resolver batch appends no command-ledger row")
boundary_uuids=[("%032x"%index) for index in range(128)]
e.run_bounded=lambda *_args,**_options:e.c.canonical([
 {"uuid":uuid,"status":"unresolved","kind":None,"id":None} for uuid in boundary_uuids])
ok(len(resolver.resolve(boundary_uuids))==128,"resolver accepts exact 128-entry boundary")
e.run_bounded=original_run
resolver_refuses(lambda:e.c._json_array(b"["+b'"00",'*8192+b'"00"]\n',16*1024,"E_ACL"),
 "resolver input byte cap enforced before parsing")
if sys.platform=="darwin":
 lib=e.ctypes.CDLL(e.c.DARWIN_SYSTEM_C,use_errno=True)
 def native_uuid(name,value):
  function=getattr(lib,name);function.argtypes=[e.ctypes.c_uint32,e.ctypes.c_char_p]
  function.restype=e.ctypes.c_int;raw=e.ctypes.create_string_buffer(16)
  ok(function(value,raw)==0,"native fixture obtains "+name.removeprefix("mbr_").removesuffix("_to_uuid"))
  return bytes(raw).hex()
 user_uuid=native_uuid("mbr_uid_to_uuid",os.getuid())
 group_uuid=native_uuid("mbr_gid_to_uuid",os.getgid())
 missing_uuid="f47ac10b58cc4372a5670e02b2c3d479"
 census=e._NativeThreadCensus();census.observe()
 native_rows=resolver.resolve([user_uuid,group_uuid,missing_uuid]);census.observe()
 ok(native_rows==[
  {"uuid":user_uuid,"status":"resolved","kind":"user","id":os.getuid()},
  {"uuid":group_uuid,"status":"resolved","kind":"group","id":os.getgid()},
  {"uuid":missing_uuid,"status":"unresolved","kind":None,"id":None}],
  "real fixed child preserves native user group and noncompatibility miss semantics")
 ok(e.CancellationSignals.active is parent_owner,
  "reaped native resolver leaves parent cancellation owner unchanged")
consumer_snapshot.close();python_snapshot.close()

original_popen=e.subprocess.Popen
class CloseResource:
 def __init__(self,failure=None,closed=False):self.failure,self.closed,self.calls=failure,closed,0
 def close(self):
  self.calls+=1
  if self.failure is not None:raise self.failure
release=object.__new__(e._NativeRelease)
release_items=[CloseResource(OSError(errno.EIO,"release close")),CloseResource(),
 CloseResource(),CloseResource(),CloseResource()]
for name,item in zip(("compiler","binary","record","script","source"),release_items):setattr(release,name,item)
try:release.close()
except OSError as exc:ok(exc is release_items[0].failure and [item.calls for item in release_items]==[1]*5
 and all(getattr(release,name) is None for name in ("compiler","binary","record","script","source")),
 "native release attempts all ordinary OSError closes once and preserves the first error")
else:raise AssertionError("native release ordinary close error accepted")
release=object.__new__(e._NativeRelease);release_items=[CloseResource(SystemExit(17)),CloseResource(),
 CloseResource(),CloseResource(),CloseResource()]
for name,item in zip(("compiler","binary","record","script","source"),release_items):setattr(release,name,item)
try:release.close()
except SystemExit as exc:ok(exc.code==17 and [item.calls for item in release_items]==[1,0,0,0,0]
 and release.compiler is release_items[0] and release.binary is release_items[1],
 "native release leaves arbitrary-interruption responsibility without attempt-all")
else:raise AssertionError("native release arbitrary interruption accepted")
normal=[CloseResource() for _ in range(4)]
ok(e._close_communication(*normal)==None and [item.calls for item in normal]==[1,1,1,1],
 "communicate close attempts each distinct normal resource once")
already_closed=CloseResource(closed=True)
ok(e._close_communication(None,already_closed,None,None)==None and already_closed.calls==0,
 "communicate close skips an already closed stream")
first_error=OSError(errno.EIO,"first close")
first=[CloseResource(first_error),CloseResource(),CloseResource(),CloseResource()]
ok(e._close_communication(*first) is first_error and [item.calls for item in first]==[1,1,1,1],
 "communicate close preserves first OSError object and attempts later resources")
middle_error=OSError(errno.EBADF,"middle close")
middle=[CloseResource(),CloseResource(),CloseResource(middle_error),CloseResource()]
ok(e._close_communication(*middle) is middle_error and [item.calls for item in middle]==[1,1,1,1],
 "communicate close preserves middle OSError object and attempts later resources")
system_exit=[CloseResource(SystemExit(7)),CloseResource(),CloseResource(),CloseResource()]
try:e._close_communication(*system_exit)
except SystemExit as exc:ok(exc.code==7 and [item.calls for item in system_exit]==[1,0,0,0],
 "communicate close does not invent attempt-all for non-OSError")
else:raise AssertionError("communicate close swallowed non-OSError")
primary=RuntimeError("primary sentinel");cleanup_error=OSError(errno.EIO,"cleanup")
class PrimarySelector(CloseResource):
 def register(self,*_args):raise primary
class PrimaryStream(CloseResource):
 def fileno(self):return 0
class PrimaryChild:
 def __init__(self):
  self.stdin,self.stdout,self.stderr=PrimaryStream(),PrimaryStream(),PrimaryStream()
primary_selector=PrimarySelector(cleanup_error);primary_child=PrimaryChild()
original_selector=e.selectors.DefaultSelector;original_set_blocking=e.os.set_blocking
e.selectors.DefaultSelector=lambda:primary_selector;e.os.set_blocking=lambda *_args:None
try:
 try:e.communicate_bounded(primary_child,b"",8,8,1,cleanup=False)
 except RuntimeError as exc:ok(exc is primary and primary_selector.calls==1
  and [primary_child.stdin.calls,primary_child.stdout.calls,primary_child.stderr.calls]==[1,1,1],
  "communicate body sentinel survives cleanup OSError after all ordinary closes")
 else:raise AssertionError("communicate primary sentinel accepted")
finally:e.selectors.DefaultSelector=original_selector;e.os.set_blocking=original_set_blocking
normal_close_error=OSError(errno.EIO,"normal cleanup")
class CloseFailSelector:
 def __init__(self):self.inner=original_selector()
 def __getattr__(self,name):return getattr(self.inner,name)
 def close(self):self.inner.close();raise normal_close_error
close_child=original_popen([sys.executable,"-I","-S","-B","-c",
 "import sys;data=sys.stdin.buffer.read();sys.stdout.buffer.write(data)"],stdin=subprocess.PIPE,
 stdout=subprocess.PIPE,stderr=subprocess.PIPE,close_fds=True,start_new_session=True)
e.selectors.DefaultSelector=CloseFailSelector
try:
 try:e.communicate_bounded(close_child,b"pipe",8,8,5)
 except OSError as exc:ok(exc is normal_close_error and close_child.returncode==0
  and close_child.stdin.closed and close_child.stdout.closed and close_child.stderr.closed,
  "normal communicate preserves first close OSError object after closing later streams")
 else:raise AssertionError("normal communicate close error accepted")
finally:e.selectors.DefaultSelector=original_selector
e.subprocess.Popen=lambda *_args,**_kwargs: (_ for _ in ()).throw(AssertionError("spawned"))
refuses("E_RUNTIME",lambda:e.run_bounded("incident-validation",
        [sys.executable,"-c","pass"],env=env,
        deadline=time.monotonic()-1),"expired overall deadline refuses before spawn")
e.subprocess.Popen=original_popen

spec=e._native_child_spec("darwin-acl-uuid-resolution",["/fixed/python","-I"],
 {"PATH":"/usr/bin:/bin","LANG":"C","LC_ALL":"C"})
ok(spec==(1,b"/fixed/python",(b"/fixed/python",b"-I"),
 (b"LANG=C",b"LC_ALL=C",b"PATH=/usr/bin:/bin")),
 "native child spec is a fixed role and canonical bytes tuple")
refuses("E_RUNTIME",lambda:e._native_child_spec("unknown",["/fixed/python"],{}),
 "unknown native child role refuses")
refuses("E_RUNTIME",lambda:e._native_child_spec("incident-validation",["relative"],{}),
 "relative native child executable refuses")

class FakeNativeChild:
 def __init__(self,state=3,fail_status_once=False):
  self.state=state;self.fail_status_once=fail_status_once;self.exit=False
  self.reaped=state==4;self.absent=state==4;self.pipes=state==4;self.calls=[]
 def status(self):
  return (self.state,321,321,1,0,0,1 if self.exit else 0,0,0,
   getattr(os,"CLD_EXITED",1) if self.exit else 0,0,int(self.exit),1 if self.reaped else 0,
   0,0,getattr(os,"CLD_EXITED",1) if self.reaped else 0,0,int(self.reaped),int(self.absent),
   int(self.pipes),1 if "term" in self.calls else 0,1 if "kill" in self.calls else 0,
   1 if "group" in self.calls else 0,0,int(self.state==4))+((0,)*24)
 def child_status(self):
  self.calls.append("status")
  if self.fail_status_once:
   self.fail_status_once=False;raise MemoryError("lost diagnostic allocation")
  return self.status()
 def _close(self,name):self.calls.append(name);self.pipes=all(
  item in self.calls for item in ("close-stdin","close-stdout","close-stderr"))
 def close_child_stdin(self):self._close("close-stdin")
 def close_child_stdout(self):self._close("close-stdout")
 def close_child_stderr(self):self._close("close-stderr")
 def term_child_group(self):self.calls.append("term")
 def observe_child_exit(self):self.calls.append("observe");self.exit=True
 def kill_child_group(self):self.calls.append("kill")
 def reap_child(self):self.calls.append("reap");self.reaped=True
 def check_child_group(self):
  self.calls.append("group");self.absent=True
  if self.reaped and self.pipes:self.state=4

fake=FakeNativeChild();e._native_child_cleanup(fake,time.monotonic()+1)
ok(fake.state==4 and fake.calls.index("term")<fake.calls.index("observe")
 and fake.calls.index("observe")<fake.calls.index("kill")
 and fake.calls.index("kill")<fake.calls.index("reap")
 and fake.calls.index("reap")<fake.calls.index("group"),
 "State cleanup retains leader through TERM and required KILL before one reap")
complete=FakeNativeChild(4);e._native_child_cleanup(complete,time.monotonic()+1)
ok("term" not in complete.calls and "kill" not in complete.calls,
 "cleanup after reap never signals the old process group")
lost=FakeNativeChild(fail_status_once=True)
try:e._native_child_cleanup(lost,time.monotonic()+1)
except MemoryError as exc:
 ok(str(exc)=="lost diagnostic allocation" and "term" in lost.calls and "kill" in lost.calls
  and "reap" in lost.calls and "group" in lost.calls,
  "lost child-status allocation preserves failure after required native cleanup")
else:raise AssertionError("lost child-status allocation accepted")

setup_ready=base/"setup.ready"
setup_child=original_popen([sys.executable,"-c","import pathlib,sys,time;pathlib.Path(sys.argv[1]).touch();time.sleep(30)",str(setup_ready)],stdin=subprocess.PIPE,
 stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
for _ in range(100):
 if setup_ready.exists():break
 time.sleep(.01)
ok(setup_ready.exists(),"setup child reached owned process group")
original_set_blocking=e.os.set_blocking;e.os.set_blocking=lambda *_args: (_ for _ in ()).throw(OSError("fixture"))
try:e.communicate_bounded(setup_child,b"",8,8,1)
except OSError:ok(True,"setup failure leaves bounded operation")
else:raise AssertionError("setup failure accepted")
e.os.set_blocking=original_set_blocking
for _ in range(100):
 if setup_child.poll() is not None:break
 time.sleep(.01)
ok(setup_child.poll() is not None,"setup-failed child was reaped")
interrupt_ready=base/"interrupt.ready"
interrupt_child=original_popen([sys.executable,"-c","import pathlib,sys,time;pathlib.Path(sys.argv[1]).touch();time.sleep(30)",str(interrupt_ready)],stdin=subprocess.PIPE,
 stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
for _ in range(100):
 if interrupt_ready.exists():break
 time.sleep(.01)
ok(interrupt_ready.exists(),"interrupt child reached owned process group")
original_selector=e.selectors.DefaultSelector
e.selectors.DefaultSelector=lambda: (_ for _ in ()).throw(KeyboardInterrupt())
try:e.communicate_bounded(interrupt_child,b"",8,8,1)
except KeyboardInterrupt:ok(True,"cancellation leaves bounded operation")
else:raise AssertionError("cancellation accepted")
finally:e.selectors.DefaultSelector=original_selector
for _ in range(100):
 if interrupt_child.poll() is not None:break
 time.sleep(.01)
ok(interrupt_child.poll() is not None,"cancelled child was reaped")
cleanup_source=inspect.getsource(e._native_child_cleanup)
ok(cleanup_source.count("CancellationSignals.checkpoint()") == 1
   and cleanup_source.count("observe_checkpoint()") >= 7
   and cleanup_source.index("term_child_group") < cleanup_source.index("kill_child_group")
   < cleanup_source.index("reap_child"),
   "owned cleanup observes cancellation without skipping TERM, KILL or reap")
bash=e.fixed_bash();bash.recheck();ok(True,"fixed /bin/bash alias and physical bytes recheck")
original_lstat=e.os.lstat
def linux_alias(path):
 state=original_lstat(path)
 if pathlib.Path(path)==pathlib.Path("/bin"):
  return types.SimpleNamespace(st_dev=state.st_dev,st_ino=state.st_ino,
   st_mode=stat.S_IFLNK|0o777,st_uid=0,st_gid=state.st_gid,st_nlink=state.st_nlink,
   st_size=state.st_size,st_mtime_ns=state.st_mtime_ns,st_ctime_ns=state.st_ctime_ns)
 return state
original_readlink=e.os.readlink
physical_bash=pathlib.Path("/bin/bash").resolve();original_resolve=e.Path.resolve
e.os.lstat=linux_alias;e.os.readlink=lambda path:"usr/bin" if pathlib.Path(path)==pathlib.Path("/bin") else original_readlink(path)
e.Path.resolve=lambda self,strict=False:physical_bash if self==pathlib.Path("/bin/bash") else original_resolve(self,strict=strict)
linux_bash=e.fixed_bash();linux_bash.recheck();linux_bash.close()
ok(True,"root-owned Linux-mode bash alias is admitted with physical byte binding")
e.os.lstat=original_lstat;e.os.readlink=original_readlink;e.Path.resolve=original_resolve
def replaced_alias(path):
 state=original_lstat(path)
 if pathlib.Path(path)==pathlib.Path("/bin"):
  return types.SimpleNamespace(st_dev=state.st_dev,st_ino=state.st_ino+1,st_mode=state.st_mode,
   st_uid=state.st_uid,st_gid=state.st_gid,st_nlink=state.st_nlink,st_size=state.st_size,
   st_mtime_ns=state.st_mtime_ns,st_ctime_ns=state.st_ctime_ns)
 return state
e.os.lstat=replaced_alias
refuses("E_DEPENDENCY",bash.recheck,"fixed executable alias replacement refuses")
e.os.lstat=original_lstat
original_read=bash.physical.held.read;bash.physical.held.read=lambda _limit,_code:b"changed"
refuses("E_DEPENDENCY",bash.recheck,"same held executable with changed bytes refuses")
bash.physical.held.read=original_read;bash.close()
fifo = base / "request-fifo"; os.mkfifo(fifo)
refuses("E_SHAPE", lambda: e.read_regular(fifo, e.REQUEST_LIMIT, "E_SHAPE"),
        "request FIFO refuses without blocking")

incident = doc("shadow_incident_record", "incident.fixture", {
    "deploy_authority": "none", "failing_check": {"check_id": "check.fixture",
    "kind": "file-digest", "path": "source.txt", "expected_sha256": "a" * 64},
    "git_revision_ref": {"repository_id": "fixture.target", "hash_algorithm": "sha1",
                         "commit_id": "b" * 40}, "observed_at": "2026-01-01T00:00:00Z",
    "observed_symptom": "changed", "reporter_actor_ref": "actor.fixture",
    "target_repository_id": "fixture.target"})
instruction = e.make_instruction(incident)
ok(instruction == (b"ystack.file-digest-instruction.v1\npath source.txt\nsha256 " + b"a" * 64 + b"\n"),
   "fixed instruction exact bytes")
for patch, message in [({"kind":"named-check"}, "named check refused"),
                       ({"path":"bad\npath"}, "newline path refused"),
                       ({"expected_sha256":"A" * 64}, "non-lowercase digest refused")]:
    changed = json.loads(json.dumps(incident)); changed["body"]["failing_check"].update(patch)
    refuses("E_RELATION", lambda changed=changed: e.make_instruction(changed), message)

# Launch and expectation are derived from one tuple. The only varying field is
# a fresh nonce. The expectation hashes the completed request and carries no
# caller-supplied replacement for store, control or subject.
policy = b'{"p":1}\n'; decision = b'{"d":1}\n'; pset = b'{"s":1}\n'
driver = b'#!/bin/bash\n'; program = b'.\n'; accepted = b'{"a":1}\n'; registry_raw = b'{"r":1}\n'
entry = {"description":"fixture","environment_id":"env.fixture","evidence_scope":"fixtures-only",
         "proof_state":"unproven","source_root_commit":"b"*40,"target_repository_id":"fixture.target"}
installed = {"control_policy":(policy,sha(policy)), "control_decision":(decision,sha(decision)),
 "control_policy_set":(pset,sha(pset)), "evaluator_driver":(driver,sha(driver)),
 "evaluator_program":(program,sha(program)), "accepted_set":(accepted,sha(accepted)),
 "registry":(registry_raw,sha(registry_raw))}
anchor = types.SimpleNamespace(config={"environment_id":"env.fixture","store_id":"store.fixture"},
                               registry=(sha(registry_raw),[entry]), installed=installed)
request = doc("shadow_enforced_request", "attempt.fixture", {"attempt_id":"attempt.fixture"})
record = {"source":{"repository_id":"fixture.target","hash_algorithm":"sha1",
 "commit_id":"b"*40,"tree_id":"c"*40}, "candidate":{"commit_id":"d"*40,"tree_id":"e"*40}}
record_raw=e.canonical(record); manifest_raw=e.canonical({"entries":[]}); evaluation_raw=e.canonical(doc(
 "sandbox_policy_evaluation","evaluation.fixture",{"verdict":"satisfied"}))
observation_raw=e.canonical(doc("sandbox_verifier_observation","observation.fixture",{}))
launch1, expectation1 = e.make_launch(anchor, request, e.canonical(incident), evaluation_raw,
                                      observation_raw, record_raw, manifest_raw, instruction)
launch2, expectation2 = e.make_launch(anchor, request, e.canonical(incident), evaluation_raw,
                                      observation_raw, record_raw, manifest_raw, instruction)
l1,l2=e.parse(launch1),e.parse(launch2); x1,x2=e.parse(expectation1),e.parse(expectation2)
ok(l1["body"]["nonce"] != l2["body"]["nonce"], "launch nonce is fresh")
ok(x1["body"]["attempt"]["launch_request_sha256"] == sha(launch1), "expectation binds completed launch")
ok(x2["body"]["attempt"]["launch_request_sha256"] == sha(launch2), "second expectation binds second launch")
for key in ("control","store_id","subject"):
    ok(x1["body"][key] == l1["body"][key], "expectation copies launch " + key)
ok(set(l1["body"]["control"]) == {"policy_sha256","decision_sha256","policy_set_sha256",
   "evaluator_driver_sha256","evaluator_program_sha256","sandbox_evaluation_sha256"},
   "launch carries all six control bindings")
ok(l1["body"]["subject"]["environment_entry_sha256"] == sha(e.canonical(entry)),
   "launch hashes selected registry entry")

# Persist request and expectation with fsync before a substituted launch is
# entered. This directly exercises the production exclusive writer.
order=[]; real_write=e.write_exclusive; real_fsync=os.fsync
def ordered_write(path, raw, mode=0o400, sync=False):
    real_write(path,raw,mode,sync); order.append((path.name,sync))
def ordered_launch(_anchor,_frame,_deadline):
    ok(order == [("sandbox-request.json",True),("sandbox-expectation.json",True)],
       "request and expectation durable before launch seam")
    return 0
e.write_exclusive=ordered_write
pre=base/"prelaunch"; pre.mkdir(mode=0o700)
e.write_exclusive(pre/"sandbox-request.json", launch1, sync=True)
e.write_exclusive(pre/"sandbox-expectation.json", expectation1, sync=True)
ordered_launch(anchor,frame,time.monotonic()+1)
e.write_exclusive=real_write
refuses("E_RUNTIME", lambda: real_write(pre/"sandbox-request.json",launch1),
        "exclusive persistence refuses overwrite")

# Every caller document is copied through a held no-follow descriptor. The
# original and private copy are both checked again before a completion marker.
input_source=base/"captured-source.json"; write(input_source,e.canonical(doc("fixture","fixture.capture",{})))
captured_dir=base/"captured"; captured_dir.mkdir(mode=0o700)
snapshot=e.snapshot_input(input_source,captured_dir/"incident.json",1024)
ok(snapshot.raw==(captured_dir/"incident.json").read_bytes(),"input snapshot preserves exact bytes")
snapshot.recheck(); ok(True,"unchanged input snapshot rechecks")
(captured_dir/"incident.json").chmod(0o600); (captured_dir/"incident.json").write_bytes(b"{}\n")
refuses("E_RELATION",snapshot.recheck,"private snapshot mutation refused")
snapshot.close()
e.disjoint([base/"a",base/"b"]); ok(True,"sibling workspaces are disjoint")
refuses("E_WORKSPACE",lambda:e.disjoint([base/"a",base/"a/b"]),"nested workspace refused")

# Payload admission compares the real manifest row, fixed filename, observed
# bytes and fixed instruction. All relation mutations are otherwise complete.
result_body={"check":{"path":"source.txt","expected_sha256":"a"*64},
             "instruction_sha256":sha(instruction),
             "observed":{"sha256":"f"*64,"size_bytes":7},
             "outcome":"mismatch","reason_id":"file.mismatch"}
result_raw=e.canonical(doc("file_digest_verifier_payload","file-digest-payload",result_body))
evidence_manifest=doc("sandbox_evidence_manifest","evidence-manifest",{"files":[{
    "name_hex":b"file-digest-result.json".hex(),"sha256":sha(result_raw),"size_bytes":len(result_raw)}]})
prep_manifest={"entries":[{"path":"source.txt","sha256":"f"*64,"size_bytes":7}]}
snapshots={"payload/stdout":b"","payload/stderr":b"","payload/evidence/0000":result_raw}
payload_receipt={"body":{"lifecycle":{"admission":"admitted","runtime":"completed","control_deadline":"met"},
 "teardown":{"state":"confirmed"},"payload":{"exit_state":"exited","exit_code":0,
 "stdout_sha256":sha(b""),"stderr_sha256":sha(b""),
 "evidence_manifest_sha256":sha(e.canonical(evidence_manifest))}}}
raw, result=e.payload_result(snapshots,evidence_manifest,instruction,prep_manifest,payload_receipt)
ok(raw==result_raw and result["outcome"]=="mismatch", "mismatch is completed comparison")
for target,key in (("result","schema_version"),("observed","size_bytes")):
 bad=e.parse(result_raw)
 if target=="result":bad[key]=True
 else:bad["body"]["observed"][key]=True
 bad_raw=e.canonical(bad);ss=dict(snapshots);ss["payload/evidence/0000"]=bad_raw
 mm=json.loads(json.dumps(evidence_manifest));mm["body"]["files"][0].update(sha256=sha(bad_raw),size_bytes=len(bad_raw))
 receipt=json.loads(json.dumps(payload_receipt));receipt["body"]["payload"]["evidence_manifest_sha256"]=sha(e.canonical(mm))
 refuses("E_RELATION",lambda ss=ss,mm=mm,receipt=receipt:e.payload_result(ss,mm,instruction,prep_manifest,receipt),
         "boolean payload "+key+" refused")
for mutate,message in [
 (lambda s,m: s.__setitem__("payload/stdout",b"noise"),"nonempty stdout refused"),
 (lambda s,m: m["body"]["files"][0].__setitem__("name_hex",b"other".hex()),"wrong evidence name refused"),
 (lambda s,m: m["body"]["files"][0].__setitem__("sha256","0"*64),"wrong evidence digest refused")]:
    ss=dict(snapshots); mm=json.loads(json.dumps(evidence_manifest)); mutate(ss,mm)
    refuses("E_RELATION",lambda ss=ss,mm=mm:e.payload_result(ss,mm,instruction,prep_manifest,payload_receipt),message)
changed=e.parse(result_raw); changed["body"]["observed"]["sha256"]="1"*64
changed_raw=e.canonical(changed); ss=dict(snapshots); ss["payload/evidence/0000"]=changed_raw
mm=json.loads(json.dumps(evidence_manifest)); mm["body"]["files"][0].update(
    sha256=sha(changed_raw),size_bytes=len(changed_raw))
changed_receipt=json.loads(json.dumps(payload_receipt))
changed_receipt["body"]["payload"]["evidence_manifest_sha256"]=sha(e.canonical(mm))
refuses("E_RELATION",lambda:e.payload_result(ss,mm,instruction,prep_manifest,changed_receipt),
        "rehashed wrong observed digest refused")
for field,value,message in (("exit_code",1,"nonzero verifier exit refused"),
                            ("exit_state","signaled","signaled verifier refused")):
    bad=json.loads(json.dumps(payload_receipt));bad["body"]["payload"][field]=value
    refuses("E_RELATION",lambda bad=bad:e.payload_result(snapshots,evidence_manifest,instruction,prep_manifest,bad),message)
bad=json.loads(json.dumps(payload_receipt));bad["body"]["teardown"]["state"]="unconfirmed"
refuses("E_RELATION",lambda:e.payload_result(snapshots,evidence_manifest,instruction,prep_manifest,bad),
        "unconfirmed teardown refused")
bad=json.loads(json.dumps(payload_receipt));bad["body"]["lifecycle"]["control_deadline"]="exceeded"
refuses("E_RELATION",lambda:e.payload_result(snapshots,evidence_manifest,instruction,prep_manifest,bad),
        "expired supervisor deadline refused")

# Completion is an exact 29-file inventory with the marker created last. A
# partial write and an unexpected file cannot masquerade as completion.
files={name:(b"" if name.endswith(".txt") else e.canonical(doc("fixture", "fixture."+str(i), {})))
       for i,name in enumerate(e.EVIDENCE_NAMES)}
files["incident.json"]=e.canonical(incident)
out=base/"bundle"; out.mkdir(mode=0o700)
out_hold=e.stable_directory(out)
sync_order=[];order_fsync=e.os.fsync;order_write=e.write_exclusive_at
def tracked_fsync(fd):
 sync_order.append("file" if stat.S_ISREG(os.fstat(fd).st_mode) else "directory");return order_fsync(fd)
def tracked_write(fd,name,raw,mode=0o400,sync=False,**options):
 sync_order.append("write:"+name);return order_write(fd,name,raw,mode,sync,**options)
e.os.fsync=tracked_fsync;e.write_exclusive_at=tracked_write
bundle=e.seal(out,out_hold,files,incident,"enforced-reproduction.v1")
e.os.fsync=order_fsync;e.write_exclusive_at=order_write;out_hold.close()
bundle_doc=e.parse(bundle)
ok([row["name"] for row in bundle_doc["body"]["files"]] == sorted(e.EVIDENCE_NAMES),
   "bundle rows are sorted exact 29-file inventory")
ok(len(bundle_doc["body"]["files"])==29 and set(p.name for p in out.iterdir())==set(e.EVIDENCE_NAMES)
   and parent_owner.completion_confirmed and parent_owner.completion_payload==bundle,
   "exact inventory is retained without a marker before native commit")
ok(all((out/row["name"]).stat().st_size==row["size_bytes"] and
       sha((out/row["name"]).read_bytes())==row["sha256"] for row in bundle_doc["body"]["files"]),
   "bundle sizes and digests bind actual bytes")
ok(len(list(out.iterdir()))==29 and not (out/"bundle.json").exists(),
   "all evidence bytes precede the native completion marker")
ok(sync_order==sum((["write:"+name,"file"] for name in sorted(e.EVIDENCE_NAMES)),[])+
   ["directory"],
   "each evidence file and its directory are durable before native marker commit")
partial=base/"partial"; partial.mkdir(mode=0o700); write(partial/"incident.json",e.canonical(incident))
ok(not (partial/"bundle.json").exists(),"partial attempt has no completion marker")
extra=base/"extra"; extra.mkdir(mode=0o700); write(extra/"extra",b"x")
extra_hold=e.stable_directory(extra)
refuses("E_RELATION",lambda:e.seal(extra,extra_hold,files,incident,"enforced-reproduction.v1"),
        "preexisting output cannot acquire marker")
ok(not (extra/"bundle.json").exists(),"late inventory refusal leaves no marker");extra_hold.close()
filefail=base/"file-fsync";filefail.mkdir(mode=0o700);filefail_hold=e.stable_directory(filefail)
real_fsync=e.os.fsync;fsync_calls=[0]
def fail_file_fsync(fd):
 if stat.S_ISREG(os.fstat(fd).st_mode):raise OSError("fixture file fsync")
 return real_fsync(fd)
e.os.fsync=fail_file_fsync
try:refuses("E_RUNTIME",lambda:e.seal(filefail,filefail_hold,files,incident,"enforced-reproduction.v1"),
            "evidence file fsync failure refuses before marker")
finally:e.os.fsync=real_fsync
ok(not (filefail/"bundle.json").exists(),"evidence fsync failure leaves no marker");filefail_hold.close()
ok(all(not path.name.endswith("bundle.json") for path in out.iterdir()),
   "Python sealing never creates the native-owned marker")
owner_source=inspect.getsource(e.CancellationSignals)
ok("signal.signal" not in owner_source and "set_wakeup_fd" not in owner_source
   and "pthread_sigmask" not in owner_source,
   "Python owner delegates actions, wakeup and masks to the native State")
evaluation_fixture=e.canonical(doc("sandbox_policy_evaluation","evaluation.fixture",{}))
checker_fixture=e.canonical(doc("sandbox_receipt_check","check.fixture",{}))
trace=e.trace_ledger(incident,"attempt.fixture","env.fixture","reproduced","tool.verifier",
                     evaluation_fixture,checker_fixture)
t=e.parse(trace)
ok(all(row["record_digest"]==sha(e.canonical({k:v for k,v in row.items() if k!="record_digest"}))
       for row in t["body"]["events"]),"trace event digests exclude their own field")
ok(t["body"]["seal"]["final_digest"]==t["body"]["events"][-1]["record_digest"],
   "trace seal binds final event")
trace_path=base/"trace.json"; write(trace_path,trace)
trace_bin=base/"trace-bin"; trace_bin.mkdir(mode=0o700); shutil.copy2(jq_bin,trace_bin/"jq"); (trace_bin/"jq").chmod(0o500)
trace_env=e.clean_env(trace_bin/"jq",base)
trace_receipt=e.run_bounded("trace-validation",["/bin/bash","-p",str(root/"telemetry/v1/validate-trace-ledger.sh"),
    "validate",incident["id"],"attempt.fixture",str(trace_path)],env=trace_env)
ok(e.parse(trace_receipt)["body"]["ledger_ref"]["sha256"]==sha(trace),
   "real trace validator binds ledger")
trace_none=e.trace_ledger(incident,"attempt.none","env.fixture","inconclusive",None,
                          evaluation_fixture,checker_fixture)
ok(e.parse(trace_none)["body"]["events"][1]["facts"]["tool"]=={"state":"not-applicable"},
   "unexecuted tool is not named")

native_state.abort_release();e.CancellationSignals.active=None
print("shadow-enforced-slice3: %d checks passed" % checks)
PY

# The native cancellation owner is exercised through the production Python boundary.
"$python_bin" -I -S -B - "$root" "$tmp/cancellation" "$tmp/native-case-12" \
  "$native_binary" <<'PY'
import importlib.util,os,pathlib,sys
root,base,case12_path,production_path=map(pathlib.Path,sys.argv[1:]);base.mkdir(mode=0o700)
spec=importlib.util.spec_from_file_location("cancel_lifecycle",root/"shadow/v1/enforced-reproduction.py")
e=importlib.util.module_from_spec(spec);sys.modules[spec.name]=e;spec.loader.exec_module(e)
checks=0
def ok(value,message):
 global checks
 if not value:raise AssertionError(message)
 checks+=1;print("ok cancel-%d - %s"%(checks,message))
class Census:
 def __init__(self):self.calls=0
 def observe(self):self.calls+=1
class Native:
 def __init__(self,path):
  binary=next(path.glob("_cancel_release*.so")) if path.is_dir() else path
  binary=binary.resolve(strict=True);self.previous_origin=e._NATIVE_ORIGIN
  e._NATIVE_ORIGIN=None
  module_spec=importlib.util.spec_from_file_location("_cancel_release",binary)
  module=importlib.util.module_from_spec(module_spec);module_spec.loader.exec_module(module)
  try:e._runtime_module_origins()
  except e.Refusal as exc:assert exc.code=="E_RUNTIME"
  else:raise AssertionError("unbound native module origin accepted")
  e._NATIVE_ORIGIN=binary
  assert str(binary) in e._runtime_module_origins()
  self.state=module.prepare_state()
  for name in ("block_entry","arm_consumer","checkpoint","hold_completion","block_final",
   "rollback_marker","commit_completion","abort_release","outcome","prepare_child","spawn_child",
   "child_fds","close_child_stdin","close_child_stdout","close_child_stderr","observe_child_exit",
   "reap_child","term_child_group","kill_child_group","check_child_group","child_status"):
   setattr(self,name,getattr(self.state,name))
 def recheck(self):pass
def admission(native):
 executable=e.stable_file(pathlib.Path(e.sys.executable))
 try:return e._StartupAdmission(e._STARTUP_KEY,e.sys.executable,executable.sha256,e.sys.version,
  tuple(e.sys.version_info[:2]),e._runtime_module_origins(),Census(),native)
 finally:executable.close()
def run(path,name,expect_success):
 directory=base/name;directory.mkdir(mode=0o700);held=e.stable_directory(directory)
 native=Native(path);owner=e.CancellationSignals(admission(native));files={key:b"x" for key in e.EVIDENCE_NAMES}
 try:
  try:
   with owner:bundle=e.seal(directory,held,files,{"body":{"git_revision_ref":"a"*40}},"enforced-reproduction.v1")
  except e.Refusal:
   if expect_success:raise
  else:
   if not expect_success:raise AssertionError("fault build accepted")
   ok((directory/"bundle.json").read_bytes()==bundle,"native commit writes the exact prepared bytes")
 finally:
  held.close();e._NATIVE_ORIGIN=native.previous_origin
  sys.modules.pop("_cancel_release",None)
 if not expect_success:ok(not (directory/"bundle.json").exists(),"native hold failure leaves no marker")
run(case12_path,"dup-failure",False)
run(production_path,"success",True)
print("shadow-enforced-cancellation: %d checks passed"%checks)
PY

cli_result=0
cli_stderr=$("$python_bin" -I -S -B "$root/shadow/v1/enforced-reproduction.py" 2>&1) || cli_result=$?
[ "$cli_result" -eq 1 ] && [ "$cli_stderr" = E_USAGE ] || fail 'standalone closed startup admission'
cli_result=0
cli_stderr=$("$python_bin" -I -S -B "$root/shadow/v1/enforced-reproduction.py" reproduce /nonexistent /nonexistent /nonexistent 2>&1) || cli_result=$?
[ "$cli_result" -eq 1 ] && [ "$cli_stderr" = E_PARENT_CONTEXT ] || fail 'standalone owner acquisition'
/usr/bin/printf 'shadow-enforced-cli: closed startup and owner acquisition passed\n'


# Exercise the production orchestration with only host identity, child process,
# and native launch boundaries substituted. The component-specific suites run
# each unchanged child interface; this case proves their byte flow and ordering.
/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C \
  "$python_bin" -I -S -B - "$root" "$tmp/slice3-orchestration" "$native_binary" \
  "$native_out/build-record.json" "$tmp/runtime-dependency-record.json" <<'PY'
import os
startup_environment_keys=tuple(sorted(os.environ))
import hashlib, importlib.util, json, pathlib, sys, sysconfig, types
root, base, native_binary, native_record, dependency_record = map(pathlib.Path,sys.argv[1:])
dependency_document=json.loads(dependency_record.read_bytes())
assert tuple(dependency_document["body"]["preexec_environment"]["observed_keys"])==startup_environment_keys
base.mkdir(mode=0o700)
spec=importlib.util.spec_from_file_location("enforced_flow",root/"shadow/v1/enforced-reproduction.py")
e=importlib.util.module_from_spec(spec);sys.modules[spec.name]=e;spec.loader.exec_module(e)
e.sys.executable=str(pathlib.Path(sys.executable).resolve())
def sha(raw): return hashlib.sha256(raw).hexdigest()
def doc(kind,identity,body): return {"schema_version":1,"kind":kind,"id":identity,"body":body}
def write(path,raw,mode=0o400): path.write_bytes(raw);path.chmod(mode)
checks=0
def ok(value,message):
 global checks
 if not value: raise AssertionError(message)
 checks+=1;print("ok flow-%d - %s"%(checks,message))

source=base/"source.git";source.mkdir(mode=0o700)
work=base/"work";output=base/"output";work.mkdir(mode=0o700);output.mkdir(mode=0o700)
helper=base/"object-closure";jq=base/"jq";write(helper,b"helper",0o500);write(jq,b"jq",0o500)
commit,tree,candidate_commit,candidate_tree="b"*40,"c"*40,"d"*40,"e"*40
expected=sha(b"fixed\n")
incident=doc("shadow_incident_record","incident.flow",{"deploy_authority":"none",
 "failing_check":{"check_id":"check.flow","kind":"file-digest","path":"source.txt","expected_sha256":expected},
 "git_revision_ref":{"repository_id":"fixture.target","hash_algorithm":"sha1","commit_id":commit},
 "observed_at":"2026-01-01T00:00:00Z","observed_symptom":"changed",
 "reporter_actor_ref":"actor.fixture","target_repository_id":"fixture.target"})
revision={"repository_id":"fixture.target","hash_algorithm":"sha1","commit_id":commit}
request_content=doc("stage_request","request.flow",{"target_repository_id":"fixture.target",
 "target_revision":{"state":"present","value":revision},
 "source":{"state":"present","value":{"type":"git-object","value":{"revision":revision}}},
 "environment_ref":{"environment_id":"env.fixture","fingerprint_sha256":"PLACEHOLDER"}})
resolved_content=doc("resolved_profile","profile.flow",{})
input_doc={"stage_request":{"content":request_content,"sha256":sha(e.canonical(request_content))},
 "resolved_profile":{"content":resolved_content,"sha256":sha(e.canonical(resolved_content))},
 "payloads":[{"input_id":"input.producer-patch","data":""}],
 "trust_context":{"verified_payloads":[{"input_id":"input.producer-patch","content":{"data":""}}]}}
instruction=e.make_instruction(incident)
identity=doc("qualified_identity","identity.flow",{"stage_request_ref":{"schema_version":1,"kind":"stage_request",
 "id":"request.flow","sha256":input_doc["stage_request"]["sha256"]},"resolved_profile_ref":{
 "schema_version":1,"kind":"resolved_profile","id":"profile.flow","sha256":input_doc["resolved_profile"]["sha256"]},
 "verification_instructions_ref":{"content_id":"instruction.flow","media_type":"text/plain","sha256":sha(instruction)}})
claim=doc("execution_environment_claim","env.fixture",{})
request_content["body"]["environment_ref"]["fingerprint_sha256"]=sha(e.canonical(claim))
input_doc["stage_request"]={"content":request_content,"sha256":sha(e.canonical(request_content))}
identity["body"]["stage_request_ref"]["sha256"]=input_doc["stage_request"]["sha256"]
duty=doc("duty_separation_evaluation","duty.flow",{})
for name,value in (("incident",incident),("claim",claim),("duty",duty),("identity",identity),("input",input_doc)):
 write(base/(name+".json"),e.canonical(value))
request=doc("shadow_enforced_request","attempt.flow",{"attempt_id":"attempt.flow","attempt_number":1,
 "incident":str(base/"incident.json"),"claim":str(base/"claim.json"),"duty_evaluation":str(base/"duty.json"),
 "materialization_input":str(base/"input.json"),"qualified_identity":str(base/"identity.json"),
 "source_git_dir":str(source),"jq":str(jq),"closure_helper":str(helper)})
write(base/"request.json",e.canonical(request))

policy=b'{"policy":true}\n';decision=b'{"decision":true}\n';pset=b'{"set":true}\n'
driver=b'#!/bin/bash\n';program=b'.\n';accepted=b'{"accepted":true}\n';registry_raw=b'{"registry":true}\n'
fake_anchor=base.parent/"flow-installation/supervisor";fake_anchor.mkdir(parents=True,mode=0o700)
entry={"description":"fixture","environment_id":"env.fixture","evidence_scope":"fixtures-only",
 "proof_state":"unproven","source_root_commit":commit,"target_repository_id":"fixture.target"}
installed={"control_policy":(policy,sha(policy)),"control_decision":(decision,sha(decision)),
 "control_policy_set":(pset,sha(pset)),"evaluator_driver":(driver,sha(driver)),
 "evaluator_program":(program,sha(program)),"accepted_set":(accepted,sha(accepted)),
 "registry":(registry_raw,sha(registry_raw))}
class Anchor:
 config={"environment_id":"env.fixture","store_id":"store.fixture","principal_uid":1234,
  "store_root":str(base/"store"),"work_root":str(base/"host-work"),"installed_files":{},
  "identity_paths":{"dyld_cache_files":[]}}
 registry=(sha(registry_raw),[entry]);installed=installed
 held=[types.SimpleNamespace(path=str(fake_anchor/"host-supervisor.py"),read=lambda maximum,code:b"host\n",
  recheck=lambda code:None)]
 def recheck(self,*_args): events.append("anchor-recheck")
 def seal_recheck(self,*_args): events.append("anchor-seal-recheck")
 def close(self): events.append("anchor-close")
e.c.ANCHOR=str(fake_anchor)
class Snap:
 def __init__(self,path,digest_value): self.snapshot=types.SimpleNamespace(path=str(path));self.sha256=digest_value
 def recheck(self): events.append("dependency-recheck")
 def close(self): events.append("dependency-close")
events=[]
e.c.snapshot_dependency=lambda path,digest_value,size,private,name: Snap(helper,digest_value)
e.c.snapshot_jq=lambda path,private: Snap(jq,sha(b"jq"))
e.c.verify_helper_source=lambda: events.append("helper-source")
e.c.probe_dependency=lambda snap,args,expected: events.append("probe:"+args[0])
e.c.load_anchor=lambda _resolver=None: Anchor()
e.c.verifier_observation=lambda anchor,environment,target:e.canonical(doc("sandbox_verifier_observation",
 "observation.flow",{"environment_id":environment,"environment_entry_sha256":sha(e.canonical(entry)),
 "target_repository_id":target,"accepted_set_sha256":sha(accepted),"verifier_sha256":"9"*64}))

record={"schema_version":1,"kind":"candidate_content_preparation","status":"completed",
 "source":{"repository_id":"fixture.target","hash_algorithm":"sha1","commit_id":commit,"tree_id":tree},
 "candidate":{"commit_id":commit,"tree_id":tree}}
manifest={"schema_version":1,"kind":"candidate_content_manifest","entries":[{
 "path":"source.txt","mode":"100644","blob_oid":"f"*40,"size_bytes":6,"sha256":sha(b"fixed\n")}],
 "file_count":1,"directory_count":0,"total_file_bytes":6,"hash_algorithm":"sha256"}
materializer_receipt={
 "source":{"repository_id":"fixture.target","hash_algorithm":"sha1","commit_id":commit,"tree_id":tree},
 "candidate":{"commit_id":commit,"tree_id":tree,"parent_commit_id":commit},
 "changed_paths":{"count":0,"sha256":"0"*64}}
stage=doc("stage_result","result.flow",{"outcome":{"family":"change","value":"no-change"}})
response={"schema_version":1,"kind":"adapter_response","stage_result":stage,"payloads":[{
 "content_id":"receipt.materialize","media_type":"application/json","sha256":sha(e.canonical(materializer_receipt)),
 "data":e.canonical(materializer_receipt).decode()}],"authority":"none","qualification":"unavailable","effects":[]}
evaluation=doc("sandbox_policy_evaluation","evaluation.flow",{
 "verdict":"satisfied","reason_ids":["sandbox.declaration-satisfied"]})
checker=doc("sandbox_receipt_check","check.flow",{"check_verdict":"valid","enforcement_verdict":"satisfied"})
result_body={"check":{"path":"source.txt","expected_sha256":expected},
 "instruction_sha256":sha(instruction),"observed":{"sha256":expected,"size_bytes":6},
 "outcome":"match","reason_id":"file.match"}
result_raw=e.canonical(doc("file_digest_verifier_payload","file-digest-payload",result_body))
evidence_manifest=e.canonical(doc("sandbox_evidence_manifest","evidence-manifest",{"files":[{
 "name_hex":b"file-digest-result.json".hex(),"sha256":sha(result_raw),"size_bytes":len(result_raw)}]}))
receipt=doc("sandbox_enforcement_receipt","attempt.flow",{
 "lifecycle":{"admission":"admitted","runtime":"completed","control_deadline":"met"},
 "teardown":{"state":"confirmed"},"payload":{"exit_state":"exited","exit_code":0,
 "stdout_sha256":sha(b""),"stderr_sha256":sha(b""),
 "evidence_manifest_sha256":sha(evidence_manifest)}})
origin=e.canonical(doc("shadow_origin_observation","attempt.flow",{"store_id":"store.fixture",
 "attempt_id":"attempt.flow","entries":[],"result":"authenticated"}))
snapshots={"receipt.json":e.canonical(receipt),"payload/stdout":b"","payload/stderr":b"",
 "payload/evidence-manifest.json":evidence_manifest,"payload/evidence/0000":result_raw}
e.c.read_store_attempt=lambda anchor,attempt:(snapshots,origin)

real_run=e.run_bounded
def child(role,argv,**kwargs):
 if role=="helper-version": return b"ystack-object-closure-v1\n"
 if role=="jq-version": return b"jq-1.6\n"
 role=pathlib.Path(argv[0]).name+":"+" ".join(argv[1:3]);events.append(role)
 if "validate-input" in argv or "validate-response" in argv: return b"true\n"
 if "validate-incident.sh" in " ".join(argv): return e.canonical(doc("shadow_incident_validation",incident["id"],{}))
 if "qualified-identity.jq" in " ".join(argv): return b""
 if "materialize.sh" in " ".join(argv): return e.canonical(response)
 if "prepare-candidate.py" in " ".join(argv):
  operation=argv[5]; out=pathlib.Path(argv[argv.index("--output")+1])
  events.append(operation)
  if operation=="prepare":
   out.mkdir(mode=0o700)
   write(out/"record.json",e.canonical(record));write(out/"manifest.json",e.canonical(manifest))
   candidate=out/"candidate";candidate.mkdir(mode=0o700);write(candidate/"source.txt",b"fixed\n")
  return b""
 if "evaluate-bound-sandbox.sh" in " ".join(argv): events.append("evaluate");return e.canonical(evaluation)
 if "check-sandbox-receipt.sh" in " ".join(argv): events.append("check-bound");return e.canonical(checker)
 if "validate-trace-ledger.sh" in " ".join(argv):
  trace=pathlib.Path(argv[-1]).read_bytes()
  return e.canonical(doc("telemetry_trace_ledger_validation","shadow-enforced-trace-ledger",{
   "ledger_ref":{"sha256":sha(trace)}}))
 raise AssertionError(argv)
e.run_bounded=child
launch_frames=[]
def launch(anchor,frame,deadline):
 ok((work/"launch/sandbox-request.json").exists() and (work/"launch/sandbox-expectation.json").exists(),
    "durable documents exist when launch seam starts")
 launch_frames.append(frame);events.append("launch");return 0
e._launch=launch
parent={"helper_source_sha256":e.c.HELPER_SOURCE_SHA256,"helper_build_record_sha256":"7"*64,
 "helper_executable_sha256":sha(b"helper"),"helper_executable_size":6,"helper_path":str(helper),
 "native_release":{"source_sha256":sha((root/"shadow/v1/_cancel_release.c").read_bytes()),
 "build_script_sha256":sha((root/"shadow/v1/build-cancel-release.sh").read_bytes()),
 "build_record_sha256":sha(native_record.read_bytes()),"binary_path":str(native_binary),
 "binary_size":native_binary.stat().st_size,"binary_sha256":sha(native_binary.read_bytes()),
 "python_path":os.path.realpath(sys.executable),"python_sha256":sha(pathlib.Path(sys.executable).read_bytes()),
 "python_abi":sysconfig.get_config_var("SOABI"),
 "dependency_record_sha256":sha(dependency_record.read_bytes()),"loader_mode":"rtld-now-local.v1"}}
class Census:
 def observe(self):pass
executable=e.stable_file(pathlib.Path(e.sys.executable))
admission=e._StartupAdmission(e._STARTUP_KEY,e.sys.executable,executable.sha256,e.sys.version,
 tuple(e.sys.version_info[:2]),e._runtime_module_origins(),Census())
executable.close();native=e._NativeRelease(parent,admission)
admission=e.dataclasses.replace(admission,native=native,module_origins=e._runtime_module_origins())
try:
 with e.CancellationSignals(admission):bundle=e.reproduce(base/"request.json",work,output,parent)
finally:native.close()
ok(len(launch_frames)==1 and launch_frames[0].startswith(b"YSFRAME1"),"one framed launch")
ok(events.index("launch")>events.index("prepare"),"launch follows preparation")
ok(events.index("launch")>events.index("evaluate"),
   "launch follows actual bound evaluation call")
bundle_doc=e.parse(bundle)
ok(bundle_doc["body"]["record_form"]=="enforced-reproduction.v1","completed bundle record form")
ok(len(bundle_doc["body"]["files"])==29,"orchestration seals 29 evidence files")
record_doc=e.parse((output/"shadow-record.json").read_bytes())
ok(record_doc["body"]["outcome"]=="no-change" and record_doc["body"]["sandbox"]["state"]=="satisfied",
   "match maps to satisfied no-change")
ok(record_doc["body"]["producer_invocations"]==0,"consumer invokes no producer")
ok((output/"payload-stdout.txt").read_bytes()==b"" and (output/"payload-stderr.txt").read_bytes()==b"",
   "empty verifier streams retained")
ok(events.index("check-bound")>events.index("launch"),
   "receipt checker follows controlled-store launch evidence")
ok(events.count("dependency-recheck")>=4 and events.count("anchor-recheck")>=2,
   "dependencies and anchor rechecked through completion")
ok(not any("incident-to-eval" in row for row in events),"slice3 never enters write converter")
changed=json.loads(json.dumps(response));changed["stage_result"]["body"]["outcome"]["value"]="changed"
changed_receipt=json.loads(changed["payloads"][0]["data"])
changed_receipt["candidate"].update(commit_id=candidate_commit,tree_id=candidate_tree)
changed_receipt["changed_paths"]["count"]=1
changed["payloads"][0]["data"]=e.canonical(changed_receipt).decode()
changed["payloads"][0]["sha256"]=sha(e.canonical(changed_receipt))
try:e.require_no_change(e.canonical(changed),incident)
except e.Refusal as exc:ok(exc.code=="E_RELATION","changed materialization response cannot launch")
else:raise AssertionError("changed materialization accepted")
print("shadow-enforced-flow: %d checks passed"%checks)
PY

# Real acyclic prerequisite proof. This invokes the unchanged materializer,
# protocol, duty evaluator, bound evaluator, and receipt checker. Synthetic
# registry/accepted bytes live only in this private fixture package.
real="$tmp/slice3-real"
/bin/mkdir -m 700 "$real" "$real/home" "$real/source.git" "$real/bin"
/bin/cp "$jq_bin" "$real/bin/jq"; /bin/chmod 0500 "$real/bin/jq"; real_jq="$real/bin/jq"
git_fixture() {
  /usr/bin/env -i HOME="$real/home" TMPDIR="$real" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects "$@"
}
git_fixture init -q --bare --object-format=sha1 "$real/source.git"
real_blob=$(/usr/bin/printf 'fixed content\n' | git_fixture --git-dir="$real/source.git" hash-object -w --stdin)
real_tree=$(/usr/bin/printf '100644 blob %s\tsource.txt\n' "$real_blob" | git_fixture --git-dir="$real/source.git" mktree)
real_commit=$(/usr/bin/printf 'source\n' | git_fixture --git-dir="$real/source.git" commit-tree "$real_tree")
git_fixture --git-dir="$real/source.git" update-ref refs/heads/main "$real_commit"
/bin/bash "$root/scripts/test/local-git-materializer-fixtures.sh" build "$real/built" \
  "$real_jq" sha1 "$real_commit" "$real_tree"
empty_sha=$(/usr/bin/printf '' | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
/usr/bin/printf '%s\n' '{"kind":"fixture-declaration","id":"environment.earlier"}' > "$real/declaration.json"
declaration_sha=$(sha_file "$real/declaration.json")
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -S -c --arg empty "$empty_sha" --arg declaration_sha "$declaration_sha" '
  .payloads |= map(if .input_id=="input.producer-patch" then .data="" else . end) |
  .trust_context.verified_payloads |= map(if .input_id=="input.producer-patch"
    then .content.data="" | .sha256=$empty else . end) |
  .stage_request.content.body.inputs |= map(if .input_id=="input.producer-patch"
    then .value.value.value.sha256=$empty else . end)
' "$real/built/input.json" > "$real/prior-stage.json"
"$real_jq" -S -c '.stage_request.content' "$real/prior-stage.json" > "$real/prior-request.json"
prior_request_sha=$(sha_file "$real/prior-request.json")
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -S -c --arg digest "$prior_request_sha" '.stage_request.sha256=$digest' \
  "$real/prior-stage.json" > "$real/prior-input.json"
generation=$("$real_jq" -er '.[-1].generation_id' "$root/core/v2/generation-registry.json")
modules="$root/core/v2/generations/$generation/modules"
protocol="$root/adapters/local-git-materializer/v1/protocol.jq"
"$real_jq" -L "$modules" -e --arg command validate-input -f "$protocol" "$real/prior-input.json" \
  > "$real/prior-input.valid"
/bin/mkdir -m 700 "$real/candidate" "$real/materializer-scratch"
"$root/adapters/local-git-materializer/v1/materialize.sh" materialize "$real/prior-input.json" \
  fixture.target "$real/source.git" "$real/candidate" "$real/materializer-scratch" \
  "$tmp/object-closure" "$real_jq" > "$real/prior-response.json"
"$real_jq" -S -c '.stage_result' "$real/prior-response.json" > "$real/prior-result.json"
"$real_jq" -S -c '.resolved_profile.content' "$real/prior-input.json" > "$real/prior-profile.json"
stage_sha=$(sha_file "$real/prior-result.json")
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -S -c --arg stage_sha "$stage_sha" '
 . as $response | ($response.payloads[0].data|fromjson) as $receipt |
 {input:$input[0],response:$response,
  verified_receipt:{content:$receipt,sha256:$response.payloads[0].sha256},
  receipt_utf8:$response.payloads[0].data,stage_result_sha256:$stage_sha}
' --slurpfile input "$real/prior-input.json" "$real/prior-response.json" > "$real/prior-response-check.json"
"$real_jq" -L "$modules" -e --arg command validate-response -f "$protocol" \
  "$real/prior-response-check.json" > "$real/prior-response.valid"
PATH="$real/bin:/usr/bin:/bin" /bin/bash -p "$root/control/v1/evaluate-duty.sh" evaluate \
  "$root/control/v1/control-policy-set-sandbox-bound.json" "$real/prior-request.json" \
  "$real/prior-profile.json" "$real/prior-result.json" > "$real/duty.json"
"$real_jq" -e '.body.verdict=="satisfied" and .body.reason_ids==["duty.satisfied"]' \
  "$real/duty.json" > /dev/null || fail 'slice3 real bound-set duty'

verifier_root="$real/verifier-root"
/bin/mkdir -m 700 "$verifier_root" "$verifier_root/candidate" "$verifier_root/evidence" \
  "$verifier_root/scratch" "$verifier_root/tools"
/usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 \
  -DYSTACK_SANDBOX_ROOT="\"$verifier_root\"" "$root/verifiers/file-digest/v1/verifier.c" \
  -o "$real/file-digest-verifier"
/bin/chmod 0555 "$real/file-digest-verifier"

fixture="$real/package"
/bin/mkdir -p "$fixture"
for component_dir in adapters core preparation control enforcement shadow telemetry scripts; do
  /bin/cp -R "$root/$component_dir" "$fixture/$component_dir"
done
for name in evaluate-bound-sandbox.sh sandbox-bound.jq sandbox-bound-policy.json \
  sandbox-bound-decision.json control-policy-set-sandbox-bound.json validate.sh policy-set.jq; do
  /bin/cp "$root/control/v1/$name" "$fixture/control/v1/$name"
done
/bin/chmod 0755 "$fixture/control/v1/evaluate-bound-sandbox.sh" "$fixture/control/v1/validate.sh"
env_id=env.local-macos-fixture; verifier_sha=$(sha_file "$real/file-digest-verifier")
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -S -c --arg commit "$real_commit" '
 .body.environments=[(.body.environments[0] | .environment_id="env.local-macos-fixture" |
   .target_repository_id="fixture.target" | .source_root_commit=$commit | .proof_state="unproven")]
' "$root/shadow/v1/shadow-environments.json" > "$fixture/shadow/v1/shadow-environments.json"
registry="$fixture/shadow/v1/shadow-environments.json"
"$real_jq" -S -c '.body.environments[0]' "$registry" > "$real/entry.json"
entry_sha=$(sha_file "$real/entry.json")
accepted="$fixture/enforcement/v1/accepted-identities.json"
expected_sha=$(/usr/bin/printf 'fixed content\n' | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
instruction_sha=$(/usr/bin/printf 'ystack.file-digest-instruction.v1\npath source.txt\nsha256 %s\n' \
  "$expected_sha" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -nSc --arg env "$env_id" --arg verifier "$verifier_sha" --arg verifier_two "$(sha_file "$tmp/object-closure")" \
 --arg instruction "$instruction_sha" --arg guest_init "$(sha_file "$fixture/control/v1/sandbox-bound-policy.json")" \
 --arg guest_kernel "$(sha_file "$fixture/control/v1/sandbox-bound-decision.json")" \
 --arg guest_config "$(sha_file "$fixture/control/v1/control-policy-set-sandbox-bound.json")" \
 --arg guest_supervisor "$(sha_file "$fixture/control/v1/evaluate-bound-sandbox.sh")" \
 --arg host_runtime "$(sha_file "$python_bin")" --arg host_supervisor "$(sha_file "$fixture/shadow/v1/_consumer.py")" \
 --arg image "$(sha_file "$registry")" --arg toolchain "$(sha_file "$real_jq")" '
 def ids:{guest_init:[$guest_init],guest_kernel:[$guest_kernel],guest_kernel_config:[$guest_config],
 guest_supervisor:[$guest_supervisor],host_runtime:[$host_runtime],host_supervisor:[$host_supervisor],
 image:[$image],toolchain:[$toolchain],verification_instructions:[$instruction],verifier:([$verifier,$verifier_two]|sort|unique)};
 def mechanisms:{cpu_time_ms:["mechanism.cpu"],memory_bytes:["mechanism.memory"],
 output_bytes:["mechanism.output"],process_count:["mechanism.process"],
 scratch_bytes:["mechanism.scratch"],wall_time_ms:["mechanism.wall"]};
 {schema_version:1,kind:"sandbox_accepted_identity_set",id:"sandbox.accepted-identities.v1",
 body:{activation_state:"inactive",environments:[{environment_id:$env,identities:ids,
 mechanisms:mechanisms,scratch_bytes:1048576}],set_version:"v1"}}
' > "$accepted"
accepted_sha=$(sha_file "$accepted"); set="$fixture/control/v1/control-policy-set-sandbox-bound.json"
set_sha=$(sha_file "$set"); policy="$fixture/control/v1/sandbox-bound-policy.json"
duty_sha=$(sha_file "$real/duty.json")
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -nSc --arg env "$env_id" --arg d "$verifier_sha" --arg duty "$duty_sha" \
  --arg set_sha "$set_sha" --slurpfile p "$policy" --slurpfile prior "$real/duty.json" '
 def ref($v;$kind;$id;$sha):{schema_version:$v,kind:$kind,id:$id,sha256:$sha};
 {schema_version:1,kind:"execution_environment_claim",id:$env,body:{declaration_status:"complete",
 duty_evaluation_ref:ref(1;"duty_separation_evaluation";$prior[0].id;$duty),
 effects:{external_writes:false,target_writes:false},environment:$p[0].body.environment,
 execution_identity:{adapter_instance_id:"instance.verifier",execution_boundary_id:"boundary.verifier",
 principal_id:"principal.verifier",role:"verifier"},filesystem:$p[0].body.filesystem,
 isolation:$p[0].body.isolation,limits:$p[0].body.limits,network:$p[0].body.network,
 policy_set_ref:ref(1;"control_policy_set";"control-policy-set.sandbox-bound.v1";$set_sha),
 resources:$p[0].body.resources,sensitive_material:$p[0].body.sensitive_material,
 stage_result_ref:$prior[0].body.stage.result_ref,
 tools:[($p[0].body.tools[0]|del(.identity_binding)+{sha256:$d})]}}
' > "$real/claim.json"
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -nSc --arg env "$env_id" --arg entry "$entry_sha" --arg accepted "$accepted_sha" \
  --arg d "$verifier_sha" '{schema_version:1,kind:"sandbox_verifier_observation",
 id:"sandbox.observation.verifier",body:{environment_id:$env,environment_entry_sha256:$entry,
 target_repository_id:"fixture.target",accepted_set_sha256:$accepted,verifier_sha256:$d}}' \
  > "$real/observation.json"
PATH="$real/bin:/usr/bin:/bin" "$fixture/control/v1/evaluate-bound-sandbox.sh" evaluate \
  "$real/duty.json" "$real/claim.json" "$real/observation.json" > "$real/evaluation.json"
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -e --arg duty "$duty_sha" --arg d "$verifier_sha" '
 .body.verdict=="satisfied" and .body.duty_evaluation_ref.sha256==$duty and
 .body.verifier_binding.verifier_sha256==$d
' "$real/evaluation.json" > /dev/null || fail 'slice3 real bound evaluation'

# Q is constructed only after D and C. P and its real R/D bytes stay unchanged.
claim_sha=$(sha_file "$real/claim.json")
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -S -c --arg claim_sha "$claim_sha" '
 .stage_request.content.body.environment_ref={environment_id:"env.local-macos-fixture",fingerprint_sha256:$claim_sha}
' "$real/prior-input.json" > "$real/q-stage.json"
"$real_jq" -S -c '.stage_request.content' "$real/q-stage.json" > "$real/q-request.json"
q_sha=$(sha_file "$real/q-request.json")
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -S -c --arg q "$q_sha" '.stage_request.sha256=$q' "$real/q-stage.json" > "$real/q-input.json"
"$real_jq" -L "$modules" -e --arg command validate-input -f "$protocol" "$real/q-input.json" \
  > "$real/q-input.valid" || {
    /bin/cp "$real/q-input.json" /private/tmp/ystack-shadow-slice3-q-input.failed.json
    fail 'slice3 acyclic consumer request'
  }
/bin/mkdir -m 700 "$real/q-candidate" "$real/q-scratch"
q_status=0
PATH="$real/bin:/usr/bin:/bin" "$fixture/adapters/local-git-materializer/v1/materialize.sh" materialize \
  "$real/q-input.json" fixture.target "$real/source.git" "$real/q-candidate" "$real/q-scratch" \
  "$tmp/object-closure" "$real_jq" > "$real/q-response.json" 2> "$real/q-materializer.err" || q_status=$?
[ "$q_status" -eq 0 ] || { /bin/cp "$real/q-materializer.err" /private/tmp/ystack-shadow-slice3-q-materializer.err; fail "slice3 Q materializer status $q_status"; }
[ "$(sha_file "$real/prior-request.json")" = "$prior_request_sha" ] &&
[ "$(sha_file "$real/duty.json")" = "$duty_sha" ] || fail 'slice3 prerequisite tuple changed'

# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -nSc --arg commit "$real_commit" --arg expected "$expected_sha" '
 {schema_version:1,kind:"shadow_incident_record",id:"incident.shadow-reproduction",
  body:{deploy_authority:"none",target_repository_id:"fixture.target",
   git_revision_ref:{repository_id:"fixture.target",hash_algorithm:"sha1",commit_id:$commit},
   failing_check:{kind:"file-digest",path:"source.txt",expected_sha256:$expected},
   observed_symptom:"fixture digest check",reporter_actor_ref:"actor.fixture-reporter",
   observed_at:"2026-08-30T00:00:04Z"}}
' > "$real/incident.json"
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -nSc --arg commit "$real_commit" --arg blob "$real_blob" \
  --arg instruction "$instruction_sha" --slurpfile input "$real/q-input.json" '
 def pair($p):{schema_version:$p.content.schema_version,kind:$p.content.kind,
   id:$p.content.id,sha256:$p.sha256};
 {schema_version:1,kind:"qualified_identity",id:"identity.shadow-reproduction",body:{
  adapter_config_refs:[{content_id:"producer-config",media_type:"application/json",sha256:("1"*64)}],
  model_request:{effort_id:"high",model_id:"model.fixture",provider_id:"provider.fixture"},
  prompt_refs:[{location:{kind:"path",value:"routines/coder.md"},mode:"100644",
   object_id:$blob,object_type:"blob",revision:{commit_id:$commit,hash_algorithm:"sha1",
   repository_id:"fixture.target"}}],resolved_profile_ref:pair($input[0].resolved_profile),skill_refs:[],
  stage_request_ref:pair($input[0].stage_request),target_revision:{commit_id:$commit,
   hash_algorithm:"sha1",repository_id:"fixture.target"},verification_instructions_ref:{
   content_id:"verification-instructions",media_type:"text/plain",sha256:$instruction}}}
' > "$real/identity.json"
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -nSc --arg real "$real" --arg jq "$real_jq" --arg helper "$tmp/object-closure" '
 {schema_version:1,kind:"shadow_enforced_request",id:"attempt.shadow-reproduction",body:{
  attempt_id:"attempt.shadow-reproduction",attempt_number:1,incident:($real+"/incident.json"),
  claim:($real+"/claim.json"),duty_evaluation:($real+"/duty.json"),
  materialization_input:($real+"/q-input.json"),qualified_identity:($real+"/identity.json"),
  source_git_dir:($real+"/source.git"),jq:$jq,closure_helper:$helper}}
' > "$real/request.json"

/usr/bin/printf 'shadow-enforced-real-chain: materializer/protocol/duty/bound-evaluator passed\n'

real_native="$real/native-release"
/bin/bash -p "$fixture/shadow/v1/build-cancel-release.sh" build "$python_bin" "$real_native"
real_native_binary=$(/usr/bin/find "$real_native" -mindepth 1 -maxdepth 1 -type f ! -name build-record.json -print)
/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C \
  "$python_bin" -I -S -B "$tmp/runtime-dependency-collector.py" "$fixture" "$real_native_binary" \
    "$native_actual_child_binary" "$native_actual_child_record" \
  > "$real/runtime-dependency-record.json"
"$python_bin" -I -S -B - "$real/runtime-dependency-record.json" <<'PY'
import hashlib,json,pathlib,sys
raw=pathlib.Path(sys.argv[1]).read_bytes();assert len(raw)<=1024*1024
record=json.loads(raw);assert raw==(json.dumps(record,sort_keys=True,separators=(",",":"),ensure_ascii=False)+"\n").encode()
evidence={"schema_version":1,"kind":"shadow_runtime_dependency_evidence",
 "id":"shadow.runtime-dependency-evidence.real-chain",
 "body":{"record_sha256":hashlib.sha256(raw).hexdigest(),"record":record}}
print(json.dumps(evidence,sort_keys=True,separators=(",",":"),ensure_ascii=False))
PY
/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C \
  "$python_bin" -I -S -B - "$real" "$fixture" "$python_bin" "$real_native_binary" \
  "$real_native/build-record.json" "$real/runtime-dependency-record.json" <<'PY'
import os
startup_environment_keys=tuple(sorted(os.environ))
import dataclasses, hashlib, importlib.util, json, pathlib, shutil, stat, subprocess, sys, sysconfig, types
base, package, physical_python, native_binary, native_record, dependency_record = map(pathlib.Path,sys.argv[1:])
dependency_document=json.loads(dependency_record.read_bytes())
assert tuple(dependency_document["body"]["preexec_environment"]["observed_keys"])==startup_environment_keys
module_path=package/"shadow/v1/enforced-reproduction.py"
spec=importlib.util.spec_from_file_location("real_shadow_enforced",module_path)
e=importlib.util.module_from_spec(spec);sys.modules[spec.name]=e;spec.loader.exec_module(e)
e.sys.executable=str(physical_python.resolve())
c=e.c
def sha(raw): return hashlib.sha256(raw).hexdigest()
def canonical(value): return json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()+b"\n"
def write(path,raw,mode):
 path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(raw);path.chmod(mode)
principal=1234;gid=os.getgid();store=base/"store";store.mkdir(mode=0o750)
anchor=base/"installation/supervisor";anchor.mkdir(parents=True,mode=0o755)
installed=base/"installation/installed";installed.mkdir(mode=0o755)
identities=base/"installation/identities";identities.mkdir(mode=0o755)
verifier=base/"file-digest-verifier"; verifier_root=base/"verifier-root"
identity_paths={}
for name in sorted(c.IDENTITY_KEYS-{"dyld_cache_files"}):
 path=verifier if name=="verifier" else identities/name
 if path!=verifier: write(path,(name+"\n").encode(),0o555)
 identity_paths[name]=str(path)
dyld=identities/"dyld-cache";write(dyld,b"dyld\n",0o555);identity_paths["dyld_cache_files"]=[str(dyld)]
installed_paths={}
for role,relative in c.INSTALLED_SOURCES.items():
 source=package/relative;target=installed/(role+".installed")
 write(target,source.read_bytes(),0o444);installed_paths[role]=str(target)
host_script=anchor/"host-supervisor.py";write(host_script,b"# fixture host supervisor\n",0o555)
config={"schema_version":1,"kind":"sandbox_host_config","id":"sandbox.host-config.v1","body":{
 "consumer_gid":gid,"environment_id":"env.local-macos-fixture","identity_paths":identity_paths,
 "installed_files":installed_paths,"principal_uid":principal,
 "runtime":{"driver":str(identities/"host_runtime"),"vfkit":str(identities/"vm_service")},
 "store_id":"store.shadow-fixture","store_root":str(store),"work_root":str(base/"host-work")}}
write(anchor/"host-config.json",canonical(config),0o444)
(base/"host-work").mkdir(mode=0o750)
c.ANCHOR=str(anchor)

# Preserve real kind/device/inode/link/size/change metadata. Substitute only the fixture's
# root/supervisor ownership and unsafe bits that cannot be created by an unprivileged test.
raw_metadata,raw_named,raw_acl=c._metadata,c._named_metadata,c._acl_state
root_ancestors=set();cursor=anchor
while True:
 root_ancestors.add(str(cursor))
 if cursor==cursor.parent: break
 cursor=cursor.parent
external_ancestors=set();cursor=base.parent.parent
while True:
 external_ancestors.add(str(cursor))
 if cursor==cursor.parent: break
 cursor=cursor.parent
external_identity={}
cursor=physical_python.resolve()
while True:
 root_ancestors.add(str(cursor))
 if cursor==cursor.parent: break
 cursor=cursor.parent
def fd_path(fd):
 if sys.platform=="darwin":
  raw=c.fcntl.fcntl(fd,50,b"\0"*1024)
  return raw.split(b"\0",1)[0].decode()
 return os.readlink(f"/proc/self/fd/{fd}")
def observed(state,path):
 path=os.path.realpath(path)
 if path in external_ancestors and stat.S_ISDIR(state.st_mode):
  key=(state.st_dev,state.st_ino)
  fixed=external_identity.setdefault(key,(state.st_nlink,state.st_size,state.st_mtime_ns,state.st_ctime_ns))
  state=types.SimpleNamespace(st_dev=state.st_dev,st_ino=state.st_ino,st_mode=state.st_mode,
   st_uid=state.st_uid,st_gid=state.st_gid,st_nlink=fixed[0],st_size=fixed[1],
   st_mtime_ns=fixed[2],st_ctime_ns=fixed[3])
 uid,gid_value,mode=state.st_uid,state.st_gid,state.st_mode
 if path==str(store) or path.startswith(str(store)+"/"):
  uid,gid_value=principal,gid
 elif (path in root_ancestors or path==str(anchor) or path.startswith(str(anchor)+"/") or
       path==str(installed) or path.startswith(str(installed)+"/") or
       path==str(identities) or path.startswith(str(identities)+"/") or
       path==str(verifier) or path==str(physical_python.resolve())):
  uid=0;mode &= ~(stat.S_IWGRP|stat.S_IWOTH)
 return types.SimpleNamespace(st_dev=state.st_dev,st_ino=state.st_ino,st_mode=mode,
  st_uid=uid,st_gid=gid_value,st_nlink=state.st_nlink,st_size=state.st_size,
  st_mtime_ns=state.st_mtime_ns,st_ctime_ns=state.st_ctime_ns)
def metadata(fd): return observed(raw_metadata(fd),fd_path(fd))
def named(name,parent_fd): return observed(raw_named(name,parent_fd),os.path.join(fd_path(parent_fd),name))
c._metadata,c._named_metadata=metadata,named
c._acl_state=lambda _fd,_resolver=None:([],None) if sys.platform=="darwin" else (None,None)

work=base/"consumer-work";output=base/"consumer-output";work.mkdir(mode=0o700);output.mkdir(mode=0o700)
raw_fsync=os.fsync;fsync_paths=[]
def recording_fsync(fd):
 fsync_paths.append(fd_path(fd));return raw_fsync(fd)
e.os.fsync=recording_fsync
request=json.loads((base/"request.json").read_bytes())
instruction=("ystack.file-digest-instruction.v1\npath source.txt\nsha256 "+
 json.loads((base/"incident.json").read_bytes())["body"]["failing_check"]["expected_sha256"]+"\n").encode()
instruction_file=base/"verifier-instruction";write(instruction_file,instruction,0o400)
generation=json.loads((package/"core/v2/generation-registry.json").read_bytes())[-1]["generation_id"]
def mutation_path(mode):
 return {"mutate-request":scenario_request,"mutate-consumer":package/"shadow/v1/_consumer.py",
  "mutate-helper-source":package/"adapters/local-git-materializer/v1/object-closure.c",
  "mutate-receipt-program":package/"enforcement/v1/sandbox-receipt.jq",
  "mutate-core-selector":package/"scripts/core-contract.sh",
  "mutate-core-ingress":package/"core/v2/generations"/generation/"core-ingress.sh",
  "mutate-contracts":package/"core/v2/generations"/generation/"contracts.jq",
  "mutate-control-source":package/"control/v1/validate.sh"}.get(mode)
checks=0
scenario_mode="success";launch_count=0;scenario_output=None;scenario_work=work;scenario_request=None
def ok(value,message):
 global checks
 if not value: raise AssertionError(message)
 checks+=1;print(f"ok real-flow-{checks} - {message}")

def decode(frame):
 cursor=8;rows=[];digest=hashlib.sha256(b"YSFRAME1")
 if frame[:8]!=b"YSFRAME1": raise AssertionError("frame magic")
 while True:
  n=frame[cursor];cursor+=1;name=frame[cursor:cursor+n];cursor+=n
  size=int.from_bytes(frame[cursor:cursor+8],"big");cursor+=8;raw=frame[cursor:cursor+size];cursor+=size
  if name==b"end":
   if size!=32 or raw!=digest.digest() or cursor!=len(frame): raise AssertionError("frame seal")
   return rows
  encoded=bytes([len(name)])+name+len(raw).to_bytes(8,"big")+raw
  digest.update(encoded);rows.append((name,raw))

def launch(anchor_value,frame,_deadline):
 global launch_count
 launch_count+=1
 durable={str(scenario_work/"launch/sandbox-request.json"),
  str(scenario_work/"launch/sandbox-expectation.json"),str(scenario_work/"launch")}
 ok(durable.issubset(set(fsync_paths)),"actual request, expectation, and containing directory are durable before launch")
 if scenario_mode=="cancel": raise e.Refusal("E_RUNTIME")
 for name in ("candidate","evidence","scratch"):
  path=verifier_root/name
  if path.exists(): shutil.rmtree(path)
  path.mkdir(mode=0o700)
 rows=decode(frame);names=[name for name,_raw in rows]
 required=[b"request.json",b"evaluation.json",b"incident.json",b"record.json",b"manifest.json",b"instruction"]
 ok(names[:6]==required and all(name==f"candidate/{i:05d}".encode() for i,name in enumerate(names[6:])),
    "actual frame has fixed records and ordered candidate export")
 values=dict(rows);manifest=json.loads(values[b"manifest.json"])
 for index,row in enumerate(manifest["entries"]):
  raw=values[f"candidate/{index:05d}".encode()]
  if len(raw)!=row["size_bytes"] or sha(raw)!=row["sha256"]: raise AssertionError("candidate binding")
  write(verifier_root/"candidate"/row["path"],raw,0o400)
 instruction_file.chmod(0o600);write(instruction_file,values[b"instruction"],0o400)
 env={"LANG":"C","LC_ALL":"C","PATH":str(verifier_root/"tools"),"TMPDIR":str(verifier_root/"scratch")}
 with instruction_file.open("rb") as stdin:
  run=subprocess.run([str(verifier),"verify","--candidate",str(verifier_root/"candidate"),
    "--evidence",str(verifier_root/"evidence")],stdin=stdin,stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,env=env,check=False,timeout=30)
 ok(run.returncode==0 and run.stdout==b"" and run.stderr==b"","actual fixed verifier completed")
 result=(verifier_root/"evidence/file-digest-result.json").read_bytes()
 result_doc=json.loads(result);ok(result_doc["body"]["instruction_sha256"]==sha(values[b"instruction"]),
   "actual verifier result binds framed instruction")
 launch_doc=json.loads(values[b"request.json"])
 expectation=json.loads((scenario_work/"launch/sandbox-expectation.json").read_bytes())
 ok(expectation["body"]["attempt"]["launch_request_sha256"]==sha(values[b"request.json"]),
   "durable expectation binds actual launch bytes")
 attempt=store/launch_doc["id"];payload=attempt/"payload";evidence=payload/"evidence"
 evidence.mkdir(parents=True,mode=0o750)
 manifest_raw=canonical({"schema_version":1,"kind":"sandbox_evidence_manifest","id":"evidence-manifest",
  "body":{"files":[{"name_hex":b"file-digest-result.json".hex(),"sha256":sha(result),"size_bytes":len(result)}]}})
 write(payload/"stdout",run.stdout,0o440);write(payload/"stderr",run.stderr,0o440)
 write(payload/"evidence-manifest.json",manifest_raw,0o440);write(evidence/"0000",result,0o440)
 accepted=json.loads((package/"enforcement/v1/accepted-identities.json").read_bytes())["body"]["environments"][0]
 identities_rows={key:{"state":"observed","sha256":value[0]} for key,value in accepted["identities"].items()}
 identities_rows["verifier"]={"state":"observed","sha256":sha(verifier.read_bytes())}
 def limit(bound,observed,resolution,mechanism,observer):
  return {"bound":bound,"observed":observed,"resolution":resolution,"observation":"complete",
   "enforcement":"hard","reached":False,"mechanism_id":mechanism,"observer":observer}
 limits={"cpu_time_ms":limit(30000,1000,1,accepted["mechanisms"]["cpu_time_ms"][0],"guest-supervisor"),
  "wall_time_ms":limit(60000,2000,1,accepted["mechanisms"]["wall_time_ms"][0],"host-supervisor"),
  "memory_bytes":limit(536870912,1048576,4096,accepted["mechanisms"]["memory_bytes"][0],"guest-supervisor"),
  "output_bytes":limit(10485760,len(result),1,accepted["mechanisms"]["output_bytes"][0],"guest-supervisor"),
  "process_count":limit(32,1,1,accepted["mechanisms"]["process_count"][0],"guest-supervisor"),
  "scratch_bytes":limit(accepted["scratch_bytes"],4096,4096,accepted["mechanisms"]["scratch_bytes"][0],"guest-supervisor")}
 receipt={"schema_version":1,"kind":"sandbox_enforcement_receipt","id":"receipt."+sha(values[b"request.json"]),
  "body":{"contract_version":"v1","origin":{"producer_role":"host-supervisor",
   "store_id":"store.shadow-fixture","accepted_set_sha256":sha((package/"enforcement/v1/accepted-identities.json").read_bytes())},
   "attempt":expectation["body"]["attempt"],"control":launch_doc["body"]["control"],
   "subject":launch_doc["body"]["subject"],"identities":identities_rows,"limits":limits,
   "teardown":{"state":"confirmed","tree_terminated":True,"storage_destroyed":True},
   "lifecycle":{"admission":"admitted","runtime":"completed","control_deadline":"met"},
   "payload":{"stdout_sha256":sha(run.stdout),"stderr_sha256":sha(run.stderr),
    "evidence_manifest_sha256":sha(manifest_raw),"exit_state":"exited","exit_code":0},
   "timing":{"admitted_at":"2026-08-30T00:00:05Z","terminated_at":"2026-08-30T00:00:06Z"},
   "outcome":{"verdict":"satisfied","reason_ids":["enforcement.satisfied"]}}}
 if scenario_mode=="cpu-none":
  receipt["body"]["limits"]["cpu_time_ms"]["enforcement"]="none"
  receipt["body"]["limits"]["wall_time_ms"]["enforcement"]="none"
 if scenario_mode=="unconfirmed":receipt["body"]["teardown"]["state"]="unconfirmed"
 if scenario_mode!="missing":write(attempt/"receipt.json",canonical(receipt),0o440)
 if scenario_mode=="partial":(evidence/"0000").unlink()
 for directory in (store,attempt,payload,evidence): directory.chmod(0o750)
 if scenario_mode=="replace-output":
  displaced=scenario_output.with_name(scenario_output.name+"-displaced")
  scenario_output.rename(displaced);scenario_output.mkdir(mode=0o700)
 if scenario_mode=="mutate-component":
  component=package/"enforcement/v1/check-sandbox-receipt.sh"
  component.chmod(0o700);component.write_bytes(component.read_bytes()+b"\n")
 changed=mutation_path(scenario_mode)
 if changed is not None:
  changed.chmod(0o600);changed.write_bytes(changed.read_bytes()+b"\n")
 return 70 if scenario_mode=="incomplete" else 65 if scenario_mode=="refused" else 0
e._launch=launch
parent={"helper_source_sha256":c.HELPER_SOURCE_SHA256,"helper_build_record_sha256":sha(b"fixture-build"),
 "helper_executable_sha256":sha((base.parent/"object-closure").read_bytes()),
 "helper_executable_size":len((base.parent/"object-closure").read_bytes()),
 "helper_path":str(base.parent/"object-closure"),"native_release":{
 "source_sha256":sha((package/"shadow/v1/_cancel_release.c").read_bytes()),
 "build_script_sha256":sha((package/"shadow/v1/build-cancel-release.sh").read_bytes()),
 "build_record_sha256":sha(native_record.read_bytes()),"binary_path":str(native_binary),
 "binary_size":native_binary.stat().st_size,"binary_sha256":sha(native_binary.read_bytes()),
 "python_path":str(physical_python),"python_sha256":sha(physical_python.read_bytes()),
 "python_abi":sysconfig.get_config_var("SOABI"),
 "dependency_record_sha256":sha(dependency_record.read_bytes()),"loader_mode":"rtld-now-local.v1"}}
census=e._NativeThreadCensus();census.observe()
executable=e.stable_file(physical_python)
admission=e._StartupAdmission(e._STARTUP_KEY,e.sys.executable,executable.sha256,e.sys.version,
 tuple(e.sys.version_info[:2]),e._runtime_module_origins(),census)
executable.close();native=e._NativeRelease(parent,admission)
admission=dataclasses.replace(admission,native=native,module_origins=e._runtime_module_origins())
with e.CancellationSignals(admission):bundle=e.reproduce(base/"request.json",work,output,parent)
bundle_doc=json.loads(bundle);ok(len(bundle_doc["body"]["files"])==29,"actual reproduce seals 29 evidence files")
record=json.loads((output/"shadow-record.json").read_bytes())
ok(record["body"]["record_form"]=="enforced-reproduction.v1" and
 record["body"]["outcome"]=="no-change" and record["body"]["producer_invocations"]==0,
 "actual reproduce retains enforced no-change record")
check=json.loads((output/"sandbox-check.json").read_bytes())
ok(check["body"]["check_verdict"]=="valid" and check["body"]["enforcement_verdict"]=="satisfied",
 "actual receipt checker accepts controlled-store receipt")
ok(json.loads((output/"file-digest-result.json").read_bytes())["body"]["reason_id"]=="file.match",
 "actual verifier payload is retained unchanged")
ok((output/"bundle.json").exists(),"completion marker written after real chain")
provenance=json.loads((output/"consumer-provenance.json").read_bytes())
roles=[row["role"] for row in provenance["body"]["commands"]]
ordinary_roles=[role for role in roles if role!="darwin-acl-uuid-resolution"]
ok(ordinary_roles==["helper-version","jq-version","incident-validation","materializer-input-validation",
 "qualified-identity-validation","materialization","materializer-response-validation",
 "candidate-preparation","candidate-inspection","sandbox-bound-evaluation",
 "sandbox-launch-boundary","sandbox-receipt-check","trace-validation"] and
 (sys.platform=="darwin" or "darwin-acl-uuid-resolution" not in roles) and
 all(set(row)=={"role","argv_sha256","executable_sha256","component_sha256"}
     for row in provenance["body"]["commands"]),
 "frozen provenance retains every executed role without private argv: "+repr(roles))
trace=json.loads((output/"trace-ledger.json").read_bytes())
ok(trace["body"]["events"][0]["facts"]["execution_environment"]["value"]=="env.local-macos-fixture" and
 trace["body"]["events"][0]["facts"]["gate"]["source_ref"]["sha256"]==sha((output/"sandbox-evaluation.json").read_bytes()) and
 trace["body"]["events"][1]["facts"]["gate"]["source_ref"]["sha256"]==sha((output/"sandbox-check.json").read_bytes()),
 "trace binds claim environment and distinct declaration and enforcement evidence")
mismatch_case=base/"case-mismatch";mismatch_case.mkdir(mode=0o700)
mismatch_q=json.loads((base/"q-input.json").read_bytes())
mismatch_identity=json.loads((base/"identity.json").read_bytes())
mismatch_incident=json.loads((base/"incident.json").read_bytes())
mismatch_outer=json.loads((base/"request.json").read_bytes())
mismatch_incident["body"]["failing_check"]["expected_sha256"]="0"*64
mismatch_q["stage_request"]["sha256"]=sha(canonical(mismatch_q["stage_request"]["content"]))
mismatch_identity["body"]["stage_request_ref"]["sha256"]=mismatch_q["stage_request"]["sha256"]
mismatch_identity["body"]["verification_instructions_ref"]["sha256"]=sha(e.make_instruction(mismatch_incident))
mismatch_outer["id"]=mismatch_outer["body"]["attempt_id"]="attempt.mismatch"
for field,value in (("incident",mismatch_incident),("materialization_input",mismatch_q),
                    ("qualified_identity",mismatch_identity)):
 path=mismatch_case/(field+".json");write(path,canonical(value),0o400);mismatch_outer["body"][field]=str(path)
mismatch_request=mismatch_case/"request.json";write(mismatch_request,canonical(mismatch_outer),0o400)
mismatch_work=mismatch_case/"work";mismatch_output=mismatch_case/"output"
mismatch_work.mkdir(mode=0o700);mismatch_output.mkdir(mode=0o700)
def reset_native():
 native.state=native.module.prepare_state()
 names=("block_entry","arm_consumer","checkpoint","hold_completion","block_final",
  "rollback_marker","commit_completion","abort_release","outcome","prepare_child","spawn_child",
  "child_fds","close_child_stdin","close_child_stdout","close_child_stderr",
  "observe_child_exit","reap_child","term_child_group","kill_child_group",
  "check_child_group","child_status")
 native.methods=tuple(getattr(native.state,name) for name in names)
 for name,method in zip(names,native.methods):setattr(native,name,method)
reset_native();admission=dataclasses.replace(admission,native=native)
try:
 with e.CancellationSignals(admission):
  mismatch=json.loads(e.reproduce(mismatch_request,mismatch_work,mismatch_output,parent))
finally:native.close()
ok(mismatch["body"]["record_form"]=="enforced-reproduction.v1" and
 json.loads((mismatch_output/"shadow-record.json").read_bytes())["body"]["outcome"]=="reproduced",
 "actual mismatch completes only as a reproduced result")
checker_driver=package/"enforcement/v1/check-sandbox-receipt.sh"
checker_env={"PATH":str(base/"bin")+":/usr/bin:/bin","LC_ALL":"C","LANG":"C","TMPDIR":str(base/"checker-tmp")}
(base/"checker-tmp").mkdir(mode=0o700)
accepted=json.loads((package/"enforcement/v1/accepted-identities.json").read_bytes())["body"]["environments"][0]
def check_mutation(name,mutate):
 receipt=json.loads((output/"sandbox-receipt.json").read_bytes());mutate(receipt)
 path=base/(name+"-receipt.json");write(path,canonical(receipt),0o400)
 run=subprocess.run(["/bin/bash","-p",str(checker_driver),"check-bound",str(path),
  str(work/"launch/sandbox-expectation.json"),str(output/"sandbox-evaluation.json"),
  str(work/"observation/observation.json")],stdout=subprocess.PIPE,stderr=subprocess.PIPE,
  env=checker_env,check=False,timeout=30)
 if run.returncode!=0 or run.stderr: raise AssertionError((name,run.returncode,run.stderr))
 return json.loads(run.stdout)
second=next(value for value in accepted["identities"]["verifier"] if value!=sha(verifier.read_bytes()))
cross=check_mutation("cross-verifier",lambda receipt:receipt["body"]["identities"]["verifier"].update(sha256=second))
ok(cross["body"]["check_verdict"]=="refused" and cross["body"]["enforcement_verdict"]=="none"
 and cross["body"]["reason_ids"]==["receipt.control-mismatch","receipt.evaluation-not-satisfied"],
 "two accepted verifier digests cannot substitute for exact measured verifier")
wrong_subject=check_mutation("wrong-subject",lambda receipt:receipt["body"]["subject"]["candidate"].update(manifest_sha256="f"*64))
ok(wrong_subject["body"]["check_verdict"]=="refused" and
 any(reason.startswith("receipt.") for reason in wrong_subject["body"]["reason_ids"]),
 "otherwise valid receipt cannot substitute a candidate subject")

base_request=json.loads((base/"request.json").read_bytes())
base_q=json.loads((base/"q-input.json").read_bytes())
base_identity=json.loads((base/"identity.json").read_bytes())
base_incident=json.loads((base/"incident.json").read_bytes())
def case_documents(name,mutate=None):
 case=base/("case-"+name);case.mkdir(mode=0o700)
 q=json.loads(json.dumps(base_q));identity=json.loads(json.dumps(base_identity))
 incident=json.loads(json.dumps(base_incident));outer=json.loads(json.dumps(base_request))
 if mutate is not None: mutate(outer,q,identity,incident)
 q["stage_request"]["sha256"]=sha(canonical(q["stage_request"]["content"]))
 identity["body"]["stage_request_ref"]["sha256"]=q["stage_request"]["sha256"]
 identity["body"]["verification_instructions_ref"]["sha256"]=sha(e.make_instruction(incident))
 outer["id"]=outer["body"]["attempt_id"]="attempt."+name
 for field,value in (("incident",incident),("materialization_input",q),("qualified_identity",identity)):
  path=case/(field+".json");write(path,canonical(value),0o400);outer["body"][field]=str(path)
 request_path=case/"request.json";write(request_path,canonical(outer),0o400)
 return case,request_path
def prewrite_refusal(name,request_change=None,parent_change=None,work_path=None,source_root=None):
 case,request_path=case_documents(name);case_work=work_path or case/("work-"+name);case_output=case/"output"
 if not case_work.exists():case_work.mkdir(mode=0o700)
 case_output.mkdir(mode=0o700);before_entries=set(case_work.iterdir())
 if request_change is not None:
  outer=json.loads(request_path.read_bytes());request_change(outer,case_work)
  request_path.chmod(0o600);request_path.write_bytes(canonical(outer));request_path.chmod(0o400)
 context=dict(parent);context.update(parent_change or {})
 before=launch_count;old_source=e.SOURCE
 try:
  if source_root is not None:e.SOURCE=source_root
  try:e.reproduce(request_path,case_work,case_output,context)
  except (e.Refusal,c.Refusal):pass
  else:raise AssertionError(name+" accepted")
 finally:e.SOURCE=old_source
 ok(set(case_work.iterdir())==before_entries and not any(case_output.iterdir()) and launch_count==before,
    name+" refuses before workspace writes or launch")
prewrite_refusal("workspace-overlap",lambda outer,workspace:
 outer["body"].__setitem__("incident",str(workspace/"incident.json")))
prewrite_refusal("helper-context-mismatch",parent_change={"helper_path":str(base/"wrong-helper")})
prewrite_refusal("source-exclusion",source_root=base/"case-source-exclusion")
prewrite_refusal("installed-exclusion",work_path=installed/"private-work")
prewrite_refusal("store-exclusion",work_path=store/"private-work")
def refuse_case(name,mode="success",mutate=None,launches=0):
 global scenario_mode,scenario_output,scenario_work,scenario_request
 case,request_path=case_documents(name,mutate);case_work=case/"work";case_output=case/"output"
 case_work.mkdir(mode=0o700);case_output.mkdir(mode=0o700)
 scenario_mode=mode;scenario_output=case_output;scenario_work=case_work;scenario_request=request_path
 before=launch_count
 component=package/"enforcement/v1/check-sandbox-receipt.sh";original=component.read_bytes()
 changed=mutation_path(mode)
 changed_raw=changed.read_bytes() if changed else None
 changed_mode=changed.stat().st_mode&0o777 if changed else None
 try:
  try: e.reproduce(request_path,case_work,case_output,parent)
  except (e.Refusal,c.Refusal): pass
  else: raise AssertionError(name+" accepted")
 finally:
  if component.read_bytes()!=original:component.write_bytes(original);component.chmod(0o755)
  if changed is not None:
   changed.chmod(0o600);changed.write_bytes(changed_raw);changed.chmod(changed_mode)
 ok(launch_count-before==launches,name+" stops at the intended boundary")
 marker=case_output/"bundle.json"
 displaced=case_output.with_name(case_output.name+"-displaced")/"bundle.json"
 ok(not marker.exists() and not displaced.exists(),name+" cannot expose completion marker")

def changed_patch(_outer,q,_identity,_incident):
 changed="changed content\n";digest=sha(changed.encode())
 for row in q["payloads"]:
  if row["input_id"]=="input.producer-patch": row["data"]=changed
 for row in q["trust_context"]["verified_payloads"]:
  if row["input_id"]=="input.producer-patch": row["content"]["data"]=changed;row["sha256"]=digest
 for row in q["stage_request"]["content"]["body"]["inputs"]:
  if row["input_id"]=="input.producer-patch": row["value"]["value"]["value"]["sha256"]=digest
def wrong_environment(_outer,q,_identity,_incident):
 q["stage_request"]["content"]["body"]["environment_ref"]={"environment_id":"env.unrelated","fingerprint_sha256":"f"*64}
def wrong_identity(_outer,_q,identity,_incident):
 identity["body"]["stage_request_ref"]["id"]="request.unrelated"
 identity["body"]["resolved_profile_ref"]["id"]="profile.unrelated"
def bool_request(outer,_q,_identity,_incident):
 outer["schema_version"]=True;outer["body"]["attempt_number"]=True
refuse_case("changed-patch",mutate=changed_patch)
refuse_case("wrong-environment",mutate=wrong_environment)
refuse_case("wrong-identity",mutate=wrong_identity)
refuse_case("boolean-request",mutate=bool_request)
for mode in ("incomplete","refused","missing","partial","cpu-none","unconfirmed","cancel",
             "replace-output","mutate-component","mutate-request","mutate-consumer",
             "mutate-helper-source","mutate-receipt-program","mutate-core-selector",
             "mutate-core-ingress","mutate-contracts","mutate-control-source"):
 refuse_case(mode,mode=mode,launches=1)
scenario_mode="success";scenario_output=None
print(f"shadow-enforced-real-reproduce: {checks} checks passed")
PY
