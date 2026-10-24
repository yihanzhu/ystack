#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077
root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
/usr/bin/python3 -I -S -B - "$root" <<'PY_RUNTIME_VALUES'
import copy
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import types

root = Path(sys.argv[1])
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

replay = load('fixed_malicious_replay', root / 'evals/v1/replay-malicious.py')
driver = load('actual_runtime_values', root / 'sandbox/v1/runtime-vfkit.py')
start = driver.canonical({'kind':'sandbox_runtime_start', 'schema_version':1, 'body':{
    'command_line':driver.COMMAND_LINE,'cpu_count':1,'memory_bytes':driver.MEMORY_BYTES,
    'export_disk':'/historical/export','input_disk':'/historical/input','kernel':'/historical/kernel',
    'initramfs':'/historical/initramfs','rest_socket':'/historical/rest'}})
config = driver.canonical({'body':{'runtime':{'vfkit':'/historical/vfkit'}}})
def emitted(owner, operation, status, body, error):
    out, err = io.BytesIO(), io.BytesIO()
    old_out,old_err,old_rest = sys.stdout,sys.stderr,owner.rest
    calls = []
    def rest(*args):
        calls.append(args)
        return None if error else (status,body)
    try:
        sys.stdout,sys.stderr = types.SimpleNamespace(buffer=out),types.SimpleNamespace(buffer=err)
        owner.rest = rest
        rc = (owner.cmd_state if operation == 'state' else owner.cmd_stop)(['/historical/rest'])
        expected = ('/historical/rest','GET','/vm/state') if operation == 'state' else (
            '/historical/rest','POST','/vm/state',b'{"state":"HardStop"}')
        assert calls == [expected]
        return rc,out.getvalue(),err.getvalue()
    finally:
        sys.stdout,sys.stderr,owner.rest = old_out,old_err,old_rest
running = b'{"state":"VirtualMachineStateRunning"}'
stopped = b'{"state":"VirtualMachineStateStopped"}'
vectors = [('state-running','state',200,running,None),
           ('state-stopped','state',200,stopped,None),
           ('state-status-500','state',500,running,None),
           ('state-malformed','state',200,b'{',None),
           ('body-65536','state',200,running.ljust(65536),None),
           ('body-65537','state',200,running.ljust(65537),None),
           ('stop-status-500','stop',500,b'',None),
           ('stop-status-200','stop',200,b'',None)]
for phase in ('request','getresponse','read'):
    for category in ('OSError','HTTPException'):
        vectors.append((phase+'-'+category,'state',None,b'',
                        {'phase':phase,'category':category,'errno':None}))
for label, operation, status, body, error in vectors:
    row = {'call':1,'operation':operation,'reply':None if error else
           {'status':status,'body_hex':body.hex()},'error':error}
    argv, results = replay._runtime_values(root,start,config,[row])
    direct = driver._state_values(status,body,error) if operation == 'state' else driver._stop_values(status,body,error)
    assert argv == driver._argv_values(start,config) and results == [direct], label
    assert emitted(driver,operation,status,body,error) == direct,label
    print('ok runtime replay pair - '+label)

def refused(owner, offline, runtime_root, body, label):
    try:
        emitted(owner,'state',200,body,None)
    except TypeError:
        pass
    else:
        return False
    row = {'call':2,'operation':'state','reply':{'status':200,'body_hex':body.hex()},'error':None}
    first = {'call':1,'operation':'state','reply':{'status':200,'body_hex':running.hex()},'error':None}
    try:
        offline._runtime_values(runtime_root,start,config,[first,row])
    except offline._CalculationRefused as exc:
        assert type(exc.__cause__) is TypeError
        assert exc.observation(label) == {
            'case_id':label,'disposition':'rejected','error_token':'E_REPLAY',
            'invariants':{'state':'absent'},'recompute_mismatches':[]}
        return True
    return False

for label,body in [('state-list',b'{"state":[]}'),('state-dict',b'{"state":{}}')]:
    assert refused(driver,replay,root,body,label),label
    print('ok actual runtime/offline owner refusal - '+label+'; rejected/E_REPLAY, no partial result')

with tempfile.TemporaryDirectory(prefix='ystack-runtime-call-controls-') as directory:
    area = Path(directory)
    runtime_path = area/'sandbox/v1/runtime-vfkit.py'
    runtime_path.parent.mkdir(parents=True)
    original = (root/'sandbox/v1/runtime-vfkit.py').read_text()
    replay_source = (root/'evals/v1/replay-malicious.py').read_text()
    for route,source,needle,replacement in [
            ('production-mutation',original,'_state_values(reply[0], reply[1], None)',
             '_state_values(500, reply[1], None)'),
            ('production-deletion',original,'_state_values(reply[0], reply[1], None)',
             '(0, b"running\\n", b"")'),
            ('offline-mutation',replay_source,'result = owner._state_values(status, body, error)',
             'result = owner._state_values(500, body, error)'),
            ('offline-deletion',replay_source,'result = owner._state_values(status, body, error)',
             'result = (0, b"running\\n", b"")')]:
        assert source.count(needle) == 1,route
        runtime_path.write_text(source.replace(needle,replacement) if route.startswith('production') else original)
        replay_path = area/'replay.py'
        replay_path.write_text(source.replace(needle,replacement) if route.startswith('offline') else replay_source)
        changed_driver = load('driver_'+route.replace('-','_'),runtime_path)
        changed_replay = load('replay_'+route.replace('-','_'),replay_path)
        assert not refused(changed_driver,changed_replay,area,b'{"state":[]}',route),route
        print('ok narrow runtime call control detected - '+route)

valid = {'call':1,'operation':'state','reply':{'status':200,'body_hex':running.hex()},'error':None}
for label, change in [('extra',lambda x:x.update(extra=True)),
                      ('ordinal',lambda x:x.update(call=2)),
                      ('two-results',lambda x:x.update(error={'phase':'read','category':'OSError','errno':None})),
                      ('over-body',lambda x:x['reply'].update(body_hex='00'*65538)),
                      ('status-type',lambda x:x['reply'].update(status=True))]:
    row = copy.deepcopy(valid)
    change(row)
    try:
        replay._runtime_values(root,start,config,[row])
    except ValueError:
        print('ok runtime replay refuses - '+label)
    else:
        raise AssertionError(label)
PY_RUNTIME_VALUES
/usr/bin/python3 -I -S -B - "$root" <<'PY_HOST_VALUES'
import importlib.util
from pathlib import Path
import sys

root = Path(sys.argv[1])
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
replay = load('fixed_host_replay', root / 'evals/v1/replay-malicious.py')
host = load('actual_host_values', root / 'sandbox/v1/host-supervisor.py')
for deadline in ('met','exceeded'):
    original_time = host.time.time
    try:
        host.time.time = lambda:1700000001.0
        actual = host.stub_run_result(deadline)
    finally:
        host.time.time = original_time
    offline = replay._host_stub_values(root,deadline,1700000001.0)
    assert actual == offline
    assert offline['runtime'] == 'error' and offline['tree_terminated']
    assert offline['exit_state'] == 'not-started' and offline['control_deadline'] == deadline
    print('ok actual not-started host/offline pair - '+deadline)
clock = {'kind':'clock','elapsed':0,'sigkill':58,'hardstop':48,'cancelled':False}
for elapsed, cancelled, expected in [(0,False,'continue'),(48,False,'continue'),
                                     (58,False,'kill'),(0,True,'continue')]:
    tick = dict(clock,elapsed=elapsed,cancelled=cancelled)
    state, transitions, _ = replay._host_values(root,[tick],[])
    assert transitions[-1] == host._host_step(host._host_state(),tick)
    assert transitions[-1][1] == expected
    assert state['stop_requested'] == (expected != 'kill' and (elapsed>=48 or cancelled))
    print('ok host deadline/cancel pair - %s/%s' % (elapsed,cancelled))
for accepted in (False,True):
    steps = [dict(clock,elapsed=48),{'kind':'stop','accepted':accepted}]
    state, _, _ = replay._host_values(root,steps,[])
    assert state['stop_issued'] is accepted and state['hard_stop'] is accepted
for reaped in (False,True):
    for code in (0,1,None):
        steps = [{'kind':'state','value':'stopped'},
                 {'kind':'reap','reaped':reaped,'returncode':code,'stopped_exit_status':0}]
        state, _, _ = replay._host_values(root,steps,[])
        assert state['tree_terminated'] is reaped
        assert state['driver_reported_error'] == (reaped and code not in (0,None))
        print('ok host confirmed-stop/reap pair - %s/%s' % (reaped,code))
for code in (None,0,1):
    poll = {'kind':'poll','state':'error','since_spawn':5,'startup':5,
            'exit_code':code,'stopped_exit_status':0,'rechecked':False}
    state, transitions, _ = replay._host_values(root,[poll],[])
    assert not state['driver_reported_error']
    assert transitions[-1][1] == ('recheck' if code is None else 'exited')
    state, _, _ = replay._host_values(root,[poll,dict(poll,rechecked=True)],[])
    assert state['driver_reported_error'] == (code is None)
for label, incomplete in [('pipe-eof',False),('pipe-timeout',True),
                           ('pipe-read-error',True),('pipe-open-after-exit-zero',True)]:
    row = {'returncode':0,'chunks':[b'stopped\n'],'incomplete':incomplete,'overflow':False}
    _, _, pipes = replay._host_values(root,[],[row])
    assert pipes == [host._driver_output_values(0,[b'stopped\n'],incomplete,False)]
    assert pipes[0] == ((None,b'') if incomplete else (0,b'stopped\n'))
    print('ok host pipe pair - '+label)
PY_HOST_VALUES
/usr/bin/python3 -I -S -B - "$root" <<'PY_VERIFIER_VALUES'
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fixed_verifier_replay',root/'evals/v1/replay-malicious.py')
replay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(replay)
with tempfile.TemporaryDirectory(prefix='ystack-verifier-value-pairs-') as directory:
    area = Path(directory)
    sandbox = area/'sandbox'
    for leaf in ('candidate','evidence','tools','scratch'):
        (sandbox/leaf).mkdir(parents=True)
    live = area/'verifier'
    compiled = subprocess.run(['/usr/bin/cc','-std=c11','-Wall','-Wextra','-Werror','-O2',
        '-DYSTACK_SANDBOX_ROOT="'+str(sandbox)+'"',str(root/'verifiers/file-digest/v1/verifier.c'),
        '-o',str(live)],capture_output=True,timeout=30)
    assert compiled.returncode == 0 and not compiled.stdout and not compiled.stderr, compiled.stderr
    file = b'ordinary trial file\n'
    digest = hashlib.sha256(file).hexdigest().encode()
    good = b'ystack.file-digest-instruction.v1\npath value.bin\nsha256 '+digest+b'\n'
    vectors = [('match',good,file),('mismatch',good,b'changed\n'),('empty',good,b''),
               ('file-at',good,b'x'*1048576),('file-over',good,b'x'*1048577),
               ('malformed',b'broken\n',file),('trailing',good+b'x',file),
               ('path-rejected',good.replace(b'value.bin',b'../value.bin'),file),
               ('instruction-at',b'x'*4208,file),('instruction-over',b'x'*4209,file)]
    environment = {'LANG':'C','LC_ALL':'C','PATH':str(sandbox/'tools'),'TMPDIR':str(sandbox/'scratch')}
    for index,(label,instruction,content) in enumerate(vectors):
        (sandbox/'candidate/value.bin').write_bytes(content)
        input_file = area/'instruction'
        input_file.write_bytes(instruction)
        result_path = sandbox/'evidence/file-digest-result.json'
        if result_path.exists():result_path.unlink()
        with input_file.open('rb') as held:
            result = subprocess.run([str(live),'verify','--candidate',str(sandbox/'candidate'),
                '--evidence',str(sandbox/'evidence')],stdin=held,capture_output=True,env=environment,timeout=10)
        assert result.returncode == 0 and not result.stdout and not result.stderr,(label,result)
        work = area/('offline-'+str(index));work.mkdir(mode=0o700)
        offline = replay._verifier_values(root,work,instruction,content)
        assert offline == result_path.read_bytes(),label
        if label == 'match':match_payload = offline
        print('ok actual verifier/offline byte pair - '+label)
    source = (root/'verifiers/file-digest/v1/verifier.c').read_text()
    for route,needle,replacement in [
            ('production-mutation','file_result_values(&values, reason);',
             'file_result_values(&values, "file.missing"); (void)reason;'),
            ('production-deletion','file_result_values(&values, reason);',
             '(void)reason; (void)&file_result_values; values.reason_id = "instruction.transport-rejected";'),
            ('offline-mutation','file_result_values(&values, NULL);',
             'file_result_values(&values, "file.missing");'),
            ('offline-deletion','file_result_values(&values, NULL);',
             'values.reason_id = "instruction.transport-rejected";')]:
        assert source.count(needle) == 1,route
        source_root = area/route
        changed_source = source_root/'verifiers/file-digest/v1/verifier.c'
        changed_source.parent.mkdir(parents=True)
        changed_source.write_text(source.replace(needle,replacement))
        if route.startswith('production'):
            executable = area/('changed-'+route)
            compiled = subprocess.run(['/usr/bin/cc','-std=c11','-Wall','-Wextra','-Werror','-O2',
                '-DYSTACK_SANDBOX_ROOT="'+str(sandbox)+'"',str(changed_source),'-o',str(executable)],
                capture_output=True,timeout=30)
            assert compiled.returncode == 0 and not compiled.stdout and not compiled.stderr,compiled.stderr
            (sandbox/'candidate/value.bin').write_bytes(file)
            input_file.write_bytes(good)
            result_path.unlink()
            with input_file.open('rb') as held:
                result = subprocess.run([str(executable),'verify','--candidate',str(sandbox/'candidate'),
                    '--evidence',str(sandbox/'evidence')],stdin=held,capture_output=True,env=environment,timeout=10)
            assert result.returncode == 0 and not result.stdout and not result.stderr,(route,result)
            changed_payload = result_path.read_bytes()
        else:
            work = area/('work-'+route);work.mkdir(mode=0o700)
            changed_payload = replay._verifier_values(source_root,work,good,file)
        assert changed_payload != match_payload,route
        print('ok narrow verifier result call control detected - '+route)
PY_VERIFIER_VALUES
/usr/bin/python3 -I -S -B - "$root" <<'PY_GUEST_VALUES'
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
def load(name,path):
    spec = importlib.util.spec_from_file_location(name,path)
    module = importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module
replay = load('fixed_guest_replay',root/'evals/v1/replay-malicious.py')
host = load('guest_plan_owner',root/'sandbox/v1/host-supervisor.py')
plan = host.build_plan_json({'entries':[]},'0'*64,'1'*64)
limits = host.GUEST_PLAN_LIMITS
def number(value):return struct.pack('>Q',value & ((1<<64)-1))
def blob(value):return number(len(value))+value
def now(n,error=0,seconds=0):return number(0)+number(1)+number(seconds)+number(n)+number(error)
ready = struct.pack('<BBHi',1,5,0,0)
events = [now(1),number(1)+number(1)+number(0)+number(17)+number(0),now(2),
    number(4)+number(len(ready))+number(0)+blob(ready),number(4)+number(0)+number(0)+blob(b''),now(3),
    number(2)+number(17)+number(0)+number(0),now(4),now(5),
    number(3)+number(1)+blob(b'populated 0\n'),number(4)+number(0)+number(0)+blob(b''),now(6)]
wire = b'YSVAL01\n'+blob(plan)
for key in ('cpu_max','cpu_max_burst','bandwidth_slice_us','pids_max'):
    wire += number(1)+number(1)+blob((str(limits[key])+'\n').encode())
wire += number(1)+blob(b'MemTotal: 100 kB\n')
wire += number(1)+number(limits['output_tmpfs_bytes'])+number(1)+number(limits['output_inodes'])
wire += number(1)+number(limits['scratch_bytes'])+number(1)+number(limits['scratch_inodes'])+number(4096)
setup_wire = wire
def control_wire(sequence):
    return number(1)+number(0)+number(0)+number(17)+number(0)+number(-1)+number(len(sequence))+b''.join(sequence)
wire += control_wire(events)
counter_offset = len(wire)
wire += number(1)+blob(b'usage_usec 1001\n')
wire += number(1)+blob(b'4096\n')+blob(b'oom_kill 0\n')
wire += number(1)+blob(b'1\n')+blob(b'max 0\n')
wire += (number(1)+number(0)+blob(b''))*2
wire += number(1)+blob(b'result.json')+number(1)+number(0o100600)+number(123)+number(1)+number(0)
wire += number(1)+number(2)+number(1)+number(2)+blob(b'{}')
wire += number(1)+number(1)+number(1)+number(10)+number(9)+number(4096)
with tempfile.TemporaryDirectory(prefix='ystack-guest-value-pairs-') as directory:
    area = Path(directory)
    work = area/'valid';work.mkdir(mode=0o700)
    frame = replay._guest_values(root,work,wire)
    records = host.frame_read(frame)
    report = json.loads(dict(records)[b'report.json'])
    assert report['body']['plan_sha256'] == hashlib.sha256(plan).hexdigest()
    assert report['body']['verifier_started'] and report['body']['tree_terminated']
    assert not report['body']['tree_deadline_fired'] and report['body']['exit_code'] == 0
    assert report['body']['limits']['cpu_time_ms'] == {
        'enforcement':'none','observation':'complete','observed':2,'reached':False,'resolution':1}
    assert report['body']['limits']['scratch_bytes']['observed'] == 4096
    assert report['body']['evidence_files'] == [{'index':0,'name_hex':b'result.json'.hex(),'size_bytes':2}]
    assert records[1:] == [(b'stdout',b''),(b'stderr',b''),(b'evidence/0000',b'{}')]
    assert host.frame_write(records) == frame
    print('ok fixed guest helper - same report/counter/controller/frame owners; no live operations')
    helper = work/'guest-values'
    suffix = wire[counter_offset:]
    wait_zero = events[:6]+[number(2)+number(0)+number(0)+number(0),now(4),now(5),
        number(1)+number(0)+number(0)+number(0)+number(0),now(6),
        number(2)+number(17)+number(0)+number(0),now(7),now(8),
        number(3)+number(1)+blob(b'populated 0\n'),number(4)+number(0)+number(0)+blob(b''),now(9)]
    wait_eintr = list(wait_zero)
    wait_eintr[6] = number(2)+number(-1)+number(0)+number(4)
    wait_eintr[7] = now(4,4)
    population_wait = events[:10]+[now(6),number(3)+number(1)+blob(b'populated 0\n')]+events[10:]
    population_wait[9] = number(3)+number(1)+blob(b'populated 1\n')
    for label,sequence in [('wait-zero',wait_zero),('wait-EINTR',wait_eintr),
                           ('reap-before-population-empty',population_wait)]:
        result = subprocess.run([str(helper)],input=setup_wire+control_wire(sequence)+suffix,
                                capture_output=True,env={},timeout=10)
        assert result.returncode == 0 and not result.stderr,label
        assert result.stdout == frame,label
        print('ok fixed guest controller branch - '+label)
    kill = number(6)+number(1)+number(0)
    foreign_wait = events[:6]+[number(2)+number(18)+number(0)+number(0),now(4),kill,now(5),
        number(2)+number(17)+number(0)+number(0),number(3)+number(1)+blob(b'populated 0\n')]
    after_wait_deadline = events[:7]+[now(0,seconds=999999),kill,now(0,seconds=999999)]
    before_loop_deadline = [now(0,seconds=999999),kill,now(0,seconds=999999)]
    for label,raw in [
            ('clock-before-launch-failure',setup_wire+number(0)+number(0)+number(0)),
            ('launch-zero',setup_wire+number(1)+number(0)+number(0)+number(0)+number(0)),
            ('launch-negative',setup_wire+number(1)+number(0)+number(0)+number(-1)+number(5)),
            ('foreign-wait',setup_wire+control_wire(foreign_wait)),
            ('deadline-after-wait',setup_wire+control_wire(after_wait_deadline)),
            ('deadline-before-loop',setup_wire+control_wire(before_loop_deadline))]:
        result = subprocess.run([str(helper)],input=raw,capture_output=True,env={},timeout=10)
        assert result.returncode == 0 and not result.stdout and not result.stderr,label
        print('ok fixed guest no-report branch - '+label)
    guest_files = ('observation-values.c','observation-values.h','common.c','common.h')
    guest_source = (root/'sandbox/v1/guest/observation-values.c').read_text()
    needle = 'action = ys_controller_step(&state, &event);'
    assert guest_source.count(needle) == 1
    for label,replacement in [('mutation','action = YS_ACTION_DONE;'),
                               ('deletion','(void)event;')]:
        source_root = area/('guest-'+label)
        source_guest = source_root/'sandbox/v1/guest'
        source_guest.mkdir(parents=True)
        for name in guest_files:
            (source_guest/name).write_bytes((root/'sandbox/v1/guest'/name).read_bytes())
        (source_guest/'observation-values.c').write_text(guest_source.replace(needle,replacement))
        changed_work = area/('guest-work-'+label);changed_work.mkdir(mode=0o700)
        try:
            replay._guest_values(source_root,changed_work,wire)
        except ValueError as exc:
            assert exc.args == ('guest value result',),(label,exc)
        else:
            raise AssertionError(label)
        print('ok narrow guest offline controller call control detected - '+label)
    plan_sha = hashlib.sha256(plan).hexdigest()
    measured = {slot:('observed',hashlib.sha256(slot.encode()).hexdigest())
                for slot in host.IDENTITY_SLOTS}
    request = {'attempt':{'attempt_id':'ordinary-value-pair','attempt_number':1},
               'control':{},'subject':{}}
    for label,steps,raw,deadline,storage in [
            ('complete',[{'kind':'state','value':'stopped'},
                         {'kind':'reap','reaped':True,'returncode':0,'stopped_exit_status':0}],frame,'met',True),
            ('unreaped',[],frame,'met',True),
            ('invalid-export',[{'kind':'state','value':'stopped'},
                               {'kind':'reap','reaped':True,'returncode':0,'stopped_exit_status':0}],b'broken','met',True),
            ('timeout',[{'kind':'state','value':'stopped'},
                        {'kind':'reap','reaped':True,'returncode':0,'stopped_exit_status':0}],frame,'exceeded',True),
            ('storage-failure',[{'kind':'state','value':'stopped'},
                                {'kind':'reap','reaped':True,'returncode':0,'stopped_exit_status':0}],frame,'met',False)]:
        state,_,_ = replay._host_values(root,steps,[])
        validated = host.validate_export(records,plan_sha) if state['tree_terminated'] and raw == frame else None
        direct = host._run_result_values(host._export_values(validated),state['tree_terminated'],state['hard_stop'],
            state['cancelled'],state['driver_reported_error'],deadline,1.0,1.125,1700000001.0,
            state['stop_issued'])
        run = replay._host_result_values(root,steps,raw,plan_sha,deadline,1.0,1.125,1700000001.0)
        assert run == direct,label
        actual_receipt = host.build_receipt({'store_id':'ordinary-store'},'a'*64,{},request,
            'b'*64,1700000000.0,host.identities_for_receipt(measured),'accepted',run,storage)
        offline_receipt = replay._host_receipt_values(root,{'store_id':'ordinary-store'},'a'*64,
            {},request,'b'*64,1700000000.0,measured,'accepted',run,storage,1700000001.0)
        assert actual_receipt == offline_receipt,label
        receipt = json.loads(actual_receipt)['body']
        assert receipt['outcome']['verdict'] == 'failed',label
        assert 'failure.enforcement-unavailable' in receipt['outcome']['reason_ids'],label
        assert run['limits']['wall_time_ms']['enforcement'] == 'none',label
        if label == 'complete':
            assert run['limits']['cpu_time_ms']['enforcement'] == 'none'
            assert receipt['outcome']['reason_ids'] == ['failure.enforcement-unavailable']
        if label == 'timeout':assert 'failure.supervisor-timeout' in receipt['outcome']['reason_ids']
        if label == 'storage-failure':assert 'failure.teardown' in receipt['outcome']['reason_ids']
        print('ok synthetic host result/actual receipt/offline byte pair - '+label)
    baseline = host.build_receipt({'store_id':'ordinary-store'},'a'*64,{},request,
        'b'*64,1700000000.0,host.identities_for_receipt(measured),'accepted',run,True)
    host_source = (root/'sandbox/v1/host-supervisor.py').read_text()
    replay_source = (root/'evals/v1/replay-malicious.py').read_text()
    host_return = host_source[host_source.index('    return _receipt_values(',host_source.index('def build_receipt(')):
                              host_source.index('\n\n\ndef _receipt_values(')]
    offline_return = replay_source[replay_source.index('    return owner._receipt_values('):
                                  replay_source.index('\n\n\ndef _verifier_values(')]
    for route,source,needle,replacement in [
            ('production-mutation',host_source,host_return,
             host_return.replace('storage_destroyed, terminated_at)','False, terminated_at)')),
            ('production-deletion',host_source,host_return,'    return b""'),
            ('offline-mutation',replay_source,offline_return,
             offline_return.replace('storage_destroyed, terminated_at)','False, terminated_at)')),
            ('offline-deletion',replay_source,offline_return,'    return b""')]:
        assert source.count(needle) == 1 and needle != replacement,route
        path = area/('host-control-'+route+'.py')
        path.write_text(source.replace(needle,replacement))
        changed = load('host_control_'+route.replace('-','_'),path)
        if route.startswith('production'):
            result = changed.build_receipt({'store_id':'ordinary-store'},'a'*64,{},request,
                'b'*64,1700000000.0,host.identities_for_receipt(measured),'accepted',run,True)
        else:
            result = changed._host_receipt_values(root,{'store_id':'ordinary-store'},'a'*64,{},request,
                'b'*64,1700000000.0,measured,'accepted',run,True,1700000001.0)
        assert result != baseline,route
        print('ok narrow host receipt call control detected - '+route)
    for label,raw in [('trailing',wire+b'x'),('truncated',wire[:-1]),('magic',b'X'+wire[1:])]:
        result = subprocess.run([str(helper)],input=raw,capture_output=True,env={},timeout=10)
        assert result.returncode != 0 and not result.stdout and not result.stderr,label
        print('ok fixed guest helper refuses - '+label)
    symbols = subprocess.run(['/usr/bin/nm','-u',str(helper)],capture_output=True,timeout=10)
    assert symbols.returncode == 0
    for name in ('execve','openat','mount','unshare','clone','fork','socket'):
        assert not any(line.strip().endswith(('_'+name,name)) for line in symbols.stdout.decode().splitlines()),name
    print('ok fixed guest helper - no native process, namespace, mount or socket imports')
PY_GUEST_VALUES
