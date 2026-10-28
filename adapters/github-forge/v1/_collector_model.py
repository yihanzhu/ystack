"""Private validation and observations for the inactive GitHub collector."""
import datetime
import json
import re

PREFIX = 'github.collect.'
MAX_RECORD = 2 * 1024 * 1024
OUTCOMES = {
    'collected': {'observed'},
    'stale': {'binding-stale', 'bracket-drift'},
    'unavailable': {'credential-binding-unavailable', 'trust-store-unavailable',
                    'network-failed', 'provider-unavailable', 'target-unavailable',
                    'identity-unavailable', 'fact-unavailable', 'request-timeout',
                    'attempt-timeout', 'cancelled'},
    'inconclusive': {'file-limit', 'page-limit', 'duplicate-file',
                     'continuation-conflict', 'count-mismatch'},
    'refused': {'invalid-input', 'unsupported-runtime', 'forbidden-destination',
                'invalid-http', 'invalid-json', 'invalid-provider-data',
                'tls-verification-failed', 'clock-invalid', 'ipc-invalid',
                'close-failed', 'worker-failed', 'worker-ownership-lost',
                'output-invalid', 'output-failed'},
}
MISSING = ['app-identity-unavailable', 'canonical-head-unavailable',
           'file-count-unavailable', 'patch-text-unavailable',
           'patch-completeness-unknown', 'atomic-revision-binding-unknown']


class Failure(Exception):
    def __init__(self, outcome, reason):
        if reason not in OUTCOMES.get(outcome, set()):
            raise ValueError('invalid fixed failure')
        self.outcome = outcome
        self.reason = PREFIX + reason
        self.cleanup = []


def fail(reason, outcome='refused'):
    raise Failure(outcome, reason)


def observed(value):
    return {'state': 'observed', 'value': value}


def unavailable(reason):
    return {'state': 'unavailable', 'reason_id': PREFIX + reason}


def exact(value, keys):
    return type(value) is dict and set(value) == set(keys)


def matches(pattern, value):
    return type(value) is str and re.fullmatch(pattern, value, re.ASCII) is not None


def decimal(value):
    return matches(r'[1-9][0-9]{0,19}', value)


def provider_id(value):
    if type(value) is not int or not decimal(str(value)):
        fail('invalid-provider-data')
    return str(value)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail('invalid-json')
        result[key] = value
    return result


def decode(data):
    try:
        text = data.decode('utf-8')
        depth = 0
        quoted = escaped = False
        for character in text:
            if quoted:
                if escaped:
                    escaped = False
                elif character == '\\':
                    escaped = True
                elif character == '"':
                    quoted = False
            elif character == '"':
                quoted = True
            elif character in '[{':
                depth += 1
                if depth > 32:
                    fail('invalid-json')
            elif character in ']}':
                depth -= 1
        value = json.loads(text, object_pairs_hook=_pairs,
                           parse_constant=lambda _: fail('invalid-json'))
        def unicode_check(item):
            if isinstance(item, str):
                item.encode('utf-8')
            elif isinstance(item, list):
                for member in item:
                    unicode_check(member)
            elif isinstance(item, dict):
                for key, member in item.items():
                    unicode_check(key)
                    unicode_check(member)
            elif isinstance(item, float):
                if item != item or abs(item) == float('inf'):
                    fail('invalid-json')
        unicode_check(value)
        return value
    except (ValueError, UnicodeError, RecursionError):
        fail('invalid-json')


def encode(value):
    try:
        data = json.dumps(value, ensure_ascii=True, allow_nan=False,
                          separators=(',', ':')).encode('utf-8')
    except (ValueError, TypeError, UnicodeError):
        fail('output-invalid')
    if len(data) > MAX_RECORD:
        fail('output-invalid')
    return data


def validate_request(value):
    fields = ['owner', 'repo', 'pull_number', 'expected_head_repository_id',
              'authentication', 'bindings']
    binding_keys = ['expected_repository_id', 'expected_change_request_id',
                    'expected_head', 'expected_base', 'expected_github_app_id',
                    'instruction_ref', 'config_ref']
    valid = exact(value, fields)
    if not valid:
        fail('invalid-input')
    valid = (matches(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?', value['owner'])
             and matches(r'[A-Za-z0-9][A-Za-z0-9._-]{0,99}', value['repo'])
             and not value['repo'].lower().endswith('.git')
             and decimal(value['pull_number'])
             and decimal(value['expected_head_repository_id'])
             and value['authentication'] in ('anonymous', 'app-bound')
             and exact(value['bindings'], binding_keys))
    if not valid:
        fail('invalid-input')
    binding = value['bindings']
    for key in ['expected_repository_id', 'expected_change_request_id', 'expected_github_app_id']:
        if not decimal(binding[key]):
            fail('invalid-input')
    for key in ['expected_head', 'expected_base']:
        revision = binding[key]
        if not (exact(revision, ['repository_id', 'hash_algorithm', 'commit_id'])
                and matches(r'[a-z0-9][a-z0-9._:-]{0,127}', revision['repository_id'])
                and revision['hash_algorithm'] == 'sha1'
                and matches(r'[0-9a-f]{40}', revision['commit_id'])):
            fail('invalid-input')
    if binding['expected_head']['repository_id'] != binding['expected_base']['repository_id']:
        fail('invalid-input')
    for key in ['instruction_ref', 'config_ref']:
        ref = binding[key]
        if not (exact(ref, ['content_id', 'media_type', 'sha256'])
                and matches(r'[a-z0-9][a-z0-9._-]{0,127}', ref['content_id'])
                and matches(r'[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*', ref['media_type'])
                and len(ref['media_type']) <= 127
                and matches(r'[0-9a-f]{64}', ref['sha256'])):
            fail('invalid-input')
    return value


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def timestamp(value):
    if not matches(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z', value):
        fail('invalid-provider-data')
    try:
        datetime.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ')
    except ValueError:
        fail('invalid-provider-data')
    return value


def target(value, request, end):
    required = ['id', 'number', 'base', 'head', 'state', 'created_at',
                'updated_at', 'closed_at', 'merged_at']
    if type(value) is not dict:
        fail('invalid-provider-data')
    if any(key not in value for key in required):
        fail('identity-unavailable', 'unavailable')
    try:
        base = value['base']
        head = value['head']
        for side in (base, head):
            if side is None:
                fail('identity-unavailable', 'unavailable')
            if type(side) is not dict:
                fail('invalid-provider-data')
            if side.get('repo') is None:
                fail('identity-unavailable', 'unavailable')
            if type(side['repo']) is not dict:
                fail('invalid-provider-data')
        projection = {
            'change_request_id': provider_id(value['id']),
            'number': provider_id(value['number']),
            'repository_id': provider_id(base['repo']['id']),
            'repository_full_name': base['repo']['full_name'],
            'head_repository_id': provider_id(head['repo']['id']),
            'head_sha': head['sha'], 'base_sha': base['sha'],
            'state': value['state'],
        }
    except KeyError:
        fail('identity-unavailable', 'unavailable')
    except TypeError:
        fail('invalid-provider-data')
    if not (matches(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9][A-Za-z0-9._-]{0,99}', projection['repository_full_name'])
            and matches(r'[0-9a-f]{40}', projection['head_sha'])
            and matches(r'[0-9a-f]{40}', projection['base_sha'])
            and projection['state'] in ('open', 'closed')):
        fail('invalid-provider-data')
    for key in ['created_at', 'updated_at', 'closed_at', 'merged_at']:
        projection[key] = value[key]
        if value[key] is not None:
            timestamp(value[key])
        elif key in ('created_at', 'updated_at'):
            fail('invalid-provider-data')
    created, updated = value['created_at'], value['updated_at']
    closed, merged = value['closed_at'], value['merged_at']
    if not created <= updated <= end:
        fail('invalid-provider-data')
    if closed is not None and not created <= closed <= updated:
        fail('invalid-provider-data')
    if merged is not None and not created <= merged <= (closed or ''):
        fail('invalid-provider-data')
    if value['state'] == 'open' and (closed is not None or merged is not None):
        fail('invalid-provider-data')
    if value['state'] == 'closed' and closed is None:
        fail('invalid-provider-data')
    for key in ['merged', 'mergeable', 'changed_files']:
        if key not in value:
            projection[key] = unavailable('fact-unavailable')
            continue
        item = value[key]
        if key == 'changed_files':
            if type(item) is not int or not 0 <= item <= 100000:
                fail('invalid-provider-data')
        elif key == 'merged':
            if type(item) is not bool or item != (merged is not None):
                fail('invalid-provider-data')
        elif item is not None and type(item) is not bool:
            fail('invalid-provider-data')
        projection[key] = observed(item)
    binding = request['bindings']
    checks = [projection['change_request_id'] == binding['expected_change_request_id'],
              projection['number'] == request['pull_number'],
              projection['repository_id'] == binding['expected_repository_id'],
              projection['head_repository_id'] == request['expected_head_repository_id'],
              projection['repository_full_name'].lower() == (request['owner'] + '/' + request['repo']).lower(),
              projection['head_sha'] == binding['expected_head']['commit_id'],
              projection['base_sha'] == binding['expected_base']['commit_id']]
    if not all(checks):
        fail('binding-stale', 'stale')
    return projection


def file_observation(value):
    if type(value) is not dict or 'filename' not in value or 'status' not in value:
        fail('invalid-provider-data')
    path, status = value['filename'], value['status']
    if not (type(path) is str and path and len(path.encode('utf-8')) <= 4096
            and not any(ord(c) < 32 or 127 <= ord(c) <= 159 or c == '\\' for c in path)
            and all(part not in ('', '.', '..') for part in path.split('/'))
            and status in ('added', 'changed', 'copied', 'modified', 'removed', 'renamed', 'unchanged')):
        fail('invalid-provider-data')
    if 'patch' not in value:
        patch = unavailable('patch-missing')
    elif value['patch'] is None:
        patch = unavailable('patch-null')
    elif type(value['patch']) is not str:
        fail('invalid-provider-data')
    elif not value['patch']:
        patch = unavailable('patch-empty')
    else:
        import hashlib
        data = value['patch'].encode('utf-8')
        patch = observed({'observed_patch_sha256': hashlib.sha256(data).hexdigest(),
                          'byte_length': len(data), 'completeness': 'unknown'})
    return {'path': path, 'status': status, 'patch': patch}


def missing_requirements(target_value=None, files=None):
    missing = [MISSING[0]]
    if target_value is None or target_value['head_repository_id'] != target_value['repository_id']:
        missing.append(MISSING[1])
    if target_value is None or target_value['changed_files']['state'] != 'observed':
        missing.append(MISSING[2])
    if files is None or any(item['patch']['state'] != 'observed' for item in files):
        missing.append(MISSING[3])
    return [PREFIX + item for item in missing + MISSING[4:]]


def worker_result(outcome='collected', reason='observed', mapped=None, files=None, counters=None, cleanup=None):
    return {'outcome': outcome, 'reason_id': PREFIX + reason,
            'target': observed(mapped) if mapped is not None and outcome == 'collected' else unavailable('fact-unavailable'),
            'files': observed(files) if files is not None and outcome == 'collected' else unavailable('fact-unavailable'),
            'counters': counters or {'requests_started': 0, 'responses_read': 0, 'body_bytes': 0, 'pages': 0},
            'cleanup_errors': cleanup or []}


def validate_worker(value, request=None):
    if not exact(value, ['outcome', 'reason_id', 'target', 'files', 'counters', 'cleanup_errors']):
        fail('ipc-invalid')
    outcome = value['outcome']
    if type(outcome) is not str or type(value['reason_id']) is not str or value['reason_id'] not in {PREFIX + r for r in OUTCOMES.get(outcome, set())}:
        fail('ipc-invalid')
    counters = value['counters']
    if not exact(counters, ['requests_started', 'responses_read', 'body_bytes', 'pages']):
        fail('ipc-invalid')
    for key, limit in [('requests_started', 5), ('responses_read', 5), ('body_bytes', 4 * MAX_RECORD), ('pages', 3)]:
        if type(counters[key]) is not int or not 0 <= counters[key] <= limit:
            fail('ipc-invalid')
    if counters['responses_read'] > counters['requests_started']:
        fail('ipc-invalid')
    if not isinstance(value['cleanup_errors'], list) or any(x != 'close-failed' for x in value['cleanup_errors']):
        fail('ipc-invalid')
    for key in ['target', 'files']:
        fact = value[key]
        if outcome == 'collected':
            if not exact(fact, ['state', 'value']) or fact['state'] != 'observed':
                fail('ipc-invalid')
        elif fact != unavailable('fact-unavailable'):
            fail('ipc-invalid')
    if outcome == 'collected':
        mapped = value['target']['value']
        keys = ['change_request_id', 'number', 'repository_id', 'repository_full_name',
                'head_repository_id', 'head_sha', 'base_sha', 'state', 'created_at',
                'updated_at', 'closed_at', 'merged_at', 'merged', 'mergeable', 'changed_files']
        if not exact(mapped, keys) or type(value['files']['value']) is not list:
            fail('ipc-invalid')
        if len(value['files']['value']) > 256:
            fail('ipc-invalid')
        if request is None:
            fail('ipc-invalid')
        provider = {'id': None, 'number': None, 'base': {'repo': {}}, 'head': {'repo': {}}}
        try:
            provider['id'] = int(mapped['change_request_id'])
            provider['number'] = int(mapped['number'])
            provider['base']['repo'] = {'id': int(mapped['repository_id']), 'full_name': mapped['repository_full_name']}
            provider['head']['repo'] = {'id': int(mapped['head_repository_id'])}
            provider['head']['sha'], provider['base']['sha'] = mapped['head_sha'], mapped['base_sha']
            for key in ['state', 'created_at', 'updated_at', 'closed_at', 'merged_at']:
                provider[key] = mapped[key]
            for key in ['merged', 'mergeable', 'changed_files']:
                fact = mapped[key]
                if fact == unavailable('fact-unavailable'):
                    continue
                if not exact(fact, ['state', 'value']) or fact['state'] != 'observed':
                    fail('ipc-invalid')
                provider[key] = fact['value']
            if target(provider, request, utc_now()) != mapped:
                fail('ipc-invalid')
        except (Failure, ValueError, TypeError, KeyError):
            fail('ipc-invalid')
        previous = None
        for item in value['files']['value']:
            if not exact(item, ['path', 'status', 'patch']):
                fail('ipc-invalid')
            path, status = item['path'], item['status']
            if not (type(path) is str and path and len(path.encode('utf-8')) <= 4096
                    and not any(ord(ch) < 32 or 127 <= ord(ch) <= 159 or ch == '\\' for ch in path)
                    and all(part not in ('', '.', '..') for part in path.split('/'))
                    and status in ('added', 'changed', 'copied', 'modified', 'removed', 'renamed', 'unchanged')
                    and (previous is None or previous < path)):
                fail('ipc-invalid')
            previous = path
            patch = item['patch']
            if type(patch) is not dict:
                fail('ipc-invalid')
            if patch.get('state') == 'observed':
                if not exact(patch, ['state', 'value']) or not exact(patch['value'], ['observed_patch_sha256', 'byte_length', 'completeness']):
                    fail('ipc-invalid')
                if (not matches(r'[0-9a-f]{64}', patch['value']['observed_patch_sha256'])
                        or patch['value']['completeness'] != 'unknown'
                        or type(patch['value']['byte_length']) is not int
                        or not 1 <= patch['value']['byte_length'] <= MAX_RECORD):
                    fail('ipc-invalid')
            elif patch not in [unavailable(r) for r in ['patch-missing', 'patch-null', 'patch-empty']]:
                fail('ipc-invalid')
        if counters['requests_started'] != counters['pages'] + 2 or counters['responses_read'] != counters['requests_started']:
            fail('ipc-invalid')
        count = mapped['changed_files']
        if count['state'] == 'observed' and count['value'] != len(value['files']['value']):
            fail('ipc-invalid')
    return value


def record(request, started, ended, elapsed, result, retirement, cleanup):
    if (ended < started or elapsed < 0
            or result['outcome'] == 'collected' and result['target']['value']['updated_at'] > ended):
        result = worker_result('refused', 'clock-invalid', counters=result['counters'],
                               cleanup=result['cleanup_errors'])
    collected = result['outcome'] == 'collected'
    mapped = result['target']['value'] if collected else None
    files = result['files']['value'] if collected else None
    if collected:
        mapped['github_app_id'] = unavailable('app-identity-unavailable')
        mapped['canonical_head'] = (observed(request['bindings']['expected_head'])
                                    if mapped['head_repository_id'] == mapped['repository_id']
                                    else unavailable('canonical-head-unavailable'))
        mapped['canonical_base'] = observed(request['bindings']['expected_base'])
    return {
        'schema_version': 1, 'kind': 'github_change_request_collection',
        'adapter': {'id': 'adapter.github-forge.collector.v1', 'version': 'v1', 'status': 'inactive'},
        'outcome': result['outcome'], 'reason_id': result['reason_id'],
        'request_binding': observed(request) if request is not None else unavailable('invalid-input'),
        'observation_window': {'started_at': started, 'ended_at': ended, 'elapsed_seconds': max(0, elapsed)},
        'target': result['target'], 'files': result['files'],
        'evidence': dict(result['counters'], enumeration='bounded-end' if collected else 'unavailable',
                         file_set_completeness='unknown', count_comparison=(
                             'count-matched' if mapped and mapped['changed_files']['state'] == 'observed' else 'unavailable'),
                         bracket_comparison='bracket-matched' if collected else 'unavailable',
                         worker_retirement=retirement, cleanup_errors=cleanup + result['cleanup_errors']),
        'normalizer': dict(unavailable('normalizer-input-unavailable'),
                           missing_requirements=missing_requirements(mapped, files)),
        'authority': 'none', 'qualification': {'state': 'unavailable', 'reason_id': 'adapter.unqualified'},
        'effects': [],
    }
