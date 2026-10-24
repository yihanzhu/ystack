#!/bin/bash
set -euo pipefail
{ [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = --pure ]; }; } || { printf '%s\n' 'usage: scope-gate-generation.test.sh --pure' >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
python3 -I -S -B - "$repo" <<'PY'
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
def gate_reject(fn,*args):
    global checks
    try:fn(*args)
    except (g.c.Refusal,KeyError,TypeError,ValueError,OSError):checks+=1
    else:raise AssertionError('accepted invalid gate contract')
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
print(f'PASS {checks} pure parser / projection / Git-history / closed argv / socket lifecycle controls; no source/native execution')
PY
