#!/bin/bash
set -euo pipefail
{ [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = --pure ]; }; } || { printf '%s\n' 'usage: scope-gate-generation.test.sh --pure' >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
python_bin=$(command -v python3)
python_bin=$("$python_bin" -I -S -B -c 'import os,sys;print(os.path.realpath(sys.executable))')
"$python_bin" -I -S -B - "$repo" <<'PY'
import copy,hashlib,importlib.util,pathlib,sys
root=pathlib.Path(sys.argv[1])
spec=importlib.util.spec_from_file_location('gate_source',root/'sandbox/v1/coverage-source.py')
n=importlib.util.module_from_spec(spec);sys.modules[spec.name]=n;spec.loader.exec_module(n)
checks=0
def check(value):
    global checks
    assert value
    checks+=1
def reject(fn,*args):
    global checks
    try:fn(*args)
    except (n.Refusal,KeyError,TypeError,ValueError):checks+=1
    else:raise AssertionError('accepted malformed source')
def env(kind,id,body):return dict(schema_version=1,kind=kind,id=id,body=body)
def obj(kind,raw):return hashlib.sha1(kind.encode()+b' '+str(len(raw)).encode()+b'\0'+raw).hexdigest()
def gitrow(register,parent=None,second=None):
    raw=n.canonical(register);blob=obj('blob',raw)
    inner=b'100644 kill-switch.json\0'+bytes.fromhex(blob);inneroid=obj('tree',inner)
    tree=b'40000 config\0'+bytes.fromhex(inneroid);treeoid=obj('tree',tree)
    commit=b'tree '+treeoid.encode()+b'\n'
    for oid in (parent,second):
        if oid:commit+=b'parent '+oid.encode()+b'\n'
    commit+=b'author Operator <operator@example.invalid> 1 +0000\ncommitter Operator <operator@example.invalid> 1 +0000\n\nregister\n'
    return dict(commit_id=obj('commit',commit),commit_hex=commit.hex(),trees=[dict(oid=treeoid,raw_hex=tree.hex()),dict(oid=inneroid,raw_hex=inner.hex())],register_hex=raw.hex())
register=env('kill_switch_register','register.control',dict(revision=1,authority_epoch='epoch.one',entries=[dict(scope_kind=k,scope_id=v,state='cleared') for k,v in [('global','*'),('repository','repo.target'),('workflow','workflow.test')]],write_entries=[]))
check(n.kill_register(n.canonical(register))==register)
for field,value in [('revision',True),('revision',0),('revision',2**53),('authority_epoch','')]:
    bad=copy.deepcopy(register);bad['body'][field]=value;reject(n.kill_register,n.canonical(bad))
for transform in [lambda b:b['entries'].append(b['entries'][0]),lambda b:b['entries'].reverse(),lambda b:b['entries'][0].update(scope_id='x'),lambda b:b['entries'][0].update(scope_kind='stage'),lambda b:b['write_entries'].append(dict(scope_id='scope.test',state='unknown'))]:
    bad=copy.deepcopy(register);transform(bad['body']);reject(n.kill_register,n.canonical(bad))
reject(n.kill_register,n.canonical(register)+b' ')
reject(n.document,b'{"x":1,"x":1}\n')
first=gitrow(register)
owner=dict(schema_version=1,kind='operator_identity',id='owner.fixed',sha256='a'*64)
boot=dict(commit_id=first['commit_id'],register_sha256=n.digest(n.canonical(register)),revision=1,authority_epoch='epoch.one',owner_identity=owner,event_sequence=40)
body={key:dict(schema_version=1,kind='binding',id='binding.'+key.replace('_','-'),sha256='b'*64) for key in n.KILL_BINDINGS}
body.update(operation=n.KILL_OPERATION,version=1,call_id='kill-register.'+'c'*64,nonce='c'*64,target_repository_id='repo.target',control_repository=dict(repository_id='repo.control',node_id='R_control',hash_algorithm='sha1'),default_branch=dict(name='main',node_id='REF_main'),bootstrap=boot,bundle_refs=[owner],initial_origin_refs=[owner],git_observation_sha256='d'*64)
request=n.canonical(env('kill_register_source_request',body['call_id'],body))
check(n.kill_request(request)['body']==body)
def pages_for(commits,events=None,merges=None):
    tip=commits[-1]['commit_id'];events=events or [];merges=merges or []
    return [n.canonical(dict(schema_version=1,repository=body['control_repository'],default_branch=body['default_branch'],before=dict(commit_id=tip,observed_at='2026-10-23T00:00:00Z'),after=dict(commit_id=tip,observed_at='2026-10-23T00:00:01Z'),start_sequence=40,end_sequence=40+len(events))),n.canonical(dict(schema_version=1,commits=commits)),n.canonical(dict(schema_version=1,events=events)),n.canonical(dict(schema_version=1,merges=merges))]
def framed(pages):
    capture=n.canonical(dict(pages=[dict(family=f,page_index=0,response_status=200,input_cursor=None,output_cursor=None) for f in n.KILL_FAMILIES]))
    return [(b'capture.json',capture)]+[(f'raw/{i:04d}'.encode(),p) for i,p in enumerate(pages)]
def normalize(pages,req=request):
    manifest,raw=n._KillNormalizer.captured(framed(pages),req)
    return n.kill_normalize(manifest,raw,req)
check(n.document(normalize(pages_for([first])))['register']==register)
second_register=copy.deepcopy(register);second_register['body']['revision']=2;second_register['body']['entries'][0]['state']='stop'
second=gitrow(second_register,first['commit_id'],'f'*40)
event=dict(sequence=41,before=first['commit_id'],after=second['commit_id'],branch_node_id='REF_main',actor=owner,action='update',at='2026-10-23T00:00:00Z')
merge=dict(pull_request_id='PR_1',repository_node_id='R_control',branch_node_id='REF_main',base=first['commit_id'],head='f'*40,merge=second['commit_id'],parents=[first['commit_id'],'f'*40],path='config/kill-switch.json',blob_oid=obj('blob',n.canonical(second_register)),actor=owner,owner_authorization=dict(identity=owner,repository_node_id='R_control',permission='owner',valid_at='2026-10-23T00:00:00Z'),merged_at='2026-10-23T00:00:00Z')
pages=pages_for([first,second],[event],[merge]);check(n.document(normalize(pages))['register']==second_register)
for family,key,value in [(0,'repository',dict(repository_id='repo.target',node_id='R_control',hash_algorithm='sha1')),(0,'end_sequence',42),(0,'before',dict(commit_id=first['commit_id'],observed_at='2026-10-23T00:00:00Z')),(3,'merges',[])]:
    bad=copy.deepcopy(pages);doc=n.document(bad[family]);doc[key]=value;bad[family]=n.canonical(doc);reject(normalize,bad)
for key,value in [('sequence',42),('action','delete'),('before',second['commit_id']),('actor',dict(owner,id='foreign'))]:
    bad=copy.deepcopy(pages);doc=n.document(bad[2]);doc['events'][0][key]=value;bad[2]=n.canonical(doc);reject(normalize,bad)
for key,value in [('actor',dict(owner,id='foreign')),('blob_oid','f'*40),('parents',[]),('head',first['commit_id'])]:
    bad=copy.deepcopy(pages);doc=n.document(bad[3]);doc['merges'][0][key]=value;bad[3]=n.canonical(doc);reject(normalize,bad)
for key,value in [('commit_hex','00'),('register_hex','00'),('trees',[])]:
    bad=copy.deepcopy(pages);doc=n.document(bad[1]);doc['commits'][1][key]=value;bad[1]=n.canonical(doc);reject(normalize,bad)
for revision in [1,0]:
    reg=copy.deepcopy(second_register);reg['body']['revision']=revision
    row=gitrow(reg,first['commit_id'],'f'*40);reject(normalize,pages_for([first,row],[dict(event,after=row['commit_id'])],[dict(merge,merge=row['commit_id'])]))
reg=copy.deepcopy(second_register);reg['body']['authority_epoch']='epoch.other'
row=gitrow(reg,first['commit_id'],'f'*40);reject(normalize,pages_for([first,row],[dict(event,after=row['commit_id'])],[dict(merge,merge=row['commit_id'])]))
manifest,raw=n._KillNormalizer.captured(framed(pages),request)
reject(n.kill_normalize,manifest,raw[:-1],request)
for field,value in [('response_status',500),('page_index',1),('output_cursor','loop')]:
    records=framed(pages);capture=n.document(records[0][1]);capture['pages'][0][field]=value;records[0]=(b'capture.json',n.canonical(capture));reject(n._KillNormalizer.captured,records,request)
spec=importlib.util.spec_from_file_location('gate_generator',root/'scope/v1/generate-gate-evidence.py')
g=importlib.util.module_from_spec(spec);sys.modules[spec.name]=g;spec.loader.exec_module(g)
def source_configuration_input_controls():
    import os,tempfile,types
    c=g.c
    original_anchor,original_rule=c.ANCHOR,c._root_rule
    counts=[]
    def document(kind,body):return n.canonical(env(kind,'source.control',body))
    for mode,fault in [('coverage-read','ok'),('kill-register-read','ok'),('coverage-read','source-bytes'),('coverage-read','bad-config'),('coverage-read','publish-memory'),('coverage-read','publish-signal'),('coverage-read','publish-keyboard'),('coverage-read','report-memory'),('coverage-read','map-build'),('coverage-read','report-signal'),('coverage-read','report-keyboard'),('coverage-read','close-error'),('coverage-read','cancel-close-error')]:
        with tempfile.TemporaryDirectory(prefix='source-config-owner-') as tmp:
            directory=pathlib.Path(tmp).resolve();prefix='coverage-source' if mode=='coverage-read' else 'kill-register-source'
            operation=n.OPERATION if mode=='coverage-read' else n.KILL_OPERATION
            families=n.FAMILIES if mode=='coverage-read' else n.KILL_FAMILIES
            normalizer=(root/'sandbox/v1/coverage-source.py').read_bytes()
            supervisor=(root/'sandbox/v1/host-supervisor.py').read_bytes()
            values={'host-config.json':n.canonical(dict(store_id='store.control',principal_uid=os.geteuid(),consumer_gid=os.getegid())),
                    'host-supervisor.py':supervisor,'coverage-source.py':normalizer,'collector.py':b'#!/usr/bin/env python3\n'}
            coverage_fields=[['branch_snapshots','commits','default_branch','repository','schema_version'],['pull_requests','schema_version'],['baseline','current','events','schema_version']]
            kill_fields=[['after','before','default_branch','end_sequence','repository','schema_version','start_sequence'],['commits','schema_version'],['events','schema_version'],['merges','schema_version']]
            fields=coverage_fields if mode=='coverage-read' else kill_fields
            rows=[dict(role='normalizer',path=str(directory/'coverage-source.py'),sha256=n.digest(normalizer)),dict(role='collector',path=str(directory/'collector.py'),sha256=n.digest(values['collector.py']))]
            for family,keys in zip(families,fields):
                name='schema-'+family+'.json';raw=n.canonical(dict(schema_version=1,family=family,operation=operation,page_fields=keys));values[name]=raw
                rows.append(dict(role='schema.'+family,path=str(directory/name),sha256=n.digest(raw)))
            package=document('coverage_source_package' if mode=='coverage-read' else 'kill_register_source_package',dict(operation=operation,files=sorted(rows,key=lambda row:row['role'])))
            values['package.json']=package
            accepted=document('coverage_source_accepted_identity_set' if mode=='coverage-read' else 'kill_register_source_accepted_identity_set',dict(activation_state='inactive',identities=[dict(source_id='source.control',operation=operation,proof_state='qualified',host_supervisor_sha256=n.digest(supervisor),source_package_sha256=n.digest(package),collector_sha256=n.digest(values['collector.py']),normalizer_sha256=n.digest(normalizer))]))
            config=dict(source_id='source.control',operation=operation,queries=n.QUERIES if mode=='coverage-read' else n.KILL_QUERIES,source_package_path=str(directory/'package.json'),source_package_sha256=n.digest(package),collector_path=str(directory/'collector.py'),collector_sha256=n.digest(values['collector.py']),accepted_set_path=str(directory/(prefix+'-accepted-identities.json')),accepted_set_sha256=n.digest(accepted),store_id='store.control',principal_uid=os.geteuid(),consumer_gid=os.getegid())
            if mode=='coverage-read':config.update(coverage_rule_version=n.RULE_VERSION,publisher_identity_ref=owner)
            else:config.update(control_repository=body['control_repository'],default_branch=body['default_branch'],bootstrap=boot)
            if fault=='bad-config':config['source_package_sha256']='0'*64
            values[prefix+'-config.json']=document('coverage_source_config' if mode=='coverage-read' else 'kill_register_source_config',config)
            values[prefix+'-accepted-identities.json']=accepted
            if fault=='source-bytes':values['coverage-source.py']+=b'\n'
            for name,raw in values.items():
                path=directory/name;path.write_bytes(raw);path.chmod(0o500 if name=='collector.py' else 0o400)
            rule=lambda *_args:True
            c.ANCHOR=str(directory);c._root_rule=lambda _resolver:rule
            anchor=types.SimpleNamespace(config_raw=values['host-config.json'],config=dict(store_id='store.control',principal_uid=os.geteuid(),consumer_gid=os.getegid()),resolver=None,held=[])
            opened=[];reads=[];native_read=c.HeldPath.read
            def observed_read(item,*args,**kwargs):
                raw=native_read(item,*args,**kwargs);reads.append((item,raw));tracked.update(component.fd for component in item.components);return raw
            anchor.recheck=lambda code='E_STALE':[item.recheck(code) for item in anchor.held]
            tracked=set();closed={}
            native_close=c.os.close
            def observed_close(fd):
                native_close(fd)
                if fd in tracked:closed[fd]=closed.get(fd,0)+1
            failure=MemoryError('source input map publication')
            if fault in ('publish-signal','cancel-close-error'):failure=InterruptedError('source input map publication');failure._scope_signal_cancel=True
            if fault=='publish-keyboard':failure=KeyboardInterrupt('source input map publication')
            reporting=InterruptedError('source input report signal') if fault=='report-signal' else KeyboardInterrupt('source input report keyboard')
            if fault=='report-signal':reporting._scope_signal_cancel=True
            class Configuration(c._CoverageConfiguration):
                def __getattribute__(self,name):
                    if fault=='map-build' and name=='config_raw' and 'hashes' in object.__getattribute__(self,'__dict__'):raise failure
                    return object.__getattribute__(self,name)
                def __setattr__(self,name,value):
                    if name=='source_inputs' and (fault.startswith(('publish-','report-')) or fault=='cancel-close-error'):raise failure
                    if name=='source_inputs_error' and fault=='report-memory':raise MemoryError('source input error report')
                    if name=='source_inputs_error' and fault in ('report-signal','report-keyboard'):raise reporting
                    object.__setattr__(self,name,value)
            configuration=None;all_components=[];caught=None
            try:
                for name,directory_flag in [(None,True),('host-config.json',False),('host-supervisor.py',False)]:
                    item=c._open_held(str(directory if name is None else directory/name),directory_flag,rule,'E_CONFIG');anchor.held.append(item)
                tracked.update(component.fd for item in anchor.held for component in item.components)
                c.HeldPath.read=observed_read;c.os.close=observed_close
                original_close=c._close_paths;closing=OSError(5,'original cleanup after new capture cancel')
                def cancelled_close(items):original_close(items);raise closing
                if fault=='cancel-close-error':c._close_paths=cancelled_close
                try:
                    try:configuration=Configuration(anchor,mode)
                    except BaseException as error:caught=error
                finally:c._close_paths=original_close
                if fault in ('source-bytes','bad-config'):
                    check(caught is not None and configuration is None)
                elif fault in ('publish-signal','publish-keyboard','report-signal','report-keyboard','cancel-close-error'):
                    check(caught is (reporting if fault.startswith('report-') else failure) and configuration is None)
                    if fault=='cancel-close-error':check(caught.__cause__ is closing)
                else:
                    check(caught is None and configuration is not None)
                    all_components=[component for held in configuration.held for component in held.components]
                    if fault in ('publish-memory','report-memory','map-build'):
                        check(configuration.source_inputs is None and configuration.source_inputs_unusable)
                        check(configuration.source_inputs_error is (None if fault=='report-memory' else failure))
                    else:
                        check(not configuration.source_inputs_unusable and set(configuration.source_inputs)=={'host','config','accepted','package','supervisor','normalizer'})
                        expected={'host':'host-config.json','config':prefix+'-config.json','accepted':prefix+'-accepted-identities.json','package':'package.json','supervisor':'host-supervisor.py','normalizer':'coverage-source.py'}
                        for key,name in expected.items():
                            raw,held=configuration.source_inputs[key]
                            check(raw==values[name] and held.path==str(directory/name) and bool(held.components))
                            check(held in anchor.held or held in configuration.held)
                            if key!='host':check(any(item is held and seen is raw for item,seen in reads))
                        check(configuration.source_inputs['host'][0] is anchor.config_raw)
                    before=len(reads);configuration.recheck();check(len(reads)==before+len(configuration.held))
                    if fault=='close-error':
                        original_close=c._close_paths;closing=OSError(5,'original configuration close')
                        def close_error(items):original_close(items);raise closing
                        c._close_paths=close_error
                        try:
                            try:configuration.close()
                            except OSError as error:check(error is closing)
                            else:raise AssertionError('original close error swallowed')
                        finally:c._close_paths=original_close
                    else:configuration.close()
                    check(not configuration.held and all(not item.components for item,_raw in reads if item not in anchor.held))
                    configuration.close()
                check(all(not item.components for item,_raw in reads if item not in anchor.held))
                counts.append((mode,fault,len(reads),sum(len(raw) for _item,raw in reads)))
            finally:
                c.HeldPath.read=native_read
                if configuration is not None:configuration.close()
                try:c._close_paths(anchor.held)
                finally:c.os.close=native_close;c.ANCHOR=original_anchor;c._root_rule=original_rule
                check(set(closed)==tracked and all(count==1 for count in closed.values()))
    print('SOURCE_CONFIGURATION_CONTROLS',counts,'full_cost_UNKNOWN root_ACL_native_NOTRUN')
source_configuration_input_controls()
def gate_reject(fn,*args):
    global checks
    try:fn(*args)
    except (g.c.Refusal,KeyError,TypeError,ValueError,OSError):checks+=1
    else:raise AssertionError('accepted invalid gate contract')
# Kill request body controls use synthetic in-memory documents only.
def kill_body_controls():
    def document(kind,identity):
        return g.c.canonical(dict(schema_version=1,kind=kind,id=identity,body={}))
    basis=dict(body=dict(target_repository_id='repo.target',qualified_identity=dict(target_revision=dict(commit_id='a'*40))))
    config=dict(control_repository=dict(repository_id='repo.control'),default_branch=dict(name='main'),bootstrap=dict(revision=1))
    bundle_a=document('shadow_bundle','bundle.a');bundle_b=document('shadow_bundle','bundle.b')
    role_files=dict(current={'second':{'bundle.json':bundle_b},'first':{'bundle.json':bundle_a},'duplicate':{'bundle.json':bundle_b}})
    initial=[dict(id='origin.control')];git_raw=b'[core]\nrepositoryformatversion = 0\n'
    package_raw=document('coverage_package','package.control');accepted_raw=document('accepted_identities','accepted.control')
    nonce='c'*64;call_id='kill-register.'+nonce
    args=(basis,config,call_id,nonce,role_files,initial,git_raw,package_raw,accepted_raw)
    result=g._kill_request_body_values(*args)
    check(g.c.digest(g.c.canonical(result))=='e2ba6405b9af5e5ec8fcace38e8f72894a822aa31447c07e31f0f89189820ecf')
    check(result['control_repository'] is config['control_repository'] and result['initial_origin_refs'] is initial)
    check(len(result['bundle_refs'])==2 and [row['id'] for row in result['bundle_refs']]==['bundle.a','bundle.b'])
    original_ref=g.ref;original_digest=g.c.digest;events=[]
    marked=InterruptedError('kill body marked source ref');marked._scope_signal_cancel=True
    inject=False
    def measured_ref(raw):
        events.append(('ref',raw))
        if inject and raw==package_raw:raise marked
        return original_ref(raw)
    def measured_digest(raw):
        events.append(('digest',raw));return original_digest(raw)
    g.ref=measured_ref;g.c.digest=measured_digest
    try:
        check(g._kill_request_body_values(*args)==result)
        check([raw for site,raw in events if site=='ref']==[bundle_b,bundle_b,bundle_a,bundle_a,bundle_b,bundle_b,package_raw,accepted_raw])
        digests=[raw for site,raw in events if site=='digest']
        check(digests[:6]==[bundle_b,bundle_b,bundle_a,bundle_a,bundle_b,bundle_b])
        check(digests[6]==git_raw and digests[-2:]==[package_raw,accepted_raw])
        events.clear();bad_config=dict(config);del bad_config['default_branch']
        try:g._kill_request_body_values(basis,bad_config,call_id,nonce,{'current':{'bad':{'bundle.json':b'invalid'}}},initial,git_raw,package_raw,accepted_raw)
        except KeyError as error:check(error.args==('default_branch',) and not events)
        else:raise AssertionError('kill body accepted missing config')
        events.clear()
        gate_reject(g._kill_request_body_values,basis,config,call_id,nonce,{'current':{'bad':{'bundle.json':b'invalid'}}},initial,git_raw,b'invalid',accepted_raw)
        check(events==[('ref',b'invalid')])
        events.clear();inject=True
        try:g._kill_request_body_values(*args)
        except BaseException as error:check(error is marked)
        else:raise AssertionError('kill body swallowed marked source ref error')
        check(events[-1]==('ref',package_raw) and ('digest',git_raw) in events)
        check(not any(raw==accepted_raw for _site,raw in events))
    finally:g.ref=original_ref;g.c.digest=original_digest
kill_body_controls()
# End kill request body controls.
# Failure marker controls avoid any instance dictionary acquisition.
def capture_marker_fault_controls():
    import tempfile,types
    dictionary_error=MemoryError('instance dictionary materialization')
    class DictionaryFaultGenerator(g._Generator):
        dictionary_reads=0
        def __getattribute__(self,name):
            if name=='__dict__':
                self.dictionary_reads+=1;raise dictionary_error
            return super().__getattribute__(name)
    def fresh(output):
        value=DictionaryFaultGenerator.__new__(DictionaryFaultGenerator)
        try:value.__dict__
        except MemoryError as error:check(error is dictionary_error)
        else:raise AssertionError('dictionary materialization fault inactive')
        value.dictionary_reads=0
        value.output=output;value.reader=value.session=None;value.held=[];value.outputs={};value._init_output_capture()
        return value
    def same_error(fn,error):
        try:fn()
        except BaseException as actual:check(actual is error)
        else:raise AssertionError('lost first marked capture error')
    with tempfile.TemporaryDirectory() as tmp:
        generator=fresh(pathlib.Path(tmp).resolve());failure=OSError(5,'original output registration')
        class FailedMap(dict):
            def __setitem__(self,key,value):raise failure
        generator.output_holds=FailedMap();(generator.output/'objects/control').mkdir(parents=True)
        check(generator.put('control',b'{}\n')==generator.path('control'))
        check(generator.capture_output_unusable and generator.capture_output_error is failure)
        check(generator.dictionary_reads==0 and generator.path('control').read_bytes()==b'{}\n')
        generator.close();check(not generator.held and generator.dictionary_reads==0)
    for marker_error in (MemoryError('marker deletion'),KeyboardInterrupt('marker deletion cancellation')):
        generator=DictionaryFaultGenerator.__new__(DictionaryFaultGenerator);generator._init_output_capture()
        def failed_delete(*args):raise marker_error
        g.object=types.SimpleNamespace(__delattr__=failed_delete,__setattr__=object.__setattr__)
        failure=OSError(5,'original capture error')
        try:
            cancellation=generator._output_capture_failed('marker-entry',failure)
            check(cancellation is (marker_error if isinstance(marker_error,KeyboardInterrupt) else None))
            check(generator.capture_output_unusable and generator.capture_output_error is failure)
            check(generator.capture_output_errors[-1]['error'] is marker_error)
        finally:del g.object
    for cancellation in (None,KeyboardInterrupt('first component cancellation'),InterruptedError('first component signal')):
        if isinstance(cancellation,InterruptedError):cancellation._scope_signal_cancel=True
        with tempfile.TemporaryDirectory() as tmp:
            generator=fresh(pathlib.Path(tmp).resolve())
            path=generator.output/'completion/COMPLETE.json';path.parent.mkdir();raw=b'{}\n'
            written=g.r.write_exclusive(path,raw);generator._capture_completion(path,raw,written)
            owner=generator.capture_output_owned;fds=[row.fd for row in owner.held.components];attempts=[]
            first=OSError(5,'first component ordinary error');later=InterruptedError('later component signal');later._scope_signal_cancel=True
            original_close=g.c.os.close
            def failed_close(fd):
                if fd in fds:
                    attempts.append(fd);original_close(fd)
                    if len(attempts)==1:raise first
                    if len(attempts)==2 and cancellation is not None:raise cancellation
                    if len(attempts)==3 and cancellation is not None:raise later
                    return
                return original_close(fd)
            g.c.os.close=failed_close
            try:
                if cancellation is None:generator.close()
                else:same_error(generator.close,cancellation)
                check(generator.capture_output_unusable and generator.capture_output_error is first)
                check(not owner.held.components and attempts==list(reversed(fds)))
                check(generator.dictionary_reads==0 and generator.capture_output_work['held_close_calls']==len(fds))
                if cancellation is not None:
                    check(generator.capture_output_cancel is cancellation)
                    check(any(row['error'] is later for row in generator.capture_output_errors))
                    same_error(generator.close,cancellation)
                else:generator.close()
                check(len(attempts)==len(fds) and generator.dictionary_reads==0)
            finally:g.c.os.close=original_close
capture_marker_fault_controls()
# End failure marker controls.
# Capture state fault controls use only synthetic files and actual source owners.
def capture_state_fault_controls():
    import tempfile,os
    class StateFaultGenerator(g._Generator):
        blocked=()
        fault=None
        release_only=False
        def __setattr__(self,name,value):
            if name in self.blocked and (not self.release_only or value is None):raise self.fault
            super().__setattr__(name,value)
    def fresh(output):
        value=StateFaultGenerator.__new__(StateFaultGenerator)
        value.output=output;value.reader=value.session=None;value.held=[];value.outputs={}
        return value
    def same_error(fn,error):
        try:fn()
        except BaseException as actual:check(actual is error)
        else:raise AssertionError('lost original capture cancellation')
    bootstrap=('output_holds','capture_output_work','capture_output_error','capture_output_cancel',
        'capture_output_error_category','capture_output_error_errno','capture_output_errors',
        'capture_output_owned','capture_output_pending','capture_output_unusable')
    for field in bootstrap:
        with tempfile.TemporaryDirectory() as tmp:
            generator=fresh(pathlib.Path(tmp).resolve());generator.blocked=(field,)
            generator.fault=MemoryError('capture bootstrap '+field)
            generator._init_output_capture()
            check(generator.capture_output_unusable and 'capture_output_unusable' not in generator.__dict__)
            (generator.output/'objects/control').mkdir(parents=True)
            check(generator.put('control',b'{}\n')==generator.path('control'))
            check(generator.path('control').read_bytes()==b'{}\n' and len(generator.held)==1)
            generator.close();check(not generator.held)
    for cancellation in (KeyboardInterrupt('bootstrap cancellation'),InterruptedError('bootstrap signal')):
        if isinstance(cancellation,InterruptedError):cancellation._scope_signal_cancel=True
        generator=StateFaultGenerator.__new__(StateFaultGenerator)
        generator.blocked=('output_holds','capture_output_cancel','capture_output_reporting_error')
        generator.fault=cancellation
        same_error(generator._init_output_capture,cancellation)
        check(generator.capture_output_unusable)
    class FailedRows:
        def append(self,row):raise MemoryError('capture error append')
    for blocked in ('capture_output_error','capture_output_reporting_error'):
        generator=StateFaultGenerator.__new__(StateFaultGenerator);generator._init_output_capture()
        generator.blocked=(blocked,);generator.fault=MemoryError('capture reporting setattr')
        if blocked=='capture_output_reporting_error':generator.capture_output_errors=FailedRows()
        original=OSError(5,'actual capture failure')
        check(generator._output_capture_failed('synthetic-report',original) is None)
        check(generator.capture_output_unusable)
        if blocked=='capture_output_error':check(generator.capture_output_errors[0]['error'] is original)
        else:check(generator.capture_output_error is original and generator.capture_output_work['accounting_incomplete'])
    for field,release_only in (('capture_output_pending',False),('capture_output_owned',False),('capture_output_pending',True)):
        with tempfile.TemporaryDirectory() as tmp:
            generator=fresh(pathlib.Path(tmp).resolve());generator._init_output_capture()
            path=generator.output/'completion/COMPLETE.json';path.parent.mkdir();raw=b'{}\n'
            written=g.r.write_exclusive(path,raw);acquired=[];closed=[];fds=set()
            original_open=g.c._open_held;original_close=g.c.os.close
            def measured_open(*args,**kwargs):
                held=original_open(*args,**kwargs)
                if args[0]==str(path):acquired.append(held);fds.update(row.fd for row in held.components)
                return held
            def measured_close(fd):
                if fd in fds:closed.append(fd)
                return original_close(fd)
            generator.blocked=(field,);generator.fault=MemoryError('capture ownership setattr');generator.release_only=release_only
            g.c._open_held=measured_open;g.c.os.close=measured_close
            try:
                generator._capture_completion(path,raw,written)
                check(generator.capture_output_unusable and generator.capture_output_error is generator.fault)
                check(acquired and not acquired[0].components and len(closed)==len(fds) and set(closed)==fds)
                check(path.read_bytes()==raw)
                generator.close();generator.close();check(len(closed)==len(fds))
            finally:g.c._open_held=original_open;g.c.os.close=original_close
    for cancel in (None,KeyboardInterrupt('component close cancellation'),InterruptedError('component close signal')):
        if isinstance(cancel,InterruptedError):cancel._scope_signal_cancel=True
        with tempfile.TemporaryDirectory() as tmp:
            generator=fresh(pathlib.Path(tmp).resolve());generator._init_output_capture()
            path=generator.output/'completion/COMPLETE.json';path.parent.mkdir();raw=b'{}\n'
            written=g.r.write_exclusive(path,raw);generator._capture_completion(path,raw,written)
            owner=generator.capture_output_owned;fds=[row.fd for row in owner.held.components];attempts=[]
            generator.capture_output_errors=FailedRows()
            generator.blocked=('capture_output_reporting_error','capture_output_owned','capture_output_pending','capture_output_cancel')
            generator.fault=MemoryError('capture secondary reporting setattr')
            first=OSError(5,'actual first component close failure');later=OSError(9,'actual later component close failure')
            original_close=g.c.os.close
            def failed_close(fd):
                if fd in fds:
                    attempts.append(fd);original_close(fd)
                    if len(attempts)==1:raise first
                    if len(attempts)==2 and cancel is not None:raise cancel
                    if len(attempts)==3:raise later
                    return
                return original_close(fd)
            g.c.os.close=failed_close
            try:
                if cancel is None:generator.close()
                else:same_error(generator.close,cancel)
                check(generator.capture_output_unusable and not owner.held.components)
                check(attempts==list(reversed(fds)) and generator.capture_output_work['held_close_calls']==len(fds))
                check(generator.capture_output_work['cost_unknown'] and generator.capture_output_work['accounting_incomplete'])
                generator.close();check(len(attempts)==len(fds))
            finally:g.c.os.close=original_close
capture_state_fault_controls()
# End capture state fault controls.
# Output hold controls use only synthetic files and the original write/hold owners.
def output_hold_controls():
    import tempfile,os,types
    def fresh(output):
        generator=g._Generator.__new__(g._Generator)
        generator.output=output;generator.reader=generator.session=None
        generator.held=[];generator.outputs={};generator._init_output_capture()
        return generator
    def same_error(fn,error):
        try:fn()
        except BaseException as actual:check(actual is error)
        else:raise AssertionError('expected original exception')
    def completed(generator):
        path=generator.output/'completion/COMPLETE.json';path.parent.mkdir(exist_ok=True)
        raw=b'{"synthetic":true}\n';written=g.r.write_exclusive(path,raw)
        generator._capture_completion(path,raw,written)
        return path,raw
    class FailedOutputMap(dict):
        def __setitem__(self,key,value):raise map_failure
    for allocation_error in (MemoryError('capture allocation'),KeyboardInterrupt('capture allocation cancel')):
        generator=g._Generator.__new__(g._Generator)
        def allocation_failure(*args,**kwargs):raise allocation_error
        g.dict=allocation_failure
        try:
            if isinstance(allocation_error,KeyboardInterrupt):
                same_error(generator._init_output_capture,allocation_error)
            else:generator._init_output_capture()
            check(generator.capture_output_unusable and generator.capture_output_error is allocation_error)
        finally:del g.dict
    with tempfile.TemporaryDirectory() as tmp:
        generator=fresh(pathlib.Path(tmp).resolve())
        generator.reader=types.SimpleNamespace(darwin=None,anchor=types.SimpleNamespace(recording_work={},private_observations={}),close=lambda:None)
        (generator.output/'completion').mkdir()
        paths=('objects/control/value.json','objects/kill-evidence/raw-0000/value.raw','manifests/manifest.json')
        for relative in paths:(generator.output/relative).parent.mkdir(parents=True,exist_ok=True)
        try:
            check(generator.put('control',b'{}\n')==generator.output/paths[0])
            for relative in paths[1:]:
                path=generator.output/relative;raw=b'{"synthetic":true}\n'
                written=g.r.write_exclusive(path,raw)
                held=generator.hold_written(path,raw,written)
                check(generator.output_holds[relative] is held)
                check(held.raw==raw and g.c._identity(held.held.before)==written)
            path,raw=completed(generator)
            complete_hold=generator.output_holds['completion/COMPLETE.json']
            check(generator.capture_output_owned is complete_hold and complete_hold not in generator.held)
            check(isinstance(complete_hold,g.c._HeldBytes) and complete_hold.raw==raw)
            check(generator.capture_output_pending is None and not generator.capture_output_unusable)
            check(generator.capture_output_work['read_bytes']>0 and generator.capture_output_work['cost_unknown'])
            check(generator.capture_output_work['accounting_incomplete'])
            check(generator.reader.anchor.recording_work['gate_output_work']==[generator.capture_output_work])
            check(generator.reader.anchor.recording_work['gate_output_work'][0] is generator.capture_output_work)
            for held in generator.output_holds.values():held.recheck()
        finally:generator.close()
        check(not generator.held and generator.capture_output_owned is None)
        generator.close()
    marked=InterruptedError('map signal');marked._scope_signal_cancel=True
    for map_failure in (OSError(5,'map failed'),MemoryError('map failed'),KeyboardInterrupt('map cancelled'),marked):
        with tempfile.TemporaryDirectory() as tmp:
            generator=fresh(pathlib.Path(tmp).resolve());generator.output_holds=FailedOutputMap()
            (generator.output/'objects/control').mkdir(parents=True)
            if isinstance(map_failure,KeyboardInterrupt) or map_failure is marked:same_error(lambda:generator.put('control',b'{}\n'),map_failure)
            else:check(generator.put('control',b'{}\n')==generator.path('control'))
            check(generator.path('control').read_bytes()==b'{}\n')
            check(generator.capture_output_unusable and generator.capture_output_error is map_failure)
            check(generator.capture_output_errors[0]['category']==type(map_failure).__name__)
            check(generator.capture_output_errors[0]['errno']==getattr(map_failure,'errno',None))
            check(len(generator.held)==1)
            held=generator.held[0];fd=held.held.fd
            check(os.fstat(fd).st_ino==held.held.before.st_ino)
            close_type=type(held.held);original_close=close_type.close;closed=[]
            def counted_close(self):
                if self is held.held:closed.append(id(self))
                return original_close(self)
            close_type.close=counted_close
            try:
                if isinstance(map_failure,KeyboardInterrupt) or map_failure is marked:same_error(generator.close,map_failure);same_error(generator.close,map_failure)
                else:generator.close();generator.close()
            finally:close_type.close=original_close
            check(closed==[id(held.held)])
            try:os.fstat(fd)
            except OSError:check(True)
            else:raise AssertionError('map failure leaked descriptor')
    for mismatch in ('bytes','identity','native-hold','native-write'):
        with tempfile.TemporaryDirectory() as tmp:
            generator=fresh(pathlib.Path(tmp).resolve())
            path=generator.output/'value.raw';raw=b'synthetic\n';written=g.r.write_exclusive(path,raw)
            try:
                if mismatch in ('bytes','identity'):
                    gate_reject(generator.hold_written,path,b'wrong\n' if mismatch=='bytes' else raw,() if mismatch=='identity' else written)
                elif mismatch=='native-hold':
                    native_error=OSError('original hold failure')
                    def native_hold(path):raise native_error
                    generator.hold=native_hold
                    same_error(lambda:generator.hold_written(path,raw,written),native_error)
                else:
                    path=generator.path('control');path.parent.mkdir(parents=True);g.r.write_exclusive(path,raw)
                    gate_reject(generator.put,'control',raw)
                check(not generator.capture_output_unusable and not generator.output_holds)
            finally:generator.close()
    for fault in ('read','map','identity'):
        with tempfile.TemporaryDirectory() as tmp:
            generator=fresh(pathlib.Path(tmp).resolve())
            path=generator.output/'completion/COMPLETE.json';path.parent.mkdir(exist_ok=True);raw=b'{}\n'
            written=g.r.write_exclusive(path,raw);acquired=[];closed=[];acquired_fds=set()
            original_read=g.c.HeldPath.read;original_close=g.c.os.close
            capture_error=OSError(5,'complete read failure')
            def failed_read(self,*args,**kwargs):
                if self.path==str(path):
                    acquired.append(self);acquired_fds.update(row.fd for row in self.components)
                    if fault=='read':raise capture_error
                return original_read(self,*args,**kwargs)
            def counted_close(fd):
                if fd in acquired_fds:closed.append(fd)
                return original_close(fd)
            if fault=='map':map_failure=MemoryError('complete map failure');generator.output_holds=FailedOutputMap()
            g.c.HeldPath.read=failed_read;g.c.os.close=counted_close
            try:
                generator._capture_completion(path,raw,() if fault=='identity' else written)
                check(generator.capture_output_unusable and path.read_bytes()==raw)
                check(generator.capture_output_owned is None and generator.capture_output_pending is None)
                check(not generator.held and len(closed)==len(acquired_fds) and set(closed)==acquired_fds)
                if fault=='read':check(generator.capture_output_error is capture_error)
                generator.close();check(len(closed)==len(acquired_fds))
            finally:g.c.HeldPath.read=original_read;g.c.os.close=original_close
    for native_fault,capture_fault in ((None,OSError('capture close')),(OSError('native close'),OSError('capture close')),
            (OSError('native close'),KeyboardInterrupt('capture close cancel')),
            (KeyboardInterrupt('native close cancel'),KeyboardInterrupt('capture close cancel'))):
        with tempfile.TemporaryDirectory() as tmp:
            generator=fresh(pathlib.Path(tmp).resolve())
            (generator.output/'completion').mkdir()
            native_path=generator.output/'native.raw';written=g.r.write_exclusive(native_path,b'original\n')
            path,raw=completed(generator)
            complete_hold=generator.capture_output_owned;closed=[];original_close=g.c.HeldPath.close
            original_os_close=g.c.os.close;capture_fds={row.fd for row in complete_hold.held.components}
            native_hold=generator.hold(native_path)
            def failed_capture_close(fd):
                if fd in capture_fds:
                    if 'capture' not in closed:closed.append('capture')
                    original_os_close(fd);raise capture_fault
                return original_os_close(fd)
            def failed_close(self):
                if self is native_hold.held:
                    closed.append('native');original_close(self)
                    if native_fault is not None:raise native_fault
                    return
                return original_close(self)
            g.c.HeldPath.close=failed_close;g.c.os.close=failed_capture_close
            try:
                expected=native_fault
                if isinstance(capture_fault,KeyboardInterrupt) and not isinstance(native_fault,KeyboardInterrupt):expected=capture_fault
                if expected is None:generator.close()
                else:same_error(generator.close,expected)
                check(closed==['native','capture'])
                check(generator.capture_output_unusable and generator.capture_output_error is capture_fault)
                if isinstance(expected,KeyboardInterrupt):same_error(generator.close,expected)
                else:generator.close()
                check(closed==['native','capture'])
            finally:g.c.HeldPath.close=original_close;g.c.os.close=original_os_close
    for fault in ('pending-cancel','final-recheck'):
        with tempfile.TemporaryDirectory() as tmp:
            generator=fresh(pathlib.Path(tmp).resolve());path=generator.output/'completion/COMPLETE.json'
            path.parent.mkdir();raw=b'{}\n';written=g.r.write_exclusive(path,raw)
            first=InterruptedError('pending capture signal') if fault=='pending-cancel' else OSError('final capture recheck')
            if fault=='pending-cancel':first._scope_signal_cancel=True
            secondary=OSError('secondary capture close');closed=[];capture_fds=set()
            original_read=g.c.HeldPath.read;original_close=g.c.os.close
            def failed_read(self,*args,**kwargs):
                if self.path==str(path):
                    capture_fds.update(row.fd for row in self.components);raise first
                return original_read(self,*args,**kwargs)
            def failed_close(fd):
                if fd in capture_fds:
                    closed.append(fd);original_close(fd);raise secondary
                return original_close(fd)
            try:
                if fault=='final-recheck':generator._capture_completion(path,raw,written)
                g.c.HeldPath.read=failed_read;g.c.os.close=failed_close
                if fault=='pending-cancel':same_error(lambda:generator._capture_completion(path,raw,written),first)
                else:generator.close()
                check(generator.capture_output_unusable and generator.capture_output_error is first)
                check(generator.capture_output_errors[-1]['error'] is secondary)
                check(len(closed)==len(capture_fds) and generator.capture_output_owned is None and generator.capture_output_pending is None)
                if fault=='pending-cancel':same_error(generator.close,first)
                else:generator.close()
                check(len(closed)==len(capture_fds) and path.read_bytes()==raw)
            finally:g.c.HeldPath.read=original_read;g.c.os.close=original_close
    with tempfile.TemporaryDirectory() as tmp:
        generator=fresh(pathlib.Path(tmp).resolve());path,raw=completed(generator)
        owned=generator.capture_output_owned;fds=[row.fd for row in owned.held.components]
        original_os_close=g.c.os.close;attempts=[];first=KeyboardInterrupt('component close cancel')
        second=InterruptedError('later component close signal');second._scope_signal_cancel=True
        third=OSError(5,'later ordinary component close')
        def interrupted_close(fd):
            if fd in fds:
                attempts.append(fd);original_os_close(fd)
                if len(attempts)==1:raise first
                if len(attempts)==2:raise second
                if len(attempts)==3:raise third
                return
            return original_os_close(fd)
        g.c.os.close=interrupted_close
        try:
            same_error(generator.close,first)
            check(attempts==list(reversed(fds)) and not owned.held.components)
            check(generator.capture_output_error is first and generator.capture_output_cancel is first)
            check(any(row['error'] is second for row in generator.capture_output_errors))
            check(any(row['error'] is third and row['errno']==5 for row in generator.capture_output_errors))
            check(generator.capture_output_work['held_close_calls']==len(fds))
            same_error(generator.close,first);check(len(attempts)==len(fds))
        finally:g.c.os.close=original_os_close
output_hold_controls()
# End output hold controls.
basis=env('workflow_scope','scope.test',dict(target_repository_id='repo.target',workflow_id='workflow.test'))
claim=env('risk_claim','claim.test',{})
request_doc=env('scope_gate_generation_request','generation.test',dict(scope_basis=basis,risk_claim=claim))
check(g.generation_request(n.canonical(request_doc))==request_doc)
for mutate in [lambda v:v['body'].update(provider='/tmp/provider'),lambda v:v['body']['scope_basis']['body'].update(gate_evidence_refs={}),lambda v:v.update(schema_version=True)]:
    bad=copy.deepcopy(request_doc);mutate(bad);gate_reject(g.generation_request,n.canonical(bad))
stage=env('stage_request','stage-request.test',dict(target_repository_id='repo.target',workflow_id='workflow.test',stage_id='stage.test'))
result=env('stage_result','attempt.test',{})
duty=n.canonical(env('duty_separation_evaluation','attempt.test',{}))
state,attempt=g.project_register(n.canonical(register),basis,stage,result,duty,True)
state_doc=n.document(state);attempt_doc=n.document(attempt)
check(state_doc['body']['register_ref']==g.ref(n.canonical(register)))
check(state_doc['body']['attempt_id']==result['id'] and attempt_doc['body']['scope']['attempt_id']==result['id'])
check(attempt_doc['body']['expected_state']['sha256']==n.digest(state))
check(len(state_doc['body']['entries'])==5)
for k in ('global','repository','workflow'):
    reg=copy.deepcopy(register)
    for entry in reg['body']['entries']:
        if entry['scope_kind']==k:entry['state']='stop'
    changed,_=g.project_register(n.canonical(reg),basis,stage,result,duty,True)
    check(next(row for row in n.document(changed)['body']['entries'] if row['scope_kind']==k)['state']=='stop')
reg=copy.deepcopy(register);reg['body']['write_entries']=[dict(scope_id='scope.test',state='stop')]
changed,_=g.project_register(n.canonical(reg),basis,stage,result,duty,True)
check(n.document(changed)['body']['entries']==state_doc['body']['entries'])
reg['body']['write_entries']=[dict(scope_id='scope.other',state='cleared')]
changed,_=g.project_register(n.canonical(reg),basis,stage,result,duty,True)
check(n.document(changed)['body']['entries']==state_doc['body']['entries'])
gate_reject(g.project_register,n.canonical(register),basis,stage,result,duty,False)
reg=copy.deepcopy(register);reg['body']['entries']=reg['body']['entries'][:-1]
gate_reject(g.project_register,n.canonical(reg),basis,stage,result,duty,True)
reg=copy.deepcopy(register);reg['body']['entries'][1]['scope_id']='repo.foreign'
gate_reject(g.project_register,n.canonical(reg),basis,stage,result,duty,True)
import socket,time,struct
left,right=socket.socketpair()
a=g.c._GateWire(left,time.monotonic()+5,'generation.test','a'*64,'b'*64)
b=g.c._GateWire(right,time.monotonic()+5)
a.send('INIT',{});check(b.receive()==('INIT',{}));b.send('INIT_ACK',{});check(a.receive()==('INIT_ACK',{}))
a.send('ACQUIRE',{'acquisition':'inner.1'});check(b.receive()==('ACQUIRE',{'acquisition':'inner.1'}))
left.close();gate_reject(b.receive);right.close()
for field,value in [('sequence',2),('version',True),('nonce','c'*64),('binding','d'*64)]:
    left,right=socket.socketpair();wire=g.c._GateWire(right,time.monotonic()+5,'generation.test','a'*64,'b'*64)
    frame=dict(version=1,call_id='generation.test',nonce='a'*64,sequence=1,phase='ACQUIRE',binding='b'*64,body={});frame[field]=value
    raw=n.canonical(frame);left.sendall(struct.pack('!I',len(raw))+raw);gate_reject(wire.receive);left.close();right.close()
left,right=socket.socketpair();wire=g.c._GateWire(right,time.monotonic()+5)
left.sendall(struct.pack('!I',n.DOCUMENT_LIMIT+1));gate_reject(wire.receive);left.close();right.close()
left,right=socket.socketpair();wire=g.c._GateWire(left,time.monotonic()-1,'generation.test','a'*64,'b'*64)
gate_reject(wire.send,'INIT',{});left.close();right.close()
session=g._GateStoreSession('generation.test','b'*64,time.monotonic()+5)
binding=dict(store_id='store.test',attempt_id='attempt.test',ancestors=[],entries=[dict(name='.',metadata_before=[1,2,3,4,5,6],metadata_after=[1,2,3,4,5,6]),dict(name='payload',metadata_before=list(range(10)),metadata_after=list(range(10)))],snapshots=[dict(name='receipt.json',size=3,sha256='e'*64)],origin_ref=owner)
check(session.remember(binding)==('store.test','attempt.test'))
changed=copy.deepcopy(binding);changed['origin_ref']=dict(owner,sha256='f'*64);check(session.remember(changed)==('store.test','attempt.test'))
for field in ('entries','snapshots','attempt_id'):
    bad=copy.deepcopy(binding)
    if field=='entries':bad[field][1]['metadata_before'][9]+=1
    elif field=='snapshots':bad[field][0]['sha256']='0'*64
    else:continue
    gate_reject(session.remember,bad)
gate_reject(session.complete)
class Bytes:
    def __init__(self,path,sha='a'*64):self.held=type('Held',(),dict(path=path))();self.sha256=sha
class Ledger:
    jq=Bytes('/fixed/jq',g.c.JQ_SHA256[sys.platform]);modules='/fixed/modules'
    def environment(self):return {'PATH':'/usr/bin:/bin','LC_ALL':'C','LANG':'C'}
ledger=Ledger();owner_obj=type('Owner',(),dict(python=Bytes(sys.executable),source=Bytes(str(root/'shadow/v1/_consumer.py')),ledger=ledger))()
argv=['/bin/bash','-p',str(root/'control/v1/evaluate-duty.sh'),'evaluate','/p/set','/p/request','/p/resolved','/p/result']
check(g.c._closed_scope_child(argv,ledger.environment(),owner_obj) is None)
for bad in [argv+['/p/extra'],argv[:-1],['/bin/bash','-c','true'],[argv[0],argv[1],argv[2],'unknown',*argv[4:]],argv[:4]+['relative']+argv[5:]]:
    gate_reject(g.c._closed_scope_child,bad,ledger.environment(),owner_obj)
for command in ('coverage-read','kill-register-read'):
    fixed=['/usr/bin/sudo','-n','-u','#123','--',sys.executable,'-I','-S','-B','/fixed/host-supervisor.py',command]
    owner_obj._coverage_invocation=fixed
    check(g.c._closed_scope_child(fixed,ledger.environment(),owner_obj) is None)
    gate_reject(g.c._closed_scope_child,fixed+['extra'],ledger.environment(),owner_obj)
    gate_reject(g.c._closed_scope_child,fixed,dict(ledger.environment(),PROVIDER='/tmp/p'),owner_obj)
owner_obj._coverage_invocation=None
left,right=socket.socketpair();wire=g.c._GateWire(left,time.monotonic()+5,'generation.test','a'*64,'b'*64)
wire.sent_bytes=64*n.DOCUMENT_LIMIT
gate_reject(wire.send,'ACQUIRE',{});left.close();right.close()
left,right=socket.socketpair();wire=g.c._GateWire(right,time.monotonic()+5,'generation.test','a'*64,'b'*64)
frame=dict(version=1,call_id='generation.test',nonce='a'*64,sequence=1,phase='ACQUIRE',binding='b'*64,body={})
raw=n.canonical(frame);following=n.canonical(dict(frame,sequence=2));left.sendall(struct.pack('!I',len(raw))+raw+struct.pack('!I',len(following))+following)
check(wire.receive()==('ACQUIRE',{}));check(wire.pending());check(wire.receive()==('ACQUIRE',{}));left.close();right.close()
import tempfile,os
for form in ('enforced-reproduction.v1','withheld-write.v1','withheld-write-policy.v1'):
    with tempfile.TemporaryDirectory() as tmp:
        parent=pathlib.Path(tmp);leaf=parent/'bundle';leaf.mkdir()
        names=set(g.c.SHADOW_EVIDENCE_NAMES)
        if form!='enforced-reproduction.v1':names.add('publisher-body.txt')
        if form=='withheld-write-policy.v1':names.add('scope-policy.json')
        values={name:(b'' if name.endswith('.txt') else n.canonical({})) for name in names}
        values['incident.json']=n.canonical(env('shadow_incident_record','incident.test',dict(git_revision_ref=dict(repository_id='repo.test',hash_algorithm='sha1',commit_id='a'*40))))
        record_body=dict(record_form=form)
        if form=='withheld-write-policy.v1':
            values['scope-policy.json']=(root/'scope/v1/scope-policy.json').read_bytes()
            record_body['scope_policy_ref']=g.c.scope_policy_ref(values['scope-policy.json'])
        values['shadow-record.json']=n.canonical(env('shadow_reproduction_record','record.test',record_body))
        marker=env('shadow_consumer_bundle','bundle.'+n.digest(values['incident.json'])[:32],dict(activation_state='inactive',record_form=form,incident_sha256=n.digest(values['incident.json']),target_revision=n.document(values['incident.json'])['body']['git_revision_ref'],files=[dict(name=name,size_bytes=len(raw),sha256=n.digest(raw)) for name,raw in sorted(values.items())]))
        values['bundle.json']=n.canonical(marker)
        for name,raw in values.items():(leaf/name).write_bytes(raw)
        def open_bundle():
            held_parent=g.c._open_held(str(parent),True,lambda fd,state,ancestor:True,'E_RELATION')
            try:
                held=g.c._HeldBundle(held_parent,'bundle',form)
                try:check(held.files==values);held.recheck()
                finally:held.close()
            finally:held_parent.close()
        open_bundle()
        (leaf/'unexpected.json').write_bytes(b'{}\n');gate_reject(open_bundle);(leaf/'unexpected.json').unlink()
        if form=='withheld-write-policy.v1':
            original=values['shadow-record.json']
            for field,value in [('size_bytes',True),('sha256','f'*64),('name','wrong.json'),('extra',1)]:
                bad=n.document(original);bad['body']['scope_policy_ref'][field]=value
                gate_reject(g.c.check_scope_policy_ref,bad['body']['scope_policy_ref'],values['scope-policy.json'])
                (leaf/'shadow-record.json').write_bytes(n.canonical(bad));gate_reject(open_bundle)
                (leaf/'shadow-record.json').write_bytes(original)
        else:
            (leaf/'scope-policy.json').write_bytes((root/'scope/v1/scope-policy.json').read_bytes());gate_reject(open_bundle);(leaf/'scope-policy.json').unlink()
        open_bundle()
reader=g.r._Reader.__new__(g.r._Reader)
reader.scope={'id':'scope.own-snapshot'}
reader.scope_body=dict(workflow_id='workflow.shadow-evidence-commit',task_class='task.commit-shadow-evidence',coverage=dict(coverage_base=dict(repository_id='repo.test',hash_algorithm='sha1',commit_id='a'*40)))
reader.anchor=type('Anchor',(),dict(registry=('registry', [dict(environment_id='environment.test')])) )()
identity={key:[] for key in ('model_request','adapter_config_refs','prompt_refs','skill_refs','verification_instructions_ref')}
files={'shadow-record.json':n.canonical(env('shadow_reproduction_record','record.test',dict(qualified_identity=identity,environment=dict(environment_id='environment.test')))),
    'materialization-input.json':n.canonical(dict(resolved_profile=dict(content=dict(body={key:[] for key in ('profile_ref','profile_source','selection_ref','bindings')})))),
    'policy-set.json':n.canonical(env('control_policy_set','policy-set.test',{})),'policy.json':n.canonical(env('sandbox_policy','policy.test',{})),
    'scope-policy.json':n.canonical(env('scope_policy','policy.historical',{}))}
reader.package_sources={'scope/v1/scope-policy.json':Bytes('/unused', 'f'*64)}
old=g.r._Reader.coverage_identity(reader,files)
check(old['scope_policy_sha256']==n.digest(files['scope-policy.json']))
files['scope-policy.json']=n.canonical(env('scope_policy','policy.current',{}))
new=g.r._Reader.coverage_identity(reader,files)
check(old['scope_policy_sha256']!=new['scope_policy_sha256'])
check({k:v for k,v in old.items() if k!='scope_policy_sha256'}=={k:v for k,v in new.items() if k!='scope_policy_sha256'})
# Both complete coverage request contracts remain valid; partial extensions fail.
revision=dict(repository_id='repo.test',hash_algorithm='sha1',commit_id='a'*40)
legacy=dict(attempt_id='coverage.'+'e'*64,nonce='e'*64,repository_id='repo.test',coverage_base=revision,evaluated_revision=revision,coverage_rule_version=n.RULE_VERSION,
    documents={name:owner for name in n.DOCUMENT_NAMES},qualifying_shadow_record_refs=[owner],current_shadow_record_refs=[owner],qualifying_receipt_refs=[owner],
    resolved_profile_ref=owner,stage_request_ref=owner,stage_result_ref=owner,source_package_ref=owner,source_accepted_set_ref=owner,
    materialization_refs=[dict(environment_id='env.test',sha256='e'*64)],publisher_request_refs=[dict(environment_id='env.test',sha256='e'*64)],post_check_refs=[dict(environment_id='env.test',sha256='e'*64)],git_observation_sha256='f'*64)
check(n.request(n.canonical(env('coverage_source_request',legacy['attempt_id'],legacy)))['body']==legacy)
extended=dict(legacy,initial_origin_refs=[owner],gate_call_ref=owner)
check(n.request(n.canonical(env('coverage_source_request',legacy['attempt_id'],extended)))['body']==extended)
for extension in [dict(initial_origin_refs=[owner]),dict(gate_call_ref=owner),dict(initial_origin_refs=[],gate_call_ref=owner)]:
    reject(n.request,n.canonical(env('coverage_source_request',legacy['attempt_id'],dict(legacy,**extension))))
# Run the generator's tuple comparison on two controlled environments after its auth boundary.
spec=importlib.util.spec_from_file_location('gate_test_enforced',root/'shadow/v1/enforced-reproduction.py')
enforced=importlib.util.module_from_spec(spec);sys.modules[spec.name]=enforced;spec.loader.exec_module(enforced)
for conflict in (None,'stage_request','resolved_profile','stage_result','policy_set'):
    with tempfile.TemporaryDirectory() as tmp:
        output=pathlib.Path(tmp)
        for name in ('stage-request','resolved-profile','stage-result','policy-set'):(output/'objects'/name).mkdir(parents=True)
        request_doc=env('stage_request','request.multi',{})
        profile_doc=env('resolved_profile','profile.multi',{})
        result_doc=env('stage_result','result.multi',{})
        policy_doc=n.document((root/'control/v1/control-policy-set.json').read_bytes())
        def material(request_doc,profile_doc,result_doc,policy_doc):
            return {'materialization-input.json':n.canonical({name:dict(content=value,sha256=n.digest(n.canonical(value)))
                for name,value in [('stage_request',request_doc),('resolved_profile',profile_doc)]}),
                'materialization-response.json':n.canonical(dict(stage_result=result_doc)), 'policy-set.json':n.canonical(policy_doc)}
        first=material(request_doc,profile_doc,result_doc,policy_doc)
        docs=dict(stage_request=copy.deepcopy(request_doc),resolved_profile=copy.deepcopy(profile_doc),
            stage_result=copy.deepcopy(result_doc),policy_set=copy.deepcopy(policy_doc))
        if conflict is not None:docs[conflict]['id']+='-other'
        second=material(*[docs[name] for name in ('stage_request','resolved_profile','stage_result','policy_set')])
        class InputReader:
            darwin=None
            scope_body=dict(required_shadow_environments=['environment.one','environment.two'])
            def authenticate_bundles(self,current_only):
                check(current_only is True)
                return ([dict(claimed=True,authentication=dict(state='authenticated'))]*2,[],
                    dict(current={'environment.one':first,'environment.two':second},qualifying={}))
            def hold(self,path,limit):
                held=g.c._hold_bytes(str(path),limit);owned.append(held);return held
        owned=[];pair_calls=[];real_pair_ref=enforced.pair_ref
        def measured_pair(pair):pair_calls.append(copy.deepcopy(pair));return real_pair_ref(pair)
        enforced.pair_ref=measured_pair
        reader=InputReader();reader.enforced=enforced
        generator=g._Generator.__new__(g._Generator);generator.reader=reader;generator.output=output;generator.held=[];generator.outputs={};generator._init_output_capture()
        generator.basis=env('workflow_scope','scope.multi',dict(qualified_identity=dict(stage_request_ref=g.ref(n.canonical(request_doc)),resolved_profile_ref=g.ref(n.canonical(profile_doc)))))
        generator.session=g._GateStoreSession('generation.multi','b'*64,time.monotonic()+10);generator.session.reader=reader
        try:
            if conflict is None:
                generator.inputs()
                check(set(generator.outputs)=={'stage-request','resolved-profile','stage-result','policy-set'})
                check([generator.outputs[name].read_bytes() for name in ('stage-request','resolved-profile','stage-result','policy-set')]
                    ==[n.canonical(value) for value in (request_doc,profile_doc,result_doc,policy_doc)])
            else:
                try:generator.inputs()
                except g.c.Refusal as error:check(error.code=='E_RELATION')
                else:raise AssertionError('generator accepted cross-environment '+conflict+' conflict')
                check(not generator.outputs and not list(output.rglob('value.json')))
            check(len(pair_calls)==4)
        finally:
            enforced.pair_ref=real_pair_ref
            for held in reversed(owned+generator.held):held.close()
# A legal old-origin request reaches the actual C_REQUEST equality guard over a real wire.
for stale in (False,True):
    fresh_origin=dict(owner,id='origin.fresh',sha256='1'*64)
    old_origin=dict(owner,id='origin.old',sha256='2'*64)
    fresh_body=dict(extended,initial_origin_refs=[fresh_origin])
    fresh_request=env('coverage_source_request',fresh_body['attempt_id'],fresh_body)
    sent=copy.deepcopy(fresh_request)
    if stale:sent['body']['initial_origin_refs']=[old_origin]
    sent_raw=n.canonical(sent);check(n.request(sent_raw)==sent)
    wanted={key:sent['body'][key] for key in ('attempt_id','nonce','coverage_base','evaluated_revision','stage_request_ref',
        'resolved_profile_ref','stage_result_ref','source_package_ref','source_accepted_set_ref','initial_origin_refs','gate_call_ref')}
    wanted.update(request_sha256=n.digest(sent_raw),scope_ref=sent['body']['documents']['scope'])
    left,right=socket.socketpair();deadline=time.monotonic()+10
    outer=g._GateStoreSession('generation.origins','b'*64,deadline);outer.phase='K_DONE';outer.initialized=True
    outer.remote={'inner.1':copy.deepcopy(binding)}
    outer.wire=g.c._GateWire(left,deadline,outer.call_id,'a'*64,outer.binding)
    peer=g.c._GateWire(right,deadline,outer.call_id,'a'*64,outer.binding)
    calls=[];written=[]
    class OriginReader:
        coverage_configuration=object()
        def source_coverage(self,qualifying,current,rows):
            check(self._coverage_prepare_only and self._coverage_nonce==fresh_body['nonce'])
            calls.append('fresh reconstruction');return n.canonical(fresh_request)
        def recheck(self):calls.append('recheck')
        def release_stores(self):calls.append('release')
    outer.reader=OriginReader()
    outer.authenticate_core=lambda:([],[],dict(qualifying={},current={}))
    outer.generator=type('Outputs',(),dict(put=lambda self,name,raw:written.append((name,raw))))()
    peer.send('C_REQUEST',dict(request=sent,expectation=wanted,acquisitions=['inner.1']))
    try:
        if stale:
            try:outer.pump()
            except g.c.Refusal as error:check(error.code=='E_RELATION')
            else:raise AssertionError('generator accepted old origins in new handoff')
            check(calls==['fresh reconstruction'] and not written and outer.coverage_request_raw is None)
        else:
            outer.pump();check(peer.receive()==('C_REQUEST_ACK',{}))
            check(calls==['fresh reconstruction','recheck','release'])
            check(written[0]==('coverage-request',n.canonical(fresh_request)))
            check(n.document(written[1][1])['body']==wanted and outer.phase=='C_REQUEST')
        check(outer.reader._coverage_prepare_only is False and outer.reader._coverage_nonce is None)
    finally:left.close();right.close()
# Invalid canonical inputs make the real fixed shell children fail without source setup.
with tempfile.TemporaryDirectory() as tmp:
    directory=pathlib.Path(tmp)
    document=directory/'input.json';document.write_bytes(b'{}\n')
    class RunnerLedger:
        store_session=object()
        def environment(self):return {'PATH':'/usr/bin:/bin','LC_ALL':'C','LANG':'C'}
    runtime=g.c._hold_bytes(sys.executable,g.c.EXECUTABLE_LIMIT)
    consumer_source=g.c._hold_bytes(str(root/'shadow/v1/_consumer.py'),g.c.EXECUTABLE_LIMIT)
    actual=[];popen=g.c.subprocess.Popen
    def traced_popen(*args,**kwargs):
        child=popen(*args,**kwargs);actual.append((args[0],child));return child
    ledger=RunnerLedger()
    runner=g.c._DarwinChildOwner(runtime,consumer_source,time.monotonic()+20,ledger)
    left,right=socket.socketpair()
    peer=g.c._GateWire(socket.socket(fileno=os.dup(right.fileno())),time.monotonic()+15,'generation.runner','a'*64,'b'*64)
    peer.send('INIT_ACK',{});peer.sock.close()
    class RunnerSession:
        child_socket=right
        wire=g.c._GateWire(left,time.monotonic()+15,'generation.runner','a'*64,'b'*64)
        closed=False
        def pump(self):
            check(self.child_socket.fileno()==-1)
            check(self.wire.receive()==('INIT_ACK',{}))
            for relative,operation,count in [('shadow/v1/validate-incident.sh','validate',1),('enforcement/v1/check-sandbox-receipt.sh','check-bound',4)]:
                nested=['/bin/bash','-p',str(root/relative),operation,*[str(document)]*count]
                before=len(actual)
                try:runner._foreground(nested,b'',1024,65536,5,ledger.environment())
                except g.c.Refusal as error:check(error.code=='E_RUNTIME')
                else:raise AssertionError('invalid fixed checker unexpectedly succeeded')
                check(len(actual)==before+1 and actual[-1][0]==nested)
                check(actual[-1][1].pid>0 and actual[-1][1].returncode is not None)
                check(all(stream.closed for stream in (actual[-1][1].stdin,actual[-1][1].stdout,actual[-1][1].stderr)))
            self.closed=True
    session=RunnerSession()
    outer=['/bin/bash','-p',str(root/'scope/v1/evaluate-scope.sh'),'evaluate',*[str(document)]*9]
    runner._gate_invocation=outer;runner._gate_session=session
    g.c.subprocess.Popen=traced_popen
    try:
        try:runner._foreground(outer,b'',1024,65536,10,ledger.environment())
        except g.c.Refusal as error:check(error.code=='E_RUNTIME')
        else:raise AssertionError('invalid fixed scope driver unexpectedly succeeded')
        check(session.closed and len(actual)==3)
        check(all(child.pid>0 and child.returncode is not None for argv,child in actual))
        check(all(stream.closed for argv,child in actual for stream in (child.stdin,child.stdout,child.stderr)))
    finally:
        g.c.subprocess.Popen=popen
        left.close();right.close();consumer_source.close();runtime.close()
with tempfile.TemporaryDirectory() as tmp:
    path=pathlib.Path(tmp)/'exclusive.json'
    identity=g.r.write_exclusive(path,b'{}\n')
    check(path.read_bytes()==b'{}\n' and identity==g.c._identity(path.stat()))
    gate_reject(g.r.write_exclusive,path,b'{"replaced":true}\n')
    check(path.read_bytes()==b'{}\n')
    target=pathlib.Path(tmp)/'original';target.write_bytes(b'original\n')
    alias=pathlib.Path(tmp)/'alias';alias.symlink_to(target)
    gate_reject(g.r.write_exclusive,alias,b'overwrite\n');check(target.read_bytes()==b'original\n')
with tempfile.TemporaryDirectory() as tmp:
    output=pathlib.Path(tmp)/'output';output.mkdir(mode=0o700)
    relative=['private/reader-captures/gate-0000','private/reader-runtime/gate-0000/dependency',
        'private/reader-runtime/no-hooks','private/observation','objects/kill-evidence/raw-0000',
        'objects/coverage-evidence/raw-0000','completion','manifests']
    for name in relative:(output/name).mkdir(mode=0o700,parents=True)
    generator=g._Generator.__new__(g._Generator);generator.output=output;generator.deadline=time.monotonic()+10
    expected={g.c._identity(path.stat())[:2] for path in [output,*output.rglob('*')] if path.is_dir()}
    synced=[];fsync=g.os.fsync
    def traced_fsync(fd):
        synced.append(g.c._identity(g.os.fstat(fd))[:2]);fsync(fd)
    g.os.fsync=traced_fsync
    try:generator.sync_directories()
    finally:g.os.fsync=fsync
    check(set(synced)==expected and len(synced)==len(expected))
    check(synced[-1]==g.c._identity(output.stat())[:2])
    def failed_fsync(fd):raise OSError('injected directory fsync failure')
    g.os.fsync=failed_fsync
    try:
        try:generator.sync_directories()
        except OSError:check(not (output/'completion/COMPLETE.json').exists())
        else:raise AssertionError('directory fsync failure ignored')
    finally:g.os.fsync=fsync
    alias=output/'private/alias';alias.symlink_to(output/'objects',target_is_directory=True)
    gate_reject(generator.sync_directories)
raw_manifest,raw_pages=n._KillNormalizer.captured(framed(pages),request)
observation=n.kill_normalize(raw_manifest,raw_pages,request)
source_identity={'source_id':'source.test','host_supervisor_sha256':'a'*64,'source_package_sha256':'b'*64,'collector_sha256':'c'*64,'normalizer_sha256':'d'*64,'accepted_source_identity_ref':owner}
receipt_body=dict(operation=n.KILL_OPERATION,version=1,store_id='store.test',call_id=body['call_id'],request_sha256=n.digest(request),source_identity=source_identity,
    query=n._KillNormalizer.query(body,observation),raw_manifest_sha256=n.digest(raw_manifest),observation_sha256=n.digest(observation),
    started_at='2026-10-23T00:00:00Z',completed_at='2026-10-23T00:00:01Z',outcome='complete',effects=['read-forge-metadata','read-register'])
check(n._KillNormalizer.receipt(n.canonical(env('kill_register_source_receipt',body['call_id'],receipt_body)),request,dict(store_id='store.test'),source_identity,raw_manifest,observation)['body']==receipt_body)
for changed in [dict(started_at='2026-10-23T00:00:02Z',completed_at='2026-10-23T00:00:03Z'),dict(completed_at='2026-10-23T00:00:00Z'),dict(query={}),dict(outcome='partial')]:
    reject(n._KillNormalizer.receipt,n.canonical(env('kill_register_source_receipt',body['call_id'],dict(receipt_body,**changed))),request,dict(store_id='store.test'),source_identity,raw_manifest,observation)
# Execute only the actual fixture's pre-producer data transformation; no producer or native entry runs.
import ast,re
text=(root/'scripts/test/scope-qualification.test.sh').read_text()
start=re.search(r"<<'PY_GENUINE_ASSEMBLER'[^\n]*\n",text).end();end=text.index('\nPY_GENUINE_ASSEMBLER',start)
module=ast.parse(text[start:end]);builder=next(node for node in module.body if isinstance(node,ast.FunctionDef) and node.name=='build_coverage_revision')
branch=next(node for node in builder.body if isinstance(node,ast.If) and ast.unparse(node.test)=='risk_assertion is not None')
compiled=compile(ast.Module(body=branch.body,type_ignores=[]),'actual-risk-input-fixture','exec')
for assertion in ('accept','reject'):
    stage=env('stage_request','request.seed',dict(risk=dict(tier=dict(namespace='core',name='routine'),reason_ids=[],policy_ref={},required_gate_refs=[]),source=dict(state='present',value=dict(content_id='source.test')),requested_at='2026-10-23T00:00:00Z',gate_decision_refs=[]))
    reviewer=dict(binding=dict(role='reviewer',adapter_instance_id='instance.review',principal_id='principal.review',execution_boundary_id='boundary.review'),adapter_implementation=dict(id='implementation.review',version='1.0.0'))
    profile=env('resolved_profile','profile.test',dict(bindings=[reviewer]))
    q=dict(stage_request=dict(content=stage,sha256=n.digest(n.canonical(stage))),resolved_profile=dict(content=profile,sha256=n.digest(n.canonical(profile))))
    written=[]
    context=dict(json=g.json,risk_assertion=assertion,q=q,canonical=n.canonical,sha=n.digest,package=root,label='pure-'+assertion,work=pathlib.Path('/unopened-fixture'),put=lambda path,raw:written.append((str(path),raw)))
    exec(compiled,context)
    request_doc=q['stage_request']['content'];claim_doc=context['risk_claim'];claim_raw=context['risk_claim_raw']
    basis=copy.deepcopy(request_doc);del basis['body']['gate_decision_refs']
    check(claim_doc['body']['request_basis_sha256']==n.digest(n.canonical(basis)[:-1]))
    check(claim_doc['body']['request_basis_sha256']!=n.digest(n.canonical(basis)))
    check(q['stage_request']['sha256']==n.digest(n.canonical(request_doc)))
    check(request_doc['body']['gate_decision_refs'][0]['decision_record_ref']['sha256']==n.digest(claim_raw))
    check(claim_doc['body']['decision']['value']['asserted_decision']==assertion)
    check(claim_doc['body']['decision']['value']['decided_by']['principal_id']=='principal.review')
    check(written==[('/unopened-fixture/risk-claim.json',claim_raw)])
# Exercise the actual entry cleanup and marker writes with a bounded filesystem owner.
original_generator=g._Generator
for fault in ('fsync','run','close','deadline','cancel','preserved'):
    with tempfile.TemporaryDirectory() as tmp:
        output=pathlib.Path(tmp)/'output'
        if fault=='preserved':
            (output/'completion').mkdir(parents=True)
            (output/'completion/COMPLETE.json').write_bytes(b'preserved\n')
        class CompletionOwner:
            sync_directories=original_generator.sync_directories
            def __init__(self,arguments):
                self.output=output;self.created=False;self.deadline=time.monotonic()+10
                if fault=='preserved':raise ValueError('preexisting output')
                output.mkdir(mode=0o700);self.created=True
                for name in ('completion','objects','objects/value'):(output/name).mkdir(mode=0o700)
            def run(self):
                g.r.write_exclusive(output/'objects/value/value.json',b'{}\n')
                self.sync_directories()
                if fault=='fsync':raise AssertionError('directory fsync should have failed')
                g.r.write_exclusive(output/'completion/COMPLETE.json',b'{}\n')
                if fault=='run':raise ValueError('post-marker error')
                if fault=='cancel':raise InterruptedError('cancelled')
                if fault=='deadline':self.deadline=time.monotonic()-1
            def close(self):
                if fault=='close':raise OSError('close failure')
        g._Generator=CompletionOwner
        fsync=g.os.fsync
        if fault=='fsync':
            def fail_directory_sync(fd):
                if g.stat.S_ISDIR(g.os.fstat(fd).st_mode):raise OSError('directory barrier failure')
                fsync(fd)
            g.os.fsync=fail_directory_sync
        try:
            try:g.main([])
            except (ValueError,OSError,InterruptedError,g.c.Refusal):pass
            else:raise AssertionError('entry failure unexpectedly returned success')
            marker=output/'completion/COMPLETE.json'
            check(marker.read_bytes()==b'preserved\n' if fault=='preserved' else not marker.exists())
        finally:g._Generator=original_generator;g.os.fsync=fsync
print(f'PASS {checks} pure parser / projection / Git-history / closed argv / socket lifecycle controls; no source/native execution')
PY
