import errno
import fcntl
import hashlib
import json
import os
import re
import stat
import sys
import zlib

PROTOCOL = "ystack.delivery-ledger.v1"
ROOT_FIELDS = {"protocol", "store_id", "ledger_id"}
INIT_FIELDS = ROOT_FIELDS | {"initialization_id", "recorded_at"}
UPDATE_FIELDS = ROOT_FIELDS | {
    "update_id", "expected_tip", "delivery_key", "action", "recorded_at",
    "delivery_ordinal",
}
KEY_FIELDS = {"stage_key", "request_sha256", "operation", "attempt_number"}
STAGE_FIELDS = {"initiative_id", "workflow_id", "stage_id", "task_class_id"}
ENTRY_FIELDS = {"delivery_key", "state", "delivery_count", "last_delivery_at"}
ID_PATTERN = re.compile(r"[a-z0-9][a-z0-9._:-]{0,127}\Z")
OID_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
TIME_PATTERN = re.compile(r"([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z\Z")
OPERATIONS = {"dispatch-stage", "retry-stage", "recover-stranded-attempt"}
ACTIONS = {"record-delivery", "record-failure", "acknowledge"}
MAX_FILES = 8192
MAX_ENTRIES = 16384
MAX_BYTES = 128 * 1024 * 1024
MAX_RAW = 270336
MAX_CONTENT = 270304
MAX_REQUEST = 8192
MAX_LEDGER = 262144
MAX_RESPONSE = 524288
RESERVE = (8, 32, 1048576, 1048576)
HEAD_BYTES = b"ref: refs/heads/ledger\n"
CONFIG_BYTES = b"[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = true\n"
AUTHOR = b"ystack ledger <ledger@invalid> 946684800 +0000"
MESSAGE = b"ystack delivery ledger\n"
NAMES = ("identity.json", "ledger.json", "receipt.json", "request.json")
CAPS = {"identity.json": 1024, "ledger.json": MAX_LEDGER,
        "receipt.json": 1024, "request.json": MAX_REQUEST}
DIRECTORIES = {"", "repository.git", "repository.git/objects", "repository.git/refs",
               "repository.git/refs/heads"}
FIXED_FILES = {"store.lock", "repository.git/HEAD", "repository.git/config",
               "repository.git/refs/heads/ledger", "repository.git/refs/heads/ledger.lock"}


class Refusal(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def require(condition, code="E_STORE"):
    if not condition:
        raise Refusal(code)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"),
                       ensure_ascii=True, allow_nan=False) + "\n").encode("ascii")


def fields(value, expected, code="E_INPUT"):
    require(type(value) is dict and set(value) == expected, code)


def identifier(value, code="E_INPUT"):
    require(type(value) is str and ID_PATTERN.fullmatch(value) is not None, code)


def integer(value, lower, upper, code="E_INPUT"):
    require(type(value) is int and lower <= value <= upper, code)


def timestamp(value, code="E_INPUT"):
    require(type(value) is str, code)
    match = TIME_PATTERN.fullmatch(value)
    require(match is not None, code)
    year, month, day, hour, minute, second = map(int, match.groups())
    leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
    days = (31, 29 if leap else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
    require(1 <= month <= 12 and 1 <= day <= days[month - 1]
            and hour <= 23 and minute <= 59 and second <= 59, code)


def oid(value, code="E_INPUT"):
    require(type(value) is str and OID_PATTERN.fullmatch(value) is not None, code)


def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def bad_number(_value):
    raise ValueError("unsupported number")


def parse_integer(text):
    if len(text) > 10 or text.startswith("-"):
        raise ValueError("integer range")
    value = int(text)
    if value > 2147483647:
        raise ValueError("integer range")
    return value


def parse(data, cap, code="E_INPUT"):
    require(0 < len(data) <= cap, code)
    depth = 0
    quoted = False
    escaped = False
    for byte in data:
        require(byte < 128, code)
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
        elif byte == 34:
            quoted = True
        elif byte in (91, 123):
            depth += 1
            require(depth <= 16, code)
        elif byte in (93, 125):
            depth -= 1
            require(depth >= 0, code)
    try:
        value = json.loads(data.decode("ascii"), object_pairs_hook=pairs,
                           parse_int=parse_integer, parse_float=bad_number,
                           parse_constant=bad_number)
        require(canonical(value) == data, code)
        return value
    except (ValueError, UnicodeError, RecursionError, TypeError):
        raise Refusal(code) from None


def validate_key(value, code="E_INPUT"):
    fields(value, KEY_FIELDS, code)
    fields(value["stage_key"], STAGE_FIELDS, code)
    for item in value["stage_key"].values():
        identifier(item, code)
    require(type(value["request_sha256"]) is str and
            re.fullmatch(r"[0-9a-f]{64}", value["request_sha256"]) is not None, code)
    require(type(value["operation"]) is str and value["operation"] in OPERATIONS, code)
    integer(value["attempt_number"], 1, 10, code)


def key_order(value):
    stage = value["stage_key"]
    return (stage["initiative_id"], stage["workflow_id"], stage["stage_id"],
            stage["task_class_id"], value["request_sha256"], value["operation"],
            value["attempt_number"])


def validate_request(verb, value, code="E_INPUT"):
    expected = INIT_FIELDS if verb == "initialize" else UPDATE_FIELDS if verb == "apply-update" else ROOT_FIELDS
    fields(value, expected, code)
    require(value["protocol"] == PROTOCOL, code)
    identifier(value["store_id"], code)
    identifier(value["ledger_id"], code)
    if verb == "initialize":
        identifier(value["initialization_id"], code)
        timestamp(value["recorded_at"], code)
    elif verb == "apply-update":
        identifier(value["update_id"], code)
        timestamp(value["recorded_at"], code)
        oid(value["expected_tip"], code)
        validate_key(value["delivery_key"], code)
        require(type(value["action"]) is str and value["action"] in ACTIONS, code)
        integer(value["delivery_ordinal"], 0, 2147483647, code)


def ledger_document(ledger_id, entries, recorded_at):
    return {"schema_version": 1, "kind": "orchestrator_delivery_ledger", "id": ledger_id,
            "body": {"entries": entries, "recorded_at": recorded_at,
                     "ledger_contract": {"declared_entry_count": len(entries),
                                         "maximum_entry_count": 128,
                                         "schema_identity": "orchestrator.delivery-ledger.v1"}}}


def transition(old, request, code="E_TRANSITION"):
    body = old["body"]
    require(request["recorded_at"] >= body["recorded_at"], code)
    entries = [dict(entry) for entry in body["entries"]]
    selected = None
    for entry in entries:
        if entry["delivery_key"] == request["delivery_key"]:
            selected = entry
            break
    action = request["action"]
    ordinal = request["delivery_ordinal"]
    if selected is None:
        require(action == "record-delivery" and ordinal == 1 and len(entries) < 128, code)
        selected = {"delivery_key": request["delivery_key"], "state": "pending",
                    "delivery_count": 1, "last_delivery_at": request["recorded_at"]}
        entries.append(selected)
    else:
        state = selected["state"]
        count = selected["delivery_count"]
        require(state != "acknowledged", code)
        if action == "record-delivery":
            require(ordinal == count + 1 and ordinal <= 1000, code)
            selected.update(state="pending", delivery_count=ordinal,
                            last_delivery_at=request["recorded_at"])
        elif action == "record-failure":
            require(state == "pending" and ordinal == count, code)
            selected["state"] = "failed"
        else:
            require(1 <= ordinal <= count, code)
            selected["state"] = "acknowledged"
    entries.sort(key=lambda entry: key_order(entry["delivery_key"]))
    return ledger_document(old["id"], entries, request["recorded_at"])


def make_receipt(verb, request, ledger):
    return {"request_kind": verb,
            "request_id": request["initialization_id"] if verb == "initialize" else request["update_id"],
            "request_sha256": digest(canonical(request)), "ledger_sha256": digest(canonical(ledger))}


def response(request, current_tip, result_tip, ledger, receipt):
    return {"protocol": PROTOCOL, "store_id": request["store_id"], "ledger_id": request["ledger_id"],
            "current_tip": current_tip, "result_tip": result_tip, "ledger": ledger,
            "receipt": receipt,
            "ledger_ref": {"kind": "orchestrator_delivery_ledger",
                           "schema_identity": "orchestrator.delivery-ledger.v1",
                           "id": ledger["id"], "sha256": digest(canonical(ledger))}}


def ancestry(path):
    current = path
    while True:
        yield current
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent


def physical(path, code="E_STORE"):
    require(type(path) is str and path.startswith("/") and os.path.normpath(path) == path, code)
    for component in ancestry(path):
        state = os.lstat(component)
        require(not stat.S_ISLNK(state.st_mode), code)
    return path


def overlaps(first, second):
    return first == second or first.startswith(second + "/") or second.startswith(first + "/")


def file_state(state, code="E_STORE"):
    require(stat.S_ISREG(state.st_mode) and state.st_uid == os.getuid() and
            stat.S_IMODE(state.st_mode) in (0o400, 0o600), code)


def fatal_close():
    try:
        os.write(2, b"E_IO\n")
    finally:
        os._exit(1)


def close_fd(descriptor):
    try:
        os.close(descriptor)
    except OSError:
        fatal_close()


def open_regular(path, code="E_STORE"):
    before = os.lstat(path)
    file_state(before, code)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        after = os.fstat(descriptor)
        file_state(after, code)
        require((before.st_dev, before.st_ino) == (after.st_dev, after.st_ino), code)
        return descriptor, after
    except BaseException:
        close_fd(descriptor)
        raise


def read_file(path, cap, code="E_STORE"):
    descriptor, state = open_regular(path, code)
    try:
        require(state.st_size <= cap, code)
        data = bytearray()
        while len(data) <= cap:
            block = os.read(descriptor, min(65536, cap + 1 - len(data)))
            if not block:
                break
            data.extend(block)
        require(len(data) <= cap and len(data) == state.st_size, code)
        return bytes(data)
    finally:
        close_fd(descriptor)


def decode_object(path, expected_oid):
    descriptor, state = open_regular(path)
    decoder = zlib.decompressobj()
    raw = bytearray()
    consumed = 0
    try:
        while True:
            compressed = os.read(descriptor, 65536)
            if not compressed:
                break
            consumed += len(compressed)
            require(not decoder.eof)
            pending = compressed
            while pending:
                prior = len(pending)
                fragment = decoder.decompress(pending, MAX_RAW + 1 - len(raw))
                raw.extend(fragment)
                require(len(raw) <= MAX_RAW, "E_LIMIT")
                require(not decoder.unused_data)
                pending = decoder.unconsumed_tail
                require(not pending or fragment or len(pending) < prior)
        require(consumed == state.st_size and decoder.eof and not decoder.unused_data)
    except zlib.error:
        raise Refusal("E_STORE") from None
    finally:
        close_fd(descriptor)
    separator = raw.find(0)
    require(0 < separator < 32)
    header = bytes(raw[:separator])
    match = re.fullmatch(rb"(blob|tree|commit) (0|[1-9][0-9]*)", header)
    require(match is not None)
    content = bytes(raw[separator + 1:])
    require(int(match.group(2)) == len(content) and len(content) <= MAX_CONTENT)
    require(hashlib.sha1(raw).hexdigest() == expected_oid)
    return match.group(1).decode("ascii"), content, len(raw)


def encode_object(kind, content):
    raw = kind.encode("ascii") + b" " + str(len(content)).encode("ascii") + b"\0" + content
    require(len(content) <= MAX_CONTENT and len(raw) <= MAX_RAW, "E_LIMIT")
    compressor = zlib.compressobj()
    compressed = bytearray()
    for offset in range(0, len(raw), 65536):
        fragment = compressor.compress(raw[offset:offset + 65536])
        require(len(compressed) + len(fragment) <= len(raw) + 1024, "E_LIMIT")
        compressed.extend(fragment)
    fragment = compressor.flush()
    require(len(compressed) + len(fragment) <= len(raw) + 1024, "E_LIMIT")
    compressed.extend(fragment)
    return hashlib.sha1(raw).hexdigest(), bytes(compressed), len(raw)


def commit_bytes(tree, parent):
    result = b"tree " + tree.encode("ascii") + b"\n"
    if parent is not None:
        result += b"parent " + parent.encode("ascii") + b"\n"
    return result + b"author " + AUTHOR + b"\ncommitter " + AUTHOR + b"\n\n" + MESSAGE


def parse_commit(content):
    require(len(content) <= 1024)
    lines = content.split(b"\n")
    require(len(lines) in (6, 7) and lines[0].startswith(b"tree "))
    try:
        tree = lines[0][5:].decode("ascii")
        oid(tree, "E_STORE")
        parent = None
        if len(lines) == 7:
            require(lines[1].startswith(b"parent "))
            parent = lines[1][7:].decode("ascii")
            oid(parent, "E_STORE")
        require(commit_bytes(tree, parent) == content)
        return tree, parent
    except UnicodeError:
        raise Refusal("E_STORE") from None


def tree_bytes(objects):
    return b"".join(b"100644 " + name.encode("ascii") + b"\0" + bytes.fromhex(objects[name])
                    for name in NAMES)


def parse_tree(content):
    require(len(content) <= 1024)
    result = {}
    offset = 0
    for name in NAMES:
        prefix = b"100644 " + name.encode("ascii") + b"\0"
        require(content[offset:offset + len(prefix)] == prefix)
        offset += len(prefix)
        require(len(content) - offset >= 20)
        result[name] = content[offset:offset + 20].hex()
        offset += 20
    require(offset == len(content))
    return result


class Store:
    def __init__(self, root):
        self.root = physical(root)
        source = os.path.realpath(__file__)
        source_root = os.path.dirname(os.path.dirname(os.path.dirname(source)))
        require(not overlaps(root, source_root))
        for parent in ancestry(root):
            require(not os.path.lexists(os.path.join(parent, ".git")))
        state = os.lstat(root)
        require(stat.S_ISDIR(state.st_mode) and state.st_uid == os.getuid()
                and stat.S_IMODE(state.st_mode) == 0o700)
        self.lock = None
        self.objects = {}
        self.inodes = {}
        self.totals = [0, 0, 0, 0]
        self.tip = None
        self.history = []
        self.identity = None
        self.latest_ledger = None
        self.reservation_start = None

    def path(self, relative):
        return os.path.join(self.root, relative)

    def acquire(self, initialize):
        lock_path = self.path("store.lock")
        if not os.path.lexists(lock_path):
            require(initialize, "E_INCOMPLETE")
            with os.scandir(self.root) as entries:
                require(next(entries, None) is None, "E_INCOMPLETE")
            try:
                descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_EXCL |
                                     os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
            except FileExistsError:
                descriptor = os.open(lock_path, os.O_RDWR | os.O_NOFOLLOW |
                                     os.O_NONBLOCK | os.O_CLOEXEC)
        else:
            descriptor = os.open(lock_path, os.O_RDWR | os.O_NOFOLLOW |
                                 os.O_NONBLOCK | os.O_CLOEXEC)
        self.lock = descriptor
        state = os.fstat(descriptor)
        file_state(state)
        require(stat.S_IMODE(state.st_mode) == 0o600 and state.st_size == 0)
        before = os.lstat(lock_path)
        require((state.st_dev, state.st_ino) == (before.st_dev, before.st_ino))
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno in (errno.EAGAIN, errno.EACCES):
                raise Refusal("E_BUSY") from None
            raise

    def release(self):
        if self.lock is not None:
            descriptor = self.lock
            self.lock = None
            close_fd(descriptor)

    def check_totals(self):
        require(self.totals[0] <= MAX_FILES and self.totals[1] <= MAX_ENTRIES
                and self.totals[2] <= MAX_BYTES and self.totals[3] <= MAX_BYTES, "E_LIMIT")

    def inventory(self):
        self.objects = {}
        self.inodes = {}
        self.totals = [0, 0, 0, 0]
        present = set()
        stack = [("", 0)]
        while stack:
            relative, depth = stack.pop()
            require(depth <= 5)
            path = self.path(relative)
            state = os.lstat(path)
            self.totals[1] += 1
            self.check_totals()
            require(state.st_uid == os.getuid())
            present.add(relative)
            if stat.S_ISDIR(state.st_mode):
                fanout = re.fullmatch(r"repository\.git/objects/[0-9a-f]{2}", relative)
                require(relative in DIRECTORIES or fanout is not None)
                require(stat.S_IMODE(state.st_mode) == 0o700)
                with os.scandir(path) as entries:
                    for entry in entries:
                        require(len(stack) + self.totals[1] < MAX_ENTRIES + 1, "E_LIMIT")
                        child = relative + "/" + entry.name if relative else entry.name
                        stack.append((child, depth + 1))
                continue
            file_state(state)
            inode = (state.st_dev, state.st_ino)
            count, links = self.inodes.get(inode, (0, state.st_nlink))
            require(links == state.st_nlink)
            self.inodes[inode] = (count + 1, links)
            self.totals[2] += state.st_size
            self.check_totals()
            parts = relative.split("/")
            if relative in FIXED_FILES:
                require(stat.S_IMODE(state.st_mode) == 0o600)
                cap = MAX_RAW if relative.endswith("ledger.lock") else 256
                require(state.st_size <= cap, "E_LIMIT")
                if relative == "store.lock":
                    require(state.st_size == 0)
                continue
            require(len(parts) == 4 and parts[:2] == ["repository.git", "objects"]
                    and re.fullmatch(r"[0-9a-f]{2}", parts[2]) is not None)
            self.totals[0] += 1
            if parts[3].startswith("tmp_obj_") and len(parts[3]) > 8:
                require(state.st_size <= MAX_RAW, "E_LIMIT")
                self.totals[3] += MAX_RAW
            else:
                require(re.fullmatch(r"[0-9a-f]{38}", parts[3]) is not None)
                object_id = parts[2] + parts[3]
                kind, content, raw_size = decode_object(path, object_id)
                self.totals[3] += raw_size
                self.objects[object_id] = (kind, len(content), raw_size)
            self.check_totals()
        require(all(count == links for count, links in self.inodes.values()))
        return present

    def load_object(self, object_id, kind, cap):
        require(object_id in self.objects)
        metadata = self.objects[object_id]
        require(metadata[0] == kind and metadata[1] <= cap)
        actual_kind, content, _ = decode_object(self.path("repository.git/objects/" +
                                                         object_id[:2] + "/" + object_id[2:]), object_id)
        require(actual_kind == kind and len(content) <= cap)
        return content

    def current_ref(self, absent=False):
        path = self.path("repository.git/refs/heads/ledger")
        if not os.path.lexists(path):
            require(absent, "E_INCOMPLETE")
            return None
        raw = read_file(path, 41)
        require(re.fullmatch(rb"[0-9a-f]{40}\n", raw) is not None)
        return raw[:-1].decode("ascii")

    def validate(self):
        present = self.inventory()
        if present == {"", "store.lock"}:
            return False
        require(DIRECTORIES.issubset(present) and
                {"repository.git/HEAD", "repository.git/config",
                 "repository.git/refs/heads/ledger"}.issubset(present), "E_INCOMPLETE")
        require(read_file(self.path("repository.git/HEAD"), 256) == HEAD_BYTES)
        require(read_file(self.path("repository.git/config"), 256) == CONFIG_BYTES)
        self.tip = self.current_ref()
        commits = []
        seen = set()
        current = self.tip
        while current is not None:
            require(current not in seen and len(commits) < 1025)
            seen.add(current)
            tree, parent = parse_commit(self.load_object(current, "commit", 1024))
            commits.append((current, tree, parent))
            current = parent
        prior_ledger = None
        prior_tip = None
        update_ids = set()
        self.history = []
        for index, (commit, tree, parent) in enumerate(reversed(commits)):
            members = parse_tree(self.load_object(tree, "tree", 1024))
            docs = {name: parse(self.load_object(members[name], "blob", CAPS[name]),
                                CAPS[name], "E_STORE") for name in NAMES}
            identity = docs["identity.json"]
            fields(identity, ROOT_FIELDS | {"initialization_id"}, "E_STORE")
            require(identity["protocol"] == PROTOCOL)
            for name in ("store_id", "ledger_id", "initialization_id"):
                identifier(identity[name], "E_STORE")
            request = docs["request.json"]
            verb = "initialize" if index == 0 else "apply-update"
            validate_request(verb, request, "E_STORE")
            require(request["store_id"] == identity["store_id"] and
                    request["ledger_id"] == identity["ledger_id"])
            if index == 0:
                self.identity = identity
                require(request["initialization_id"] == identity["initialization_id"])
                expected = ledger_document(identity["ledger_id"], [], request["recorded_at"])
            else:
                require(identity == self.identity and parent == prior_tip and
                        request["expected_tip"] == prior_tip and request["update_id"] not in update_ids)
                update_ids.add(request["update_id"])
                expected = transition(prior_ledger, request, "E_STORE")
            require(docs["ledger.json"] == expected)
            receipt = make_receipt(verb, request, expected)
            require(docs["receipt.json"] == receipt)
            self.history.append((commit, request, members["ledger.json"], receipt))
            prior_ledger = expected
            prior_tip = commit
        self.latest_ledger = prior_ledger
        return True

    def historical_ledger(self, record):
        return parse(self.load_object(record[2], "blob", CAPS["ledger.json"]),
                     CAPS["ledger.json"], "E_STORE")

    def reserve(self):
        for total, extra, cap in zip(self.totals, RESERVE,
                                     (MAX_FILES, MAX_ENTRIES, MAX_BYTES, MAX_BYTES)):
            require(total + extra <= cap, "E_LIMIT")
        self.reservation_start = tuple(self.totals)

    def charge(self, files=0, entries=0, regular=0, inflated=0):
        additions = (files, entries, regular, inflated)
        self.totals = [old + added for old, added in zip(self.totals, additions)]
        self.check_totals()
        require(self.reservation_start is not None, "E_IO")
        require(all(current - start <= allowed for current, start, allowed in
                    zip(self.totals, self.reservation_start, RESERVE)), "E_LIMIT")

    def directory(self, relative):
        path = self.path(relative)
        if os.path.lexists(path):
            state = os.lstat(path)
            require(stat.S_ISDIR(state.st_mode) and state.st_uid == os.getuid()
                    and stat.S_IMODE(state.st_mode) == 0o700)
            return
        self.charge(entries=1)
        os.mkdir(path, 0o700)
        state = os.lstat(path)
        require(stat.S_IMODE(state.st_mode) == 0o700 and stat.S_ISDIR(state.st_mode))

    def create(self, path):
        return os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                       os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)

    def write_all(self, descriptor, data):
        offset = 0
        while offset < len(data):
            try:
                count = os.write(descriptor, data[offset:offset + 65536])
            except InterruptedError:
                continue
            require(type(count) is int and 0 < count <= min(65536, len(data) - offset), "E_IO")
            offset += count
        state = os.fstat(descriptor)
        require(stat.S_ISREG(state.st_mode) and state.st_uid == os.getuid()
                and stat.S_IMODE(state.st_mode) == 0o600 and state.st_size == len(data), "E_IO")

    def write_closed(self, path, data):
        descriptor = self.create(path)
        try:
            self.write_all(descriptor, data)
        finally:
            close_fd(descriptor)

    def initialize_layout(self):
        for relative in ("repository.git", "repository.git/objects", "repository.git/refs",
                         "repository.git/refs/heads"):
            self.directory(relative)
        for relative, data in (("repository.git/HEAD", HEAD_BYTES), ("repository.git/config", CONFIG_BYTES)):
            self.charge(entries=1, regular=len(data))
            self.write_closed(self.path(relative), data)

    def write_object(self, kind, content):
        object_id, compressed, raw_size = encode_object(kind, content)
        relative = "repository.git/objects/" + object_id[:2]
        final = self.path(relative + "/" + object_id[2:])
        if os.path.lexists(final):
            old_kind, old_content, _ = decode_object(final, object_id)
            require(old_kind == kind and old_content == content)
            return object_id
        self.directory(relative)
        self.charge(files=1, entries=1, regular=len(compressed), inflated=MAX_RAW)
        descriptor = None
        temporary = None
        for _attempt in range(32):
            temporary = self.path(relative + "/tmp_obj_" + os.urandom(12).hex())
            try:
                descriptor = self.create(temporary)
                break
            except FileExistsError:
                continue
        require(descriptor is not None, "E_IO")
        try:
            self.write_all(descriptor, compressed)
        finally:
            close_fd(descriptor)
        require(not os.path.lexists(final))
        os.rename(temporary, final)
        self.totals[3] += raw_size - MAX_RAW
        return object_id

    def publish(self, identity, request, ledger, receipt, parent):
        documents = {"identity.json": identity, "request.json": request,
                     "ledger.json": ledger, "receipt.json": receipt}
        encoded = {name: canonical(value) for name, value in documents.items()}
        for name, data in encoded.items():
            require(len(data) <= CAPS[name], "E_LIMIT")
        members = {name: self.write_object("blob", encoded[name]) for name in NAMES}
        tree = self.write_object("tree", tree_bytes(members))
        commit = self.write_object("commit", commit_bytes(tree, parent))
        for name in NAMES:
            object_id = members[name]
            kind, content, _ = decode_object(self.path("repository.git/objects/" +
                                           object_id[:2] + "/" + object_id[2:]), object_id)
            require(kind == "blob" and content == encoded[name])
        kind, content, _ = decode_object(self.path("repository.git/objects/" +
                                        tree[:2] + "/" + tree[2:]), tree)
        require(kind == "tree" and parse_tree(content) == members)
        kind, content, _ = decode_object(self.path("repository.git/objects/" +
                                        commit[:2] + "/" + commit[2:]), commit)
        require(kind == "commit" and parse_commit(content) == (tree, parent))
        saved_start = self.reservation_start
        self.inventory()
        self.reservation_start = saved_start
        lock = self.path("repository.git/refs/heads/ledger.lock")
        require(not os.path.lexists(lock), "E_BUSY")
        self.charge(entries=1, regular=41)
        descriptor = self.create(lock)
        try:
            require(self.current_ref(absent=parent is None) == parent, "E_STALE")
            self.write_all(descriptor, (commit + "\n").encode("ascii"))
        finally:
            close_fd(descriptor)
        os.replace(lock, self.path("repository.git/refs/heads/ledger"))
        return commit

    def execute(self, verb, request):
        valid = self.validate()
        if not valid:
            require(verb == "initialize", "E_INCOMPLETE")
            identity = {name: request[name] for name in ROOT_FIELDS | {"initialization_id"}}
            ledger = ledger_document(request["ledger_id"], [], request["recorded_at"])
            receipt = make_receipt(verb, request, ledger)
            parent = None
        else:
            require(request["store_id"] == self.identity["store_id"] and
                    request["ledger_id"] == self.identity["ledger_id"], "E_IDENTITY")
            identity = self.identity
            if verb == "read":
                return response(request, self.tip, self.tip, self.latest_ledger, None)
            if verb == "initialize":
                prior = self.history[0]
                require(request == prior[1], "E_CONFLICT")
                return response(request, self.tip, prior[0], self.historical_ledger(prior), prior[3])
            for prior in self.history[1:]:
                if prior[1]["update_id"] == request["update_id"]:
                    require(request == prior[1], "E_CONFLICT")
                    return response(request, self.tip, prior[0], self.historical_ledger(prior), prior[3])
            require(request["expected_tip"] == self.tip, "E_STALE")
            require(len(self.history) <= 1024, "E_LIMIT")
            ledger = transition(self.latest_ledger, request)
            receipt = make_receipt(verb, request, ledger)
            parent = self.tip
        require(not os.path.lexists(self.path("repository.git/refs/heads/ledger.lock")), "E_BUSY")
        require(len(canonical(response(request, "0" * 40, "0" * 40, ledger, receipt))) <= MAX_RESPONSE,
                "E_LIMIT")
        self.reserve()
        if not valid:
            self.initialize_layout()
        tip = self.publish(identity, request, ledger, receipt, parent)
        return response(request, tip, tip, ledger, receipt)


def output(data):
    offset = 0
    while offset < len(data):
        try:
            count = os.write(1, data[offset:offset + 65536])
        except InterruptedError:
            continue
        require(type(count) is int and 0 < count <= min(65536, len(data) - offset), "E_IO")
        offset += count


def main(argv):
    store = None
    try:
        require(len(argv) == 4 and argv[1] in ("initialize", "read", "apply-update"), "E_USAGE")
        os.umask(0o077)
        verb, root, request_path = argv[1:]
        store = Store(root)
        physical(request_path, "E_INPUT")
        require(not overlaps(root, request_path), "E_INPUT")
        request = parse(read_file(request_path, MAX_REQUEST, "E_INPUT"), MAX_REQUEST)
        validate_request(verb, request)
        store.acquire(verb == "initialize")
        result = canonical(store.execute(verb, request))
        require(len(result) <= MAX_RESPONSE, "E_LIMIT")
        output(result)
        return 0
    except Refusal as error:
        code = error.code
    except (OSError, ValueError, UnicodeError, OverflowError, RecursionError):
        code = "E_IO"
    finally:
        if store is not None:
            store.release()
    try:
        os.write(2, (code + "\n").encode("ascii"))
    except OSError:
        pass
    return 2 if code == "E_USAGE" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
