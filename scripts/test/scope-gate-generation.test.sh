#!/bin/bash
set -euo pipefail
[ "$#" -eq 1 ] && [ "$1" = --pure ] || { printf '%s\n' 'usage: scope-gate-generation.test.sh --pure' >&2; exit 1; }
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
print(f'PASS {checks} pure parser / Git-object / ref-history / owner-merge controls; no source/native execution')
PY
