"""Hermetic controls for the production collector byte reader and direct owner."""
import sys
import os

_INITIAL_ENV = dict(os.environ)
import importlib.util

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../..'))
ENTRY = os.path.join(ROOT, 'adapters/github-forge/v1/collect.py')
_spec = importlib.util.spec_from_file_location('collector_entry', ENTRY)
c = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(c)

import copy
import errno
import json
import signal
import socket
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

m, h = c.model, c.http
_REAL_SOCKET = socket.socket
_REAL_RESOLVER = socket.getaddrinfo


def deny(*_args, **_kwargs):
    raise AssertionError('native network forbidden by hermetic suite')


socket.socket = deny
socket.getaddrinfo = deny


def request():
    revision = lambda oid: {'repository_id': 'repo.target', 'hash_algorithm': 'sha1', 'commit_id': oid * 40}
    content = lambda char: {'content_id': 'fixture', 'media_type': 'application/json', 'sha256': char * 64}
    return {'owner': 'Fixture', 'repo': 'sample', 'pull_number': '7',
            'expected_head_repository_id': '11', 'authentication': 'anonymous',
            'bindings': {'expected_repository_id': '11', 'expected_change_request_id': '9007199254740993',
                         'expected_head': revision('a'), 'expected_base': revision('b'),
                         'expected_github_app_id': '42', 'instruction_ref': content('c'), 'config_ref': content('d')}}


def pr(count=1):
    return {'id': 9007199254740993, 'number': 7,
            'base': {'repo': {'id': 11, 'full_name': 'fixture/sample'}, 'sha': 'b' * 40},
            'head': {'repo': {'id': 11}, 'sha': 'a' * 40}, 'state': 'open',
            'created_at': '2020-01-01T00:00:00Z', 'updated_at': '2020-02-01T00:00:00Z',
            'closed_at': None, 'merged_at': None, 'merged': False, 'mergeable': None,
            'changed_files': count}


def file_value(path='src/a', text='hello\r\n世界'):
    return {'filename': path, 'status': 'modified', 'patch': text}


def wire(value=None, status=200, headers=None, body=None, framing='length'):
    body = json.dumps(value, ensure_ascii=False).encode() if body is None else body
    fields = [('Content-Type', 'application/json')]
    if framing == 'length':
        fields.append(('Content-Length', str(len(body))))
    elif framing == 'chunked':
        fields.append(('Transfer-Encoding', 'chunked'))
        body = format(len(body), 'x').encode() + b'\r\n' + body + b'\r\n0\r\n\r\n'
    fields += headers or []
    return (('HTTP/1.1 ' + str(status) + ' Fixture\r\n').encode()
            + b''.join((name + ': ' + val + '\r\n').encode() for name, val in fields)
            + b'\r\n' + body)


class BytesConnection:
    def __init__(self, data, chunk=19, close_error=False, hold=None):
        self.data = bytearray(data)
        self.header_end = data.find(b'\r\n\r\n') + 4
        self.consumed = 0
        self.chunk = chunk
        self.sent = []
        self.closed = False
        self.close_error = close_error
        self.hold = hold

    def settimeout(self, seconds):
        assert seconds > 0

    def sendall(self, data):
        self.sent.append(data)
        if self.hold == 'connect':
            time.sleep(60)

    def recv(self, count):
        if self.hold in ('headers', 'body'):
            if self.hold == 'headers' or self.consumed >= self.header_end:
                time.sleep(60)
        amount = min(count, self.chunk, len(self.data))
        data = bytes(self.data[:amount])
        del self.data[:amount]
        self.consumed += amount
        return data

    def close(self):
        self.closed = True
        if self.close_error:
            raise OSError(errno.EIO, 'fixture secret never publish')


class Script:
    def __init__(self, responses, chunk=19, close_error=False):
        self.responses = list(responses)
        self.connections = []
        self.chunk = chunk
        self.close_error = close_error

    def __call__(self, deadline):
        h.remaining(deadline)
        if not self.responses:
            raise AssertionError('unexpected follow-up request')
        item = BytesConnection(self.responses.pop(0), self.chunk, self.close_error)
        self.connections.append(item)
        return item


def sequence(target=None, files=None, final=None):
    first = target if target is not None else pr()
    return [wire(first), wire(files if files is not None else [file_value()]),
            wire(final if final is not None else first)]


def collect(responses, req=None, **kwargs):
    script = Script(responses, **kwargs)
    starts, ends = [], []
    def begin(ordinal):
        starts.append(ordinal)
        return time.monotonic() + 5
    with patch.object(h, 'native_connection', script):
        result = h.collect(req or request(), begin, ends.append, lambda: False)
    return result, script, starts, ends


class MappingAndWire(unittest.TestCase):
    def assert_result(self, responses, outcome, reason=None, req=None, **kwargs):
        result, script, starts, ends = collect(responses, req, **kwargs)
        self.assertEqual(result['outcome'], outcome)
        if reason:
            self.assertEqual(result['reason_id'], m.PREFIX + reason)
        self.assertEqual(len(starts), len(script.connections))
        self.assertTrue(all(conn.closed for conn in script.connections))
        self.assertLessEqual(len(starts), 5)
        if outcome != 'collected':
            self.assertEqual(result['target'], m.unavailable('fact-unavailable'))
            self.assertEqual(result['files'], m.unavailable('fact-unavailable'))
        return result, script

    def test_same_repository_fragmented(self):
        result, script = self.assert_result(sequence(), 'collected', chunk=1)
        self.assertEqual(result['target']['value']['change_request_id'], '9007199254740993')
        patch_fact = result['files']['value'][0]['patch']['value']
        import hashlib
        self.assertEqual(patch_fact['observed_patch_sha256'], hashlib.sha256('hello\r\n世界'.encode()).hexdigest())
        self.assertEqual(patch_fact['byte_length'], 13)
        self.assertEqual(patch_fact['completeness'], 'unknown')
        self.assertEqual(len(script.connections), 3)
        expected = ['/repos/Fixture/sample/pulls/7',
                    '/repos/Fixture/sample/pulls/7/files?per_page=100&page=1',
                    '/repos/Fixture/sample/pulls/7']
        for conn, route in zip(script.connections, expected):
            self.assertEqual(conn.sent, [h.request_bytes(route)])
            self.assertNotIn(b'Authorization', conn.sent[0])
        self.assertIn(m.PREFIX + 'atomic-revision-binding-unknown',
                      m.missing_requirements(result['target']['value'], result['files']['value']))

    def test_fork(self):
        value = pr()
        value['head']['repo']['id'] = 22
        req = request()
        req['expected_head_repository_id'] = '22'
        result, _ = self.assert_result(sequence(value), 'collected', req=req)
        self.assertIn(m.PREFIX + 'canonical-head-unavailable',
                      m.missing_requirements(result['target']['value'], result['files']['value']))

    def test_missing_optional(self):
        value = pr()
        for key in ('merged', 'mergeable', 'changed_files'):
            del value[key]
        result, _ = self.assert_result(sequence(value), 'collected')
        self.assertEqual(result['target']['value']['changed_files']['state'], 'unavailable')

    def test_missing_patches(self):
        for patch_value, reason in [(None, 'patch-null'), ('', 'patch-empty'), ('missing', 'patch-missing')]:
            value = file_value()
            if patch_value == 'missing':
                del value['patch']
            else:
                value['patch'] = patch_value
            with self.subTest(reason=reason):
                result, _ = self.assert_result(sequence(files=[value]), 'collected')
                self.assertEqual(result['files']['value'][0]['patch'], m.unavailable(reason))
        for text in ('@@ -1 +1 @@\n+x', 'binary\x00text'):
            result, _ = self.assert_result(sequence(files=[file_value(text=text)]), 'collected')
            self.assertEqual(result['files']['value'][0]['patch']['value']['completeness'], 'unknown')

    def test_identity_and_revisions(self):
        for field, value in [('id', 7), ('number', 9007199254740993), ('id', 9007199254740992)]:
            item = pr()
            item[field] = value
            self.assert_result([wire(item)], 'stale', 'binding-stale')
        for side in ('head', 'base'):
            value = pr()
            value[side]['sha'] = 'c' * 40
            self.assert_result([wire(value)], 'stale')
            value = pr()
            value[side]['repo']['id'] = 22
            self.assert_result([wire(value)], 'stale')
        value = pr()
        value['base']['repo']['full_name'] = 'elsewhere/repo'
        self.assert_result([wire(value)], 'stale')
        value = pr()
        value['head']['repo'] = None
        self.assert_result([wire(value)], 'unavailable', 'identity-unavailable')

    def test_invalid_facts(self):
        for key, item in [('id', True), ('id', 1.0), ('state', 'ready'),
                          ('created_at', '2021-02-29T00:00:00Z'), ('updated_at', '9999-01-01T00:00:00Z'),
                          ('closed_at', '2020-01-01T00:00:00Z'), ('merged', True),
                          ('mergeable', 1), ('changed_files', True), ('changed_files', -1)]:
            value = pr()
            value[key] = item
            with self.subTest(key=key, item=item):
                self.assert_result([wire(value)], 'refused', 'invalid-provider-data')

    def test_drift(self):
        for key, item in [('updated_at', '2020-03-01T00:00:00Z'), ('mergeable', True), ('changed_files', 2)]:
            value = pr()
            value[key] = item
            self.assert_result(sequence(final=value), 'stale', 'bracket-drift')
        value = pr()
        del value['merged']
        self.assert_result(sequence(final=value), 'stale', 'bracket-drift')
        self.assert_result(sequence()[:2] + [wire(status=404)], 'unavailable', 'target-unavailable')

    def test_count_and_duplicate(self):
        self.assert_result([wire(pr(257))], 'inconclusive', 'file-limit')
        self.assert_result(sequence(pr(2)), 'inconclusive', 'count-mismatch')
        self.assert_result(sequence(pr(2), [file_value(), file_value()]), 'inconclusive', 'duplicate-file')
        value = pr()
        del value['changed_files']
        result, _ = self.assert_result(sequence(value, []), 'collected')
        self.assertIn(m.PREFIX + 'file-count-unavailable', m.missing_requirements(result['target']['value'], []))

    def test_pages_and_sort(self):
        files = [file_value('z/' + str(i)) for i in range(100)]
        responses = [wire(pr(101)), wire(files), wire([file_value('a')]), wire(pr(101))]
        result, script = self.assert_result(responses, 'collected')
        self.assertEqual(result['files']['value'][0]['path'], 'a')
        self.assertEqual(result['counters']['pages'], 2)
        self.assertIn(b'page=2', script.connections[2].sent[0])
        files2 = [file_value('b/' + str(i)) for i in range(100)]
        files3 = [file_value('c/' + str(i)) for i in range(57)]
        self.assert_result([wire(pr(256)), wire(files), wire(files2), wire(files3)], 'inconclusive', 'file-limit')
        result, _ = self.assert_result([wire(pr(256)), wire(files), wire(files2), wire(files3[:56]), wire(pr(256))], 'collected')
        self.assertEqual(len(result['files']['value']), 256)

    def test_links(self):
        route = 'https://api.github.com/repos/Fixture/sample/pulls/7/files?per_page=100&page='
        for value in ['<https://evil.invalid/>; rel="next"', '<' + route + '2>; rel="next"',
                      '<' + route + '1>; rel="next"', '<' + route + '4>; rel="last"',
                      '<' + route + '1>; rel="first", <' + route + '1>; rel="first"',
                      '<' + route + '1>; rel="unknown"']:
            result, _ = collect([wire(pr()), wire([file_value()], headers=[('Link', value)])])[:2]
            self.assertIn(result['outcome'], ('refused', 'inconclusive'))
        h.links('<' + route + '2>; rel="next", <' + route + '3>; rel="last"',
                '/repos/Fixture/sample/pulls/7', 1, False)

    def test_paths_and_statuses(self):
        for path in ['/a', 'a//b', '../a', 'a/..', 'a\\b', 'a\x00b', 'a\x85b', 'a' * 4097]:
            self.assert_result(sequence(files=[file_value(path)]), 'refused', 'invalid-provider-data')
        for status in ['MODIFIED', 'unknown', None]:
            value = file_value()
            value['status'] = status
            self.assert_result(sequence(files=[value]), 'refused')
        self.assert_result(sequence(files=[dict(file_value(), patch=[]) ]), 'refused')

    def test_http_status_classes(self):
        for status in [301, 302, 307, 308, 400, 418]:
            self.assert_result([wire(status=status)], 'refused', 'invalid-http')
        for status in [401, 403, 429, 500, 503, 599]:
            self.assert_result([wire(status=status)], 'unavailable', 'provider-unavailable')
        self.assert_result([wire(status=404)], 'unavailable', 'target-unavailable')

    def test_http_framing(self):
        for framing in ['chunked', 'close']:
            self.assert_result([wire(pr(), framing=framing), wire([file_value()], framing=framing), wire(pr(), framing=framing)], 'collected', chunk=1)
        invalid = [b'HTTP/2 200 OK\r\n\r\n', b'HTTP/1.1 200 OK\r\n fold: x\r\n\r\n',
                   wire(pr(), headers=[('Content-Length', '1')]),
                   wire(pr(), headers=[('Transfer-Encoding', 'chunked')]),
                   wire(pr(), headers=[('Content-Encoding', 'gzip')]),
                   wire(pr()).replace(b'application/json', b'text/plain'),
                   wire(pr())[:-1], wire(pr()) + b'X', wire(pr()).replace(b'Content-Length: ', b'Content-Length: +'),
                   wire(body=b'1\r\nx\r\n0\r\n', framing='close', headers=[('Transfer-Encoding', 'chunked')]),
                   wire(body=b'z\r\nx\r\n0\r\n\r\n', framing='close', headers=[('Transfer-Encoding', 'chunked')]),
                   wire(pr(), framing='chunked') + b'X',
                   wire(body=b'0\r\nContent-Type: x\r\n\r\n', framing='close', headers=[('Transfer-Encoding', 'chunked')]),
                   wire(pr(), headers=[('X-Bad', 'x\x01y')]),
                   wire(pr(), headers=[('X-Large', 'x' * 8193)]),
                   wire(pr(), headers=[('X-' + str(i), 'x') for i in range(101)])]
        for index, data in enumerate(invalid):
            with self.subTest(index=index):
                self.assert_result([data], 'refused', 'invalid-http')
        self.assert_result([wire(body=b'x' * (h.BODY_LIMIT + 1))], 'refused', 'invalid-http', chunk=65536)

    def test_json(self):
        for body in [b'{"id":1,"id":2}', b'NaN', b'Infinity', b'1e999', b'"\\ud800"',
                     b'\xff', b'{}{}', b'[' * 33 + b'0' + b']' * 33, b'{']:
            self.assert_result([wire(body=body)], 'refused', 'invalid-json')
        self.assertEqual(m.decode(b'9007199254740993'), 9007199254740993)
        self.assertEqual(m.decode(b'[' * 32 + b'0' + b']' * 32)[0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0][0], 0)

    def test_close_failure_preserves_first(self):
        result, _, _, _ = collect([wire(pr())], close_error=True)
        self.assertEqual(result['reason_id'], m.PREFIX + 'close-failed')
        result, _, _, _ = collect([wire(status=403)], close_error=True)
        self.assertEqual(result['reason_id'], m.PREFIX + 'provider-unavailable')
        self.assertEqual(result['cleanup_errors'], ['close-failed'])

    def test_remaining_resource_bounds(self):
        many_headers = [('X-' + str(i), 'x' * 8000) for i in range(5)]
        self.assert_result([wire(pr(), headers=many_headers)], 'refused', 'invalid-http')
        connection = BytesConnection(wire(body=b'x' * 101), chunk=1)
        with self.assertRaises(m.Failure):
            h.Reader(connection, time.monotonic() + 2, lambda: False).response(100)
        with self.assertRaises(m.Failure):
            m.encode({'payload': 'x' * m.MAX_RECORD})
        with self.assertRaises(m.Failure):
            h.remaining(time.monotonic() - 1)
        with self.assertRaises(m.Failure):
            h.request_bytes('/repos/a/b/pulls/1?url=elsewhere')
        result, _ = self.assert_result([wire(pr()), wire([file_value()] * 101)], 'refused')
        self.assertEqual(result['counters']['requests_started'], 2)

    def test_request_validation(self):
        self.assertEqual(m.validate_request(request()), request())
        cases = []
        for key, value in [('owner', '../x'), ('owner', 'a-'), ('repo', 'a.git'), ('repo', 'a?x'),
                           ('pull_number', '01'), ('pull_number', '1e2'), ('pull_number', True),
                           ('authentication', 'token'), ('url', 'https://evil.invalid')]:
            item = request()
            item[key] = value
            cases.append(item)
        item = request()
        item['bindings']['expected_head']['hash_algorithm'] = 'sha256'
        cases.append(item)
        item = request()
        item['bindings']['expected_head']['repository_id'] = 'another'
        cases.append(item)
        for item in cases:
            with self.assertRaises(m.Failure) as raised:
                m.validate_request(item)
            self.assertEqual(raised.exception.reason, m.PREFIX + 'invalid-input')


class NativeConstructor(unittest.TestCase):
    def test_default_factory_and_checked_tls(self):
        import ssl
        calls = []
        class Sock:
            def settimeout(self, value):
                self.timeout = value
            def connect(self, address):
                calls.append(('connect', address))
            def do_handshake(self):
                calls.append(('handshake',))
            def close(self):
                calls.append(('close',))
        sock = Sock()
        class Context:
            def __init__(self, protocol):
                calls.append(('protocol', protocol))
            def load_default_certs(self, purpose):
                calls.append(('roots', purpose))
            def get_ca_certs(self):
                return [object()]
            def wrap_socket(self, owned, **kwargs):
                self.flags = (self.check_hostname, self.verify_mode, self.minimum_version)
                calls.append(('wrap', kwargs, self.flags))
                return owned
        address = (socket.AF_INET, socket.SOCK_STREAM, 6, '', ('140.82.112.5', 443))
        with patch.object(socket, 'getaddrinfo', return_value=[address]) as resolver, \
                patch.object(socket, 'socket', return_value=sock), patch.object(ssl, 'SSLContext', Context):
            self.assertIs(h.native_connection(time.monotonic() + 5), sock)
            resolver.assert_called_once_with('api.github.com', 443, type=socket.SOCK_STREAM)
        wrap = next(item for item in calls if item[0] == 'wrap')
        self.assertEqual(wrap[1], {'server_hostname': 'api.github.com', 'do_handshake_on_connect': False})
        self.assertEqual(wrap[2], (True, ssl.CERT_REQUIRED, ssl.TLSVersion.TLSv1_2))
        self.assertIs(h.exchange.__globals__['native_connection'], h.native_connection)

    def test_expired_native_construction_still_closes(self):
        import ssl
        now = [1.0]
        closed = []
        class Sock:
            def settimeout(self, value):
                assert value > 0
            def connect(self, address):
                now[0] = 7.0
                raise m.Failure('unavailable', 'request-timeout')
            def close(self):
                closed.append(True)
        class Context:
            def __init__(self, *_):
                pass
            def load_default_certs(self, *_):
                pass
            def get_ca_certs(self):
                return [1]
        address = (socket.AF_INET, socket.SOCK_STREAM, 6, '', ('140.82.112.5', 443))
        with patch.object(ssl, 'SSLContext', Context), patch.object(socket, 'getaddrinfo', return_value=[address]), \
                patch.object(socket, 'socket', return_value=Sock()), patch.object(h.time, 'monotonic', side_effect=lambda: now[0]):
            with self.assertRaises(m.Failure) as raised:
                h.native_connection(6.0)
        self.assertEqual(raised.exception.reason, m.PREFIX + 'request-timeout')
        self.assertEqual(closed, [True])

    def test_forbidden_addresses(self):
        import ssl
        class Context:
            def __init__(self, *_):
                pass
            def load_default_certs(self, *_):
                pass
            def get_ca_certs(self):
                return [1]
        for host in ['127.0.0.1', '10.0.0.1', '169.254.1.1', '224.0.0.1', '0.0.0.0',
                     '::1', '::ffff:127.0.0.1', 'fe80::1', 'ff02::1', '2606:50c0::1%en0']:
            family = socket.AF_INET6 if ':' in host else socket.AF_INET
            address = (host, 443, 0, 0) if family == socket.AF_INET6 else (host, 443)
            with patch.object(ssl, 'SSLContext', Context), patch.object(socket, 'getaddrinfo',
                    return_value=[(family, socket.SOCK_STREAM, 6, '', address)]):
                with self.assertRaises(m.Failure) as raised:
                    h.native_connection(time.monotonic() + 5)
                self.assertEqual(raised.exception.reason, m.PREFIX + 'forbidden-destination')


class OwnedWorker(unittest.TestCase):
    def owner(self, responses=None, req=None, seconds=10):
        owner = c._Owner()
        with patch.object(h, 'native_connection', Script(responses or sequence())):
            result = owner.run(req or request(), time.monotonic() + seconds)
        self.assertEqual(owner.phase, 'reaped')
        self.assertIsNone(owner.pid)
        self.assertTrue(owner.eof)
        return result, owner

    def test_real_wait_same_repo_and_fork(self):
        result, owner = self.owner()
        self.assertEqual(result['outcome'], 'collected')
        self.assertEqual(owner.status, 0)
        self.assertEqual(owner.frames.ordinal, 3)
        item = pr()
        item['head']['repo']['id'] = 22
        req = request()
        req['expected_head_repository_id'] = '22'
        result, _ = self.owner(sequence(item), req)
        self.assertEqual(result['outcome'], 'collected')
        record = m.record(req, '2020-01-01T00:00:00Z', m.utc_now(), 1, result, 'reaped', [])
        self.assertEqual(record['target']['value']['canonical_head']['state'], 'unavailable')
        self.assertEqual(record['authority'], 'none')
        self.assertEqual(record['effects'], [])
        self.assertNotIn('snapshot', record['normalizer'])

    def test_actual_five_second_request_timeout(self):
        owner = c._Owner()
        def blocked(_deadline):
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(60)
        started = time.monotonic()
        with patch.object(h, 'native_connection', blocked):
            result = owner.run(request(), started + 20)
        elapsed = time.monotonic() - started
        self.assertGreaterEqual(elapsed, 5)
        self.assertLess(elapsed, 8)
        self.assertEqual(result['reason_id'], m.PREFIX + 'request-timeout')
        self.assertEqual(owner.phase, 'reaped')
        self.assertEqual(os.WTERMSIG(owner.status), signal.SIGKILL)

    def test_actual_thirty_second_attempt_stall(self):
        owner = c._Owner()
        original = c._worker
        def stalled(_request, _events, _admission, _deadline, mask):
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)
            time.sleep(60)
            os._exit(65)
        started = time.monotonic()
        with patch.object(c, '_worker', stalled):
            result = owner.run(request(), started + 30)
        self.assertGreaterEqual(time.monotonic() - started, 30)
        self.assertLess(time.monotonic() - started, 33)
        self.assertEqual(result['reason_id'], m.PREFIX + 'attempt-timeout')
        self.assertEqual(owner.phase, 'reaped')
        self.assertIs(c._worker, original)

    def test_cancellation_checkpoints(self):
        for checkpoint in ('lookup', 'connect', 'headers', 'body', 'page-transition'):
            owner = c._Owner()
            parent = os.getpid()
            calls = [0]
            def factory(deadline):
                calls[0] += 1
                ordinal = calls[0]
                if checkpoint == 'lookup' or checkpoint == 'page-transition' and ordinal == 2:
                    os.kill(parent, signal.SIGTERM)
                    time.sleep(60)
                class Held(BytesConnection):
                    def sendall(self, data):
                        super().sendall(data)
                        if checkpoint == 'connect':
                            os.kill(parent, signal.SIGTERM)
                            time.sleep(60)
                    def recv(self, count):
                        if checkpoint in ('headers', 'body'):
                            if checkpoint == 'headers' or self.consumed >= self.header_end:
                                os.kill(parent, signal.SIGTERM)
                                time.sleep(60)
                        return super().recv(count)
                return Held(wire(pr()) if ordinal != 2 else wire([file_value()]), chunk=1)
            c._CANCELLED = False
            previous = signal.signal(signal.SIGTERM, c._cancel)
            try:
                with patch.object(h, 'native_connection', factory):
                    result = owner.run(request(), time.monotonic() + 4)
                self.assertEqual(result['reason_id'], m.PREFIX + 'cancelled', checkpoint)
                self.assertEqual(owner.phase, 'reaped')
            finally:
                signal.signal(signal.SIGTERM, previous)
                c._CANCELLED = False

    def test_frames_and_early_exit(self):
        invalid = [b'', b'B\x02', b'Q', b'B', b'E\x01', b'R' + (m.MAX_RECORD + 1).to_bytes(8, 'big'),
                   b'R' + (2).to_bytes(8, 'big') + b'{}', b'B\x01B\x02']
        for data in invalid:
            def wrong(_request, events, _admission, deadline, mask):
                signal.pthread_sigmask(signal.SIG_SETMASK, mask)
                os.write(events, data)
                os._exit(0)
            with patch.object(c, '_worker', wrong):
                owner = c._Owner()
                result = owner.run(request(), time.monotonic() + 2)
            self.assertEqual(result['outcome'], 'refused')
            self.assertEqual(owner.phase, 'reaped')

    def test_real_worker_close_failure(self):
        owner = c._Owner()
        with patch.object(h, 'native_connection', Script([wire(pr())], close_error=True)):
            result = owner.run(request(), time.monotonic() + 3)
        self.assertEqual(result['reason_id'], m.PREFIX + 'close-failed')
        self.assertEqual(owner.phase, 'reaped')
        self.assertEqual(owner.status, 0)

    def test_real_wait_observer_failure(self):
        owner = c._Owner()
        actual_wait = os.waitpid
        reaped = []
        def observer(pid, flags):
            result = actual_wait(pid, flags)
            if result[0] == pid:
                reaped.append(result)
                raise ChildProcessError('fixture observer failure after actual direct wait')
            return result
        with patch.object(h, 'native_connection', Script(sequence())), patch.object(os, 'waitpid', observer):
            result = owner.run(request(), time.monotonic() + 3)
        self.assertEqual(len(reaped), 1)
        self.assertEqual(owner.phase, 'unconfirmed')
        self.assertEqual(result['reason_id'], m.PREFIX + 'worker-ownership-lost')

    def test_wait_authority_lost(self):
        owner = c._Owner()
        owner.pid = 123
        owner.phase = 'owned'
        with patch.object(os, 'waitpid', side_effect=ChildProcessError()), patch.object(os, 'kill') as kill:
            with self.assertRaises(m.Failure):
                owner.wait()
            owner.stop()
            kill.assert_not_called()
        self.assertEqual(owner.phase, 'unconfirmed')
        owner = c._Owner()
        owner.pid = 123
        owner.phase = 'owned'
        with patch.object(os, 'waitpid', return_value=(456, 0)), patch.object(os, 'kill') as kill:
            with self.assertRaises(m.Failure):
                owner.wait()
            owner.stop()
            kill.assert_not_called()

    def test_deep_final_frame_validation(self):
        result, _, _, _ = collect(sequence())
        self.assertEqual(m.validate_worker(copy.deepcopy(result), request()), result)
        mutations = [
            lambda value: value['counters'].update(body_bytes=8 * 1024 * 1024 + 1),
            lambda value: value['target']['value'].update(repository_full_name='untrusted/provider'),
            lambda value: value['target']['value'].update(change_request_id=True),
            lambda value: value['target']['value'].update(mergeable={'state': 'observed', 'value': 'raw'}),
            lambda value: value['files']['value'][0].update(path='../unsafe'),
            lambda value: value['files']['value'][0]['patch']['value'].update(byte_length=True),
            lambda value: value['files']['value'][0]['patch']['value'].update(observed_patch_sha256='raw'),
            lambda value: value['files']['value'].append(value['files']['value'][0]),
            lambda value: value['counters'].update(responses_read=2),
        ]
        for mutate in mutations:
            candidate = copy.deepcopy(result)
            mutate(candidate)
            with self.assertRaises(m.Failure) as raised:
                m.validate_worker(candidate, request())
            self.assertEqual(raised.exception.reason, m.PREFIX + 'ipc-invalid')
        accepted = m.worker_result('refused', 'invalid-http')
        accepted['counters']['body_bytes'] = 8 * 1024 * 1024
        self.assertEqual(m.validate_worker(accepted, request()), accepted)

    def test_no_signal_after_wait(self):
        owner = c._Owner()
        owner.pid = 123
        owner.phase = 'owned'
        with patch.object(os, 'waitpid', return_value=(123, 0)), patch.object(os, 'kill') as kill:
            owner.wait()
            owner.stop()
            kill.assert_not_called()
        self.assertIsNone(owner.pid)


class EntryControls(unittest.TestCase):
    def child(self, code, data=b'', flags=('-I', '-S', '-B'), timeout=8):
        environment = dict(_INITIAL_ENV)
        environment.update({key: 'COLLECTOR_SENTINEL_NEVER_READ' for key in
                            ['GH_TOKEN', 'GITHUB_TOKEN', 'HTTPS_PROXY', 'SSL_CERT_FILE',
                             'SSL_CERT_DIR', 'SSLKEYLOGFILE', 'OPENSSL_CONF', 'HOME', 'PYTHONPATH']})
        with tempfile.TemporaryDirectory(prefix='collector-startup-config-') as owned:
            config = os.path.join(owned, 'COLLECTOR_SENTINEL_OPENSSL_CONF')
            with open(config, 'w', encoding='ascii') as stream:
                stream.write('openssl_conf = fixture_init\n[fixture_init]\n')
            environment['OPENSSL_CONF'] = config
            environment['SSLKEYLOGFILE'] = os.path.join(owned, 'COLLECTOR_SENTINEL_KEYLOG')
            return subprocess.run([sys.executable, *flags, '-c', code], input=data,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  env=environment, timeout=timeout, check=False)

    def load(self):
        return ('import sys,os,importlib.util; '
                f's=importlib.util.spec_from_file_location("entry",{ENTRY!r}); '
                'e=importlib.util.module_from_spec(s); s.loader.exec_module(e); ')

    def test_public_invalid_and_app_bound(self):
        for data, reason in [(b'{}', 'invalid-input'), (b'x' * 16385, 'invalid-input'),
                             (m.encode(dict(request(), authentication='app-bound')), 'credential-binding-unavailable')]:
            result = self.child(self.load() + 'sys.exit(e.main())', data)
            self.assertEqual(result.returncode, 65)
            self.assertFalse(result.stderr)
            value = json.loads(result.stdout)
            self.assertEqual(value['reason_id'], m.PREFIX + reason)
            self.assertEqual(value['evidence']['worker_retirement'], 'not-started')
            self.assertNotIn(b'COLLECTOR_SENTINEL', result.stdout)

    def test_preloaded_crypto_and_site(self):
        for prelude in ['import hashlib; ', 'import types; sys.modules["sitecustomize"]=types.ModuleType("sitecustomize"); ']:
            result = self.child('import sys; ' + prelude + self.load() + 'sys.exit(e.main())', m.encode(request()))
            self.assertEqual(result.returncode, 65)
            self.assertEqual(json.loads(result.stdout)['reason_id'], m.PREFIX + 'unsupported-runtime')
        for flags in [('-I', '-S'), ('-S', '-B')]:
            direct = 'import sys; sys.argv=[' + repr(ENTRY) + ']; exec(compile(open(' + repr(ENTRY) + ',"rb").read(),' + repr(ENTRY) + ',"exec"),{"__name__":"__main__","__file__":' + repr(ENTRY) + '})'
            result = self.child(direct, m.encode(request()), flags)
            self.assertEqual(result.returncode, 65)
            self.assertEqual(json.loads(result.stdout)['reason_id'], m.PREFIX + 'unsupported-runtime')

    def test_startup_order_and_real_public_io(self):
        code = f'''
import sys,os,importlib.util
seen=[]
def audit(event,args):
    if event == 'import' and args[0] in ('_ssl','ssl','hashlib','_hashlib','_collector_model','_collector_http'):
        if os.environ:
            raise AssertionError('environment precedes import')
        seen.append((args[0],os.getpid()))
    if event in ('socket.__new__','socket.getaddrinfo'):
        raise AssertionError('native network forbidden')
    if event == 'open' and isinstance(args[0],str) and 'COLLECTOR_SENTINEL' in args[0]:
        raise AssertionError('sentinel file discovery')
sys.addaudithook(audit)
s=importlib.util.spec_from_file_location('entry',{ENTRY!r})
e=importlib.util.module_from_spec(s)
s.loader.exec_module(e)
assert e._SUPPORTED and not os.environ
assert not any(x in sys.modules for x in ('hashlib','_hashlib','ssl','_ssl','sitecustomize','usercustomize','site'))
responses={sequence()!r}
class Connection:
    def __init__(self,data): self.data=bytearray(data)
    def settimeout(self,value): assert value>0
    def sendall(self,data): assert data.startswith(b'GET /repos/Fixture/sample/pulls/7')
    def recv(self,count):
        chunk=bytes(self.data[:min(count,7)]); del self.data[:len(chunk)]; return chunk
    def close(self): pass
def factory(deadline):
    assert os.getpid()!=parent and not os.environ
    return Connection(responses.pop(0))
parent=os.getpid()
e.http.native_connection=factory
sys.exit(e.main())
'''
        result = self.child(code, m.encode(request()))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(value['evidence']['worker_retirement'], 'reaped')
        self.assertEqual(value['outcome'], 'collected')
        self.assertEqual(value['normalizer']['state'], 'unavailable')
        self.assertEqual(set(value), {'schema_version', 'kind', 'adapter', 'outcome', 'reason_id',
                                     'request_binding', 'observation_window', 'target', 'files',
                                     'evidence', 'normalizer', 'authority', 'qualification', 'effects'})
        jq = _INITIAL_ENV.get('COLLECTOR_TEST_JQ')
        if jq:
            command = [jq, '-f', os.path.join(ROOT, 'adapters/github-forge/v1/normalize.jq')]
            if sys.platform == 'darwin' and os.uname().machine == 'arm64':
                command = ['/usr/bin/arch', '-x86_64'] + command
            rejected = subprocess.run(command, input=result.stdout, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, timeout=5, check=False)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn(b'github-forge.invalid-envelope', rejected.stderr)
        else:
            self.fail('pinned test-only jq path required for normalizer integration')

    def test_real_signal_during_blocked_output(self):
        read_fd, write_fd = os.pipe()
        os.set_blocking(write_fd, False)
        try:
            while True:
                os.write(write_fd, b'x' * 65536)
        except BlockingIOError:
            pass
        ready_read, ready_write = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(ready_read)
            signal.signal(signal.SIGTERM, c._cancel)
            c._CANCELLED = False
            os.write(ready_write, b'R')
            try:
                c._write(write_fd, b'final', time.monotonic() + 3)
            except m.Failure:
                os._exit(65)
            os._exit(0)
        try:
            os.close(ready_write)
            self.assertEqual(os.read(ready_read, 1), b'R')
            os.kill(pid, signal.SIGTERM)
            returned, status = os.waitpid(pid, 0)
            self.assertEqual(returned, pid)
            self.assertEqual(os.WEXITSTATUS(status), 65)
        finally:
            os.close(ready_read)
            os.close(read_fd)
            os.close(write_fd)

    def test_output_backpressure(self):
        read_fd, write_fd = os.pipe()
        os.set_blocking(write_fd, False)
        try:
            while True:
                os.write(write_fd, b'x' * 65536)
        except BlockingIOError:
            pass
        started = time.monotonic()
        try:
            with self.assertRaises(m.Failure):
                c._write(write_fd, b'final', started + 0.05)
            self.assertLess(time.monotonic() - started, 1)
        finally:
            os.close(read_fd)
            os.close(write_fd)


if __name__ == '__main__':
    print('interpreter=' + sys.executable + ' version=' + sys.version.split()[0] + ' flags=-I -S -B', flush=True)
    unittest.main(verbosity=2, failfast=True)
