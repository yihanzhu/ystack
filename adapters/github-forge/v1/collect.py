"""Inactive, anonymous-only bounded GitHub change-request collector."""
import sys
import os


def _bootstrap():
    unsupported = (sys.implementation.name != 'cpython' or sys.version_info < (3, 11)
                   or os.name != 'posix' or not (sys.platform.startswith('linux') or sys.platform == 'darwin')
                   or not sys.flags.isolated
                   or not sys.flags.no_site or not sys.flags.dont_write_bytecode
                   or any(name in sys.modules for name in
                          ('site', 'sitecustomize', 'usercustomize', 'ssl', '_ssl', 'hashlib', '_hashlib')))
    os.environ.clear()
    sys.dont_write_bytecode = True
    return not unsupported


_SUPPORTED = _bootstrap()

import errno
import fcntl
import importlib.util
import select
import signal
import time


def _adjacent(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + '.py')
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


model = _adjacent('_collector_model')
http = _adjacent('_collector_http')
_CANCELLED = False


def _cancel(_number, _frame):
    global _CANCELLED
    _CANCELLED = True


def _check(deadline, request=False):
    if _CANCELLED:
        model.fail('cancelled', 'unavailable')
    if time.monotonic() >= deadline:
        model.fail('request-timeout' if request else 'attempt-timeout', 'unavailable')


def _poll(fd, write, deadline, cancellation=True):
    poller = select.poll()
    poller.register(fd, select.POLLOUT if write else select.POLLIN)
    while True:
        if cancellation:
            _check(deadline)
        seconds = deadline - time.monotonic()
        if seconds <= 0:
            model.fail('attempt-timeout', 'unavailable')
        ready = poller.poll(max(1, min(50, int(seconds * 1000))))
        if ready:
            return


def _write(fd, data, deadline, cancellation=True):
    offset = 0
    while offset < len(data):
        _poll(fd, True, deadline, cancellation)
        try:
            count = os.write(fd, data[offset:offset + 65536])
        except BlockingIOError:
            continue
        if count <= 0:
            model.fail('output-failed')
        offset += count


def _read_exact(fd, size, deadline):
    result = bytearray()
    while len(result) < size:
        _poll(fd, False, deadline)
        try:
            data = os.read(fd, size - len(result))
        except BlockingIOError:
            continue
        if not data:
            model.fail('ipc-invalid')
        result.extend(data)
    return bytes(result)


def _close_except(keep):
    directory = '/proc/self/fd' if sys.platform.startswith('linux') else '/dev/fd'
    directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        descriptors = [int(name) for name in os.listdir(directory_fd) if name.isdecimal()]
        for fd in descriptors:
            if fd not in keep and fd != directory_fd:
                try:
                    os.fstat(fd)
                except OSError as error:
                    if error.errno == errno.EBADF:
                        continue
                    raise
                os.close(fd)
    finally:
        os.close(directory_fd)


def _worker(request, events, admission, deadline, old_mask):
    global _CANCELLED
    _CANCELLED = False
    try:
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, _cancel)
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        _close_except({events, admission})
        os.environ.clear()
        os.set_blocking(events, False)
        os.set_blocking(admission, False)
        def begin(ordinal):
            _check(deadline)
            _write(events, b'B' + bytes([ordinal]), deadline)
            reply = _read_exact(admission, 9, deadline)
            request_deadline = int.from_bytes(reply[1:], 'big') / 1_000_000_000
            if reply[0] != ordinal or request_deadline > deadline or request_deadline <= time.monotonic():
                model.fail('ipc-invalid')
            return request_deadline
        def end(ordinal):
            _write(events, b'E' + bytes([ordinal]), deadline)
        result = http.collect(request, begin, end, lambda: _CANCELLED)
        payload = model.encode(result)
        _write(events, b'R' + len(payload).to_bytes(8, 'big') + payload, deadline)
        os.close(events)
        os.close(admission)
        os._exit(0)
    except BaseException:
        os._exit(65)


class _Frames:
    def __init__(self, request):
        self.request = request
        self.buffer = bytearray()
        self.ordinal = 0
        self.active = None
        self.result = None
        self.request_deadline = None

    def feed(self, data, admission, deadline):
        self.buffer.extend(data)
        if len(self.buffer) > model.MAX_RECORD + 9:
            model.fail('ipc-invalid')
        while self.buffer:
            tag = self.buffer[0]
            if self.result is not None:
                model.fail('ipc-invalid')
            if tag in (ord('B'), ord('E')):
                if len(self.buffer) < 2:
                    return
                ordinal = self.buffer[1]
                del self.buffer[:2]
                if tag == ord('B'):
                    if self.active is not None or ordinal != self.ordinal + 1 or ordinal > 5:
                        model.fail('ipc-invalid')
                    _check(deadline)
                    self.ordinal = self.active = ordinal
                    self.request_deadline = min(deadline, time.monotonic() + 5)
                    reply = bytes([ordinal]) + int(self.request_deadline * 1_000_000_000).to_bytes(8, 'big')
                    _write(admission, reply, self.request_deadline)
                else:
                    if ordinal != self.active:
                        model.fail('ipc-invalid')
                    self.active = self.request_deadline = None
            elif tag == ord('R'):
                if len(self.buffer) < 9:
                    return
                size = int.from_bytes(self.buffer[1:9], 'big')
                if size > model.MAX_RECORD or size == 0:
                    model.fail('ipc-invalid')
                if len(self.buffer) < 9 + size:
                    return
                try:
                    self.result = model.validate_worker(model.decode(bytes(self.buffer[9:9 + size])), self.request)
                except model.Failure:
                    model.fail('ipc-invalid')
                del self.buffer[:9 + size]
                if (self.result['counters']['requests_started'] != self.ordinal
                        or self.result['outcome'] == 'collected' and self.active is not None):
                    model.fail('ipc-invalid')
            else:
                model.fail('ipc-invalid')


# Blocking resolver containment: work/github-change-request-collector/plan.md section 3.
class _Owner:
    def __init__(self):
        self.pid = None
        self.phase = 'not-started'
        self.status = None
        self.cleanup = []
        self.events = self.admission = None
        self.frames = None
        self.eof = False

    def wait(self):
        if self.phase not in ('owned', 'stopping'):
            return
        try:
            returned, status = os.waitpid(self.pid, os.WNOHANG)
        except OSError:
            self.phase = 'unconfirmed'
            self.cleanup.append('wait-failed')
            model.fail('worker-ownership-lost')
        if returned == 0:
            return
        if returned != self.pid:
            self.phase = 'unconfirmed'
            self.cleanup.append('wait-invalid')
            model.fail('worker-ownership-lost')
        self.phase = 'reaped'
        self.status = status
        self.pid = None

    def drain(self, deadline, parse=True):
        if self.events is None or self.eof:
            return
        try:
            data = os.read(self.events, 65536)
        except BlockingIOError:
            return
        except OSError:
            self.cleanup.append('read-failed')
            model.fail('ipc-invalid')
        if not data:
            self.eof = True
        elif parse:
            self.frames.feed(data, self.admission, deadline)

    def stop(self):
        if self.phase not in ('owned', 'stopping'):
            return
        self.phase = 'stopping'
        started = time.monotonic()
        limit = started + 2
        sent_kill = False
        def send(number):
            if self.phase not in ('owned', 'stopping'):
                return
            try:
                os.kill(self.pid, number)
            except OSError:
                self.cleanup.append('signal-failed')
        send(signal.SIGTERM)
        while self.phase == 'stopping' and time.monotonic() < limit:
            try:
                self.wait()
            except model.Failure:
                break
            if self.phase != 'stopping':
                break
            if not sent_kill and time.monotonic() >= started + 1:
                send(signal.SIGKILL)
                sent_kill = True
            try:
                self.drain(limit, parse=False)
            except model.Failure:
                pass
            try:
                select.select([], [], [], min(0.01, max(0, limit - time.monotonic())))
            except OSError:
                self.cleanup.append('poll-failed')
        if self.phase == 'stopping':
            self.phase = 'unconfirmed'
            self.pid = None
            self.cleanup.append('wait-unconfirmed')

    def close(self):
        for name in ('events', 'admission'):
            fd = getattr(self, name)
            if fd is not None:
                setattr(self, name, None)
                try:
                    os.close(fd)
                except OSError:
                    self.cleanup.append('close-failed')

    def run(self, request, deadline):
        self.frames = _Frames(request)
        event_read = event_write = admit_read = admit_write = None
        first = None
        try:
            event_read, event_write = os.pipe()
            admit_read, admit_write = os.pipe()
            signal.signal(signal.SIGCHLD, signal.SIG_DFL)
            blocked = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
            old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
            try:
                child = os.fork()
                if child == 0:
                    _worker(request, event_write, admit_read, deadline, old_mask)
                    os._exit(65)
                self.pid = child
                self.phase = 'owned'
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
            self.events, self.admission = event_read, admit_write
            event_read = admit_write = None
            os.close(event_write)
            event_write = None
            os.close(admit_read)
            admit_read = None
            os.set_blocking(self.events, False)
            os.set_blocking(self.admission, False)
            while True:
                _check(deadline)
                if self.frames.request_deadline is not None:
                    _check(self.frames.request_deadline, request=True)
                self.wait()
                self.drain(deadline)
                if self.eof and self.phase == 'reaped':
                    break
                if self.phase == 'reaped' and not self.eof:
                    self.drain(deadline)
                select.select([], [], [], 0.001)
            if self.status != 0 or self.frames.result is None or self.frames.buffer:
                model.fail('worker-failed' if self.status != 0 else 'ipc-invalid')
            return self.frames.result
        except model.Failure as error:
            first = error
        except (OSError, ValueError):
            first = model.Failure('refused', 'worker-failed')
        finally:
            self.stop()
            self.close()
            for fd in (event_read, event_write, admit_read, admit_write):
                if fd is not None:
                    try:
                        os.close(fd)
                    except OSError:
                        self.cleanup.append('close-failed')
        if self.phase == 'unconfirmed':
            if first is None:
                first = model.Failure('refused', 'worker-ownership-lost')
        if first is not None:
            return model.worker_result(first.outcome, first.reason.removeprefix('github.collect.'))
        return model.worker_result('refused', 'worker-failed')


def _input(deadline):
    data = bytearray()
    while True:
        _poll(0, False, deadline)
        try:
            chunk = os.read(0, min(4096, 16385 - len(data)))
        except BlockingIOError:
            continue
        if not chunk:
            break
        data.extend(chunk)
        if len(data) > 16384:
            model.fail('invalid-input')
    try:
        return model.validate_request(model.decode(bytes(data)))
    except model.Failure:
        model.fail('invalid-input')


def main():
    global _CANCELLED
    _CANCELLED = False
    started_mono = time.monotonic()
    deadline = started_mono + 30
    started = model.utc_now()
    request = None
    owner = _Owner()
    flags = {}
    handlers = {}
    result = None
    try:
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            handlers[number] = signal.signal(number, _cancel)
        for fd in (0, 1):
            flags[fd] = fcntl.fcntl(fd, fcntl.F_GETFL)
            fcntl.fcntl(fd, fcntl.F_SETFL, flags[fd] | os.O_NONBLOCK)
        if not _SUPPORTED or len(sys.argv) != 1:
            model.fail('unsupported-runtime')
        request = _input(deadline)
        if request['authentication'] == 'app-bound':
            model.fail('credential-binding-unavailable', 'unavailable')
        result = owner.run(request, deadline)
        if owner.cleanup and result['outcome'] == 'collected':
            result = model.worker_result('refused', 'close-failed')
    except model.Failure as error:
        result = model.worker_result(error.outcome, error.reason.removeprefix('github.collect.'))
    except (OSError, ValueError):
        result = model.worker_result('refused', 'output-failed')
    try:
        if _CANCELLED and result['outcome'] == 'collected':
            result = model.worker_result('unavailable', 'cancelled')
        output = model.record(request, started, model.utc_now(), time.monotonic() - started_mono,
                              result, owner.phase, owner.cleanup)
        payload = model.encode(output) + b'\n'
        _write(1, payload, deadline if result['outcome'] == 'collected' else deadline + 2,
               cancellation=result['outcome'] == 'collected')
        status = 0 if result['outcome'] == 'collected' else 65
    except (model.Failure, OSError, ValueError):
        status = 65
    finally:
        for fd, flag in flags.items():
            try:
                fcntl.fcntl(fd, fcntl.F_SETFL, flag)
            except OSError:
                status = 65
        for number, handler in handlers.items():
            signal.signal(number, handler)
    return status


if __name__ == '__main__':
    sys.exit(main())
