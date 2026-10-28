"""Fixed-origin HTTP/1 reader; native construction is private to the worker."""
import ipaddress
import re
import socket
import time
from _collector_model import Failure, fail, decode, target, file_observation, worker_result, utc_now

BODY_LIMIT = 2 * 1024 * 1024
HEADER_LIMIT = 32768


def remaining(deadline):
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        fail('request-timeout', 'unavailable')
    return seconds


def native_connection(deadline):
    import ssl
    owned = None
    first = None
    try:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = True
        context.verify_mode = ssl.CERT_REQUIRED
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        try:
            context.load_default_certs(ssl.Purpose.SERVER_AUTH)
            if not context.get_ca_certs():
                fail('trust-store-unavailable', 'unavailable')
        except (OSError, ssl.SSLError):
            fail('trust-store-unavailable', 'unavailable')
        remaining(deadline)
        addresses = socket.getaddrinfo('api.github.com', 443, type=socket.SOCK_STREAM)
        if not addresses:
            fail('network-failed', 'unavailable')
        selected = None
        for family, socktype, protocol, _, address in addresses:
            raw = address[0]
            if '%' in raw or (family == socket.AF_INET6 and (len(address) < 4 or address[3] != 0)):
                fail('forbidden-destination')
            ip = ipaddress.ip_address(raw)
            ip = ip.ipv4_mapped if getattr(ip, 'ipv4_mapped', None) else ip
            if not ip.is_global or ip.is_multicast or ip.is_unspecified:
                fail('forbidden-destination')
            if family not in (socket.AF_INET, socket.AF_INET6) or address[1] != 443:
                fail('forbidden-destination')
            if selected is None:
                selected = (family, socktype, protocol, address)
        family, socktype, protocol, address = selected
        owned = socket.socket(family, socktype, protocol)
        owned.settimeout(remaining(deadline))
        owned.connect(address)
        wrapped = context.wrap_socket(owned, server_hostname='api.github.com', do_handshake_on_connect=False)
        owned = wrapped
        owned.settimeout(remaining(deadline))
        owned.do_handshake()
        return owned
    except ssl.SSLCertVerificationError:
        first = Failure('refused', 'tls-verification-failed')
    except Failure as error:
        first = error
    except (OSError, ValueError, ssl.SSLError):
        first = Failure('unavailable', 'network-failed')
    finally:
        if first is not None and owned is not None:
            try:
                owned.close()
            except (OSError, Failure):
                first.cleanup.append('close-failed')
    raise first


def request_bytes(route):
    if not re.fullmatch(r'/repos/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/pulls/[1-9][0-9]{0,19}(?:/files\?per_page=100&page=[1-3])?', route):
        fail('invalid-input')
    return ('GET ' + route + ' HTTP/1.1\r\nHost: api.github.com\r\n'
            'Connection: close\r\nUser-Agent: ystack-github-collector/1\r\n'
            'Accept: application/vnd.github+json\r\nX-GitHub-Api-Version: 2026-03-10\r\n'
            'Accept-Encoding: identity\r\n\r\n').encode('ascii')


class Reader:
    def __init__(self, connection, deadline, cancelled):
        self.connection = connection
        self.deadline = deadline
        self.cancelled = cancelled
        self.buffer = bytearray()
        self.header_bytes = 0
        self.header_fields = 0

    def receive(self, count):
        if self.cancelled():
            fail('cancelled', 'unavailable')
        self.connection.settimeout(remaining(self.deadline))
        data = self.connection.recv(count)
        if type(data) is not bytes or len(data) > count:
            fail('invalid-http')
        return data

    def line(self):
        while b'\r\n' not in self.buffer:
            if len(self.buffer) > 8192:
                fail('invalid-http')
            chunk = self.receive(min(4096, 8195 - len(self.buffer)))
            if not chunk:
                fail('invalid-http')
            self.buffer.extend(chunk)
        index = self.buffer.index(b'\r\n')
        line = bytes(self.buffer[:index])
        del self.buffer[:index + 2]
        self.header_bytes += index + 2
        if len(line) > 8192 or self.header_bytes > HEADER_LIMIT:
            fail('invalid-http')
        return line

    def exact(self, count):
        result = bytearray()
        while len(result) < count:
            if self.buffer:
                amount = min(count - len(result), len(self.buffer))
                result.extend(self.buffer[:amount])
                del self.buffer[:amount]
            else:
                chunk = self.receive(min(65536, count - len(result)))
                if not chunk:
                    fail('invalid-http')
                result.extend(chunk)
        return bytes(result)

    def headers(self, trailers=False):
        result = {}
        while True:
            line = self.line()
            if not line:
                return result
            self.header_fields += 1
            if self.header_fields > 100 or line[:1] in (b' ', b'\t') or b':' not in line:
                fail('invalid-http')
            name, value = line.split(b':', 1)
            if not re.fullmatch(rb"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name):
                fail('invalid-http')
            if any(c < 32 and c != 9 or c == 127 for c in value):
                fail('invalid-http')
            name = name.decode('ascii').lower()
            if name in result or trailers:
                fail('invalid-http')
            result[name] = value.strip(b' \t').decode('latin1')

    def response(self, allowance):
        status_line = self.line()
        match = re.fullmatch(rb'HTTP/1\.[01] ([0-9]{3})(?: [\x20-\x7e]*)?', status_line)
        if match is None:
            fail('invalid-http')
        status = int(match[1])
        headers = self.headers()
        if status != 200:
            if status == 404:
                fail('target-unavailable', 'unavailable')
            if status in (401, 403, 429) or 500 <= status <= 599:
                fail('provider-unavailable', 'unavailable')
            fail('invalid-http')
        media = headers.get('content-type', '').lower()
        if re.fullmatch(r'(?:application/json|application/vnd\.github\+json)(?:\s*;\s*charset\s*=\s*(?:utf-8|"utf-8"))?', media) is None:
            fail('invalid-http')
        if headers.get('content-encoding', 'identity').lower() != 'identity':
            fail('invalid-http')
        length = headers.get('content-length')
        transfer = headers.get('transfer-encoding')
        cap = min(BODY_LIMIT, allowance)
        if cap < 0 or length is not None and transfer is not None:
            fail('invalid-http')
        body = bytearray()
        if length is not None:
            if not re.fullmatch(r'0|[1-9][0-9]*', length) or len(length) > 10:
                fail('invalid-http')
            count = int(length)
            if count > cap:
                self.exact(cap + 1)
                fail('invalid-http')
            body.extend(self.exact(count))
        elif transfer is not None:
            if transfer.lower() != 'chunked':
                fail('invalid-http')
            while True:
                line = self.line()
                if not re.fullmatch(rb'[0-9A-Fa-f]{1,8}', line):
                    fail('invalid-http')
                size = int(line, 16)
                if size == 0:
                    self.headers(trailers=True)
                    break
                if size > cap - len(body):
                    self.exact(cap - len(body) + 1)
                    fail('invalid-http')
                body.extend(self.exact(size))
                if self.exact(2) != b'\r\n':
                    fail('invalid-http')
        else:
            while True:
                if self.buffer:
                    chunk = bytes(self.buffer)
                    self.buffer.clear()
                else:
                    chunk = self.receive(min(65536, cap - len(body) + 1))
                if not chunk:
                    break
                body.extend(chunk)
                if len(body) > cap:
                    fail('invalid-http')
        if self.buffer or (length is not None or transfer is not None) and self.receive(1):
            fail('invalid-http')
        return bytes(body), headers


def exchange(route, deadline, allowance, cancelled):
    connection = None
    first = None
    result = None
    try:
        connection = native_connection(deadline)
        if cancelled():
            fail('cancelled', 'unavailable')
        connection.settimeout(remaining(deadline))
        connection.sendall(request_bytes(route))
        result = Reader(connection, deadline, cancelled).response(allowance)
    except Failure as error:
        first = error
    except (OSError, ValueError):
        first = Failure('unavailable', 'network-failed')
    finally:
        if connection is not None:
            try:
                connection.close()
            except (OSError, ValueError):
                if first is None:
                    first = Failure('refused', 'close-failed')
                first.cleanup.append('close-failed')
    if first is not None:
        raise first
    return result


def links(value, route, page, short):
    if value is None:
        return
    relations = {}
    for item in value.split(','):
        match = re.fullmatch(r'\s*<([^<>]+)>;\s*rel="(next|prev|first|last)"\s*', item)
        if match is None or match[2] in relations:
            fail('invalid-http')
        link, relation = match[1], match[2]
        prefix = 'https://api.github.com' + route + '/files?per_page=100&page='
        if not link.startswith(prefix) or not re.fullmatch('[1-3]', link[len(prefix):]):
            fail('invalid-http')
        number = int(link[len(prefix):])
        if ((relation == 'next' and number != page + 1)
                or (relation == 'prev' and number != page - 1)
                or (relation == 'first' and number != 1)
                or (relation == 'last' and number < page)):
            fail('invalid-http')
        relations[relation] = number
    if ('next' in relations and ('last' in relations and relations['next'] > relations['last'])
            or short and ('next' in relations or relations.get('last', page) > page)):
        fail('continuation-conflict', 'inconclusive')


def collect(request, begin, end, cancelled):
    counters = {'requests_started': 0, 'responses_read': 0, 'body_bytes': 0, 'pages': 0}
    route = '/repos/{owner}/{repo}/pulls/{pull_number}'.format(**request)
    def get(path):
        if cancelled():
            fail('cancelled', 'unavailable')
        ordinal = counters['requests_started'] + 1
        if ordinal > 5:
            fail('page-limit', 'inconclusive')
        deadline = begin(ordinal)
        counters['requests_started'] = ordinal
        data, headers = exchange(path, deadline, 8 * 1024 * 1024 - counters['body_bytes'], cancelled)
        counters['body_bytes'] += len(data)
        counters['responses_read'] += 1
        end(ordinal)
        return decode(data), headers
    try:
        before, _ = get(route)
        mapped = target(before, request, utc_now())
        count = mapped['changed_files']
        if count['state'] == 'observed' and count['value'] > 256:
            fail('file-limit', 'inconclusive')
        files = []
        paths = set()
        for page in range(1, 4):
            values, headers = get(route + '/files?per_page=100&page=' + str(page))
            if type(values) is not list or len(values) > 100:
                fail('invalid-provider-data')
            counters['pages'] += 1
            links(headers.get('link'), route, page, len(values) < 100)
            for value in values:
                item = file_observation(value)
                if item['path'] in paths:
                    fail('duplicate-file', 'inconclusive')
                paths.add(item['path'])
                files.append(item)
                if len(files) > 256:
                    fail('file-limit', 'inconclusive')
            if len(values) < 100:
                break
            if page == 3:
                fail('page-limit', 'inconclusive')
        if count['state'] == 'observed' and count['value'] != len(files):
            fail('count-mismatch', 'inconclusive')
        after, _ = get(route)
        final = target(after, request, utc_now())
        if final != mapped:
            fail('bracket-drift', 'stale')
        files.sort(key=lambda item: item['path'])
        return worker_result(mapped=mapped, files=files, counters=counters)
    except Failure as error:
        return worker_result(error.outcome, error.reason.removeprefix('github.collect.'),
                             counters=counters, cleanup=error.cleanup)
