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
        previous_capture = host._capture_process
        locators = {name:str(area/name) for name in slot_names}
        locators['dyld_cache_files'] = [str(area/'dyld0'),str(area/'dyld1')]
        runtime_config = host.canonical({'body':{'identity_paths':locators,
            'runtime':{'vfkit':locators['runtime_vfkit'],'driver':locators['runtime_driver']}}})
        try:
            for failed_slot in (None,'guest_kernel','verifier','guest_kernel_config','dyld_cache_files'):
                host._capture_process = {'complete':True,'runtime_locators':locators}
                observed_fds = dict(descriptors)
                if failed_slot == 'dyld_cache_files':
                    observed_fds[failed_slot] = [descriptors[failed_slot][0],-1]
                elif failed_slot is not None:
                    observed_fds[failed_slot] = -1
                actual = host.measure_identities(observed_fds,b'instruction',runtime_config,b'supervisor',b'python')
                reads = host._capture_process['runtime_reads']
                assert sum(row['errno'] is not None for row in reads) == int(failed_slot is not None)
                if failed_slot is not None:
                    assert next(row['errno'] for row in reads if row['errno'] is not None) == host.errno.EBADF
                assert replay._identity_values(root,slots,b'instruction',runtime_config,b'supervisor',b'python',reads) == actual
                print('ok actual runtime slot read errno/offline identity pair - '+str(failed_slot))
            import copy
            for label,change in [('missing',lambda v:v[0].pop('errno')),
                    ('extra',lambda v:v[0].update(extra=0)),
                    ('wrong-type',lambda v:v[0].update(errno=True)),
                    ('invalid',lambda v:v[0].update(errno=-1)),
                    ('changed-locator',lambda v:v[0].update(locator='/ordinary/changed')),
                    ('unused',lambda v:v.append(dict(v[-1]))),
                    ('reordered',lambda v:v.reverse())]:
                changed = copy.deepcopy(reads);change(changed)
                try:replay._identity_values(root,slots,b'instruction',runtime_config,b'supervisor',b'python',changed)
                except Exception as error:assert type(error).__name__ == 'Refusal' and str(error) == 'E_CAPTURE'
                else:raise AssertionError('runtime read shape '+label)
        finally:host._capture_process = previous_capture
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
    bridge_wire=replay._guest_wire_values(root,plan,guest_raw)
    bridge_work=area/'bridge';bridge_work.mkdir(mode=0o700)
    assert replay._guest_values(root,bridge_work,bridge_wire)==frame
    print('ok synthetic closed guest RAW -> strict02 -> same original report/frame bytes; Linux production route NOTRUN')
    old_dumps = replay.json.dumps
    def forbidden_row_encoding(*args,**kwargs):
        raise AssertionError('row encoded before bounded size admission')
    try:
        replay.json.dumps = forbidden_row_encoding
        assert replay._guest_wire_values(root,plan,guest_raw) == bridge_wire
        import copy
        oversized = copy.deepcopy(guest_raw)
        oversized['control'][0]['sec'] = 'x'*8192
        try:replay._guest_wire_values(root,plan,oversized)
        except ValueError as error:assert str(error) == 'guest control row'
        else:raise AssertionError('oversized row admitted')
    finally:replay.json.dumps = old_dumps
    print('ok guest control row exact owner bounds before JSON allocation, normal bridge unchanged')
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
        try:bad_wire=replay._guest_wire_values(root,plan,damaged)
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
import ast
import copy
import importlib.util
import inspect
import json
import os
from pathlib import Path
import sys
import tempfile
import textwrap
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
scope_capture_reader = load('capture_scope_reader',root/'scope/v1/read-shadow-evidence.py')
scope_capture_reader.c=consumer
request = host.canonical({'ordinary':'request bytes'})
group = {'host':{'process':[],'driver_rest':[]}}
for attempt_id in ('attempt.completion', 'a'*128):
    capture = host._capture_values(attempt_id,request,group,True)
    hashed = []
    original_sha = host.sha256_hex
    def observed_sha(raw):
        hashed.append(raw)
        return original_sha(raw)
    host.sha256_hex = observed_sha
    try:
        witness = host._capture_completion_values(attempt_id,request,capture)
    finally:host.sha256_hex = original_sha
    assert len(hashed) == 2 and hashed[0] is request and hashed[1] is capture
    assert witness == capture_replay._capture_completion_values(root,attempt_id,request,capture)
    assert json.loads(witness) == {'schema_version':1,'kind':'malicious_capture_commit','id':attempt_id,
        'body':{'request_sha256':original_sha(request),'capture_sha256':original_sha(capture)}}
    assert len(witness) <= 512 and witness.endswith(b'\n')
    assert host._capture_completion_values(attempt_id,request+b'x',capture) != witness
    assert host._capture_completion_values(attempt_id,request,capture+b'x') != witness
    print(json.dumps({'completion_constructor':attempt_id,'request_hash_bytes':len(request),
        'capture_hash_bytes':len(capture),'witness_bytes':len(witness),
        'canonical_processing_ceiling':4*len(witness)},sort_keys=True))
for invalid in [('bad id',request,b'{}'),('a'*129,request,b'{}'),
                ('attempt.completion',None,b'{}'),('attempt.completion',request,None),
                ('attempt.completion',request,b'x'*(1024*1024+1))]:
    for build in (lambda:host._capture_completion_values(*invalid),
                  lambda:capture_replay._capture_completion_values(root,*invalid)):
        try:build()
        except Exception as error:assert type(error).__name__ == 'Refusal'
        else:raise AssertionError('invalid completion constructor input')
print('ok shared host/offline completion constructor; exact original bytes, bounded canonical witness')
if sys.platform in {'darwin','linux'}:
    with tempfile.TemporaryDirectory(prefix='ystack-capture-publication-') as temporary:
        publication_root = Path(temporary)
        publication_root.chmod(0o750)
        root_fd = os.open(publication_root,os.O_RDONLY|os.O_DIRECTORY)
        try:
            export = host.frame_write([(b'stdout',b''),(b'stderr',b'')])
            export += bytes(consumer.EXPORT_LIMIT-len(export))
            export_sha = host.sha256_hex(export)
            process_row = {'site':'run_vm.export-read','ordinal':0,'return':len(export),'errno':None,
                'bytes':{'role':'sandbox-export-capture-bytes','size_bytes':len(export),'sha256':export_sha},
                'timeout':None}
            publication_group = {'host':{'process':[process_row],'driver_rest':[],'signals':[]}}
            publication_work, export_work = {}, {}
            witness = host._publish_capture(root_fd,os.getuid(),os.getgid(),'attempt.publication',request,
                publication_group,True,export,export_sha,export_work,publication_work)
            directory = publication_root/'.capture-attempt.publication'
            assert {p.name for p in directory.iterdir()} == {'capture.json','sandbox-export.bin','complete.json'}
            captured = host._capture_values('attempt.publication',request,publication_group,True)
            assert (directory/'capture.json').read_bytes() == captured
            assert (directory/'complete.json').read_bytes() == witness
            assert witness == capture_replay._capture_completion_values(root,'attempt.publication',request,captured)
            assert (directory/'sandbox-export.bin').stat().st_size == len(export)
            assert all(p.stat().st_mode & 0o777 == 0o440 for p in directory.iterdir())
            assert directory.stat().st_mode & 0o777 == 0o750
            assert publication_work['files'] == 3
            assert publication_work['physical_bytes'] == publication_work['write_bytes'] == len(export)+len(captured)+len(witness)
            assert export_work == {key:len(export) for key in ('controlled_copy','controlled_write','controlled_readback')}
            renames = [row for row in publication_work['operations'] if row['site'] in {'renameatx_np','renameat2'}]
            assert len(renames)==2 and all(row['return']==0 for row in renames)
            old_inode = directory.stat().st_ino
            collision_work = {}
            try:host._publish_capture(root_fd,os.getuid(),os.getgid(),'attempt.publication',request,
                publication_group,True,export,export_sha,{},collision_work)
            except host.Refusal:pass
            else:raise AssertionError('published capture replaced')
            assert directory.stat().st_ino == old_inode and (directory/'complete.json').read_bytes() == witness
            pending = publication_root/'.capture-attempt.publication.pending'
            assert pending.is_dir() and not (pending/'complete.json').exists()
            assert {p.name for p in pending.iterdir()} == {'capture.json','sandbox-export.bin'}
            print(json.dumps({'Darwin_publication_work':publication_work,
                'retained_collision_work':collision_work,'retained_collision_export_bytes':
                (pending/'sandbox-export.bin').stat().st_size},sort_keys=True))
            directory_fd = os.open(directory,os.O_RDONLY|os.O_DIRECTORY)
            try:
                existing = directory/'complete.json'
                late = directory/'.completion.pending'
                late.write_bytes(b'ordinary collision');late.chmod(0o440)
                before_names = {p.name:(p.stat().st_ino,p.read_bytes()) for p in (existing,late)}
                completion_collision = {}
                try:host._capture_rename_noreplace(directory_fd,b'.completion.pending',b'complete.json',completion_collision)
                except host.Refusal:pass
                else:raise AssertionError('completion replaced')
                assert {p.name:(p.stat().st_ino,p.read_bytes()) for p in (existing,late)} == before_names
                assert completion_collision['operations'][-1]['return'] != 0
                assert completion_collision['operations'][-1]['errno'] > 0
                print(json.dumps({'actual_completion_collision':completion_collision},sort_keys=True))
            finally:os.close(directory_fd)
            original_sync = host._capture_sync
            failure_work = {}
            def fail_after_directory_rename(fd,work,site):
                if site == 'published-directory-fsync':
                    original_fsync = host.os.fsync
                    def fail_fsync(_):raise OSError(5,'ordinary fixture sync failure')
                    try:
                        host.os.fsync = fail_fsync
                        return original_sync(fd,work,site)
                    finally:host.os.fsync = original_fsync
                return original_sync(fd,work,site)
            try:
                host._capture_sync = fail_after_directory_rename
                try:host._publish_capture(root_fd,os.getuid(),os.getgid(),'attempt.syncfailure',request,
                    group,True,work=failure_work)
                except OSError as error:assert error.errno==5
                else:raise AssertionError('completion before published sync')
            finally:host._capture_sync = original_sync
            failed = publication_root/'.capture-attempt.syncfailure'
            assert failed.is_dir() and {p.name for p in failed.iterdir()} == {'capture.json'}
            assert (failed/'capture.json').read_bytes() == host._capture_values('attempt.syncfailure',request,group,True)
            assert any(row['site']=='published-directory-fsync' and row['errno']==5
                       for row in failure_work['operations'])
            print(json.dumps({'simulated_sync_failure_actual_work':failure_work},sort_keys=True))
            overflow_work = {}
            overflow_group = {'host':{'process':[{'bytes':'x'*(1024*1024)}]}}
            try:host._publish_capture(root_fd,os.getuid(),os.getgid(),'attempt.overflow',request,
                overflow_group,True,work=overflow_work)
            except host.Refusal:pass
            else:raise AssertionError('capture overflow published')
            assert not (publication_root/'.capture-attempt.overflow.pending').exists()
            assert not (publication_root/'.capture-attempt.overflow').exists()
            assert overflow_work['read_bytes'] > len(request)
            print(json.dumps({'overflow_pre_refusal_work':overflow_work},sort_keys=True))
            for size in (512,513):
                bounded = publication_root/('.capture-attempt.readbound'+str(size))
                bounded.mkdir(mode=0o750);bounded.chmod(0o750)
                bounded_fd = os.open(bounded,os.O_RDONLY|os.O_DIRECTORY)
                bounded_work = {}
                expected_bytes = b'x'*size
                try:
                    host.write_excl(bounded_fd,'.completion.pending',expected_bytes,os.getuid(),os.getgid(),
                                    capture_work=bounded_work)
                    try:host._capture_completion_readback(bounded_fd,os.getuid(),os.getgid(),expected_bytes,bounded_work)
                    except host.Refusal:assert size==513
                    else:assert size==512
                    assert bounded_work.get('read_bytes',0) == (3*size if size==512 else 0)
                    assert (bounded/'.completion.pending').read_bytes()==expected_bytes
                    print(json.dumps({'witness_readback_byte_boundary_only':size,
                        'malformed_bytes_not_a_valid_completion':True,'actual_work':bounded_work},sort_keys=True))
                finally:os.close(bounded_fd)
            old_process,old_clocks = host._capture_process,host._capture_clocks
            try:
                for failed_sync in (False,True):
                    io_attempt = 'attempt.nativeio.'+str(int(failed_sync))
                    io_fd = host.mkdir_excl(root_fd,io_attempt,os.getuid(),os.getgid())
                    host.write_payload(io_fd,os.getuid(),os.getgid(),[(b'stdout',b''),(b'stderr',b'')])
                    native_receipt = host.canonical({'ordinary':'native writer byte control'})
                    host._capture_process = {'rows':[],'ordinals':{},'bytes':0,'complete':True,
                        'driver_rest':[],'signals':[],'request_raw':request,'attempt_id':io_attempt}
                    host._capture_clocks = {'wall':[],'monotonic':[],'complete':True}
                    try:
                        if failed_sync:host._capture_sync=fail_after_directory_rename
                        assert host.write_receipt_file(root_fd,io_fd,os.getuid(),os.getgid(),native_receipt) is None
                    finally:host._capture_sync=original_sync
                    native_path = publication_root/io_attempt
                    assert {p.name for p in native_path.iterdir()} == {'receipt.json','payload'}
                    assert (native_path/'receipt.json').read_bytes()==native_receipt
                    captured_path=publication_root/('.capture-'+io_attempt)
                    io_work=host._capture_process['publication_work']
                    assert io_work['complete'] is (not failed_sync)
                    assert (captured_path/'capture.json').is_file()
                    assert (captured_path/'complete.json').exists() is (not failed_sync)
                    if failed_sync:assert io_work['failure']['errno']==5
                    print(json.dumps({'actual_native_receipt_writer_capture_failure':failed_sync,
                        'receipt_payload_bytes_and_original_return_unchanged':True,
                        'receipt_schema_or_native_qualification_not_claimed':True,'actual_work':io_work},sort_keys=True))
                io_attempt='attempt.nativeio.originalerror'
                io_fd=host.mkdir_excl(root_fd,io_attempt,os.getuid(),os.getgid())
                host._capture_process=dict(host._capture_process,attempt_id=io_attempt)
                original_write=host.write_excl
                def native_write_failure(parent,name,*args,**kwargs):
                    if name=='receipt.json':raise OSError(5,'ordinary native write failure')
                    return original_write(parent,name,*args,**kwargs)
                try:
                    host.write_excl=native_write_failure
                    try:host.write_receipt_file(root_fd,io_fd,os.getuid(),os.getgid(),native_receipt)
                    except OSError as error:
                        assert error.errno==5
                        print(json.dumps({'simulated_native_write_errno_observed':error.errno,
                                          'native_error_not_swallowed':True},sort_keys=True))
                    else:raise AssertionError('native write failure swallowed')
                finally:host.write_excl=original_write
                assert not (publication_root/('.capture-'+io_attempt)).exists()
                for primary_failure in (False,True):
                    failed_id='attempt.close.'+str(int(primary_failure))
                    failed_fd=host.mkdir_excl(root_fd,failed_id,os.getuid(),os.getgid())
                    host.write_payload(failed_fd,os.getuid(),os.getgid(),[(b'stdout',b''),(b'stderr',b'')])
                    host._capture_process={'rows':[],'ordinals':{},'bytes':0,'complete':True,
                        'driver_rest':[],'signals':[],'request_raw':request,'attempt_id':failed_id}
                    actual_open,actual_close,actual_chown=host.os.open,host.os.close,host.os.fchown
                    target=[None]
                    def opening(name,*args,**kwargs):
                        fd=actual_open(name,*args,**kwargs)
                        if name=='capture.json':target[0]=fd
                        return fd
                    def chowning(fd,*args):
                        if fd==target[0] and primary_failure:raise OSError(5,'ordinary capture chown failure')
                        return actual_chown(fd,*args)
                    def closing(fd):
                        result=actual_close(fd)
                        if fd==target[0]:
                            target[0]=None
                            raise OSError(9,'ordinary capture secondary close failure')
                        return result
                    try:
                        host.os.open=opening;host.os.close=closing;host.os.fchown=chowning
                        assert host.write_receipt_file(root_fd,failed_fd,os.getuid(),os.getgid(),native_receipt) is None
                    finally:host.os.open=actual_open;host.os.close=actual_close;host.os.fchown=actual_chown
                    failed_work=host._capture_process['publication_work']
                    assert failed_work['complete'] is False
                    assert failed_work['failure']['errno']==(5 if primary_failure else 9)
                    assert any(row['site']=='close' and row['errno']==9 for row in failed_work['operations'])
                    if primary_failure:assert any(row['site']=='chown' and row['errno']==5 for row in failed_work['operations'])
                    retained=publication_root/('.capture-'+failed_id+'.pending')/'capture.json'
                    retained_bytes=retained.read_bytes()
                    assert retained_bytes==host._capture_values(failed_id,request,{
                        'host':{'process':[],'driver_rest':[],'signals':[]},
                        'clocks':{key:host._capture_clocks[key] for key in ('wall','monotonic')}},True)
                    assert (publication_root/failed_id/'receipt.json').read_bytes()==native_receipt
                    assert {p.name for p in (publication_root/failed_id).iterdir()}=={'receipt.json','payload'}
                    assert not (retained.parent/'complete.json').exists()
                    print(json.dumps({'actual_capture_primary_and_close_failure':primary_failure,
                        'retained_capture_hex':retained_bytes.hex(),'retained_mode':retained.stat().st_mode & 0o777,
                        'native_result_and_receipt_unchanged':True,'actual_work':failed_work},sort_keys=True))
                host._capture_process=None
                for operation,role in (('kill-register-read','kill'),('coverage-read','coverage')):
                    source_attempt='attempt.sourceio.'+role
                    source_fd=host.mkdir_excl(root_fd,source_attempt,os.getuid(),os.getgid())
                    host.write_payload(source_fd,os.getuid(),os.getgid(),[(b'stdout',b''),(b'stderr',b'')])
                    host.write_receipt_file(root_fd,source_fd,os.getuid(),os.getgid(),native_receipt)
                    meta={'family':'fixture','page_index':0,'response_status':200,'input_cursor':None,'output_cursor':None}
                    records=[(b'capture.json',host.canonical({'pages':[meta]})),(b'raw/0000',b'{}\n')]
                    source_group,source_complete=host._source_capture_group_values(source_attempt,request,records,
                        [b'{}\n'],host._capture_clocks,True,operation)
                    source_work={}
                    host._write_capture_file(root_fd,os.getuid(),os.getgid(),source_attempt,request,
                        source_group,source_complete,work=source_work)
                    source_directory=publication_root/('.capture-'+source_attempt)
                    assert source_work['complete'] is True
                    assert {p.name for p in source_directory.iterdir()}=={'capture.json','complete.json'}
                    assert {p.name for p in (publication_root/source_attempt).iterdir()}=={'receipt.json','payload'}
                    print(json.dumps({'actual_source_writer_adapter':operation,'synthetic_pages_not_full_collector_route':True,
                        'actual_work':source_work},sort_keys=True))
                original_installation=host._CoverageInstallation
                original_collector=host._coverage_collector
                original_store=host.check_store_root
                original_stdin=host.sys.stdin
                try:
                    for failed_sync in (False,True):
                        outer_id='attempt.outer.'+str(int(failed_sync))
                        work_path=publication_root/('work-'+str(int(failed_sync)))
                        work_path.mkdir(mode=0o700)
                        outer_request=host.canonical({'id':outer_id,'body':{
                            'nonce':('01' if failed_sync else '02')*32,
                            'source_package_ref':'package','source_accepted_set_ref':'accepted'}})
                        manifest=host.canonical({'pages':[meta]})
                        observation=b'{}\n'
                        receipt=host.canonical({'ordinary':'outer source native receipt'})
                        calls=[]
                        normalizer=types.SimpleNamespace(DOCUMENT_LIMIT=1024*1024,
                            FAMILIES=('fixture',),PAGE_LIMIT=128,RAW_LIMIT=64*1024*1024,
                            request=json.loads,doc_ref=lambda raw:raw.decode(),
                            captured=lambda records,raw:(manifest,[b'{}\n']),
                            normalize=lambda *args:observation,
                            _source_values=lambda *args:(manifest,[b'{}\n'],observation,receipt),
                            receipt=lambda *args:calls.append('receipt'))
                        class Installation:
                            n=normalizer
                            host={'principal_uid':os.getuid(),'consumer_gid':os.getgid(),
                                  'store_root':str(publication_root.resolve()),'work_root':str(work_path.resolve())}
                            package_raw=b'package'
                            accepted_raw=b'accepted'
                            source_bytes={}
                            identity={}
                            def __init__(self,operation):assert operation=='coverage-read'
                            def owned_directory(self,path,mode):
                                assert (os.stat(path).st_mode & 0o777)==mode
                                return os.open(path,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
                            def recheck(self):calls.append('recheck')
                            def close(self):calls.append('close')
                        host._CoverageInstallation=Installation
                        host._coverage_collector=lambda *args:records
                        host.check_store_root=lambda path,*args:os.open(path,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
                        host.sys.stdin=types.SimpleNamespace(buffer=__import__('io').BytesIO(outer_request))
                        if failed_sync:host._capture_sync=fail_after_directory_rename
                        try:assert host.run_coverage_read(['coverage-read']) is None
                        finally:host._capture_sync=original_sync
                        actual_work=host._capture_clocks['publication_work']
                        assert actual_work['complete'] is (not failed_sync)
                        assert actual_work['operations'] and actual_work['write_bytes']>0
                        if failed_sync:assert actual_work['failure']['errno']==5
                        assert calls.count('receipt')==1 and calls[-1]=='close'
                        native_path=publication_root/outer_id
                        assert {p.name for p in native_path.iterdir()}=={'receipt.json','payload'}
                        assert (native_path/'receipt.json').read_bytes()==receipt
                        assert (native_path/'payload/request.json').read_bytes()==outer_request
                        assert (native_path/'payload/raw/0000').read_bytes()==b'{}\n'
                        source_config={'principal_uid':os.getuid(),'consumer_gid':os.getgid(),
                            'store_id':'store.outer','environment_id':'environment.outer',
                            'store_root':str(publication_root.resolve()),'work_root':str(work_path.resolve()),
                            'runtime':{'driver':'/ordinary/driver','vfkit':'/ordinary/vfkit'},
                            'installed_files':{key:'/ordinary/installed/'+key for key in consumer.INSTALLED_SOURCES},
                            'identity_paths':{key:['/ordinary/dyld'] if key=='dyld_cache_files' else '/ordinary/identity/'+key
                                for key in consumer.IDENTITY_KEYS}}
                        source_config_raw=consumer.canonical({'schema_version':1,'kind':'sandbox_host_config',
                            'id':'host.outer','body':source_config})
                        source_anchor=types.SimpleNamespace(config=source_config,config_raw=source_config_raw,
                            resolver=None,recheck=lambda *args:None,private_observations={},
                            recording_work={},identity_context={'uid':os.getuid(),'euid':os.geteuid(),
                                'gid':os.getgid(),'egid':os.getegid(),'groups':os.getgroups(),
                                'platform':sys.platform,'uuid_replies':None,'group_replies':None},
                            capture_completion_owner=types.SimpleNamespace(construct=lambda anchor,attempt_id,request,capture:
                                host._capture_completion_values(attempt_id,request,capture),
                                authenticate=lambda anchor:None,transfer=lambda work,case:None))
                        source_configuration=types.SimpleNamespace(normalizer=normalizer,identity={},recheck=lambda *args:None)
                        original_source_acl=consumer._acl_state
                        consumer._acl_state=lambda *args:([],None) if sys.platform=='darwin' else (None,None)
                        native_source=None
                        try:
                            native_source=consumer._HeldCoverageRead(source_anchor,source_configuration,outer_request)
                            assert native_source.snapshots['receipt.json']==receipt
                            assert native_source.snapshots['payload/request.json']==outer_request
                            assert 'capture.json' not in native_source.snapshots
                            assert native_source.recheck() is None
                            if failed_sync:
                                assert source_anchor.private_observations['unusable'] is True
                                assert not hasattr(native_source,'capture')
                            else:
                                assert native_source.capture.snapshots['complete.json']==host._capture_completion_values(
                                    outer_id,outer_request,native_source.capture.snapshots['capture.json'])
                                assert capture_replay._origin_values(root,native_source.snapshots,native_source.storage_rows,
                                    {'attempt_id':outer_id,'platform':sys.platform},{'host-config.json':source_config_raw},
                                    capture_files=native_source.capture.snapshots,
                                    capture_storage_rows=native_source.capture.storage_rows)==native_source.capture_origin
                                private_sources=work_path/'source-recorder';private_sources.mkdir(mode=0o700)
                                for slot in (4095,4094):(private_sources/('gate-%04d'%slot)).mkdir(mode=0o700)
                                reader=object.__new__(scope_capture_reader._Reader)
                                reader.captures=private_sources.resolve();reader.source_capture_ordinal=0
                                reader.source_capture_work=[]
                                reader.inputs=[];reader.darwin=None
                                acquisitions=[]
                                reader.store_session=types.SimpleNamespace(acquire=lambda item:acquisitions.append(item.attempt_id))
                                owned=scope_capture_reader._Owned(reader)
                                owned.append(native_source)
                                source_again=consumer._HeldCoverageRead(source_anchor,source_configuration,outer_request)
                                try:
                                    owned.append(source_again)
                                    for ordinal,slot in enumerate((4095,4094)):
                                        copied_source=private_sources/('gate-%04d'%slot)/('source-%04d'%ordinal)
                                        assert {p.name for p in copied_source.iterdir()}=={
                                            'capture.json','complete.json','origin-observation.json','consumer-observations.json'}
                                        assert (copied_source/'capture.json').read_bytes()==native_source.capture.snapshots['capture.json']
                                        assert (copied_source/'complete.json').read_bytes()==native_source.capture.snapshots['complete.json']
                                        assert (copied_source/'origin-observation.json').read_bytes()==native_source.capture_origin
                                        assert all(p.stat().st_mode & 0o777==0o400 for p in copied_source.iterdir())
                                    assert acquisitions==[outer_id,outer_id]
                                    assert source_anchor.recording_work['files']==8
                                    assert len(source_anchor.recording_work['cases'])==1
                                    assert native_source.recheck() is None and source_again.recheck() is None
                                    final_owner_module=load('source_final_owner',root/'shadow/v1/enforced-reproduction.py')
                                    installed_owner=private_sources/'installed-owner';installed_owner.mkdir(mode=0o700)
                                    installed_path=installed_owner/'host-supervisor.py'
                                    installed_bytes=(root/'sandbox/v1/host-supervisor.py').read_bytes()
                                    installed_path.write_bytes(installed_bytes);installed_path.chmod(0o440)
                                    final_owner_module.c.ANCHOR=str(installed_owner.resolve())
                                    installed_hold=final_owner_module.c._open_held(str(installed_path.resolve()),False,
                                        lambda *args:True,'E_STORE')
                                    final_owner=final_owner_module._load_capture_completion_owner()
                                    assert final_owner is not None,final_owner_module._CAPTURE_OWNER_WORK
                                    try:
                                        source_anchor.held=[installed_hold]
                                        source_anchor.capture_completion_owner=final_owner
                                        final_owner.authenticate(source_anchor)
                                        reader.anchor=source_anchor;reader.enforced=final_owner_module
                                        reader.seal_source_captures()
                                        assert source_anchor.private_observations['recording_sealed'] is True
                                        assert final_owner.work['transferred_read_bytes']==final_owner.work['read_bytes']
                                        assert all(work['transferred_read_bytes']==work['read_bytes'] for work in reader.source_capture_work)
                                        assert len(source_anchor.recording_work['cases'])==1
                                    finally:
                                        installed_hold.close();final_owner_module._close_capture_completion_owner(final_owner)
                                        if sys.modules.get(final_owner.name) is final_owner.module:del sys.modules[final_owner.name]
                                    print(json.dumps({'actual_source_owned_append_and_private_copy':True,
                                        'two_reacquisitions_share_one_counter':True,
                                        'scope_session_and_completion_startup_are_fixture_doubles':True,
                                        'actual_final_source_owner_and_tail_transfer':True,
                                        'additional_fixture_installed_owner_copy_bytes':len(installed_bytes),
                                        'actual_work':source_anchor.recording_work},sort_keys=True))
                                finally:source_again.close()
                        finally:
                            if native_source is not None:native_source.close()
                            consumer._acl_state=original_source_acl
                        print(json.dumps({'actual_run_coverage_read':True,'capture_failure':failed_sync,
                            'normalization_installation_store_admission_and_consumer_acl_are_fixture_doubles':True,
                            'actual_payload_receipt_publisher_and_return_preserved':True,
                            'actual_work':actual_work},sort_keys=True))
                finally:
                    host._CoverageInstallation=original_installation
                    host._coverage_collector=original_collector
                    host.check_store_root=original_store
                    host.sys.stdin=original_stdin
            finally:host._capture_process,host._capture_clocks=old_process,old_clocks
        finally:os.close(root_fd)
    print('ok ordinary full export publication/completion, no-replace collision and pre-completion failure - '+sys.platform+'; not native qualification')
else:
    print('NOTRUN capture publication mechanism: unsupported ordinary host')
enforced=load('capture_enforced_owner',root/'shadow/v1/enforced-reproduction.py')
completion_owner=enforced._load_capture_completion_owner()
assert completion_owner is not None, enforced._CAPTURE_OWNER_WORK
assert completion_owner.loaded is completion_owner.source.raw
assert completion_owner.module.__loader__ is completion_owner
assert completion_owner.module.__spec__.origin==str(root/'sandbox/v1/host-supervisor.py')
original_anchor_path=enforced.c.ANCHOR
try:
    with tempfile.TemporaryDirectory(prefix='ystack-completion-owner-') as temporary:
        fixed=Path(temporary).resolve()
        installed=fixed/'host-supervisor.py'
        installed.write_bytes(completion_owner.source.raw)
        installed.chmod(0o440)
        enforced.c.ANCHOR=str(fixed)
        held=enforced.c._open_held(str(installed),False,lambda *args:True,'E_STORE')
        try:
            anchor=types.SimpleNamespace(held=[held],private_observations={})
            original_active=enforced.CancellationSignals.active
            enforced.CancellationSignals.active=types.SimpleNamespace(
                admission=types.SimpleNamespace(capture_owner=completion_owner))
            try:enforced._bind_capture_completion_owner(anchor)
            finally:enforced.CancellationSignals.active=original_active
            assert anchor.capture_completion_owner is completion_owner and not anchor.private_observations
            witness=completion_owner.construct(anchor,'attempt.owner',request,capture)
            assert witness==host._capture_completion_values('attempt.owner',request,capture)
            assert completion_owner.work['installed_comparison_bytes']>=2*len(completion_owner.source.raw)
            total={};case=enforced.c._capture_work_values(total,'ordinary')
            completion_owner.transfer(total,case)
            charged=total['read_bytes']
            assert charged==completion_owner.work['read_bytes'] and case['read_bytes']==charged
            completion_owner.transfer(total,case)
            assert total['read_bytes']==charged
            installed.chmod(0o640)
            installed.write_bytes(b'changed installed owner\n')
            installed.chmod(0o440)
            try:completion_owner.authenticate(anchor)
            except enforced.c.Refusal:pass
            else:raise AssertionError('installed owner drift admitted')
            enforced.CancellationSignals.active=types.SimpleNamespace(
                admission=types.SimpleNamespace(capture_owner=completion_owner))
            try:assert enforced._bind_capture_completion_owner(anchor) is None
            finally:enforced.CancellationSignals.active=original_active
            assert anchor.private_observations['unusable'] is True
            assert anchor.private_observations['completion_owner_failure']['category']=='Refusal'
            print(json.dumps({'startup_same_byte_loader_and_installed_owner':True,
                'ordinary_private_installed_fixture_not_real_anchor':True,
                'actual_owner_work':completion_owner.work,'transferred_work':total},sort_keys=True))
        finally:held.close()
finally:
    enforced.c.ANCHOR=original_anchor_path
    enforced._close_capture_completion_owner(completion_owner)
    if sys.modules.get(completion_owner.name) is completion_owner.module:del sys.modules[completion_owner.name]
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
    anchor = types.SimpleNamespace(config=config,config_raw=config_raw,resolver=None,recheck=lambda *_:None,recording_work={})
    anchor.identity_context = {'uid':os.getuid(),'euid':os.geteuid(),'gid':os.getgid(),
        'egid':os.getegid(),'groups':os.getgroups(),'platform':sys.platform,
        'uuid_replies':None,'group_replies':None}
    anchor.private_observations = {}
    anchor.capture_completion_owner=types.SimpleNamespace(construct=lambda anchor,attempt_id,request,capture:
        host._capture_completion_values(attempt_id,request,capture))
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
            capture_values={}
            if complete is not None:
                capture_values['capture.json']=host._capture_values(attempt_id,request,group,complete)
                capture_values['complete.json']=host._capture_completion_values(attempt_id,request,capture_values['capture.json'])
                capture_path=store/('.capture-'+attempt_id);capture_path.mkdir(mode=0o750);capture_path.chmod(0o750)
                for name,raw in capture_values.items():
                    path=capture_path/name;path.write_bytes(raw);path.chmod(0o440)
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
                    held.capture=consumer._HeldCaptureRead(held,request)
                    assert held.capture.snapshots==capture_values
                    storage_mutations = [
                        ('missing',lambda rows:rows[0].pop('name')),
                        ('extra',lambda rows:rows[0].update(extra=True)),
                        ('wrong-name-type',lambda rows:rows[0].update(name=[])),
                        ('nonhex-name',lambda rows:rows[0].update(name='gg')),
                        ('odd-name',lambda rows:rows[0].update(name='2')),
                        ('uppercase-name',lambda rows:rows[0].update(name='2E')),
                        ('wrong-stat-type',lambda rows:rows[0]['before'].update(dev=True)),
                        ('read-error',lambda rows:rows[0].update(read_error=5)),
                        ('wrong-list-type',lambda rows:rows[1].update(directory_names={})),
                        ('wrong-entry-type',lambda rows:rows[1].update(directory_names=[[]])),
                        ('nonhex-entry',lambda rows:rows[1].update(directory_names=['gg'])),
                        ('over-entry-count',lambda rows:rows[1].update(directory_names=['00']*65537))]
                    for label,mutate in storage_mutations:
                        changed = copy.deepcopy(held.storage_rows);mutate(changed)
                        refuses(lambda:consumer._origin_values(held.snapshots,changed,
                            {'attempt_id':attempt_id,'platform':sys.platform},
                            {'host-config.json':config_raw}),'storage-shape-'+label)
                    assert consumer._capture_for_replay(held.capture.snapshots,attempt_id,request) == group
                    print('ok capture envelope and actual held inventory - new; not a complete case replay')
                    for label,change in [('extra-key',lambda v:v.update(extra=True)),
                            ('wrong-attempt',lambda v:v.update(id='other')),
                            ('wrong-request',lambda v:v['body'].update(request_sha256='a'*64)),
                            ('wrong-complete-type',lambda v:v['body'].update(complete=1))]:
                        changed = json.loads(capture_values['capture.json']);change(changed)
                        refuses(lambda:consumer._capture_envelope(consumer.canonical(changed),attempt_id,
                            host.sha256_hex(request)),label)
                    path = capture_path/'capture.json';path.chmod(0o640)
                    path.write_bytes(capture_values['capture.json'].replace(b'"complete":true',b'"complete":false'))
                    path.chmod(0o440)
                    refuses(held.capture.recheck,'changed-after-held-read')
                    assert held.recheck() is None and anchor.private_observations['unusable']
                    anchor.private_observations.clear()
                else:
                    refuses(lambda:consumer._HeldCaptureRead(held,request),
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
        originals = area/'originals';originals.mkdir(mode=0o700)
        private = area/'private-recorder';private.mkdir(mode=0o700);private.chmod(0o700)
        failed_private = area/'failed-private-recorder';failed_private.mkdir(mode=0o700);failed_private.chmod(0o700)
        seed_exports = area/'seed-exports';seed_exports.mkdir(mode=0o700)
        private_held = consumer._open_held(str(private),True,
            consumer._store_rule(os.getuid(),os.getgid(),0o700,True), 'E_STORE')
        failed_private_held = consumer._open_held(str(failed_private),True,
            consumer._store_rule(os.getuid(),os.getgid(),0o700,True), 'E_STORE')
        private_work = {}
        recording_pair = []
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
            outer = {'schema_version':1,'kind':'shadow_enforced_request' if launch == 'reproduction'
                else 'shadow_write_request','id':attempt_id,'body':{'attempt_id':attempt_id}}
            attempt_values = {'attempt_id':attempt_id,'attempt_number':1}
            launch_body = {'attempt':attempt_values,'store_id':config['store_id'],
                           'control':{'ordinary':'control'},'subject':{'ordinary':'subject'}}
            request = host.canonical({'schema_version':1,'kind':'sandbox_launch_request',
                                      'id':attempt_id,'body':launch_body})
            bound_attempt = attempt_values | {'launch_request_sha256':host.sha256_hex(request)}
            expectation = host.canonical({'schema_version':1,'kind':'sandbox_receipt_expectation',
                'id':attempt_id,'body':launch_body | {'attempt':bound_attempt}})
            receipt = host.canonical({'schema_version':1,'kind':'sandbox_enforcement_receipt',
                'id':'receipt.'+host.sha256_hex(request),'body':{'attempt':bound_attempt,
                'control':launch_body['control'],'subject':launch_body['subject'],
                'origin':{'store_id':config['store_id']}}})
            host._capture_process = {'rows':[],'ordinals':{},'bytes':0,'complete':True,
                'driver_rest':[],'signals':[],'request_raw':request,'attempt_id':attempt_id}
            host._capture_clocks = {'wall':[],'monotonic':[],'complete':True}
            original = originals/(launch+'.bin')
            assert original.write_bytes(export) == len(export)
            with original.open('rb') as stream:export = host._read_export_value(stream)
            assert host.frame_read(export) == [(b'stdout',b''),(b'stderr',b'')]
            reference = host._capture_process['rows'][0]['bytes']
            export_group = {'host':{'process':host._capture_process['rows'],
                'driver_rest':[],'signals':[]},'clocks':{'wall':[],'monotonic':[]}}
            values = {'receipt.json':receipt,
                'payload/stdout':b'','payload/stderr':b'',
                'payload/evidence-manifest.json':host.empty_evidence_manifest()[0],
                'capture.json':host._capture_values(attempt_id,request,export_group,True),
                'sandbox-export.bin':export}
            capture_values={name:values.pop(name) for name in ('capture.json','sandbox-export.bin')}
            capture_values['complete.json']=host._capture_completion_values(attempt_id,request,capture_values['capture.json'])
            export_anchor = consumer.Anchor(config,config_raw,[],{},('',[]),('',[]),None,
                                            identity_context=anchor.identity_context)
            export_anchor.capture_completion_owner=types.SimpleNamespace(
                construct=lambda anchor,attempt_id,request,capture:host._capture_completion_values(attempt_id,request,capture),
                authenticate=lambda anchor:None,transfer=lambda work,case:None)
            for name,raw in values.items():
                if name in {'receipt.json','capture.json','sandbox-export.bin'}:continue
                path = attempt/name;path.write_bytes(raw);path.chmod(0o440)
            store_fd = os.open(store,os.O_RDONLY | os.O_DIRECTORY)
            try:
                attempt_fd = os.open(attempt,os.O_RDONLY | os.O_DIRECTORY)
                host.write_receipt_file(store_fd,attempt_fd,os.getuid(),os.getgid(),receipt)
            finally:os.close(store_fd)
            assert host._capture_process['complete'] is True
            host_work = host._capture_process['export_work']
            assert all(host_work[key] == len(export) for key in
                ('original_read','original_sha','controlled_copy','controlled_write','controlled_readback'))
            assert host_work['frame_read_calls'] == 1
            assert 2*len(export) <= host_work['frame_read_bytes'] <= 2*len(export)+512*1024
            selected_owner_module=load('selected_owner_'+launch,root/'shadow/v1/enforced-reproduction.py')
            selected_owner=selected_owner_module._load_capture_completion_owner()
            assert selected_owner is not None,selected_owner_module._CAPTURE_OWNER_WORK
            owner_install=originals/('installed-owner-'+launch);owner_install.mkdir(mode=0o700)
            owner_path=owner_install/'host-supervisor.py'
            owner_path.write_bytes(selected_owner.source.raw);owner_path.chmod(0o440)
            selected_owner_module.c.ANCHOR=str(owner_install.resolve())
            installed_owner_hold=selected_owner_module.c._open_held(str(owner_path.resolve()),False,lambda *args:True,'E_STORE')
            export_anchor.held=[installed_owner_hold]
            export_anchor.recording_work=private_work
            selected_active=selected_owner_module.CancellationSignals.active
            selected_owner_module.CancellationSignals.active=types.SimpleNamespace(
                admission=types.SimpleNamespace(capture_owner=selected_owner))
            try:selected_owner_module._bind_capture_completion_owner(export_anchor)
            finally:selected_owner_module.CancellationSignals.active=selected_active
            assert export_anchor.capture_completion_owner is selected_owner and not export_anchor.private_observations
            held = consumer._HeldStoreRead(export_anchor,attempt_id)
            try:
                acquired = export_anchor.private_observations['storage_reads'][-1]
                assert acquired['error'] is None and len(acquired['held']) == len(held.held)
                for actual,recorded in zip(held.held,acquired['held']):
                    assert bytes.fromhex(recorded['path']) == os.fsencode(actual.path)
                    assert len(recorded['components']) == len(actual.components)
                    assert recorded['components'][0]['name'] is None
                    for component,row in zip(actual.components,recorded['components']):
                        assert row['before'] == consumer._stat_values(component.before)
                        assert row['after'] == row['named_after'] == consumer._stat_values(os.fstat(component.fd))
                    assert 'access_acl' in recorded['components'][-1]
                projected = (held.record_reproduction if launch == 'reproduction' else held.record_write)(
                    host.canonical(outer),request,expectation)
                assert projected is not None
                for mismatch in ('owner','anchor'):
                    saved_owner=export_anchor.capture_completion_owner;saved_anchor=held.anchor
                    if mismatch=='owner':export_anchor.capture_completion_owner=object()
                    else:held.anchor=copy.copy(export_anchor)
                    try:refuses(lambda:held.copy_capture(private_held,request,launch,{}),'cross-'+mismatch+'-capture-copy')
                    finally:export_anchor.capture_completion_owner=saved_owner;held.anchor=saved_anchor
                    assert not (private/launch).exists()
                snapshot = held.capture.snapshots['sandbox-export.bin']
                assert len(snapshot.chunks) == consumer.EXPORT_LIMIT//65536
                assert all(type(chunk) is bytes and len(chunk) == 65536 for chunk in snapshot.chunks)
                try: snapshot.chunks = ()
                except consumer.dataclasses.FrozenInstanceError: pass
                else: raise AssertionError('mutable export snapshot')
                assert spent('consumer.held-acquisition','calls') == 1
                assert spent('consumer.held-acquisition','read_bytes') == len(export)
                assert spent('consumer.independent-sha','calls') == 1
                assert spent('consumer.independent-sha','read_bytes') == len(export)
                assert held.snapshots == values and held.capture.snapshots == capture_values
                assert spent('consumer.whole-equality','calls') == 1
                assert spent('consumer.whole-equality','read_bytes') == 2*len(export)
                assert capture_replay._origin_values(root,held.snapshots,held.storage_rows,
                    {'attempt_id':attempt_id,'platform':sys.platform},
                    {'host-config.json':config_raw},capture_files=held.capture.snapshots,
                    capture_storage_rows=held.capture.storage_rows) == held.capture_origin
                assert spent('consumer.independent-sha','calls') == 1
                assert spent('consumer.independent-sha','read_bytes') == len(export)
                offline_work = sys.modules['malicious_origin_values']._export_work
                assert offline_work['consumer.independent-sha'] == {'calls':1,'read_bytes':len(export)}
                assert consumer._capture_for_replay(held.capture.snapshots,attempt_id,request) == export_group
                final_ref = consumer._capture_export_reference(projected,final=True)
                assert final_ref == reference | {'role':'sandbox-export-bytes','launch':launch}
                replay_projection = (capture_replay._reproduction_capture_values if launch == 'reproduction'
                                     else capture_replay._write_capture_values)
                rebuilt_capture,offline_projection = replay_projection(root,capture_values['capture.json'],
                    export_group,host.canonical(outer),request,expectation,receipt)
                assert rebuilt_capture == held.capture.snapshots['capture.json'] and offline_projection == projected
                def delete_call(function,attribute,replacement,namespace):
                    tree = ast.parse(textwrap.dedent(inspect.getsource(function)))
                    hits = []
                    class Delete(ast.NodeTransformer):
                        def visit_Call(self,node):
                            if (isinstance(node.func,ast.Name) and node.func.id == attribute
                                    or isinstance(node.func,ast.Attribute) and node.func.attr == attribute):
                                hits.append(1)
                                return ast.copy_location(ast.parse(replacement,mode='eval').body,node)
                            return self.generic_visit(node)
                    changed = Delete().visit(tree)
                    assert len(hits) == 1
                    space = dict(namespace)
                    exec(compile(ast.fix_missing_locations(changed),'<capture-call-deletion>','exec'),space)
                    return space[function.__name__]
                method = held.record_reproduction if launch == 'reproduction' else held.record_write
                original_method = consumer._HeldStoreRead._record_launch
                original_projection = capture_replay._capture_projection_values
                original_rebuild = consumer._capture_envelope_values
                original_values = consumer._launch_capture_values
                calls = []
                def observed_rebuild(*args):
                    calls.append(1)
                    return original_rebuild(*args)
                try:
                    consumer._capture_envelope_values = observed_rebuild
                    assert method(host.canonical(outer),request,expectation) == projected and len(calls) == 1
                    for control in ('production','offline','envelope'):
                        calls.clear()
                        if control == 'production':
                            consumer._HeldStoreRead._record_launch = delete_call(original_method,
                                '_launch_capture_values',
                                '_capture_envelope(self.capture.snapshots["capture.json"],self.attempt_id,digest(launch_raw),seed=True)',
                                consumer.__dict__)
                        elif control == 'offline':
                            capture_replay._capture_projection_values = delete_call(original_projection,
                                '_launch_capture_values','groups',capture_replay.__dict__)
                        else:
                            consumer._launch_capture_values = delete_call(original_values,
                                '_capture_envelope_values','capture_raw',consumer.__dict__)
                        try:
                            assert method(host.canonical(outer),request,expectation) == projected
                            assert len(calls) == 1
                            assert replay_projection(root,capture_values['capture.json'],export_group,
                                host.canonical(outer),request,expectation,receipt)[1] == projected
                        except AssertionError:print('ok EXP.bind06 '+control+' call deletion detected - '+launch)
                        else:raise AssertionError('undetected '+control+' deletion')
                        finally:
                            consumer._HeldStoreRead._record_launch = original_method
                            capture_replay._capture_projection_values = original_projection
                            consumer._launch_capture_values = original_values
                finally:
                    consumer._capture_envelope_values = original_rebuild
                assert method(host.canonical(outer),request,expectation) == projected
                changed_original = copy.deepcopy(export_group)
                changed_original['clocks']['wall'].append({'site':'ordinary-clock','value':'0000000000000000'})
                try:replay_projection(root,host._capture_values(attempt_id,request,changed_original,True),
                    export_group,host.canonical(outer),request,expectation,receipt)
                except Exception as error:
                    assert type(error).__name__ == 'Refusal' and str(error) == 'E_STORE'
                else:raise AssertionError('independently changed original capture accepted')
                for label,index,mutate in [
                    ('outer-kind',0,lambda v:v.update(kind='shadow_write_request' if launch == 'reproduction' else 'shadow_enforced_request')),
                    ('outer-attempt',0,lambda v:v['body'].update(attempt_id='attempt.other')),
                    ('outer-id',0,lambda v:v.update(id='attempt.other')),
                    ('launch-id',1,lambda v:v.update(id='attempt.other')),
                    ('launch-bytes',1,lambda v:v['body'].update(nonce='a'*64)),
                    ('expectation-attempt',2,lambda v:v['body']['attempt'].update(attempt_id='attempt.other')),
                    ('expectation-sha',2,lambda v:v['body']['attempt'].update(launch_request_sha256='a'*64)),
                    ('receipt-attempt',3,lambda v:v['body']['attempt'].update(attempt_id='attempt.other')),
                    ('receipt-sha',3,lambda v:v['body']['attempt'].update(launch_request_sha256='a'*64))]:
                    raw_documents = [host.canonical(outer),request,expectation,receipt]
                    changed = json.loads(raw_documents[index]);mutate(changed)
                    raw_documents[index] = host.canonical(changed)
                    refuses(lambda:consumer._launch_capture_values(capture_values['capture.json'],*raw_documents,
                        outer['kind']),'binding-'+label)
                    try:replay_projection(root,capture_values['capture.json'],export_group,*raw_documents)
                    except Exception as error:
                        assert type(error).__name__ == 'Refusal' and str(error) == 'E_STORE'
                    else:raise AssertionError('offline binding-'+label)
                refuses(lambda:consumer._capture_export_reference(projected),'final-at-host-stage')
                refuses(lambda:consumer._capture_export_reference(export_group,final=True),'host-at-final-stage')
                refuses(lambda:consumer._capture_export_binding(projected,held.capture.snapshots,final=True,
                    launch='write' if launch == 'reproduction' else 'reproduction'),'cross-launch')
                refuses(lambda:consumer._capture_export_binding(export_group,held.capture.snapshots,source=True),'source-binary')
                for label,change in [('missing-role',lambda v:v.pop('role')),
                        ('extra-key',lambda v:v.update(path='other')),
                        ('wrong-size-type',lambda v:v.update(size_bytes=True)),
                        ('over-size',lambda v:v.update(size_bytes=consumer.EXPORT_LIMIT+1))]:
                    changed = copy.deepcopy(export_group);change(changed['host']['process'][0]['bytes'])
                    refuses(lambda:consumer._capture_export_binding(changed,held.capture.snapshots),label)
                for label,change in [('inline-export',lambda r:r.update(bytes='00')),
                        ('wrong-site',lambda r:r.update(site='run_driver.read')),
                        ('wrong-return',lambda r:r.update(**{'return':0})),
                        ('wrong-ordinal',lambda r:r.update(ordinal=1))]:
                    changed = copy.deepcopy(export_group);change(changed['host']['process'][0])
                    refuses(lambda:consumer._capture_export_binding(changed,held.capture.snapshots),label)
                duplicate = copy.deepcopy(export_group)
                duplicate['host']['process'] *= 2
                refuses(lambda:consumer._capture_export_binding(duplicate,held.capture.snapshots),'duplicate-export')
                refuses(lambda:consumer._capture_export_binding(export_group,
                    {k:v for k,v in held.capture.snapshots.items() if k != 'sandbox-export.bin'}),'missing-binary')
                refuses(lambda:consumer._capture_export_binding(group,held.capture.snapshots),'unused-binary')
                prior_copy = dict(private_work)
                prior_export_copy_calls = private_work.get('calls',{}).get('sandbox-export.bin',0)
                for component in private_held.components:
                    current = os.fstat(component.fd)
                    assert consumer._identity(component.before) == consumer._identity(current), (
                        component.name,consumer._stat_values(component.before),consumer._stat_values(current))
                held.copy_capture(private_held,request,launch,private_work)
                assert private_work['export_read_bytes']-prior_copy.get('export_read_bytes',0) == len(export)
                assert private_work['export_write_bytes']-prior_copy.get('export_write_bytes',0) == len(export)
                assert private_work['export_physical_bytes']-prior_copy.get('export_physical_bytes',0) == len(export)
                assert private_work['export_files']-prior_copy.get('export_files',0) == 1
                assert {path.name for path in (private/launch).iterdir()} == {
                    'capture.json','complete.json','sandbox-export.bin','origin-observation.json','consumer-observations.json',
                    'launch-binding.json'}
                assert json.loads((private/launch/'launch-binding.json').read_bytes()) == held.launch_binding | {'raw':projected}
                consumer_observations = (private/launch/'consumer-observations.json').read_bytes()
                assert json.loads(consumer_observations) == {'attempt_id':attempt_id,
                    'request_sha256':host.sha256_hex(request),'storage':held.storage_rows,
                    'storage_reads':export_anchor.private_observations['storage_reads'],
                    'identity_context':anchor.identity_context,'commands':{},'preparation':{},'entropy':{},'clocks':consumer._clock_observations}
                copied = private/launch/'sandbox-export.bin'
                assert copied.stat().st_size == len(export) and copied.stat().st_mode & 0o777 == 0o400
                measured = consumer.hashlib.sha256()
                validation_bytes = 0
                seed = seed_exports/(launch+'.bin')
                seed_written = 0
                with copied.open('rb') as stream, seed.open('xb') as target:
                    while True:
                        chunk = stream.read(65536)
                        if not chunk: break
                        measured.update(chunk);validation_bytes += len(chunk)
                        view = memoryview(chunk)
                        while view:
                            count = target.write(view)
                            assert count is not None and 0 < count <= len(view)
                            seed_written += count;view = view[count:]
                    target.flush();os.fsync(target.fileno())
                    os.fchmod(target.fileno(),0o400)
                assert seed_written == validation_bytes == len(export)
                assert seed.stat().st_size == len(export) and seed.stat().st_mode & 0o777 == 0o400
                assert validation_bytes == len(export) and measured.hexdigest() == reference['sha256']
                print(json.dumps({'private_copy_work':private_work,
                    'additional_ordinary_destination_validation_read_bytes':validation_bytes,
                    'additional_ordinary_consumer_doc_validation_input_bytes':len(consumer_observations)},sort_keys=True))
                held.recheck()
                selected_owner_module._seal_capture_recording(export_anchor,private_held,held)
                assert export_anchor.private_observations['recording_sealed'] is True
                assert selected_owner.work['transferred_read_bytes']==selected_owner.work['read_bytes']
                assert selected_owner.work['authentication_calls']==2 and selected_owner.work['constructor_calls']==1
                assert spent('consumer.completion-reread','calls') == 1
                assert spent('consumer.completion-reread','read_bytes') == 2*len(export)
                print(json.dumps({'launch':launch,'consumer_work':{
                    site:{field:spent(site,field) for field in ('calls','read_bytes')}
                    for site in consumer._export_work},'offline_origin_work':offline_work},sort_keys=True))
                ledger = {'original_read':host_work['original_read'],
                    'original_sha':host_work['original_sha'],
                    'frame_read':host_work['frame_read_bytes'],
                    'controlled_copy':host_work['controlled_copy'],
                    'controlled_readback_sha':host_work['controlled_readback'],
                    'held_acquisition_sha':spent('consumer.held-acquisition','read_bytes'),
                    'origin_sha':spent('consumer.independent-sha','read_bytes'),
                    'snapshot_whole_equality':spent('consumer.whole-equality','read_bytes'),
                    'independent_origin_sha':offline_work['consumer.independent-sha']['read_bytes'],
                    'private_recorder_copy':private_work['export_read_bytes']-prior_copy.get('export_read_bytes',0),
                    'fixed_seed_copy_and_destination_sha':validation_bytes,
                    'held_completion_equality_sha':spent('consumer.completion-reread','read_bytes')}
                assert sum(value for key,value in ledger.items() if key != 'frame_read') == 13*len(export)
                assert sum(ledger.values()) <= 15*len(export)+512*1024
                recording_pair.append({'launch':launch,'actual_fixed_completion_owner':True,
                    'installation_and_signals_admission_are_fixture_doubles':True,
                    'actual_completion_owner_work':copy.deepcopy(selected_owner.work),
                    'additional_fixture_installed_owner_copy_bytes':len(selected_owner.source.raw),
                    'calls':{'original_read':1,'original_sha':1,
                    'frame_read':host_work['frame_read_calls'],'controlled_copy':1,'controlled_readback_sha':1,
                    'held_acquisition_sha':spent('consumer.held-acquisition','calls'),
                    'origin_sha':spent('consumer.independent-sha','calls'),
                    'snapshot_whole_equality':spent('consumer.whole-equality','calls'),
                    'independent_origin_sha':offline_work['consumer.independent-sha']['calls'],
                    'private_recorder_copy':private_work['calls']['sandbox-export.bin']-prior_export_copy_calls,
                    'fixed_seed_copy_and_destination_sha':1,
                    'held_completion_equality_sha':spent('consumer.completion-reread','calls')},
                    'read_charges':ledger,'total_read_bytes':sum(ledger.values()),
                    'seed_write_bytes':seed_written})
                assert all(value == 1 for value in recording_pair[-1]['calls'].values())
                failed_state = failed_private_held.before
                failed_key = str(failed_state.st_dev)+':'+str(failed_state.st_ino)
                fields = ('files','read_bytes','write_bytes','physical_bytes','export_read_bytes',
                          'export_write_bytes','export_physical_bytes','export_files')
                failure_work = {key:0 for key in fields}
                case_work = {key:0 for key in fields}
                case_work.update(write_bytes=192*1024*1024-65536,
                    export_write_bytes=192*1024*1024-65536)
                failure_work['cases'] = {failed_key:case_work}
                failure_work.update(write_bytes=case_work['write_bytes'],
                                    export_write_bytes=case_work['export_write_bytes'])
                initial_writes = failure_work['write_bytes']
                refuses(lambda:held.copy_capture(failed_private_held,request,launch,failure_work),
                        'private-copy-case-write-limit')
                partial = failed_private/launch/'sandbox-export.bin'
                assert partial.stat().st_size == 65536
                assert partial.stat().st_mode & 0o777 == 0o600
                assert case_work['export_write_bytes'] == 192*1024*1024
                print(json.dumps({'capacity_counter_prestate_only':initial_writes,
                    'actual_failed_fixture_write_bytes':failure_work['write_bytes']-initial_writes,
                    'retained_partial_export_bytes':partial.stat().st_size},sort_keys=True))
                path = store/('.capture-'+attempt_id)/'sandbox-export.bin';path.chmod(0o640)
                with path.open('r+b') as output:
                    output.seek(-1,os.SEEK_END);output.write(b'x')
                path.chmod(0o440)
                refuses(held.capture.recheck,'export-tail-changed-after-held-read')
                assert held.recheck() is None and export_anchor.private_observations['unusable']
                refuses(lambda:consumer._HeldCaptureRead(held,request),'export-digest-mismatch')
                print(json.dumps({'recording_ordinary_positive':recording_pair[-1]},sort_keys=True))
                print('ok complete 12MiB conditional binary held inventory/origin/binding - '+launch+
                      '; capture path only, full accounting/replay remain separate')
                refuses(lambda:consumer.read_store_attempt(export_anchor,'attempt.absent'),
                        'actual-store-open-failure-retained')
                failed_read = export_anchor.private_observations['storage_reads'][-1]
                assert failed_read['error']['category'] == 'Refusal'
                assert failed_read['error']['code'] == 'E_STORE'
                assert failed_read['error']['errno'] == consumer.errno.ENOENT
                assert len(failed_read['held']) == 1
                assert len(failed_read['held'][0]['components']) >= 2
                assert export_anchor.private_observations['unusable'] is True
            finally:
                held.close();installed_owner_hold.close()
                selected_owner_module._close_capture_completion_owner(selected_owner)
                if sys.modules.get(selected_owner.name) is selected_owner.module:del sys.modules[selected_owner.name]
        assert [row['launch'] for row in recording_pair] == ['reproduction','write']
        export_pair_read = sum(row['total_read_bytes'] for row in recording_pair)
        assert export_pair_read <= 15*24*1024*1024+1024*1024
        print(json.dumps({'recording_pair_export_read_bytes':export_pair_read,
            'recording_pair_export_read_limit':15*24*1024*1024+1024*1024,
            'non_export_and_failed_bytes_are_separate':True},sort_keys=True))
        private_held.close()
        failed_private_held.close()
        runtime_sources = {}
        runtime_raw = {}
        runtime_names = ('guest_kernel','guest_init','guest_supervisor','image','toolchain','verifier',
                         'guest_kernel_config','vm_service','runtime_vfkit','runtime_driver')
        runtime_locators = {}
        runtime_parent = area/'runtime-recorder';runtime_parent.mkdir(mode=0o700)
        runtime_limit = area/'runtime-limit';runtime_limit.mkdir(mode=0o700)
        runtime_limit_failed = area/'runtime-limit-failed';runtime_limit_failed.mkdir(mode=0o700)
        runtime_counter_parents={}
        for fault in ('runtime_files','close_calls','sha'):
            path=area/('runtime-counter-'+fault);path.mkdir(mode=0o700);runtime_counter_parents[fault]=path
        runtime_hold = consumer._open_held(str(runtime_parent),True,
            consumer._store_rule(os.getuid(),os.getgid(),0o700,True),'E_STORE')
        try:
            for role in runtime_names:
                raw = b'k'*65537 if role == 'guest_kernel' else (role+' ordinary input').encode()
                path = originals/('runtime.'+role);path.write_bytes(raw);path.chmod(0o400)
                runtime_raw[role] = raw;runtime_locators[role] = str(path)
            runtime_sources['dyld_cache_files'] = []
            runtime_locators['dyld_cache_files'] = []
            runtime_raw['dyld_cache_files'] = []
            for index in range(2):
                raw = ('dyld ordinary '+str(index)).encode()
                path = originals/('runtime.dyld'+str(index));path.write_bytes(raw);path.chmod(0o400)
                runtime_raw['dyld_cache_files'].append(raw);runtime_locators['dyld_cache_files'].append(str(path))
            for role,paths in runtime_locators.items():
                selected_paths = paths if type(paths) is list else [paths]
                opened = [consumer._open_held(path,False,
                    consumer._store_rule(os.getuid(),os.getgid(),0o400,False),'E_STORE')
                    for path in selected_paths]
                runtime_sources[role] = opened if type(paths) is list else opened[0]
            runtime_config = copy.deepcopy(config)
            runtime_config['identity_paths'].update({key:value for key,value in runtime_locators.items()
                if key not in {'runtime_vfkit','runtime_driver'}})
            runtime_config['runtime'].update(vfkit=runtime_locators['runtime_vfkit'],driver=runtime_locators['runtime_driver'])
            runtime_config_raw = host.canonical({'schema_version':1,'kind':'sandbox_host_config',
                'id':'runtime.ordinary','body':runtime_config})
            runtime_anchor = consumer.Anchor(runtime_config,runtime_config_raw,[],{},('',[]),('',[]),None)
            runtime_work = {}
            runtime_manifest = runtime_anchor.copy_runtime_slots(runtime_hold,runtime_sources,runtime_work)
            copied_runtime = {role:[] if role == 'dyld_cache_files' else None for role in runtime_sources}
            for row in runtime_manifest:
                name = row['slot'] + ('.%04d'%row['index'] if row['slot'] == 'dyld_cache_files' else '')
                path = runtime_parent/'qualified-runtime'/name
                raw = path.read_bytes()
                assert len(raw) == row['size_bytes'] and host.sha256_hex(raw) == row['sha256']
                assert path.stat().st_mode & 0o777 == 0o400
                if row['slot'] == 'dyld_cache_files':copied_runtime[row['slot']].append(raw)
                else:copied_runtime[row['slot']] = raw
            assert copied_runtime == runtime_raw
            total_runtime = sum(len(value) for role,value in runtime_raw.items() if role != 'dyld_cache_files')
            total_runtime += sum(map(len,runtime_raw['dyld_cache_files']))
            assert runtime_work == {'runtime_read_bytes':total_runtime,'runtime_write_bytes':total_runtime,
                'runtime_physical_bytes':total_runtime,'runtime_files':12,'close_calls':13}
            host._capture_process = {'complete':True,'runtime_locators':runtime_locators}
            descriptors = {role:[item.fd for item in value] if type(value) is list else value.fd
                           for role,value in runtime_sources.items()}
            measured = host.measure_identities(descriptors,b'instruction',runtime_config_raw,b'supervisor',b'python')
            assert capture_replay._identity_values(root,copied_runtime,b'instruction',runtime_config_raw,
                b'supervisor',b'python',host._capture_process['runtime_reads']) == measured
            runtime_reads = host._capture_process['runtime_reads']
            runtime_attempt = 'attempt.runtime.metadata'
            runtime_request = host.canonical({'schema_version':1,'kind':'sandbox_launch_request',
                'id':runtime_attempt,'body':{'attempt':{'attempt_id':runtime_attempt,'attempt_number':1},
                'control':{},'subject':{},'store_id':runtime_config['store_id']}})
            runtime_bound = {'attempt_id':runtime_attempt,'attempt_number':1,
                             'launch_request_sha256':host.sha256_hex(runtime_request)}
            runtime_receipt = host.canonical({'schema_version':1,'kind':'sandbox_enforcement_receipt',
                'id':'receipt.'+host.sha256_hex(runtime_request),'body':{'attempt':runtime_bound,
                'control':{},'subject':{},'origin':{'store_id':runtime_config['store_id']}}})
            runtime_expectation = host.canonical({'schema_version':1,'kind':'sandbox_receipt_expectation',
                'id':runtime_attempt,'body':{'attempt':runtime_bound,'control':{},'subject':{},
                'store_id':runtime_config['store_id']}})
            runtime_outer = host.canonical({'schema_version':1,'kind':'shadow_enforced_request',
                'id':runtime_attempt,'body':{'attempt_id':runtime_attempt}})
            runtime_attempt_path = store/runtime_attempt;runtime_attempt_path.mkdir(mode=0o750);runtime_attempt_path.chmod(0o750)
            runtime_payload = runtime_attempt_path/'payload';runtime_payload.mkdir(mode=0o750);runtime_payload.chmod(0o750)
            for name,raw in [('stdout',b''),('stderr',b''),('evidence-manifest.json',host.empty_evidence_manifest()[0])]:
                path = runtime_payload/name;path.write_bytes(raw);path.chmod(0o440)
            host._capture_process.update(rows=[],driver_rest=[],signals=[],request_raw=runtime_request,
                                         attempt_id=runtime_attempt,ordinals={},bytes=0)
            host._capture_clocks = {'wall':[],'monotonic':[],'complete':True}
            store_fd = os.open(store,os.O_RDONLY | os.O_DIRECTORY)
            try:host.write_receipt_file(store_fd,os.open(runtime_attempt_path,os.O_RDONLY | os.O_DIRECTORY),
                                        os.getuid(),os.getgid(),runtime_receipt)
            finally:os.close(store_fd)
            runtime_anchor.identity_context = anchor.identity_context
            runtime_anchor.capture_completion_owner=types.SimpleNamespace(
                construct=lambda anchor,attempt_id,request,capture:host._capture_completion_values(attempt_id,request,capture),
                authenticate=lambda anchor:None,transfer=lambda work,case:None)
            captured_runtime = consumer._HeldStoreRead(runtime_anchor,runtime_attempt)
            try:
                group = captured_runtime.record_reproduction(runtime_outer,runtime_request,runtime_expectation)
                assert group['runtime']['slots'] == runtime_reads
                runtime_capture_work = {}
                captured_runtime.copy_capture(runtime_hold,runtime_request,'reproduction',runtime_capture_work)
                preserved = json.loads((runtime_parent/'reproduction/capture.json').read_bytes())
                assert preserved['body']['raw']['runtime']['slots'] == runtime_reads
                assert capture_replay._identity_values(root,copied_runtime,b'instruction',runtime_config_raw,
                    b'supervisor',b'python',preserved['body']['raw']['runtime']['slots']) == measured
                captured_runtime.recheck()
            finally:captured_runtime.close()
            print(json.dumps({'qualified_runtime_work':runtime_work,
                'runtime_capture_work':runtime_capture_work,
                'additional_ordinary_qualified_validation_input_bytes':total_runtime},sort_keys=True))
            print('ok actual held qualified-slot streaming copy and original/offline identity owners; fixture bytes only')
            for crossing,parent in [(False,runtime_limit),(True,runtime_limit_failed)]:
                held_parent = consumer._open_held(str(parent),True,
                    consumer._store_rule(os.getuid(),os.getgid(),0o700,True),'E_STORE')
                prestate = 4*1024*1024*1024-total_runtime+int(crossing)
                boundary_work = {'runtime_read_bytes':prestate,'runtime_write_bytes':prestate,
                                 'runtime_physical_bytes':prestate,'runtime_files':1}
                try:
                    if crossing:
                        refuses(lambda:runtime_anchor.copy_runtime_slots(held_parent,runtime_sources,boundary_work),
                                'runtime-copy-real-file-crossing')
                        partial = parent/'qualified-runtime/vm_service'
                        assert partial.exists() and partial.stat().st_size == 0
                        assert partial.stat().st_mode & 0o777 == 0o600
                        assert 0 < boundary_work['runtime_physical_bytes']-prestate < total_runtime
                    else:
                        assert len(runtime_anchor.copy_runtime_slots(held_parent,runtime_sources,boundary_work)) == 12
                        assert boundary_work['runtime_physical_bytes'] == 4*1024*1024*1024
                    print(json.dumps({'runtime_capacity_counter_prestate_only':prestate,
                        'runtime_actual_fixture_copy_bytes':boundary_work['runtime_physical_bytes']-prestate,
                        'runtime_crossing':crossing},sort_keys=True))
                finally:held_parent.close()
            for fault,parent_path in runtime_counter_parents.items():
                held_parent=consumer._open_held(str(parent_path),True,
                    consumer._store_rule(os.getuid(),os.getgid(),0o700,True),'E_STORE')
                class RuntimeCounters(dict):
                    def __setitem__(self,key,value):
                        if key==fault:raise MemoryError('ordinary qualified-slot counter allocation fixture')
                        return super().__setitem__(key,value)
                counter_work=RuntimeCounters();opened=[]
                actual_open=consumer.os.open;actual_sha=consumer.hashlib.sha256
                def counter_open(*args,**kwargs):
                    fd=actual_open(*args,**kwargs);opened.append(fd);return fd
                def counter_sha(*args,**kwargs):raise MemoryError('ordinary qualified-slot hash allocation fixture')
                try:
                    consumer.os.open=counter_open
                    if fault=='sha':consumer.hashlib.sha256=counter_sha
                    try:runtime_anchor.copy_runtime_slots(held_parent,runtime_sources,counter_work)
                    except MemoryError:pass
                    else:raise AssertionError('qualified runtime allocation failure not reached')
                finally:
                    consumer.os.open=actual_open;consumer.hashlib.sha256=actual_sha;held_parent.close()
                assert len(opened)==2 and counter_work['runtime_accounting_incomplete']
                for fd in opened:
                    try:os.fstat(fd)
                    except OSError as error:assert error.errno==9
                    else:raise AssertionError('qualified runtime allocation failure leaked descriptor')
                retained=[{'name':path.name,'inode':path.stat().st_ino,'size':path.stat().st_size,
                           'mode':path.stat().st_mode & 0o777} for path in (parent_path/'qualified-runtime').iterdir()]
                assert len(retained)==1
                assert retained[0]['size']==(len(runtime_raw['dyld_cache_files'][0]) if fault=='close_calls' else 0)
                print(json.dumps({'qualified_slot_allocation_failure':fault,'retained':retained,
                    'actual_work_with_incomplete_counter_flag':counter_work,'opened_and_closed_fds':opened},sort_keys=True))
        finally:
            for value in runtime_sources.values():
                for item in value if type(value) is list else [value]:item.close()
            runtime_hold.close()
    finally:consumer._acl_state = original_acl
PY_CAPTURE_VALUES
/usr/bin/python3 -I -S -B - "$root" <<'PY_CAPTURE_FAILURES'
import ctypes
import errno
import hashlib
import io
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types

root=Path(sys.argv[1])
spec=importlib.util.spec_from_file_location('capture_failure_host',root/'sandbox/v1/host-supervisor.py')
host=importlib.util.module_from_spec(spec);spec.loader.exec_module(host)
cases=[(name,phase) for name in ('capture.json','.completion.pending')
       for phase in ('open','write','zero','short','chown','chmod','fsync','close')]
cases += [('sync',site) for site in ('pending-directory-fsync','pending-store-fsync',
    'published-directory-fsync','published-store-fsync','completion-directory-fsync','completion-store-fsync')]
cases += [('held',str(ordinal)) for ordinal in (1,2,3)]
cases += [('readback',phase) for phase in ('open','read','mismatch','close')]
cases += [('rename',phase) for phase in ('directory-eio','completion-eio','completion-eintr',
                                        'directory-committed-eio','completion-committed-eio')]
cases += [('rename',site+'-'+kind) for site in ('directory','completion')
          for kind in ('collision-file','collision-empty','collision-nonempty','missing-symbol','exdev','permission','eintr')]
cases += [('directory','close')]
cases += [('capture-directory',phase) for phase in ('mkdir','open','chown','chmod','fsync','chown-close')]
cases += [('sandbox-export.bin',phase) for phase in ('open','write','zero','short','chown','chmod','fsync','close','read','mismatch')]
for ordinal,(target,phase) in enumerate(cases):
    with tempfile.TemporaryDirectory(prefix='ystack-capture-failure-') as temporary:
        area=Path(temporary).resolve();area.chmod(0o750)
        store=os.open(area,os.O_RDONLY|os.O_DIRECTORY)
        attempt_id='attempt.failure.%03d'%ordinal
        attempt=host.mkdir_excl(store,attempt_id,os.getuid(),os.getgid())
        host.write_payload(attempt,os.getuid(),os.getgid(),[(b'stdout',b''),(b'stderr',b'')])
        request=host.canonical({'ordinary':'request','id':attempt_id})
        receipt=host.canonical({'ordinary':'native receipt','id':attempt_id})
        host._capture_clocks={'wall':[],'monotonic':[],'complete':True}
        host._capture_process={'rows':[],'driver_rest':[],'signals':[],'complete':True,
            'request_raw':request,'attempt_id':attempt_id}
        if target=='sandbox-export.bin':
            export=host.frame_write([(b'stdout',b''),(b'stderr',b'')])
            export += bytes(12582912-len(export))
            host._capture_process.update(ordinals={},bytes=0)
            assert host._read_export_value(io.BytesIO(export))==export
        original={name:getattr(host.os,name) for name in ('mkdir','open','read','write','fchown','fchmod','fsync','close')}
        sync,check,rename=host._capture_sync,host._capture_directory_check,host._capture_rename_noreplace
        roles={store:'store',attempt:'native-attempt'}
        state={'site':None,'checks':0,'fired':False,'partial':False,'renames':0}
        def fail():state['fired']=True;raise OSError(5,'ordinary controlled capture failure')
        def making(name,*args,**kwargs):
            if target=='capture-directory' and phase=='mkdir' and os.fsdecode(name).startswith('.capture-'):fail()
            return original['mkdir'](name,*args,**kwargs)
        def opening(name,flags,*args,**kwargs):
            text=os.fsdecode(name)
            if target==text and phase=='open':fail()
            if target=='capture-directory' and phase=='open' and text.startswith('.capture-'):fail()
            if target=='readback' and phase=='open' and text=='.completion.pending' and flags & os.O_ACCMODE==os.O_RDONLY:fail()
            fd=original['open'](name,flags,*args,**kwargs)
            roles[fd]=('capture-directory' if text.startswith('.capture-') else
                       'witness-read' if text=='.completion.pending' and flags & os.O_ACCMODE==os.O_RDONLY else text)
            return fd
        def writing(fd,data):
            if roles.get(fd)==target:
                if phase=='write':fail()
                if phase=='zero':state['fired']=True;return 0
                if phase=='short':
                    if state['partial']:fail()
                    state['partial']=True
                    return original['write'](fd,data[:3])
            return original['write'](fd,data)
        def chowning(fd,*args):
            if roles.get(fd)==target and phase in ('chown','chown-close'):fail()
            return original['fchown'](fd,*args)
        def chmodding(fd,*args):
            if roles.get(fd)==target and phase=='chmod':fail()
            return original['fchmod'](fd,*args)
        def syncing(fd):
            if ((roles.get(fd)==target and phase=='fsync')
                    or target=='sync' and state['site']==phase):fail()
            return original['fsync'](fd)
        def reading(fd,count):
            if ((target=='readback' and roles.get(fd)=='witness-read')
                    or target=='sandbox-export.bin' and roles.get(fd)==target):
                if phase=='read':fail()
                if phase=='mismatch':
                    data=original['read'](fd,count);state['fired']=True
                    return b'x'+data[1:] if data else data
            return original['read'](fd,count)
        def closing(fd):
            role=roles.pop(fd,None);result=original['close'](fd)
            if ((role==target and phase=='close')
                    or target=='readback' and role=='witness-read' and phase=='close'
                    or target=='directory' and role=='capture-directory' and phase=='close'
                    or target=='capture-directory' and role=='capture-directory' and phase=='chown-close'):
                state['fired']=True;raise OSError(9,'ordinary controlled capture close failure')
            return result
        def sync_site(fd,work,site):
            state['site']=site
            try:return sync(fd,work,site)
            finally:state['site']=None
        def held_check(store_fd,directory,name,expected,uid,gid,work):
            state['checks']+=1
            if target=='held' and state['checks']==int(phase):
                state['fired']=True
                os.chmod('capture.json',0o640,dir_fd=directory)
            return check(store_fd,directory,name,expected,uid,gid,work)
        def renaming(parent,source,destination,work):
            state['renames']+=1
            selected=(target=='rename' and ((phase.startswith('directory') and source.startswith(b'.capture-'))
                or (phase.startswith('completion') and source==b'.completion.pending')))
            if not selected:return rename(parent,source,destination,work)
            state['fired']=True
            if 'collision-' in phase:
                if phase.endswith('file'):
                    collided=original['open'](destination,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600,dir_fd=parent)
                    try:original['write'](collided,b'preexisting collision')
                    finally:original['close'](collided)
                else:
                    original['mkdir'](destination,mode=0o750,dir_fd=parent)
                    if phase.endswith('nonempty'):
                        collided=original['open'](destination,os.O_RDONLY|os.O_DIRECTORY,dir_fd=parent)
                        try:original['mkdir']('retained',mode=0o750,dir_fd=collided)
                        finally:original['close'](collided)
                state['collision_inode']=os.stat(destination,dir_fd=parent,follow_symlinks=False).st_ino
                return rename(parent,source,destination,work)
            symbol='renameatx_np' if sys.platform=='darwin' else 'renameat2'
            provider=host._darwin_libc if sys.platform=='darwin' else host.ctypes.CDLL
            class Fault:
                def __call__(self,*args):
                    if 'committed' in phase:
                        real=getattr(provider() if sys.platform=='darwin' else provider(None,use_errno=True),symbol)
                        real.argtypes=self.argtypes;real.restype=self.restype
                        assert real(*args)==0
                    ctypes.set_errno(errno.EINTR if phase.endswith('eintr') else errno.EXDEV if phase.endswith('exdev') else errno.EACCES if phase.endswith('permission') else errno.EIO)
                    return -1
            replacement=lambda *args,**kwargs:types.SimpleNamespace(**({} if phase.endswith('missing-symbol') else {symbol:Fault()}))
            try:
                if sys.platform=='darwin':host._darwin_libc=replacement
                else:host.ctypes.CDLL=replacement
                return rename(parent,source,destination,work)
            finally:
                if sys.platform=='darwin':host._darwin_libc=provider
                else:host.ctypes.CDLL=provider
        try:
            for name,function in [('mkdir',making),('open',opening),('write',writing),('fchown',chowning),
                    ('fchmod',chmodding),('fsync',syncing),('read',reading),('close',closing)]:setattr(host.os,name,function)
            host._capture_sync=sync_site;host._capture_directory_check=held_check;host._capture_rename_noreplace=renaming
            assert host.write_receipt_file(store,attempt,os.getuid(),os.getgid(),receipt) is None
        finally:
            for name,function in original.items():setattr(host.os,name,function)
            host._capture_sync=sync;host._capture_directory_check=check;host._capture_rename_noreplace=rename
        try:
            assert state['fired'],(target,phase,state)
            work=host._capture_process['publication_work']
            assert work['complete'] is False and host._capture_process['complete'] is False
            if target=='capture-directory' and phase=='chown-close':
                assert work['failure']['errno']==5 and any(row.get('errno')==9 for row in work['operations'])
            if target=='sandbox-export.bin':
                export_work=host._capture_process['export_work']
                assert export_work['original_read']==export_work['original_sha']==12582912
                copied=3 if phase=='short' else 0 if phase in ('open','write','zero') else 12582912
                assert export_work.get('controlled_copy',0)==export_work.get('controlled_write',0)==copied
                readback=12582912 if phase in ('close','mismatch') else 0
                assert export_work.get('controlled_readback',0)==readback
                assert work.get('export_write_bytes',0)==copied and work.get('export_read_bytes',0)==readback
            native=area/attempt_id
            assert {path.name for path in native.iterdir()}=={'receipt.json','payload'}
            assert (native/'receipt.json').read_bytes()==receipt
            assert (native/'payload/stdout').read_bytes()==b'' and (native/'payload/stderr').read_bytes()==b''
            pending=area/('.capture-'+attempt_id+'.pending');published=area/('.capture-'+attempt_id)
            namespace=[]
            def retained_value(path):
                if path.is_dir():return {'directory_names':sorted(child.name for child in path.iterdir())}
                if path.name=='sandbox-export.bin':
                    return {'size':path.stat().st_size,'fixture_sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
                return {'bytes_hex':path.read_bytes().hex()}
            for directory in (pending,published):
                if directory.exists():
                    namespace.append({'name':directory.name,'inode':directory.stat().st_ino,
                        'files':([{'name':path.name,'inode':path.stat().st_ino,
                                   'mode':path.stat().st_mode & 0o777,**retained_value(path)}
                                  for path in sorted(directory.iterdir())] if directory.is_dir() else retained_value(directory))})
            committed=target=='rename' and phase=='completion-committed-eio' or target=='directory'
            collision=target=='rename' and 'collision-' in phase
            if collision:
                destination=published/'complete.json' if phase.startswith('completion') else published
                assert destination.stat().st_ino==state['collision_inode']
                if phase.endswith('file'):assert destination.read_bytes()==b'preexisting collision'
                elif phase.endswith('nonempty'):assert [child.name for child in destination.iterdir()]==['retained']
                else:assert list(destination.iterdir())==[]
            assert (published/'complete.json').exists() is (committed or collision and phase.startswith('completion'))
            print(json.dumps({'capture_failure_case':[target,phase],'controlled_fault_not_native_qualification':True,
                'native_receipt_and_return_unchanged':True,'state':state,'namespace':namespace,'actual_work':work,'actual_export_work':host._capture_process.get('export_work')},sort_keys=True))
        finally:os.close(store)
PY_CAPTURE_FAILURES
/usr/bin/python3 -I -S -B - "$root" <<'PY_CAPTURE_ADMISSION'
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types

root=Path(sys.argv[1])
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);sys.modules[name]=module;spec.loader.exec_module(module)
    return module
host=load('capture_admission_host',root/'sandbox/v1/host-supervisor.py')
consumer=load('capture_admission_consumer',root/'shadow/v1/_consumer.py')
consumer._acl_state=lambda *_: ([],None) if sys.platform=='darwin' else (None,None)
cases=('positive','missing','empty','partial','duplicate','wrong-id','wrong-request','wrong-capture',
       'extra-witness-key','512-malformed','513-over','extra-entry','witness-symlink','capture-symlink',
       'witness-mode','directory-mode','legacy-flat','lost-directory')
for label in cases:
    with tempfile.TemporaryDirectory(prefix='ystack-capture-admission-') as temporary:
        area=Path(temporary).resolve();store=area/'store';store.mkdir(mode=0o750);store.chmod(0o750)
        attempt_id='attempt.admission';request=host.canonical({'ordinary':'request'})
        receipt=host.canonical({'body':{'attempt':{'attempt_id':attempt_id,
            'launch_request_sha256':host.sha256_hex(request)}}})
        store_fd=os.open(store,os.O_RDONLY|os.O_DIRECTORY)
        attempt=host.mkdir_excl(store_fd,attempt_id,os.getuid(),os.getgid())
        host.write_payload(attempt,os.getuid(),os.getgid(),[(b'stdout',b''),(b'stderr',b''),(b'evidence-manifest.json',host.empty_evidence_manifest()[0])])
        host._capture_clocks={'wall':[],'monotonic':[],'complete':True}
        host._capture_process={'rows':[],'driver_rest':[],'signals':[],'complete':True,
            'request_raw':request,'attempt_id':attempt_id}
        try:assert host.write_receipt_file(store_fd,attempt,os.getuid(),os.getgid(),receipt) is None
        finally:os.close(store_fd)
        private=store/('.capture-'+attempt_id);witness=private/'complete.json';capture=private/'capture.json'
        original_witness=witness.read_bytes();original_capture=capture.read_bytes()
        def replace(path,raw):
            path.chmod(0o640);path.write_bytes(raw);path.chmod(0o440)
        if label=='missing':witness.unlink()
        elif label=='empty':replace(witness,b'')
        elif label=='partial':replace(witness,original_witness[:17])
        elif label=='duplicate':replace(witness,original_witness+original_witness)
        elif label in ('wrong-id','wrong-request','wrong-capture','extra-witness-key'):
            changed=json.loads(original_witness)
            if label=='wrong-id':changed['id']='attempt.other'
            elif label=='wrong-request':changed['body']['request_sha256']='a'*64
            elif label=='wrong-capture':changed['body']['capture_sha256']='a'*64
            else:changed['extra']=True
            replace(witness,host.canonical(changed))
        elif label in ('512-malformed','513-over'):replace(witness,b'x'*(512 if label=='512-malformed' else 513))
        elif label=='extra-entry':(private/'extra').write_bytes(b'kept')
        elif label in ('witness-symlink','capture-symlink'):
            path=witness if label=='witness-symlink' else capture
            path.rename(area/'retained-original');path.symlink_to(area/'retained-original')
        elif label=='witness-mode':witness.chmod(0o640)
        elif label=='directory-mode':private.chmod(0o770)
        elif label=='legacy-flat':
            for path in (capture,witness):path.rename(store/attempt_id/path.name)
            private.rmdir()
        elif label=='lost-directory':private.rename(area/'retained-crash-directory')
        config={'principal_uid':os.getuid(),'consumer_gid':os.getgid(),'store_root':str(store),
            'store_id':'store.ordinary','environment_id':'environment.ordinary','work_root':str(area/'work'),
            'runtime':{'driver':'/ordinary/driver','vfkit':'/ordinary/vfkit'},
            'installed_files':{key:'/ordinary/installed/'+key for key in consumer.INSTALLED_SOURCES},
            'identity_paths':{key:['/ordinary/dyld'] if key=='dyld_cache_files' else '/ordinary/identity/'+key
                              for key in consumer.IDENTITY_KEYS}}
        config_raw=host.canonical({'schema_version':1,'kind':'sandbox_host_config','id':'host.ordinary','body':config})
        anchor=types.SimpleNamespace(config=config,config_raw=config_raw,resolver=None,recheck=lambda *_:None,
            recording_work={},identity_context={},private_observations={},capture_completion_owner=types.SimpleNamespace(
                construct=lambda anchor,attempt_id,request,capture:host._capture_completion_values(attempt_id,request,capture)))
        private_parents=[]
        if label=='positive':
            for ordinal in range(5):
                parent=area/('private-'+str(ordinal));parent.mkdir(mode=0o700);parent.chmod(0o700)
                private_parents.append(parent)
        native=None;held=None;refused=False
        try:
            native=consumer._HeldStoreRead(anchor,attempt_id)
            try:held=consumer._HeldCaptureRead(native,request)
            except consumer.Refusal:refused=True
            if label=='positive':
                assert not refused and held.snapshots=={'capture.json':original_capture,'complete.json':original_witness}
                held.recheck()
                native.capture=held
                native.capture_origin=consumer._origin_values(native.snapshots,native.storage_rows,
                    {'attempt_id':attempt_id,'platform':sys.platform},{'host-config.json':config_raw},
                    capture_files=held.snapshots,capture_storage_rows=held.storage_rows)
                anchor.capture_completion_owner.transfer=lambda *_:None
                work=anchor.recording_work;retained=[]
                actual_write=consumer.os.write;actual_open=consumer.os.open
                for ordinal,parent_path in enumerate(private_parents):
                    parent=consumer._open_held(str(parent_path),True,
                        consumer._store_rule(os.getuid(),os.getgid(),0o700,True),'E_STORE')
                    state={'prefix_written':False,'opened':[]}
                    class CaseCounters(dict):
                        def __setitem__(self,key,value):
                            if ordinal==2 and key=='files' or ordinal==3 and key=='close_calls':
                                raise MemoryError('ordinary private-copy counter allocation failure')
                            return super().__setitem__(key,value)
                    if ordinal in (2,3):
                        state_key=str(parent.before.st_dev)+':'+str(parent.before.st_ino)
                        work['cases'][state_key]=CaseCounters({key:0 for key in ('files','read_bytes','write_bytes',
                            'physical_bytes','export_read_bytes','export_write_bytes','export_physical_bytes','export_files')})
                    def opening(name,*args,**kwargs):
                        fd=actual_open(name,*args,**kwargs);state['opened'].append(fd);return fd
                    def partial_write(fd,data):
                        if state['prefix_written']:raise OSError(5,'ordinary retained private-copy failure')
                        state['prefix_written']=True
                        return actual_write(fd,data[:3])
                    try:
                        consumer.os.open=opening
                        if ordinal<2:consumer.os.write=partial_write
                        try:native.copy_capture(parent,request,'reproduction',work)
                        except OSError as error:assert ordinal<2 and error.errno==5
                        except MemoryError:assert ordinal in (2,3)
                        else:assert ordinal==4
                    finally:
                        consumer.os.write=actual_write;consumer.os.open=actual_open;parent.close()
                    for opened_fd in state['opened']:
                        try:os.fstat(opened_fd)
                        except OSError as error:assert error.errno==9
                        else:raise AssertionError('private-copy counter failure leaked descriptor')
                    files=sorted((parent_path/'reproduction').iterdir())
                    rows=[{'name':path.name,'inode':path.stat().st_ino,'size':path.stat().st_size,
                           'mode':path.stat().st_mode & 0o777} for path in files]
                    if ordinal<2:
                        assert len(files)==1 and files[0].read_bytes()==original_capture[:3]
                        assert rows[0]['size']==3 and rows[0]['mode']==0o600
                    elif ordinal in (2,3):
                        assert len(files)==1 and work['copy_accounting_incomplete']
                        assert rows[0]['size']==(0 if ordinal==2 else len(original_capture))
                        if ordinal==3:assert work['close_observations_incomplete']
                    else:assert {row['name'] for row in rows}=={
                        'capture.json','complete.json','origin-observation.json','consumer-observations.json'}
                    retained.append(rows)
                    physical=sum(row['size'] for group in retained for row in group)
                    assert work['physical_bytes']==work['write_bytes']==physical
                    assert work['files']==sum(len(group) for group in retained)
                assert len(work['cases'])==5 and work['physical_bytes']>6
                assert all((private_parents[index]/'reproduction/capture.json').stat().st_ino==retained[index][0]['inode']
                           for index in (0,1))
                print(json.dumps({'two_failed_copies_and_two_counter_failures_retained_before_later_positive':retained,
                    'actual_shared_private_copy_work':work,
                    'later_copy_is_not_overall_recording_eligibility':True,
                    'additional_fixture_prefix_read_bytes':6,'additional_fixture_prefix_slice_copy_bytes':6,
                    'additional_fixture_prefix_comparison_input_bytes':12},sort_keys=True))
            else:assert refused,label
        except consumer.Refusal:
            assert label=='legacy-flat',label
            refused=True
        finally:
            if held is not None:held.close()
            if native is not None:native.close()
        assert (store/attempt_id/'receipt.json').read_bytes()==receipt
        assert (store/attempt_id/'payload/stdout').read_bytes()==b''
        print(json.dumps({'capture_admission_case':label,'refused':refused,
            'completion_constructor_is_fixture_owner':True,'ACL_admission_is_fixture_double':True,
            'host_publication_work':host._capture_process['publication_work'],
            'private_capture_work':getattr(native,'capture_work',None)},sort_keys=True))
PY_CAPTURE_ADMISSION
/usr/bin/python3 -I -S -B - "$root" <<'PY_CAPTURE_OBSERVER'
import errno
import io
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile

root=Path(sys.argv[1])
spec=importlib.util.spec_from_file_location('capture_observer_host',root/'sandbox/v1/host-supervisor.py')
host=importlib.util.module_from_spec(spec);spec.loader.exec_module(host)
for label in ('created-row-limit','open-row-limit','created-memory','open-memory','open-counter-memory','chown-memory-close','export-counter-memory'):
    with tempfile.TemporaryDirectory(prefix='ystack-capture-observer-') as temporary:
        area=Path(temporary).resolve();area.chmod(0o750)
        store=os.open(area,os.O_RDONLY|os.O_DIRECTORY)
        attempt_id='attempt.observer'
        attempt=host.mkdir_excl(store,attempt_id,os.getuid(),os.getgid())
        host.write_payload(attempt,os.getuid(),os.getgid(),[(b'stdout',b''),(b'stderr',b'')])
        request=host.canonical({'ordinary':'request'});receipt=host.canonical({'ordinary':'native receipt'})
        state={'opened':[],'closed':[],'append_failures':0,'actual_rows':[]}
        class Work(dict):
            def __setitem__(self,key,value):
                if label=='open-counter-memory' and key=='close_calls':
                    raise MemoryError('ordinary close accounting allocation failure')
                if label=='export-counter-memory' and key=='files' and value==2:
                    raise MemoryError('ordinary export file accounting allocation failure')
                return super().__setitem__(key,value)
        work=Work()
        class Rows(list):
            def append(self,row):
                selected=(label=='created-memory' and row['site']=='capture-directory-created'
                    or label in ('open-memory','open-counter-memory') and row['site']=='directory-open'
                    or label=='chown-memory-close' and row['site'] in ('directory-chown','directory-close'))
                if selected:
                    state['append_failures']+=1
                    raise MemoryError('ordinary private observer append fixture')
                super().append(row);state['actual_rows'].append(row)
        prestate=4095 if label=='created-row-limit' else 4093 if label=='open-row-limit' else 0
        work['operations']=Rows([{'capacity_prestate_only':True}]*prestate)
        host._capture_process={'rows':[],'driver_rest':[],'signals':[],'complete':True,
            'request_raw':request,'attempt_id':attempt_id,'publication_work':work}
        host._capture_clocks={'wall':[],'monotonic':[],'complete':True}
        if label=='export-counter-memory':
            host._capture_process.update(ordinals={},bytes=0)
            export=host.frame_write([(b'stdout',b''),(b'stderr',b'')]);export+=bytes(12582912-len(export))
            assert host._read_export_value(io.BytesIO(export))==export
        opening,closing,chowning=os.open,os.close,os.fchown
        def observed_open(name,*args,**kwargs):
            fd=opening(name,*args,**kwargs)
            if os.fsdecode(name).startswith('.capture-') or os.fsdecode(name)=='sandbox-export.bin':state['opened'].append(fd)
            return fd
        def observed_chown(fd,*args):
            if label=='chown-memory-close' and fd in state['opened']:
                raise OSError(errno.EIO,'ordinary original directory chown failure')
            return chowning(fd,*args)
        def observed_close(fd):
            if fd in state['opened']:
                state['closed'].append(fd);result=closing(fd)
                if label=='chown-memory-close':raise OSError(errno.EBADF,'ordinary secondary close failure')
                return result
            return closing(fd)
        try:
            host.os.open=observed_open;host.os.close=observed_close;host.os.fchown=observed_chown
            assert host.write_receipt_file(store,attempt,os.getuid(),os.getgid(),receipt) is None
        finally:host.os.open=opening;host.os.close=closing;host.os.fchown=chowning
        try:
            assert work['directories']==1 and not work['complete']
            assert work.get('observations_incomplete',False) or work.get('export_accounting_incomplete',False)
            assert sorted(state['opened'])==sorted(state['closed']) and len(set(state['closed']))==len(state['closed'])
            assert len(state['opened'])==(0 if label.startswith('created') else 2 if label=='export-counter-memory' else 1)
            if label=='open-counter-memory':assert work['close_observations_incomplete'] and 'close_calls' not in work
            else:assert work.get('close_calls',0)==(3 if label=='export-counter-memory' else len(state['opened']))
            for fd in state['closed']:
                try:os.fstat(fd)
                except OSError as error:assert error.errno==errno.EBADF
                else:raise AssertionError('private directory descriptor leaked')
            if label=='chown-memory-close':
                assert work['failure']['errno']==errno.EIO and work['close_failure']['errno']==errno.EBADF
                assert work['observation_failure']['category']=='MemoryError'
            elif label.endswith('row-limit'):
                assert work['failure']['category']=='Refusal' and len(work['operations'])==4096
            else:assert work['failure']['category']=='MemoryError'
            assert (area/attempt_id/'receipt.json').read_bytes()==receipt
            pending=area/('.capture-'+attempt_id+'.pending')
            assert pending.is_dir()
            if label=='export-counter-memory':
                assert {path.name for path in pending.iterdir()}=={'capture.json','sandbox-export.bin'}
                assert (pending/'sandbox-export.bin').stat().st_size==0 and work['files']==1
                assert work['export_accounting_incomplete']
            else:assert list(pending.iterdir())==[]
            print(json.dumps({'capture_observer_case':label,'capacity_row_prestate_only':prestate,
                'pending_inode':pending.stat().st_ino,'pending_mode':pending.stat().st_mode & 0o777,
                'state':state,'actual_work_without_capacity_placeholder_rows':
                    {key:value for key,value in work.items() if key!='operations'},
                'retained_operation_count':len(work['operations'])},sort_keys=True))
        finally:os.close(store)
PY_CAPTURE_OBSERVER
/usr/bin/python3 -I -S -B - "$root" <<'PY_CAPTURE_ACCOUNTING'
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types

root=Path(sys.argv[1])
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);sys.modules[name]=module;spec.loader.exec_module(module)
    return module
e=load('wm_enforced',root/'shadow/v1/enforced-reproduction.py');c=e.c
host=load('wm_host_values',root/'sandbox/v1/host-supervisor.py')
with tempfile.TemporaryDirectory(prefix='ystack-private-accounting-') as temporary:
    area=Path(temporary).resolve();path=area/'input';path.write_bytes(b'actual-input');path.chmod(0o400)
    leaf={};c._capture_work_values(leaf,'leaf');leaf.update(input_kind='L',metadata_kind='M')
    held=c._open_held(str(path),False,lambda *_:True,'E_STORE',recording_work=leaf,accounting_kind='M')
    assert held.read(64,'E_STORE',leaf)==b'actual-input'
    operation={};case=c._capture_work_values(operation,'case')
    first=c._capture_transfer_work(leaf,operation,case)
    assert first==operation['read_bytes']==case['read_bytes']
    before=json.dumps(operation,sort_keys=True);assert c._capture_transfer_work(leaf,operation,case)==0
    assert json.dumps(operation,sort_keys=True)==before
    held.close();tail=c._capture_transfer_work(leaf,operation,case)
    assert tail>0 and operation['held_close_calls']==leaf['held_close_calls'] and not held.components
    assert operation['accounting']['L']['read_bytes']==2*len(b'actual-input')
    assert operation['accounting']['M']['occurrences']==len(operation['accounting_rows'])
    assert sum(row.get('read_bytes',0) for row in operation['accounting'].values())==operation['read_bytes']
    try:c._capture_transfer_work(leaf,{},dict(case))
    except c.Refusal:pass
    else:raise AssertionError('cross-operation fee transfer accepted')
    print(json.dumps({'wm_real_held_read_transfer_repeat_close_tail':operation,
        'initial_read_charge':first,'later_close_charge':tail},sort_keys=True))
    failing={};c._capture_work_values(failing,'leaf')
    fd=c._open_held(str(path),False,lambda *_:True,'E_STORE',recording_work=failing,accounting_kind='M')
    fd.read(64,'E_STORE',failing);fd.close()
    class FailedCase(dict):
        def __setitem__(self,key,value):
            if key=='read_bytes':raise MemoryError('ordinary transfer counter allocation failure')
            return super().__setitem__(key,value)
    partial={};initial_case=c._capture_work_values(partial,'case');bad=FailedCase(initial_case)
    try:c._capture_transfer_work(failing,partial,bad)
    except MemoryError:pass
    else:raise AssertionError('partial transfer failure not reached')
    assert failing['transfer_incomplete'] and partial['transfer_incomplete'] and bad['transfer_incomplete']
    assert partial['read_bytes']==failing['read_bytes']
    prefix=dict(partial)
    try:c._capture_transfer_work(failing,partial,bad)
    except c.Refusal:pass
    else:raise AssertionError('incomplete transfer replayed')
    assert partial==prefix
    print(json.dumps({'wm_partial_transfer_actual_global_read':partial['read_bytes'],
        'case_read_counter':'UNKNOWN after allocation failure; initial value is not observed zero',
        'retry_refused_without_refund':True},sort_keys=True))
    error_work={};c._capture_work_values(error_work,'leaf')
    error_hold=c._open_held(str(path),False,lambda *_:True,'E_STORE',recording_work=error_work,accounting_kind='M')
    metadata=c._metadata
    def failed_metadata(fd):
        if fd==error_hold.fd:raise OSError(5,'ordinary observed metadata failure')
        return metadata(fd)
    try:
        c._metadata=failed_metadata
        try:error_hold.recheck('E_STORE')
        except c.Refusal:pass
        else:raise AssertionError('metadata failure accepted')
    finally:c._metadata=metadata;error_hold.close()
    errors=[row for row in error_work['accounting_rows'] if row['site']=='fstat-error']
    assert len(errors)==1 and errors[0]['value']['errno']==5
    error_total={};error_case=c._capture_work_values(error_total,'case')
    c._capture_transfer_work(error_work,error_total,error_case)
    assert any(row['field']=='metadata_failure' and row['value']['errno']==5 for row in error_total['leaf_failures'])
    print('ok actual metadata errno retained before original refusal and close')
    for boundary in ('open','dup'):
        work={};c._capture_work_values(work,'leaf')
        parent=c._open_held(str(area),True,lambda *_:True,'E_STORE')
        actual_open,actual_dup,actual_close=c.os.open,c.os.dup,c.os.close
        encode=c._private_capture_observations;opened=[];closed=[]
        def opening(*args,**kwargs):
            fd=actual_open(*args,**kwargs);opened.append(fd);return fd
        def duplicating(*args):
            fd=actual_dup(*args);opened.append(fd);return fd
        def closing(fd):
            if fd in opened:closed.append(fd)
            return actual_close(fd)
        def failed_encoding(value,*args):
            if value['site']==('fstat' if boundary=='open' else 'dup'):
                raise MemoryError('ordinary metadata encoding allocation failure')
            return encode(value,*args)
        try:
            c.os.open=opening;c.os.dup=duplicating;c.os.close=closing;c._private_capture_observations=failed_encoding
            try:
                if boundary=='open':c._open_held(str(path),False,lambda *_:True,'E_STORE',recording_work=work,accounting_kind='M')
                else:c._open_child(parent,'input',False,lambda *_:True,'E_STORE',recording_work=work,accounting_kind='M')
            except MemoryError:pass
            else:raise AssertionError('owned observation allocation failure did not occur')
        finally:c.os.open=actual_open;c.os.dup=actual_dup;c.os.close=actual_close;c._private_capture_observations=encode;parent.close()
        assert opened and sorted(opened)==sorted(closed) and work['accounting_incomplete']
        for fd in opened:
            try:os.fstat(fd)
            except OSError as error:assert error.errno==9
            else:raise AssertionError('observation failure leaked owned descriptor')
        print(json.dumps({'wm_observer_allocation_boundary':boundary,'actual_fds_closed':closed,
            'incomplete':work['accounting_incomplete']},sort_keys=True))
    owner=e._CaptureCompletionOwner()
    source_path=area/'source';source_path.write_bytes(b'ordinary owner bytes');source_path.chmod(0o400)
    installed=area/'installed';installed.mkdir(mode=0o700)
    installed_path=installed/'host-supervisor.py';installed_path.write_bytes(source_path.read_bytes());installed_path.chmod(0o400)
    source_hold=c._open_held(str(source_path),False,lambda *_:True,'E_STORE',recording_work=owner.work,accounting_kind='M')
    source_raw=source_hold.read(c.EXECUTABLE_LIMIT,'E_STORE',owner.work)
    owner.source=e.StableFile(source_hold,source_raw,owner.work);owner.module=host
    installed_hold=c._open_held(str(installed_path),False,lambda *_:True,'E_STORE')
    anchor=types.SimpleNamespace(held=[installed_hold],recording_work={},private_observations={})
    original_anchor=c.ANCHOR;c.ANCHOR=str(installed)
    try:
        request=host.canonical({'ordinary':'request'})
        capture=host._capture_values('attempt.wm',request,{'source_pages':{'coverage':[]}},True)
        witness=owner.construct(anchor,'attempt.wm',request,capture)
        assert witness==host._capture_completion_values('attempt.wm',request,capture)
        assert owner.work['accounting']['W']['read_bytes']==4*len(witness)
        assert owner.work['accounting']['raw']['read_bytes']==len(request)+len(capture)
        local=c._capture_work_values(anchor.recording_work,'case');owner.transfer(anchor.recording_work,local)
        before=anchor.recording_work['read_bytes'];e._close_capture_completion_owner(owner)
        owner.transfer(anchor.recording_work,local)
        assert anchor.recording_work['read_bytes']>before and owner.work['transferred_read_bytes']==owner.work['read_bytes']
        assert owner.work['close_calls']==1 and owner.work['held_close_calls']>0
        receipt=c._capture_accounting_receipt(anchor)
        assert receipt['classes']['W']['read_bytes']==4*len(witness)
        assert receipt['complete'] is False and receipt['host_publication_work'].startswith('UNKNOWN')
        print(json.dumps({'wm_actual_authenticate_construct_and_close_transfer':receipt,
            'startup_loader_and_installed_admission_are_fixture_inputs':True,
            'no_native_or_source_qualification':True},sort_keys=True))
    finally:c.ANCHOR=original_anchor;installed_hold.close();e._close_capture_completion_owner(owner)
PY_CAPTURE_ACCOUNTING
/usr/bin/python3 -I -S -B - "$root" <<'PY_CAPTURE_CANCEL_TAIL'
import importlib.util,json,os,signal,sys,tempfile,types
from pathlib import Path
root=Path(sys.argv[1])
spec=importlib.util.spec_from_file_location('wm_tail_reader',root/'scope/v1/read-shadow-evidence.py')
r=importlib.util.module_from_spec(spec);sys.modules[spec.name]=r;spec.loader.exec_module(r);c=r.c
cancel_code=next(code for code in r.main.__code__.co_consts if isinstance(code,types.CodeType) and code.co_name=='cancel')
cancel=types.FunctionType(cancel_code,{'InterruptedError':InterruptedError})
failures=[]
for label,first,tail in [('close-A-transfer-B',True,'transfer'),('close-A-receipt-B',True,'receipt'),
        ('transfer-B-only',False,'transfer'),('receipt-B-only',False,'receipt'),('native-and-tail-ordinary',False,'ordinary')]:
    with tempfile.TemporaryDirectory(prefix='ystack-wm-tail-') as temporary:
        events=[];close_calls={};held=[];fees={};c._capture_work_values(fees,'leaf')
        for index in range(2):
            path=Path(temporary)/str(index);path.write_bytes(b'actual held bytes');path.chmod(0o400)
            fd=os.open(path,os.O_RDONLY);close_calls[fd]=0
            item=c.HeldPath(str(path),[c.HeldComponent(fd,None,os.fstat(fd),lambda *_:True,False)])
            assert item.read(64,'E_STORE',fees)==b'actual held bytes';held.append(item)
        anchor=types.SimpleNamespace(recording_work={},private_observations={})
        local=c._capture_work_values(anchor.recording_work,'case')
        capture=object.__new__(c._HeldCaptureRead);capture.held=held;capture.work=fees;capture.anchor=anchor
        capture.attempt_id='attempt.tail';capture.transferred=0;capture.transfer_target=(anchor.recording_work,local)
        original_close=c.HeldPath.close;original_os_close=c.os.close
        original_transfer=c._capture_transfer_work;original_receipt=c._capture_accounting_receipt
        previous=signal.getsignal(signal.SIGTERM);state={'close':0,'transfer':0,'receipt':0}
        native_error=OSError(5,'ordinary native-close failure');tail_error=OSError(9,'ordinary tail failure')
        def handler(number,frame):
            try:cancel(number,frame)
            except InterruptedError as error:events.append(error);raise
        def interrupt():os.kill(os.getpid(),signal.SIGTERM)
        def closing_fd(fd):
            if fd in close_calls:close_calls[fd]+=1
            return original_os_close(fd)
        def closing(item):
            result=original_close(item);state['close']+=1
            if state['close']==1:
                if first:interrupt()
                if tail=='ordinary':raise native_error
            return result
        def transferring(source,work,case):
            result=original_transfer(source,work,case);state['transfer']+=1
            if tail=='transfer':interrupt()
            if tail=='ordinary':raise tail_error
            return result
        def receipt(actual_anchor):
            result=original_receipt(actual_anchor);state['receipt']+=1
            if tail=='receipt':interrupt()
            return result
        caught=None
        try:
            signal.signal(signal.SIGTERM,handler);c.HeldPath.close=closing;c.os.close=closing_fd
            c._capture_transfer_work=transferring;c._capture_accounting_receipt=receipt
            try:capture.close()
            except BaseException as error:caught=error
        finally:
            signal.signal(signal.SIGTERM,previous);c.HeldPath.close=original_close;c.os.close=original_os_close
            c._capture_transfer_work=original_transfer;c._capture_accounting_receipt=original_receipt
        assert fees['close_tail_incomplete']
        secondary=fees['close_tail_failure']
        assert secondary['stage']==('receipt' if tail=='receipt' else 'transfer')
        assert secondary['marked_cancel'] is (tail!='ordinary')
        assert secondary['category']==('OSError' if tail=='ordinary' else 'InterruptedError')
        assert secondary['primary_category']==('InterruptedError' if first else 'OSError' if tail=='ordinary' else None)
        if tail=='ordinary':assert secondary['errno']==9 and secondary['primary_errno']==5
        expected=native_error if tail=='ordinary' else events[0]
        same=caught is expected
        assert len(events)==(0 if tail=='ordinary' else 2 if first else 1)
        assert all(type(error) is InterruptedError and error._scope_signal_cancel for error in events)
        if first:assert events[0] is not events[1]
        assert state['close']==2 and state['transfer']==1 and all(count==1 for count in close_calls.values())
        assert capture.held==[] and all(item.components==[] for item in held)
        for fd in close_calls:
            try:os.fstat(fd)
            except OSError as error:assert error.errno==9
            else:raise AssertionError('descriptor not closed')
        assert anchor.recording_work['read_bytes']==fees['read_bytes']==fees['transferred_read_bytes']
        print(json.dumps({'case':label,'same_first_object':same,'distinct_real_handler_objects':first,
            'event_count':len(events),'caught_category':type(caught).__name__,'fd_close_counts':close_calls,
            'actual_calls':state,'source_work':fees,'operation_work':anchor.recording_work,
            'private_observations':anchor.private_observations},sort_keys=True))
        if not same:failures.append(label)
assert not failures,failures
PY_CAPTURE_CANCEL_TAIL
/usr/bin/python3 -I -S -B - "$root" <<'PY_SOURCE_CANCEL'
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import types

root=Path(sys.argv[1])
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);sys.modules[name]=module;spec.loader.exec_module(module)
    return module
r=load('source_cancel_reader',root/'scope/v1/read-shadow-evidence.py');c=r.c
host=load('source_cancel_host',root/'sandbox/v1/host-supervisor.py')
e=load('source_cancel_final',root/'shadow/v1/enforced-reproduction.py')
cancel_code=next(value for value in r.main.__code__.co_consts if isinstance(value,types.CodeType) and value.co_name=='cancel')
reader_cancel=types.FunctionType(cancel_code,{'InterruptedError':InterruptedError})
g=load('source_cancel_generator',root/'scope/v1/generate-gate-evidence.py')
generator_cancel_code=next(value for value in g.main.__code__.co_consts if isinstance(value,types.CodeType) and value.co_name=='cancel')
assert generator_cancel_code.co_freevars==('generator',)
for label in ('positive','io-eintr','io-error','copy-signal','copy-signal-close-error',
              'parent-close-signal','parent-close-eintr','open-signal','read-signal','constructor-read-signal',
              'seal-signal','seal-close-signal','seal-close-eintr',
              'generator-copy-signal','generator-seal-close-signal',
              'metadata-before-signal','metadata-after-signal','named-before-signal','named-after-signal',
              'metadata-eintr','named-eintr','copy-signal-target-close-error','copy-signal-directory-close-error',
              'target-close-signal','directory-close-signal','target-close-eintr','directory-close-eintr'):
    case=label[len('generator-'):] if label.startswith('generator-') else label
    generator_state=types.SimpleNamespace(active=True)
    cell=(lambda value:lambda:value)(generator_state).__closure__[0]
    cancel=(types.FunctionType(generator_cancel_code,{'InterruptedError':InterruptedError},closure=(cell,))
            if label.startswith('generator-') else reader_cancel)
    with tempfile.TemporaryDirectory(prefix='ystack-source-cancel-') as temporary:
        area=Path(temporary).resolve();area.chmod(0o700)
        observed=[];fired=[];closed=[];opened={};raw_closed=[]
        checking={'active':False,'metadata':0,'named':0}
        def handler(number,frame):
            try:cancel(number,frame)
            except InterruptedError as error:observed.append(error);raise
        previous=signal.signal(signal.SIGTERM,handler)
        raw=host.canonical({'ordinary':'source request'})
        captured=host._capture_values('attempt.cancel',raw,{'source_pages':{'coverage':[]}},True)
        work={};c._capture_work_values(work,'source-read')
        anchor=types.SimpleNamespace(identity_context={},private_observations={},recording_work={},resolver=None,
            capture_completion_owner=types.SimpleNamespace(authenticate=lambda anchor:None,transfer=lambda total,local:None))
        source=object.__new__(c._HeldCoverageRead)
        source.anchor=anchor;source.attempt_id='attempt.cancel';source.held=[object()]
        source.snapshots={'payload/request.json':raw};source.observation=b'{}\n';source.storage_rows=[]
        source.capture_origin=b'{}\n';source.capture_work=work
        source.capture=types.SimpleNamespace(snapshots={'capture.json':captured,
            'complete.json':host._capture_completion_values(source.attempt_id,raw,captured)},
            completion_owner=anchor.capture_completion_owner,anchor=anchor,transfer=lambda total,local:None)
        reader=object.__new__(r._Reader)
        reader.captures=area;reader.source_capture_ordinal=0;reader.source_capture_work=[]
        reader.inputs=[];reader.darwin=None;reader.store_session=None;reader.anchor=anchor;reader.enforced=e
        owned=r._Owned(reader)
        input_path=area/'held-input';input_path.write_bytes(b'fixed input');input_path.chmod(0o400)
        native_parent=None
        if case in {'read-signal','constructor-read-signal'}:
            native_store=area/'native-store';native_store.mkdir(mode=0o750);native_store.chmod(0o750)
            capture_directory=native_store/('.capture-'+source.attempt_id)
            capture_directory.mkdir(mode=0o750);capture_directory.chmod(0o750)
            for name,value in source.capture.snapshots.items():
                path=capture_directory/name;path.write_bytes(value);path.chmod(0o440)
            anchor.config={'store_root':str(native_store),'principal_uid':os.getuid(),'consumer_gid':os.getgid()}
            native_parent=c._open_held(str(native_store),True,lambda *args:True,'E_STORE')
            source.held=[native_parent]
        input_hold=c._open_held(str(input_path),False,lambda *args:True,'E_STORE')
        original_open,original_read,original_write,original_close=c.os.open,c.os.read,c.os.write,c.HeldPath.close
        original_os_close,original_metadata,original_named,original_recheck=c.os.close,c._metadata,c._named_metadata,c.HeldPath.recheck
        original_dup=c.os.dup
        original_acl=c._acl_state
        def interrupt():
            fired.append(case);os.kill(os.getpid(),signal.SIGTERM)
            raise AssertionError('signal handler did not raise')
        def opening(*args,**kwargs):
            if case=='open-signal' and not fired:interrupt()
            fd=original_open(*args,**kwargs);opened[fd]=os.fsdecode(args[0]);return fd
        def duplicating(fd):
            copied=original_dup(fd);opened[copied]='dup';return copied
        def metadata(fd):
            if checking['active']:
                checking['metadata']+=1
                if not fired and ((case=='metadata-before-signal' and checking['metadata']==1)
                                  or (case=='metadata-after-signal' and checking['metadata']==2)):interrupt()
                if not fired and case=='metadata-eintr':
                    fired.append(case);raise InterruptedError(4,'ordinary metadata EINTR')
            return original_metadata(fd)
        def named(*args):
            if checking['active']:
                checking['named']+=1
                if not fired and ((case=='named-before-signal' and checking['named']==1)
                                  or (case=='named-after-signal' and checking['named']==2)):interrupt()
                if not fired and case=='named-eintr':
                    fired.append(case);raise InterruptedError(4,'ordinary named metadata EINTR')
            return original_named(*args)
        def rechecking(held,code,*args,**kwargs):
            checking.update(active=True,metadata=0,named=0)
            try:return original_recheck(held,code,*args,**kwargs)
            finally:checking['active']=False
        def reading(*args):
            if case in {'read-signal','constructor-read-signal','seal-signal'} and not fired:interrupt()
            return original_read(*args)
        def writing(*args):
            if not fired:
                if case.startswith('copy-signal'):interrupt()
                if case in {'io-eintr','io-error'}:
                    fired.append(case)
                    raise InterruptedError(4,'ordinary I/O EINTR') if case=='io-eintr' else OSError(5,'ordinary I/O error')
            return original_write(*args)
        def closing(held):
            result=original_close(held);closed.append(len(held.components))
            if not fired and case in {'parent-close-signal','seal-close-signal'}:interrupt()
            if not fired and case in {'parent-close-eintr','seal-close-eintr'}:
                fired.append(case);raise InterruptedError(4,'ordinary close EINTR')
            if case=='copy-signal-close-error':raise OSError(9,'ordinary secondary close failure')
            return result
        def raw_closing(fd):
            role=opened.pop(fd,None)
            result=original_os_close(fd);raw_closed.append(role)
            target=role=='capture.json';directory=role=='source-0000'
            if ((case=='copy-signal-target-close-error' and target)
                    or (case=='copy-signal-directory-close-error' and directory)):
                raise OSError(9,'ordinary raw secondary close failure')
            if not fired:
                if (case=='target-close-signal' and target) or (case=='directory-close-signal' and directory):interrupt()
                if (case=='target-close-eintr' and target) or (case=='directory-close-eintr' and directory):
                    fired.append(case);raise InterruptedError(4,'ordinary raw close EINTR')
            return result
        if case.startswith('seal-'):
            anchor.capture_completion_owner=types.SimpleNamespace(source=e.StableFile(input_hold,b'fixed input',work),
                work=work,transfer=lambda total,local:c._capture_transfer_work(work,total,local))
        caught=None
        try:
            c.os.open=opening;c.os.read=reading;c.os.write=writing;c.HeldPath.close=closing
            c.os.close=raw_closing;c._metadata=metadata;c._named_metadata=named;c.HeldPath.recheck=rechecking
            c.os.dup=duplicating
            c._acl_state=lambda *args:([],None) if sys.platform=='darwin' else (None,None)
            try:
                if case.startswith('seal-'):reader.seal_source_captures()
                elif case=='read-signal':
                    del source.capture
                    source.record_source(raw)
                elif case=='constructor-read-signal':
                    original_native_reader=c.read_coverage_attempt
                    constructed=[]
                    def native_reader(anchor,configuration,request_raw,*,_owner):
                        _owner.held=[native_parent];_owner.storage_rows=[];constructed.append(_owner)
                        return {'payload/request.json':request_raw},b'{}\n'
                    c.read_coverage_attempt=native_reader
                    try:c._HeldCoverageRead(anchor,types.SimpleNamespace(normalizer=types.SimpleNamespace(
                        request=lambda raw:{'id':'attempt.cancel'})),raw)
                    finally:
                        c.read_coverage_attempt=original_native_reader
                        if constructed:source=constructed[0]
                else:owned.append(source)
            except BaseException as error:caught=error
            if 'signal' in case:
                assert len(observed)==1 and caught is observed[0]
                assert type(caught) is InterruptedError and caught._scope_signal_cancel is True
                assert anchor.private_observations['unusable'] is True
            else:
                assert caught is None and owned==([] if case.startswith('seal-') else [source])
                assert bool(anchor.private_observations.get('unusable')) is (case!='positive')
            if case=='positive':assert len(list((area/'source-0000').iterdir()))==4
            if case.startswith('seal-'):
                assert work['transferred_read_bytes']==work['read_bytes']==anchor.recording_work['read_bytes']
                assert anchor.private_observations['recording_sealed'] is False
            assert not opened and all(value==0 for value in closed)
            if 'metadata-' in case or 'named-' in case:
                assert checking['metadata']>0
                if case.startswith('named-'):assert checking['named']>0
            if case in {'copy-signal-target-close-error','copy-signal-directory-close-error'}:
                assert any(row['errno']==9 for row in anchor.recording_work['close_failures'])
            if case=='constructor-read-signal':assert source.held==[] and native_parent.components==[]
            if label.startswith('generator-'):assert generator_state.active is False
            print(json.dumps({'actual_source_copy_append_or_seal_control':label,
                'actual_handler_signal':bool(observed),'same_cancel_object':caught is observed[0] if observed else None,
                'normalizer_session_installation_and_copy_inputs_are_fixture_doubles':True,
                'private_observations':anchor.private_observations,'copy_work':anchor.recording_work,
                'read_work':source.capture_work,'closed_components':closed,'metadata_calls':checking,
                'raw_closed_roles':raw_closed,'all_new_fds_closed':not opened},sort_keys=True))
        finally:
            c.os.open=original_open;c.os.read=original_read;c.os.write=original_write;c.HeldPath.close=original_close
            c.os.close=original_os_close;c._metadata=original_metadata;c._named_metadata=original_named;c.HeldPath.recheck=original_recheck
            c.os.dup=original_dup
            c._acl_state=original_acl;signal.signal(signal.SIGTERM,previous)
            input_hold.close()
            if native_parent is not None:native_parent.close()
PY_SOURCE_CANCEL
capture_python=$(/usr/bin/python3 -I -S -B -c 'import os,sys;print(os.path.realpath(sys.executable))')
for capture_route in reproduce write; do
  for capture_drift in stable file parent native-failure; do
    "$capture_python" -I -S -B - "$root" "$capture_route" "$capture_drift" <<'PY_CAPTURE_FINAL'
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types

original,route,drift=Path(sys.argv[1]),sys.argv[2],sys.argv[3]
with tempfile.TemporaryDirectory(prefix='ystack-capture-final-') as temporary:
    area=Path(temporary).resolve()
    package=area/'source'
    copied=0
    for relative in ('shadow/v1/_consumer.py','shadow/v1/enforced-reproduction.py',
                     'shadow/v1/write-shadow.py','sandbox/v1/host-supervisor.py'):
        path=package/relative;path.parent.mkdir(parents=True,exist_ok=True)
        raw=(original/relative).read_bytes();copied+=len(raw);path.write_bytes(raw);path.chmod(0o440)
    relative='shadow/v1/write-shadow.py' if route=='write' else 'shadow/v1/enforced-reproduction.py'
    spec=importlib.util.spec_from_file_location('fixed_capture_main',package/relative)
    entry=importlib.util.module_from_spec(spec);sys.modules[spec.name]=entry;spec.loader.exec_module(entry)
    e=entry.e if route=='write' else entry
    events=[]
    class Native:
        def __init__(self,*args):self.state='native-release.pending';events.append('native-created')
        def recheck(self):events.append('native-recheck')
        def block_entry(self):events.append('block-entry')
        def arm_consumer(self):events.append('arm-consumer')
        def checkpoint(self):return 'native-checkpoint.clear'
        def hold_completion(self,fd):events.append('hold-completion')
        def block_final(self):events.append('block-final')
        def outcome(self):return self.state
        def commit_completion(self,raw):
            self.state='native-release.success';events.append('native-committed')
        def abort_release(self):self.state='native-release.failure';events.append('native-aborted')
        def close(self):
            events.append('native-close')
            if drift=='native-failure':raise OSError(5,'ordinary original native close failure')
    e._NativeRelease=Native
    e.c.capture_parent_context=lambda:{}
    admission=e._StartupAdmission(e._STARTUP_KEY,sys.executable,
        e.sha(Path(sys.executable).read_bytes()),sys.version,tuple(sys.version_info[:2]),(),
        types.SimpleNamespace(observe=lambda:events.append('census')))
    installed=area/'installed';installed.mkdir()
    installed_host=installed/'host-supervisor.py'
    installed_host.write_bytes((package/'sandbox/v1/host-supervisor.py').read_bytes());installed_host.chmod(0o440)
    e.c.ANCHOR=str(installed)
    work=area/'work';work.mkdir(mode=0o700)
    output=area/'output';output.mkdir(mode=0o700)
    installed_hold=e.c._open_held(str(installed_host),False,lambda *args:True,'E_STORE')
    anchor=types.SimpleNamespace(held=[installed_hold],private_observations={},recording_work={},
        seal_recheck=lambda:events.append('anchor-final'))
    work_hold=e.stable_directory(work);output_hold=e.stable_directory(output)
    incident={'id':'incident.ordinary','body':{'git_revision_ref':'a'*40}}
    def drift_after_authentication():
        assert e.CancellationSignals.active is not None
        e._bind_capture_completion_owner(anchor)
        assert getattr(anchor,'capture_completion_owner',None) is not None, (
            anchor.private_observations,e._CAPTURE_OWNER_WORK)
        assert anchor.capture_completion_owner is e.CancellationSignals.active.admission.capture_owner
        anchor.capture_completion_owner.authenticate(anchor)
        events.append('last-authentication')
        path=package/'sandbox/v1/host-supervisor.py'
        if drift=='file':path.chmod(0o640);path.write_bytes(path.read_bytes()+b'\n');path.chmod(0o440)
        elif drift=='parent':path.parent.rename(path.parent.with_name('v1-moved'))
        if drift in {'file','parent'}:events.append('source-drift')
    if route=='reproduce':
        def reproduce(*args,**kwargs):
            drift_after_authentication()
            files={name:b'{}\n' for name in e.EVIDENCE_NAMES}
            e.seal(output,output_hold,files,incident,'enforced-reproduction.v1',
                   _capture=(anchor,work_hold.held,None))
        e.reproduce=reproduce
        argv=['entry','reproduce','request',str(work),str(output)]
    else:
        frozen=work/'frozen';frozen.mkdir();captured=work/'captured';captured.mkdir()
        for name in entry.NAMES:(frozen/name).write_bytes(e.canonical(incident if name=='incident.json' else
            {'body':{'outcome':'match'}} if name=='file-digest-result.json' else {'id':'ordinary'}))
        for name in ('claim.json','duty_evaluation.json'):(captured/name).write_bytes(e.canonical({'id':'ordinary'}))
        materialized=types.SimpleNamespace(candidate_tree_id='a'*40,write_set=[],verification_files={},
            input_raw=e.canonical({'stage_request':{'content':{'body':{}}}}),
            **{name:b'{}\n' for name in ('response_raw','preparation_record_raw','preparation_manifest_raw',
                'qualified_identity_raw','evaluation_raw')})
        class Workspace:
            def __init__(self,*args):
                self.record_form='withheld-write.v1';self.request_doc={'id':'ordinary','body':{'scope_id':'scope.ordinary'}}
                self.anchor=anchor;self.output_hold=output_hold;self.work_hold=work_hold
                self.launch_holds=[types.SimpleNamespace()];self.checks=0
                drift_after_authentication()
            def capture(self,name,raw):path=captured/name;path.write_bytes(raw);return path
            def component(self,*args):return b'{}\n'
            def recheck(self,**kwargs):self.checks+=1;events.append('workspace-final')
            def close(self):events.append('workspace-close')
        entry._Workspace=Workspace;entry._materialize=lambda ws:materialized
        entry._publisher=lambda *args:({},b'ordinary publisher')
        entry._write_section_values=lambda *args:{};entry._admit=lambda *args:None
        e.trace_ledger=lambda *args:b'{}\n'
        argv=['entry','prepare','request','bundle',str(work),str(output)]
    try:
        result=entry.main(argv,admission)
        assert result==(1 if drift=='native-failure' else 0),(result,events)
        assert anchor.private_observations['recording_sealed'] is (drift not in {'file','parent'})
        owner=anchor.capture_completion_owner
        assert owner.source_closed and owner.work['close_calls']==1
        assert owner.transferred==owner.work['read_bytes']==anchor.recording_work['read_bytes']
        assert sum(case['read_bytes'] for case in anchor.recording_work['cases'].values())==owner.work['read_bytes']
        assert events.index('last-authentication')<events.index('hold-completion')
        print(json.dumps({'actual_main_signals_and_final_seal':route,'source_control':drift,
            'native_backend_thread_census_parent_context_materialization_and_install_admission_are_fixture_doubles':True,
            'not_native_or_complete_pipeline_qualification':True,'result':result,'events':events,
            'fixture_source_copy_bytes':copied,'final_private_observations':anchor.private_observations,
            'owner_work':owner.work,'recording_work':anchor.recording_work},sort_keys=True))
    finally:installed_hold.close();work_hold.close();output_hold.close()
PY_CAPTURE_FINAL
  done
done
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
runtime_wire = {'git_version':b'git version ordinary\n'.hex(),'python_version':'ordinary python','unicode_version':'16.0.0'}
assert replay._preparation_runtime_values(root,runtime_wire) == dict(runtime_wire,git_version=b'git version ordinary\n')
for label,change in [('missing',lambda v:v.pop('git_version')),('extra',lambda v:v.update(argv=[])),
        ('wrong-type',lambda v:v.update(python_version=True)),('over-limit',lambda v:v.update(git_version='00'*129))]:
    changed = dict(runtime_wire);change(changed)
    try:replay._preparation_runtime_values(root,changed)
    except Exception as error:assert type(error).__name__ == 'Refusal',label
    else:raise AssertionError('runtime values '+label)
native_values = {'platform':'darwin','architecture':'arm64','python_implementation':'cpython',
    'python_version':'ordinary qualified Python','soabi':'cpython-ordinary','ext_suffix':'.ordinary.so',
    'configuration':{key:None for key in launch._NATIVE_CONFIGURATION_KEYS}}
native_locators = {'compiler':'/historical/compiler','include':'/historical/include',
    'config_include':'/historical/config-include','source':'/historical/source.c','binary':'/historical/output.so'}
native_argv = launch._native_argv_values(native_values['platform'], **native_locators)
assert replay._native_runtime_values(root,native_values,native_locators) == native_argv
assert native_argv == ['/historical/compiler','-std=gnu11','-Wall','-Wextra','-Werror',
    '-O2','-fvisibility=hidden','-fPIC','-I/historical/include','-I/historical/config-include',
    '-bundle','-undefined','dynamic_lookup','/historical/source.c','-o','/historical/output.so']
linux_values = dict(native_values,platform='linux')
assert replay._native_runtime_values(root,linux_values,native_locators) == launch._native_argv_values('linux', **native_locators)
old_active = launch.CancellationSignals.active
try:
    native = object.__new__(launch._NativeRelease)
    native.runtime_values = {'values':native_values,'locators':native_locators}
    launch.CancellationSignals.active = types.SimpleNamespace(native=native)
    retained_anchor = types.SimpleNamespace(private_observations={})
    launch._retain_native_runtime(retained_anchor)
    assert retained_anchor.private_observations == {'commands':{'runtime_values':[native.runtime_values]}}
finally:launch.CancellationSignals.active = old_active
import copy
for label,change in [('missing',lambda v:v.pop('soabi')),('extra',lambda v:v.update(argv=[])),
        ('wrong-type',lambda v:v.update(python_version=True)),
        ('over-version',lambda v:v.update(python_version='x'*129)),
        ('surrogate',lambda v:v.update(soabi='\ud800')),
        ('configuration-missing',lambda v:v['configuration'].pop('Py_DEBUG')),
        ('configuration-extra',lambda v:v['configuration'].update(derived_output=True)),
        ('configuration-type',lambda v:v['configuration'].update(Py_DEBUG=[]))]:
    changed = copy.deepcopy(native_values);change(changed)
    try:replay._native_runtime_values(root,changed,native_locators)
    except Exception as error:assert type(error).__name__ == 'Refusal',label
    else:raise AssertionError('native runtime '+label)
for label,change in [('missing',lambda v:v.pop('include')),('extra',lambda v:v.update(selector='other')),
        ('type',lambda v:v.update(binary=[])),('bound',lambda v:v.update(include='x'*4097))]:
    changed = dict(native_locators);change(changed)
    try:replay._native_runtime_values(root,native_values,changed)
    except Exception as error:assert type(error).__name__ == 'Refusal',label
    else:raise AssertionError('native locator '+label)
print('ok RAW15 shared native recipe/private retention/offline config and locator matrix; synthetic facts, native loader NOTRUN')
principal = 1 if launch.os.getuid() != 1 and launch.os.geteuid() != 1 else 2
actual_context = launch.c._anchor_identity_context(principal,launch.os.getgid(),None,None)
assert replay._identity_context_values(root,actual_context,principal,launch.os.getgid()) == actual_context
resolver = object.__new__(launch._DarwinUUIDResolver)
resolver.owner = object.__new__(launch.c._DarwinChildOwner)
resolver.owner.uuid_replies = []
resolver.owner.group_replies = []
resolver.owner.observation_bytes = 0
resolver.owner.observations_complete = True
group_reader = launch._DarwinGroupReader(resolver)
assert resolver.raw_uuid_replies() is resolver.owner.uuid_replies
assert group_reader.raw_group_replies() is resolver.owner.group_replies
uuid = '01'*16
uuid_output = launch.c.canonical([{'uuid':uuid,'status':'resolved','kind':'user','id':launch.os.getuid()}])
resolver.owner._retain_identity_reply(resolver.owner.uuid_replies,{'uuids':[uuid]},uuid_output)
wire_context = dict(actual_context,platform='darwin',uuid_replies=resolver.raw_uuid_replies(),
                    group_replies=list(group_reader.raw_group_replies()))
assert replay._identity_context_values(root,wire_context,principal,launch.os.getgid()) == wire_context
assert resolver.observations_complete is True
resolver.owner.observations_complete = False
assert resolver.observations_complete is False
query_gid = max(launch.os.getgid(),launch.os.getegid())+1
group_wire = launch.c.canonical([query_gid])
def fixed_group_wire(operation,raw,cap,context):
    assert operation == '_read-darwin-group' and raw == launch.c.canonical({'gid':query_gid}) and cap == 16
    return group_wire
resolver.owner._fixed = fixed_group_wire
assert resolver.owner.contains(query_gid) is True
group_context = dict(actual_context,platform='darwin',groups=None,
    uuid_replies=resolver.raw_uuid_replies(),group_replies=group_reader.raw_group_replies())
assert replay._identity_context_values(root,group_context,principal,query_gid) == group_context
import copy
assert replay._identity_context_values(root,wire_context,principal,launch.os.getgid()) == wire_context
for label,change in [('missing',lambda v:v.pop('uid')),('extra',lambda v:v.update(authenticated=True)),
        ('wrong-type',lambda v:v.update(uid=True)),('invalid',lambda v:v.update(euid=-1)),
        ('wrong-platform-type',lambda v:v.update(platform=[])),
        ('uuid-bytes',lambda v:v['uuid_replies'][0].update(bytes='zz'))]:
    changed = copy.deepcopy(wire_context);change(changed)
    try:replay._identity_context_values(root,changed,principal,launch.os.getgid())
    except Exception as error:assert type(error).__name__ == 'Refusal',label
    else:raise AssertionError('identity context '+label)
print('ok actual uid/gid acquisition/offline membership owners; Darwin wrapper raw reply and overflow forwarding; synthetic UUID wire only')
with preparation.tempfile.TemporaryDirectory(prefix='ystack-private-recording-parent-') as directory:
    work = Path(directory).resolve()
    holder = launch.stable_directory(work)
    try:
        (work/'owned-output').write_bytes(b'ordinary owned workspace output')
        try:holder.held.recheck('E_STORE')
        except launch.c.Refusal:pass
        else:raise AssertionError('old bookkeeping snapshot unexpectedly fresh')
        holder._recording_parent().recheck('E_STORE')
        work.chmod(0o750)
        try:holder._recording_parent()
        except launch.Refusal:pass
        else:raise AssertionError('recording parent accepted mode drift')
    finally:holder.close()
print('ok actual StableDirectory recorder boundary accepts owned bookkeeping and rejects mode drift')
with preparation.tempfile.TemporaryDirectory(prefix='ystack-preparation-relay-') as directory:
    work = Path(directory).resolve();scratch_root = work/'preparation-scratch';scratch_root.mkdir(mode=0o700)
    holder = launch.stable_directory(work)
    private_owner = load('private_preparation_capture_producer',root/'preparation/v1/prepare-candidate.py')
    boundary = private_owner.hold_boundary(scratch_root,'directory',private_owner.time.monotonic()+30,private_leaf=True)
    ctx = private_owner.create_context(types.SimpleNamespace(operation='prepare',scratch=str(scratch_root),
        _boundaries={'scratch':boundary}),private_owner.time.monotonic()+30)
    input_bytes,response_bytes = b'ordinary input bytes',b'ordinary response bytes'
    ctx.input_hashes = {'input':private_owner.sha256(input_bytes),'response':private_owner.sha256(response_bytes)}
    private_owner._preparation_observations['runtime_values'].append(runtime_wire)
    old_acl = launch.c._acl_state
    launch.c._acl_state = lambda *_:([],None) if sys.platform == 'darwin' else (None,None)
    try:
        private_owner._write_preparation_observations(ctx,True)
        raw = (ctx.scratch/'capture.json').read_bytes()
        consumer_anchor = launch.c.Anchor({},b'',[],{},('',[]),('',[]),None)
        before_modules = set(sys.modules)
        retained_capture = holder._retain_preparation(consumer_anchor,'preparation-scratch','prepare',input_bytes,response_bytes)
        assert set(sys.modules) == before_modules
        assert retained_capture == replay._preparation_capture_values(root,raw,ctx.scratch.name,'prepare',input_bytes,response_bytes)
        assert consumer_anchor.recording_work['read_bytes'] == 8*len(raw)
        assert consumer_anchor.private_observations['preparation']['prepare'] == retained_capture
        print('ok private preparation producer/held relay before cleanup/offline parser; synthetic version-wire transport fixture only')
    finally:
        launch.c._acl_state = old_acl
        ctx.close_boundaries();holder.close()
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
        context = preparation.create_context(types.SimpleNamespace(operation='prepare',scratch=str(scratch),
            _boundaries={'scratch':boundary}),deadline)
        try:
            retained = preparation._preparation_names[-1]
            assert retained == [{'entropy':observed[0],'errno':preparation.errno.EEXIST},
                                {'entropy':observed[1],'errno':None}]
            assert context.scratch.name == preparation._preparation_names_values(observed,[True,False])
            assert context.scratch.name == replay._preparation_workspace_values(root,retained)
            assert context.scratch.is_dir() and len(observed) == 2
            repository = scratch/'repository';repository.mkdir(mode=0o700)
            for name in ('objects','objects/info','objects/pack','refs','refs/heads','refs/tags'):
                (repository/name).mkdir(mode=0o700)
            source_files = {'HEAD':b'ref: refs/heads/candidate\n','config':b'[core]\n bare = true\n',
                            'refs/heads/candidate':b'1'*40+b'\n'}
            for name,raw in source_files.items():(repository/name).write_bytes(raw)
            context.args.candidate_repository = str(repository)
            context.boundaries['candidate_repository'] = preparation.hold_boundary(repository,'directory',deadline,private_leaf=True)
            context.algorithm = 'sha1'
            start = len(preparation._preparation_observations['storage'])
            facts,actual_storage = preparation.enumerate_storage(context)
            storage_events = preparation._preparation_observations['storage'][start:]
            assert replay._preparation_storage_values(root,storage_events,source_files,'sha1') == [actual_storage]
            assert set(facts) == set(source_files)
            for label,change in [('missing',lambda v:v[0].pop('stat')),
                    ('extra',lambda v:v[0].update(extra=True)),
                    ('wrong-type',lambda v:v[0]['stat'].update(ino=True)),
                    ('invalid',lambda v:v.pop())]:
                changed = copy.deepcopy(storage_events);change(changed)
                try:replay._preparation_storage_values(root,changed,source_files,'sha1')
                except Exception as error:assert type(error).__name__ == 'Refusal',label
                else:raise AssertionError('preparation storage '+label)
            native_ledger = preparation.dataclasses.asdict(context.ledger)
            preparation._write_preparation_observations(context,False)
            private_capture = context.scratch/'capture.json'
            assert private_capture.stat().st_mode & 0o777 == 0o400
            captured = preparation.strict_json(private_capture.read_bytes(),'E_INPUT')
            assert captured['complete'] is False and captured['entropy']['preparation_names'][-1] == retained
            assert preparation.dataclasses.asdict(context.ledger) == native_ledger
            assert context.recording_work['write_bytes'] == private_capture.stat().st_size
            print('ok actual preparation stat acquisition/storage owner/private capture; incomplete fixture never seeded')
            for label,rows,token in [
                    ('missing',[{'entropy':observed[0]}],'E_INPUT'),
                    ('extra',[{'entropy':observed[0],'errno':None,'extra':1}],'E_INPUT'),
                    ('wrong-type',[{'entropy':observed[0],'errno':True}],'E_INPUT'),
                    ('invalid-errno',[{'entropy':observed[0],'errno':2147483648}],'E_INPUT'),
                    ('failed-mkdir',[{'entropy':observed[0],'errno':preparation.errno.EACCES}],'E_IO'),
                    ('unused-after-success',retained+[{'entropy':observed[0],'errno':None}],'E_INPUT'),
                    ('over-128',[{'entropy':observed[0],'errno':preparation.errno.EEXIST}]*129,'E_INPUT')]:
                for owner in (preparation,sys.modules['malicious_workspace_values']):
                    try: owner._preparation_workspace_values(rows)
                    except owner.Refusal as error: assert error.token == token,(label,error.token)
                    else: raise AssertionError('preparation raw workspace '+label)
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
