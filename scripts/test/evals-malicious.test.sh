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
import os
import tempfile
with tempfile.TemporaryDirectory(prefix='ystack-runtime-identity-values-') as directory:
    area = Path(directory)
    slot_names = ('guest_kernel','guest_init','guest_supervisor','image','toolchain',
                  'runtime_vfkit','runtime_driver','vm_service','guest_kernel_config','verifier')
    slots = {name:(name+' ordinary bytes\n').encode() for name in slot_names}
    slots['dyld_cache_files'] = [b'ordinary dyld zero\n',b'ordinary dyld one\n']
    descriptors = {}
    try:
        for name in slot_names:
            path = area/name;path.write_bytes(slots[name]);descriptors[name] = os.open(path,os.O_RDONLY)
        descriptors['dyld_cache_files'] = []
        for index,raw in enumerate(slots['dyld_cache_files']):
            path = area/('dyld'+str(index));path.write_bytes(raw)
            descriptors['dyld_cache_files'].append(os.open(path,os.O_RDONLY))
        for missing in (None,'guest_kernel','verifier','guest_kernel_config','dyld_cache_files'):
            original_unreadable = host.os.environ.get('YSTACK_TEST_IDENTITY_UNREADABLE')
            if missing is None: host.os.environ.pop('YSTACK_TEST_IDENTITY_UNREADABLE',None)
            else: host.os.environ['YSTACK_TEST_IDENTITY_UNREADABLE'] = missing
            try: actual = host.measure_identities(descriptors,b'instruction',b'config',b'supervisor',b'python')
            finally:
                if original_unreadable is None: host.os.environ.pop('YSTACK_TEST_IDENTITY_UNREADABLE',None)
                else: host.os.environ['YSTACK_TEST_IDENTITY_UNREADABLE'] = original_unreadable
            raw = dict(slots)
            if missing is not None: raw[missing] = None
            offline = replay._identity_values(root,raw,b'instruction',b'config',b'supervisor',b'python')
            assert actual == offline,missing
            print('ok actual held runtime identity/composite/offline whole tuple - '+str(missing))
        chunked = dict(slots,guest_kernel=(slots['guest_kernel'][:3],slots['guest_kernel'][3:]))
        assert replay._identity_values(root,chunked,b'instruction',b'config',b'supervisor',b'python') == replay._identity_values(
            root,slots,b'instruction',b'config',b'supervisor',b'python')
        for label,raw in [('missing-key',{key:value for key,value in slots.items() if key != 'image'}),
                ('extra-key',dict(slots,unexpected=b'x')),('wrong-type',dict(slots,image=1)),
                ('over-count',dict(slots,dyld_cache_files=[b'x']*65))]:
            try: replay._identity_values(root,raw,b'instruction',b'config',b'supervisor',b'python')
            except Exception as error: assert type(error).__name__ == 'Refusal',label
            else: raise AssertionError(label)
        chunk = b'x'*1048576
        finite = {name:(chunk,)*64 for name in slot_names}
        finite.update(verifier=b'',guest_kernel_config=b'',image=(chunk,)*192,
                      dyld_cache_files=[(chunk,)*64]*54)
        assert host._runtime_slot_input_values(finite) == (4*1024*1024*1024,64)
        over = dict(finite,image=finite['image']+(b'x',))
        try: host._runtime_slot_input_values(over)
        except host.Refusal as error: assert error.code == 'E_CAPTURE'
        else: raise AssertionError('runtime total over 4GiB')
        print('ok actual runtime input counter at 4GiB/64 and one byte over; finite immutable chunk references only, no 4GiB allocation or hashing')
    finally:
        for value in descriptors.values():
            for fd in value if type(value) is list else [value]: os.close(fd)
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
    def io_value(result,raw=b'',error=None):
        return {'return':result,'bytes':raw.hex(),'errno':error}
    def read_values(group,name,raw):
        group[name+'_open']=io_value(3)
        group[name]=io_value(len(raw),raw)
        group[name+'_close']=io_value(0)
    def stat_values(size=0):
        return {'return':0,'errno':None,'stat':{'dev':2,'gid':501,'ino':123,
            'mode':0o100600,'nlink':1,'size':size,'uid':501}}
    def filesystem(blocks,free,fragment,files):
        return {'return':0,'errno':None,'stat':{'f_blocks':blocks,'f_bfree':free,'f_frsize':fragment,'f_files':files}}
    setup={'page_size':io_value(4096),'report_page_size':io_value(4096),'cgroup_open':io_value(4)}
    for key in ('cpu_max','cpu_max_burst','bandwidth_slice_us','pids_max'):
        text=(str(limits[key])+(' 100000\n' if key=='cpu_max' else '\n')).encode()
        setup[key+'_write_open']=io_value(3)
        setup[key+'_write']=io_value(len(text))
        setup[key+'_write_close']=io_value(0)
        read_values(setup,key,(str(limits[key])+'\n').encode())
    setup['subtree_control_write_open']=io_value(3)
    setup['subtree_control_write']=io_value(len(b'+cpu +pids +memory\n'))
    setup['subtree_control_write_close']=io_value(0)
    read_values(setup,'meminfo',b'MemTotal: 100 kB\n')
    setup['output']=filesystem(limits['output_tmpfs_bytes'],1,1,limits['output_inodes'])
    setup['scratch']=filesystem(limits['scratch_bytes'],1,1,limits['scratch_inodes'])
    def raw_now(n):return {'tag':'now','sec':0,'nsec':n,'errno':None}
    primitive_control=[raw_now(0),{'tag':'launch','pid':17,'errno':None},raw_now(1),
        {'tag':'poll','count':1,'errno':None,'revents':[{'role':'exec','revents':17}]},raw_now(2),
        {'tag':'exec-read','bytes':ready.hex(),'eof':False,'errno':None},
        {'tag':'exec-read','bytes':'','eof':True,'errno':None},raw_now(3),
        {'tag':'wait','pid':17,'status':0,'errno':None},raw_now(4),raw_now(5),
        {'tag':'population','bytes':b'populated 0\n'.hex(),'errno':None},
        {'tag':'exec-read','bytes':'','eof':True,'errno':None},raw_now(6)]
    counters={}
    for name,value in [('cpu_stat',b'usage_usec 1001\n'),('memory_peak',b'4096\n'),
                       ('memory_events',b'oom_kill 0\n'),('pids_peak',b'1\n'),('pids_events',b'max 0\n')]:
        read_values(counters,name,value)
    for name in ('stdout','stderr'):
        counters[name]=stat_values()
        counters[name+'_bytes']=io_value(0)
    counters['entry_0000_name']=io_value(len(b'result.json'),b'result.json')
    counters['entry_0000_stat']=stat_values(2)
    counters['directory']=io_value(0)
    for suffix in ('size','report_stat','export_stat'):
        counters['evidence_0000_'+suffix]=stat_values(2)
    counters['evidence_0000_bytes']=io_value(2,b'{}')
    counters['output']=filesystem(10,1,4096,64)
    counters['scratch']=filesystem(10,9,4096,64)
    guest_raw={'setup':setup,'control':primitive_control,'counters':counters}
    bridge_wire=replay._guest_wire_values(plan,guest_raw)
    bridge_work=area/'bridge';bridge_work.mkdir(mode=0o700)
    assert replay._guest_values(root,bridge_work,bridge_wire)==frame
    print('ok synthetic closed guest RAW -> strict02 -> same original report/frame bytes; Linux production route NOTRUN')
    import copy
    for label,change in [
            ('setup-missing',lambda d:d['setup'].pop('meminfo_open')),
            ('setup-extra',lambda d:d['setup'].update(unknown=io_value(0))),
            ('setup-wrong-type',lambda d:d['setup']['page_size'].update(**{'return':True})),
            ('setup-over-read',lambda d:d['setup']['cpu_max'].update(bytes='ff'*128,**{'return':128})),
            ('control-missing',lambda d:d['control'].pop(2)),
            ('control-extra',lambda d:d['control'][0].update(unknown=0)),
            ('control-wrong-type',lambda d:d['control'][0].update(sec=True)),
            ('control-over-read',lambda d:d['control'][5].update(bytes='00'*33)),
            ('counter-missing',lambda d:d['counters'].pop('cpu_stat_open')),
            ('counter-extra',lambda d:d['counters'].update(unknown=io_value(0))),
            ('counter-wrong-type',lambda d:d['counters']['stdout']['stat'].update(size=True)),
            ('counter-over-name',lambda d:d['counters']['entry_0000_name'].update(bytes='61'*256,**{'return':256}))]:
        damaged=copy.deepcopy(guest_raw);change(damaged)
        try:bad_wire=replay._guest_wire_values(plan,damaged)
        except ValueError:pass
        else:
            rejected=subprocess.run([str(bridge_work/'guest-values')],input=bad_wire,capture_output=True,env={},timeout=10)
            assert rejected.returncode!=0,label
        print('ok strict guest bridge refuses - '+label)
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
/usr/bin/python3 -I -S -B - "$root" <<'PY_CAPTURE_VALUES'
import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types

root = Path(sys.argv[1])
def load(name,path):
    spec = importlib.util.spec_from_file_location(name,path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module
host = load('capture_host',root/'sandbox/v1/host-supervisor.py')
consumer = load('capture_consumer',root/'shadow/v1/_consumer.py')
capture_replay = load('capture_replay',root/'evals/v1/replay-malicious.py')
request = host.canonical({'ordinary':'request bytes'})
group = {'host':{'process':[],'driver_rest':[]}}
def refuses(function,label):
    try:function()
    except consumer.Refusal:
        print('ok capture refuses - '+label)
    else:raise AssertionError(label)

with tempfile.TemporaryDirectory(prefix='ystack-capture-held-values-') as directory:
    area = Path(directory).resolve()
    store = area/'store';store.mkdir(mode=0o750);store.chmod(0o750)
    config = {'principal_uid':os.getuid(),'consumer_gid':os.getgid(),'store_id':'store.ordinary',
        'environment_id':'environment.ordinary','store_root':str(store),'work_root':str(area/'work'),
        'runtime':{'driver':'/ordinary/driver','vfkit':'/ordinary/vfkit'},
        'installed_files':{key:'/ordinary/installed/'+key for key in consumer.INSTALLED_SOURCES},
        'identity_paths':{key: ['/ordinary/dyld'] if key == 'dyld_cache_files' else '/ordinary/identity/'+key
                          for key in consumer.IDENTITY_KEYS}}
    config_raw = consumer.canonical({'schema_version':1,'kind':'sandbox_host_config','id':'host.ordinary','body':config})
    anchor = types.SimpleNamespace(config=config,config_raw=config_raw,resolver=None,recheck=lambda *_:None)
    original_acl = consumer._acl_state
    consumer._acl_state = lambda *_: ([],None) if sys.platform == 'darwin' else (None,None)
    try:
        for index,complete in enumerate((None,False,True)):
            attempt_id = 'attempt.capture.'+str(index)
            attempt = store/attempt_id;attempt.mkdir(mode=0o750);attempt.chmod(0o750)
            payload = attempt/'payload';payload.mkdir(mode=0o750);payload.chmod(0o750)
            values = {'receipt.json':host.canonical({'body':{'attempt':{
                'attempt_id':attempt_id,'launch_request_sha256':host.sha256_hex(request)}}}),
                'payload/stdout':b'','payload/stderr':b'',
                'payload/evidence-manifest.json':host.empty_evidence_manifest()[0]}
            if complete is not None:values['capture.json'] = host._capture_values(attempt_id,request,group,complete)
            for name,raw in values.items():
                path = attempt/name;path.write_bytes(raw);path.chmod(0o440)
            held = consumer._HeldStoreRead(anchor,attempt_id)
            try:
                assert held.snapshots == values
                held.recheck()
                rebuilt = consumer._origin_values(held.snapshots,held.storage_rows,
                    {'attempt_id':attempt_id,'platform':sys.platform},{'host-config.json':config_raw})
                assert rebuilt == held.observation
                if complete:
                    assert consumer._capture_for_replay(held.snapshots,attempt_id,request) == group
                    print('ok capture envelope and actual held inventory - new; not a complete case replay')
                    for label,change in [('extra-key',lambda v:v.update(extra=True)),
                            ('wrong-attempt',lambda v:v.update(id='other')),
                            ('wrong-request',lambda v:v['body'].update(request_sha256='a'*64)),
                            ('wrong-complete-type',lambda v:v['body'].update(complete=1))]:
                        changed = json.loads(values['capture.json']);change(changed)
                        refuses(lambda:consumer._capture_envelope(consumer.canonical(changed),attempt_id,
                            host.sha256_hex(request)),label)
                    path = attempt/'capture.json';path.chmod(0o640)
                    path.write_bytes(values['capture.json'].replace(b'"complete":true',b'"complete":false'))
                    path.chmod(0o440)
                    refuses(held.recheck,'changed-after-held-read')
                else:
                    refuses(lambda:consumer._capture_for_replay(held.snapshots,attempt_id,request),
                            'legacy-missing' if complete is None else 'partial')
                    print('ok actual held inventory - '+('legacy' if complete is None else 'partial capture'))
            finally:held.close()
            extra = attempt/'unknown';extra.write_bytes(b'x');extra.chmod(0o440)
            refuses(lambda:consumer.read_store_attempt(anchor,attempt_id),'extra-attempt-entry')
        oversized = host._capture_values('attempt.capture.overflow',request,
            {'host':{'process':['x'*(4*1024*1024)],'driver_rest':[]}},True)
        assert json.loads(oversized)['body']['complete'] is False
        assert json.loads(oversized)['body']['raw'] == {}
        print('ok capture overflow - incomplete; no seed admission')
        for value in (None,True,False,0,-17,'quote" slash\\ newline\n','中文',
                      {'path':'/ordinary','values':[1,None,'\x00\b\t\r\f']}):
            assert host._capture_size(value,1024*1024)+1 == len(host.canonical(value))
        boundary_id = 'attempt.capture.boundary'
        boundary_group = {'host':{'process':[{'site':'run_driver.read','ordinal':0,
            'return':0,'errno':None,'bytes':'','timeout':None}], 'driver_rest':[], 'signals':[]},
            'clocks':{'wall':[],'monotonic':[]}}
        row = boundary_group['host']['process'][0]
        row['return'] = 500000
        overhead = len(host._capture_values(boundary_id,request,boundary_group,True))
        if (1024*1024-overhead) % 2:
            boundary_id += 'a';overhead += 1
        row['bytes'] = '00'*((1024*1024-overhead)//2)
        row['return'] = len(row['bytes'])//2
        at_limit = host._capture_values(boundary_id,request,boundary_group,True)
        assert len(at_limit) == 1024*1024 and json.loads(at_limit)['body']['complete']
        assert consumer._capture_envelope(at_limit,boundary_id,host.sha256_hex(request)) == boundary_group
        over_limit = host._capture_values(boundary_id+'a',request,boundary_group,True)
        assert not json.loads(over_limit)['body']['complete'] and json.loads(over_limit)['body']['raw'] == {}
        print('ok exact capture document boundary and one-byte-over envelope; primitive schema/case admission remain separate')
        for operation,source_role in (('kill-register-read','kill'),('coverage-read','coverage')):
            metadata = {'family':'fixture','page_index':0,'response_status':200,
                        'input_cursor':None,'output_cursor':None}
            records = [(b'capture.json',host.canonical({'pages':[metadata]})),(b'raw/0000',b'{}\n')]
            clocks = {'wall':[],'monotonic':[],'complete':True}
            result = host._source_capture_values('attempt.source',request,records,[b'{}\n'],clocks,True,operation)
            source_raw = consumer._capture_envelope(result,'attempt.source',host.sha256_hex(request),seed=True)
            assert source_raw == {'source_pages':{source_role:[dict(metadata,body_hex=b'{}\n'.hex())]},
                                  'clocks':{'wall':[],'monotonic':[]}}
            assert consumer._capture_export_binding(source_raw,{'capture.json':result},source=True) is None
            overflow = host._source_capture_values('attempt.source',request,records,
                [bytes(1024*1024)],clocks,True,operation)
            assert json.loads(overflow)['body'] == {'request_sha256':host.sha256_hex(request),
                'raw':{},'complete':False}
            print('ok source capture operation binding and pre-hex document overflow - '+operation)
        for launch in ('reproduction','write'):
            before_work = copy.deepcopy(consumer._export_work)
            def spent(site,field):
                return (consumer._export_work.get(site,{}).get(field,0)
                        - before_work.get(site,{}).get(field,0))
            attempt_id = 'attempt.export.'+launch
            attempt = store/attempt_id;attempt.mkdir(mode=0o750);attempt.chmod(0o750)
            payload = attempt/'payload';payload.mkdir(mode=0o750);payload.chmod(0o750)
            export = host.frame_write([(b'stdout',b''),(b'stderr',b'')])
            export += bytes(consumer.EXPORT_LIMIT-len(export))
            reference = {'role':'sandbox-export-bytes','launch':launch,
                         'size_bytes':len(export),'sha256':host.sha256_hex(export)}
            export_group = {'host':{'process':[{'site':'run_vm.export-read','ordinal':0,
                'return':len(export),'errno':None,'bytes':reference,'timeout':None}],
                'driver_rest':[],'signals':[]}}
            values = {'receipt.json':host.canonical({'body':{'attempt':{
                'attempt_id':attempt_id,'launch_request_sha256':host.sha256_hex(request)}}}),
                'payload/stdout':b'','payload/stderr':b'',
                'payload/evidence-manifest.json':host.empty_evidence_manifest()[0],
                'capture.json':host._capture_values(attempt_id,request,export_group,True),
                'sandbox-export.bin':export}
            for name,raw in values.items():
                path = attempt/name;path.write_bytes(raw);path.chmod(0o440)
            held = consumer._HeldStoreRead(anchor,attempt_id)
            try:
                snapshot = held.snapshots['sandbox-export.bin']
                assert len(snapshot.chunks) == consumer.EXPORT_LIMIT//65536
                assert all(type(chunk) is bytes and len(chunk) == 65536 for chunk in snapshot.chunks)
                try: snapshot.chunks = ()
                except consumer.dataclasses.FrozenInstanceError: pass
                else: raise AssertionError('mutable export snapshot')
                assert spent('consumer.held-acquisition','calls') == 1
                assert spent('consumer.held-acquisition','read_bytes') == len(export)
                assert spent('consumer.independent-sha','calls') == 1
                assert spent('consumer.independent-sha','read_bytes') == len(export)
                assert held.snapshots == values
                assert spent('consumer.whole-equality','calls') == 1
                assert spent('consumer.whole-equality','read_bytes') == 2*len(export)
                assert capture_replay._origin_values(root,held.snapshots,held.storage_rows,
                    {'attempt_id':attempt_id,'platform':sys.platform},
                    {'host-config.json':config_raw}) == held.observation
                assert spent('consumer.independent-sha','calls') == 1
                assert spent('consumer.independent-sha','read_bytes') == len(export)
                offline_work = sys.modules['malicious_origin_values']._export_work
                assert offline_work['consumer.independent-sha'] == {'calls':1,'read_bytes':len(export)}
                assert consumer._capture_for_replay(held.snapshots,attempt_id,request,launch=launch) == export_group
                refuses(lambda:consumer._capture_for_replay(held.snapshots,attempt_id,request,
                    launch='write' if launch == 'reproduction' else 'reproduction'),'cross-launch')
                refuses(lambda:consumer._capture_export_binding(export_group,held.snapshots,source=True),'source-binary')
                for label,change in [('missing-role',lambda v:v.pop('role')),
                        ('extra-key',lambda v:v.update(path='other')),
                        ('wrong-size-type',lambda v:v.update(size_bytes=True)),
                        ('over-size',lambda v:v.update(size_bytes=consumer.EXPORT_LIMIT+1))]:
                    changed = copy.deepcopy(export_group);change(changed['host']['process'][0]['bytes'])
                    refuses(lambda:consumer._capture_export_binding(changed,held.snapshots),label)
                for label,change in [('inline-export',lambda r:r.update(bytes='00')),
                        ('wrong-site',lambda r:r.update(site='run_driver.read')),
                        ('wrong-return',lambda r:r.update(**{'return':0})),
                        ('wrong-ordinal',lambda r:r.update(ordinal=1))]:
                    changed = copy.deepcopy(export_group);change(changed['host']['process'][0])
                    refuses(lambda:consumer._capture_export_binding(changed,held.snapshots),label)
                duplicate = copy.deepcopy(export_group)
                duplicate['host']['process'] *= 2
                refuses(lambda:consumer._capture_export_binding(duplicate,held.snapshots),'duplicate-export')
                refuses(lambda:consumer._capture_export_binding(export_group,
                    {k:v for k,v in held.snapshots.items() if k != 'sandbox-export.bin'}),'missing-binary')
                refuses(lambda:consumer._capture_export_binding(group,held.snapshots),'unused-binary')
                held.recheck()
                assert spent('consumer.completion-reread','calls') == 1
                assert spent('consumer.completion-reread','read_bytes') == 2*len(export)
                print(json.dumps({'launch':launch,'consumer_work':{
                    site:{field:spent(site,field) for field in ('calls','read_bytes')}
                    for site in consumer._export_work},'offline_origin_work':offline_work},sort_keys=True))
                path = attempt/'sandbox-export.bin';path.chmod(0o640)
                with path.open('r+b') as output:
                    output.seek(-1,os.SEEK_END);output.write(b'x')
                path.chmod(0o440)
                refuses(held.recheck,'export-tail-changed-after-held-read')
                refuses(lambda:consumer.read_store_attempt(anchor,attempt_id),'export-digest-mismatch')
                print('ok complete 12MiB conditional binary held inventory/origin/binding - '+launch+
                      '; capture path only, full accounting/replay remain separate')
            finally:held.close()
    finally:consumer._acl_state = original_acl
PY_CAPTURE_VALUES
/usr/bin/python3 -I -S -B - "$root" <<'PY_LAUNCH_PREPARATION_VALUES'
import importlib.util
from pathlib import Path
import sys
import types

root = Path(sys.argv[1])
def load(name,path):
    spec = importlib.util.spec_from_file_location(name,path)
    owner = importlib.util.module_from_spec(spec);sys.modules[name] = owner
    spec.loader.exec_module(owner)
    return owner
replay = load('projection_replay',root/'evals/v1/replay-malicious.py')
launch = load('projection_launch',root/'shadow/v1/enforced-reproduction.py')
preparation = load('projection_preparation',root/'preparation/v1/prepare-candidate.py')
with preparation.tempfile.TemporaryDirectory(prefix='ystack-preparation-name-values-') as directory:
    scratch = Path(directory).resolve()
    deadline = preparation.time.monotonic()+30
    boundary = preparation.hold_boundary(scratch,'directory',deadline,private_leaf=True)
    token_hex = preparation.secrets.token_hex
    observed = []
    def actual_entropy_with_one_collision(size):
        value = token_hex(size);observed.append(value)
        if len(observed) == 1:
            (scratch/preparation._workspace_name_values(value)).mkdir(mode=0o700)
        return value
    preparation.secrets.token_hex = actual_entropy_with_one_collision
    try:
        context = preparation.create_context(types.SimpleNamespace(scratch=str(scratch),
            _boundaries={'scratch':boundary}),deadline)
        try:
            retained = preparation._preparation_names[-1]
            assert retained == [{'entropy':observed[0],'errno':preparation.errno.EEXIST},
                                {'entropy':observed[1],'errno':None}]
            assert context.scratch.name == preparation._preparation_names_values(observed,[True,False])
            assert context.scratch.is_dir() and len(observed) == 2
            for entropy,collisions in [([],[]),([observed[0]],[0]),([observed[0]],[]),
                    ([observed[0]],[True]),([observed[0],'g'*16],[True,False]),
                    ([observed[0]]*129,[True]*128+[False]),
                    ([observed[0]]*2,[False,False])]:
                try: preparation._preparation_names_values(entropy,collisions)
                except preparation.Refusal as error: assert error.token == 'E_INPUT'
                else: raise AssertionError('preparation entropy/collision shape')
            try: preparation._preparation_names_values([observed[0]]*128,[True]*128)
            except preparation.Refusal as error: assert error.token == 'E_IO'
            else: raise AssertionError('128 collisions')
            print('ok actual preparation workspace entropy/collision acquisition and same naming owner; bounded refusal matrix')
        finally: context.close_boundaries()
    finally:
        preparation.secrets.token_hex = token_hex
        if boundary.descriptors: boundary.close()
incident = launch.canonical({'id':'incident.ordinary','body':{'target_repository_id':'repo.ordinary'}})
record = launch.canonical({'source':{'repository_id':'repo.ordinary','hash_algorithm':'sha1',
    'commit_id':'a'*40,'tree_id':'b'*40},'candidate':{'commit_id':'c'*40,'tree_id':'d'*40}})
manifest = launch.canonical({'ordinary':'manifest'})
evaluation = launch.canonical({'ordinary':'evaluation'})
observation = launch.canonical({'ordinary':'observation'})
request = {'body':{'attempt_id':'attempt.ordinary'}}
names = ('control_policy','control_decision','control_policy_set','evaluator_driver','evaluator_program')
installed = {name:((name+' ordinary source').encode(),launch.sha((name+' ordinary source').encode()))
             for name in names}
anchor = types.SimpleNamespace(config={'environment_id':'environment.ordinary','store_id':'store.ordinary'},
    registry=('registry-sha',[{'environment_id':'environment.ordinary'}]),installed=installed)
actual_entropy = []
urandom = launch.os.urandom
def observed_entropy(size):
    value = urandom(size);actual_entropy.append(value);return value
launch.os.urandom = observed_entropy
try:
    actual = launch.make_launch(anchor,request,incident,evaluation,observation,record,manifest,b'instruction')
    assert len(actual_entropy) == 1 and len(actual_entropy[0]) == 32
    context = {'environment_id':anchor.config['environment_id'],'store_id':anchor.config['store_id'],
               'registry':anchor.registry[1]}
    control = {'context':context,'control':launch.control(anchor,evaluation)}
    offline = replay._launch_values(root,launch.canonical(request),incident,evaluation,observation,
                                    record,manifest,b'instruction',control,actual_entropy[0])
    assert actual == offline
    changed = bytes([actual_entropy[0][0]^1])+actual_entropy[0][1:]
    assert replay._launch_values(root,launch.canonical(request),incident,evaluation,observation,
        record,manifest,b'instruction',control,changed) != actual
    try:launch.make_launch(anchor,request,b'{}',evaluation,observation,record,manifest,b'instruction')
    except (KeyError,launch.Refusal):pass
    else:raise AssertionError('invalid subject')
    assert len(actual_entropy) == 1
finally:launch.os.urandom = urandom
print('ok synthetic actual launch/offline bytes - same control, subject and entropy owners; refusal before entropy')

source_bytes = {'component':b'ordinary component','python':b'ordinary executable','git':b'ordinary git'}
identities = {'jq':{'sha256':'e'*64},'core':{'sha256':'f'*64}}
context = types.SimpleNamespace(args=types.SimpleNamespace(input_sha256='1'*64,response_sha256='2'*64),
    source_observation=[],identities=identities,deadline=1,
    boundaries={name:types.SimpleNamespace(fd=index) for index,name in enumerate(('component_source','python','git'),1)})
sources = {1:source_bytes['component'],2:source_bytes['python'],3:source_bytes['git']}
calls = []
read_limited,run_child,clean_env = preparation.read_limited,preparation.run_child,preparation.clean_git_env
def held_read(path,maximum,**kwargs):
    calls.append(('held-read',kwargs['source_fd']));return sources[kwargs['source_fd']]
def version_command(ctx,argv,**kwargs):
    assert argv == [preparation.GIT,'--version'] and kwargs['output_limit'] == 128
    calls.append(('version',tuple(argv)));return b'git version ordinary\n'
preparation.read_limited,preparation.run_child,preparation.clean_git_env = held_read,version_command,lambda _:{}
try:
    inventory = [{'kind':'file','path':'ordinary.txt','size_bytes':2,'sha256':preparation.sha256(b'{}')}]
    response = {'stage_result':{'body':{'outcome':{'value':'changed'}}}}
    details = {'stage_result_sha256':'3'*64,'verified_receipt':{'sha256':'4'*64}}
    receipt = {'source':{'repository_id':'repo.ordinary','hash_algorithm':'sha1','commit_id':'a'*40,'tree_id':'b'*40},
        'candidate':{'hash_algorithm':'sha1','commit_id':'c'*40,'tree_id':'d'*40,'parent_commit_id':'a'*40},
        'attempt':{'attempt_id':'attempt.ordinary','attempt_number':1},'request_ref':{},'resolved_profile_ref':{}}
    manifest = preparation.canonical(preparation.manifest_for(inventory))
    actual = preparation.canonical(preparation.make_record(context,{},response,details,receipt,manifest))
    assert calls[:3] == [('held-read',1),('held-read',2),('held-read',3)] and calls[3][0] == 'version'
    runtime = {'git_version':b'git version ordinary\n','python_version':sys.version.splitlines()[0],
               'unicode_version':preparation.unicodedata.unidata_version}
    offline_manifest,offline,completion = replay._preparation_values(root,inventory,source_bytes,runtime,
        identities,'1'*64,'2'*64,response,details,receipt,[])
    assert offline_manifest == manifest and offline == actual
    assert completion == preparation.completion_envelope(actual,manifest)
finally:preparation.read_limited,preparation.run_child,preparation.clean_git_env = read_limited,run_child,clean_env
print('ok synthetic actual preparation/offline manifest, producer, record and completion bytes - held acquisition retained')
PY_LAUNCH_PREPARATION_VALUES

/usr/bin/python3 -I -S -B - "$root" <<'PY_REST_CAPTURE'
import errno
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile

root = Path(sys.argv[1])
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    owner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(owner)
    return owner
host = load('capture_process_owner', root/'sandbox/v1/host-supervisor.py')
driver = load('capture_rest_owner', root/'sandbox/v1/runtime-vfkit.py')
magic = b'YSTACK_REST_CAPTURE_V1\n'

class Connection:
    phase = None
    status = 200
    body = b'{"state":"VirtualMachineStateStopped"}'
    calls = []
    def __init__(self, path):
        assert path == '/ordinary-not-opened'
    def request(self, method, target, **kwargs):
        self.calls.append((method, target, kwargs))
        if self.phase == 'request':raise OSError(errno.ECONNREFUSED, 'ordinary refusal')
    def getresponse(self):
        if self.phase == 'getresponse':raise driver.http.client.HTTPException('ordinary response')
        return self
    def read(self, size):
        assert size == 65537
        if self.phase == 'read':raise OSError(errno.EIO, 'ordinary read')
        return self.body
    def close(self):self.calls.append('closed')

driver.UnixConnection = Connection
with tempfile.TemporaryDirectory() as directory:
    os.chmod(directory, 0o700)
    host._driver_capture_dir = directory
    def reset():
        host._capture_process = {'rows':[], 'ordinals':{}, 'bytes':0,
            'complete':True, 'driver_rest':[]}
    for phase in (None, 'request', 'getresponse', 'read'):
        reset()
        fd = host._open_driver_capture()
        assert fd is not None and os.fstat(fd).st_nlink == 0
        assert os.listdir(directory) == []
        Connection.phase = phase
        reply = driver.rest('/ordinary-not-opened', 'GET', '/vm/state')
        raw = os.pread(fd, 132096, len(magic))
        value = json.loads(raw)
        assert raw == driver.canonical(value)
        if phase is None:
            assert reply == (200, Connection.body)
            assert value == {'reply':{'status':200, 'body_hex':Connection.body.hex()}, 'error':None}
        else:
            assert reply is None and value['reply'] is None
            assert value['error']['phase'] == phase
            assert value['error']['category'] == ('HTTPException' if phase == 'getresponse' else 'OSError')
        assert Connection.calls[-1] == 'closed'
        os.close(fd)
    reset()
    script = Path(directory)/'ordinary-driver'
    script.write_text('#!/usr/bin/python3\nimport importlib.util,sys\n'
        's=importlib.util.spec_from_file_location("owner",'+repr(str(root/'sandbox/v1/runtime-vfkit.py'))+')\n'
        'm=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n'
        'm._capture_rest({"status":200,"body_hex":"7b7d"},None)\n'
        'sys.stdout.buffer.write(b"stopped\\n")\n')
    script.chmod(0o700)
    result = host.run_driver(str(script), ['state','/ordinary-not-opened'])
    assert result == (0,b'stopped\n')
    assert host._capture_process['complete']
    assert host._capture_process['driver_rest'] == [
        {'call':0,'operation':'state','reply':{'status':200,'body_hex':'7b7d'},'error':None}]
    reads = [row for row in host._capture_process['rows'] if row['site']=='run_driver.read']
    assert b''.join(bytes.fromhex(row['bytes']) for row in reads) == b'stopped\n'
    assert reads[-1]['return'] == 0
    script.write_text('#!/usr/bin/python3\nimport sys\nsys.stdout.buffer.write(b"stopped\\n")\n')
    reset()
    assert host.run_driver(str(script), ['state','/ordinary-not-opened']) == result
    assert not host._capture_process['complete'] and not host._capture_process['driver_rest']
    assert sorted(os.listdir(directory)) == ['ordinary-driver']
print('ok actual REST owner request/getresponse/read primitives and inherited private capture; missing capture preserves driver result')
PY_REST_CAPTURE

/usr/bin/python3 -I -S -B - "$root" <<'PY_WRITER_VALUES'
import importlib.util
from pathlib import Path
import sys
import tempfile
import types
root = Path(sys.argv[1])
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    owner=importlib.util.module_from_spec(spec);sys.modules[name]=owner
    spec.loader.exec_module(owner);return owner
writer=load('actual_write_projection_owner',root/'shadow/v1/write-shadow.py')
replay=load('offline_write_projection_owner',root/'evals/v1/replay-malicious.py')
def document(kind,identity,body):
    return writer.canonical({'schema_version':1,'kind':kind,'id':identity,'body':body})
incident={'schema_version':1,'kind':'shadow_incident','id':'incident.ordinary','body':{
    'target_repository_id':'repo.ordinary',
    'git_revision_ref':{'repository_id':'repo.ordinary','hash_algorithm':'sha1','commit_id':'a'*40},
    'failing_check':{'kind':'file-digest','path':'ordinary.txt','expected_sha256':'b'*64}}}
frozen={name:document('ordinary_document','ordinary.'+str(i),{}) for i,name in enumerate(writer.NAMES)}
frozen['incident.json']=writer.canonical(incident)
frozen['shadow-record.json']=document('shadow_reproduction_record','incident.ordinary',
    {'environment':{'claim_ref':{'sha256':'c'*64}}})
files={name:frozen[name] for name in writer.e.EVIDENCE_NAMES}
files['file-digest-result.json']=document('file_digest_result','result.ordinary',
    {'outcome':'match','observed':{'sha256':'b'*64}})
prefix='ystack-evidence/'+incident['id']+'/'
materialized_files={prefix+name:raw for name,raw in frozen.items()}
materialized_files[prefix+'eval-seed.json']=document('eval_seed_case','seed.ordinary',{})
materialized_files[prefix+'README.md']=b'Shadow evidence. Publication is withheld.\n'
write_set=writer.c.evidence_patch(materialized_files,'sha1')[1]
request={'id':'attempt.write.ordinary','body':{'scope_id':'scope.ordinary',
    'allowed_paths':[row['path'] for row in write_set]}}
input_raw=writer.canonical({'stage_request':{'content':{'body':{
    'workflow_id':'workflow.shadow-evidence-commit','task_class_id':'task.commit-shadow-evidence'}}}})
response_raw=writer.canonical({'payloads':[{'data':writer.canonical({
    'source':incident['body']['git_revision_ref'],
    'candidate':{'tree_id':'d'*40}}).decode()}],
    'stage_result':{'schema_version':2,'kind':'stage_result','id':'stage.ordinary',
        'body':{'outcome':{'value':'changed'}}}})
evaluation_raw=document('control_evaluation','evaluation.ordinary',{'verdict':'satisfied','reason_ids':[]})
qualified_raw=document('qualified_identity','qualified.ordinary',{'environment_id':'environment.ordinary'})
native={key:'e'*64 for key in writer.c.NATIVE_RELEASE_KEYS}
native.update(binary_path='/ordinary/native',python_path='/ordinary/python',binary_size=123,
    python_abi='ordinary',loader_mode='ordinary')
parent={'native_release':native,**{key:'f'*64 for key in writer.c.HASH_KEYS}}
commands=[{'role':'ordinary','argv_sha256':'a'*64}]
observation=document('write_observation','observation.ordinary',{})
trace=document('telemetry_trace_ledger','trace.ordinary',{})
materialized=types.SimpleNamespace(input_raw=input_raw,response_raw=response_raw,evaluation_raw=evaluation_raw,
    qualified_identity_raw=qualified_raw,candidate_tree_id='d'*40,write_set=write_set,files=materialized_files)
with tempfile.TemporaryDirectory() as area:
    work=Path(area);(work/'observation').mkdir()
    (work/'observation/write-observation.json').write_bytes(observation)
    ws=types.SimpleNamespace(request_doc=request,parent=parent,work=work,commands=commands,
        components={writer.SOURCE/'shadow/v1/write-shadow.py':types.SimpleNamespace(sha256='1'*64)},
        python=types.SimpleNamespace(sha256='2'*64),jq=types.SimpleNamespace(sha256='3'*64),
        anchor=types.SimpleNamespace(config={'store_id':'store.ordinary'}))
    active=writer.e.CancellationSignals.active
    writer.e.CancellationSignals.active=types.SimpleNamespace(native=types.SimpleNamespace(
        provenance=lambda context:writer.e._NativeRelease.provenance(None,context)))
    try:provenance=writer._write_provenance(ws,incident)
    finally:writer.e.CancellationSignals.active=active
    publisher,publisher_body=writer._publisher(incident,'d'*40)
    stage=writer.parse(input_raw)['stage_request']['content']['body']
    write=writer._write_section_values(frozen['bundle.json'],'scope.ordinary',stage,write_set,
        publisher,incident['body']['git_revision_ref'],'d'*40)
    actual_files=dict(files,**{'publisher-body.txt':publisher_body,'consumer-provenance.json':provenance})
    actual_files['shadow-record.json']=writer._outer_record(ws,materialized,frozen,actual_files,write,provenance,trace)
    context={'request':request,'record_form':'withheld-write.v1','scope_policy_raw':None,
        'store_id':'store.ordinary','parent':parent,'consumer_sha256':'1'*64,'python_sha256':'2'*64,
        'jq_sha256':'3'*64,'native_context':parent,'commands':commands,'observation':observation,'trace':trace}
    offline,marker,admission=replay._writer_values(root,frozen,files,vars(materialized),context)
    assert offline==actual_files and marker==writer._bundle_values(actual_files,incident,'withheld-write.v1')
    assert admission==write['admission']
    damaged=dict(context);damaged['request']={'id':request['id'],'body':dict(request['body'],allowed_paths=[])}
    try:replay._writer_values(root,frozen,files,vars(materialized),damaged)
    except writer.c.Refusal:pass
    except Exception as error:
        assert type(error).__name__=='Refusal'
    else:raise AssertionError('admission paths control missing')
print('ok synthetic writer caller/offline full provenance, admission, outer record and bundle; native Git/authority route not claimed')
PY_WRITER_VALUES
