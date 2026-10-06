--- @since 26.8.15

-- MIME types understood by GNOME Files (Nautilus) and Dolphin, see docs/research.md
local GNOME = "x-special/gnome-copied-files"
local URI_LIST = "text/uri-list"
local KDE_CUT = "application/x-kde-cutselection"
local TEXTS = { "text/plain;charset=utf-8", "text/plain", "UTF8_STRING" }

local HELPER -- Python source of the Wayland helper, assigned at the end of this file

local M = {}

local function notify(content, level)
	ya.notify { title = "Clipboard", content = content, level = level or "error", timeout = 5 }
end

-- Must be called in the sync context
local function snapshot()
	local s = { paths = {}, cut = cx.yanked.is_cut, foreign = false }
	for _, file in pairs(cx.yanked) do
		local kind = file.url.spec.kind
		if kind == "regular" or kind == "search" then
			s.paths[#s.paths + 1] = tostring(file.url.path)
		else
			s.foreign = true
		end
	end
	return s
end

local function to_uri(path) return "file://" .. ya.percent_encode(path) end

local function to_path(uri)
	local host, path = uri:match("^file://([^/]*)(/.*)$")
	if host == "" or host == "localhost" then
		return ya.percent_decode(path)
	end
end

local function offers(paths, cut)
	local uris, lines = {}, {}
	for i, path in ipairs(paths) do
		uris[i] = to_uri(path)
		lines[i] = utf8.len(path) and path or uris[i]
	end

	local list = {
		{ GNOME, (cut and "cut\n" or "copy\n") .. table.concat(uris, "\n") },
		{ URI_LIST, table.concat(uris, "\r\n") .. "\r\n" },
	}
	if cut then
		list[#list + 1] = { KDE_CUT, "1" }
	end
	for _, mime in ipairs(TEXTS) do
		list[#list + 1] = { mime, table.concat(lines, "\n") }
	end
	return list, uris
end

-- Turn clipboard data into `{ cut = bool, paths = {...} }`, or nil if it holds no local files
local function parse(data)
	local cut, uris = false, {}
	local gnome = data[GNOME] and data[GNOME]:match("^(%l+)\r?\n")
	if gnome == "cut" or gnome == "copy" then
		cut = gnome == "cut"
		for line in data[GNOME]:gmatch("[^\r\n]+") do
			uris[#uris + 1] = line
		end
		table.remove(uris, 1)
	elseif data[URI_LIST] then
		cut = (data[KDE_CUT] or ""):sub(1, 1) == "1"
		for line in data[URI_LIST]:gmatch("[^\r\n]+") do
			if line:sub(1, 1) ~= "#" then
				uris[#uris + 1] = line
			end
		end
	end

	local paths = {}
	for _, uri in ipairs(uris) do
		paths[#paths + 1] = to_path(uri)
	end
	if #paths < #uris then
		notify("Skipped non-local URIs in the clipboard", "warn")
	end
	return #paths > 0 and { cut = cut, paths = paths } or nil
end

-- Returns stdout, or nil, exit code (2 = no data-control protocol), message
local function exec(cmd, args, input)
	local child, err = Command(cmd)
		:arg(args)
		:stdin(input and Command.PIPED or Command.NULL)
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()
	if not child then
		return nil, 2, string.format("Failed to start `%s`: %s", cmd, err)
	end

	if input then
		child:write_all(input)
		child:flush()
	end
	local output, err = child:wait_with_output()
	if not output then
		return nil, 1, tostring(err)
	elseif output.status.success then
		return output.stdout
	end
	return nil, output.status.code, output.stderr
end

local function helper(conf, args, input)
	return exec(conf.python or "python3", { "-I", "-c", HELPER, table.unpack(args) }, input)
end

-- Fallback for compositors without data-control (e.g. GNOME Shell): wl-clipboard can offer only one type,
-- so offer the one the desktop's own file manager understands.
local Fallback = {}

function Fallback.copy(items)
	local want = (os.getenv("XDG_CURRENT_DESKTOP") or ""):find("GNOME") and GNOME or URI_LIST
	for _, item in ipairs(items) do
		if item[1] == want then
			return exec("wl-copy", { "--type", want }, item[2])
		end
	end
end

function Fallback.paste()
	local types, code, err = exec("wl-paste", { "--list-types" })
	if code == 1 then
		return {} -- Nothing is copied
	elseif not types then
		return nil, code, err
	end

	local data = {}
	for mime in types:gmatch("[^\n]+") do
		if mime == GNOME or mime == URI_LIST or mime == KDE_CUT then
			data[mime] = exec("wl-paste", { "--no-newline", "--type", mime })
		end
	end
	return data
end

function Fallback.clear() return exec("wl-copy", { "--clear" }) end

-- Paths of `a` that are not in `b`
local function difference(a, b)
	local set, diff = {}, {}
	for _, path in ipairs(b.paths) do
		set[path] = true
	end
	for _, path in ipairs(a.paths) do
		if not set[path] then
			diff[#diff + 1] = path
		end
	end
	return diff
end

local function same(a, b) return a.cut == b.cut and #a.paths == #b.paths and #difference(a, b) == 0 end

local function vanished(paths)
	for _, path in ipairs(paths) do
		if fs.cha(Url(path)) then
			return false
		end
	end
	return true
end

-- Offer `want.items` on the clipboard, or give up our ownership of it if `want` is false
local function write(st, want)
	if not want then
		local pid = st.pid
		st.pid = nil
		return not pid or helper(st, { "release", pid })
	end

	-- Yanked files were deleted or renamed rather than yanked by the user: follow along only
	-- while the clipboard is still ours, instead of taking it back from whichever app owns it now
	local passive = want.dropped and vanished(want.dropped)
	if passive and not st.pid then
		return true
	end

	if not st.fallback then
		local json = ya.json_encode { items = want.items, uris = want.uris }
		local out, code, err = helper(st, { "copy", passive and st.pid or nil }, json)
		if out then
			st.pid = out:match("%d+")
			return true
		elseif code ~= 2 then
			return nil, code, err
		end
		st.fallback = true
	end
	return Fallback.copy(want.items)
end

-- Serialize clipboard writes so that the latest yank always wins
local function flush(st)
	while st.want ~= nil do
		local want = st.want
		st.want = nil

		local ok, out, code, err = pcall(write, st, want)
		if not ok or not out then
			notify(string.format("Failed to sync the clipboard (%s):\n%s", code, ok and err or out))
		end
	end
	st.busy = false
end

local function sync_yanked(st)
	local s, prev = snapshot(), st.prev
	st.prev = s
	if #s.paths == 0 then
		st.want = false
	else
		local items, uris = offers(s.paths, s.cut)
		local shrunk = prev and s.cut == prev.cut and #s.paths < #prev.paths and #difference(s, prev) == 0
		st.want = { items = items, uris = uris, dropped = shrunk and difference(prev, s) or nil }
	end

	if not st.busy then
		st.busy = true
		ya.async(flush, st)
	end
end

local state = ya.sync(function(st)
	local s = snapshot()
	s.cwd, s.python, s.fallback = cx.active.current.cwd, st.python, st.fallback
	return s
end)

local reset_behavior = ya.sync(function() cx.tasks.behavior:reset() end)

local function read(s)
	if not s.fallback then
		local out, code, err = helper(s, { "paste", GNOME, URI_LIST, KDE_CUT })
		if out then
			return (ya.json_decode(out) or {}).data
		elseif code ~= 2 then
			return nil, code, err
		end
	end
	return Fallback.paste()
end

local function clear(s)
	if not s.fallback then
		local _, code = helper(s, { "clear" })
		if code ~= 2 then
			return
		end
	end
	Fallback.clear()
end

local function paste(job)
	local s = state()
	local data, code, err = read(s)
	if not data then
		return notify(string.format("Failed to read the clipboard (%s):\n%s", code, err))
	end

	local opts = { force = job.args.force, follow = job.args.follow }
	local clip = parse(data)

	-- Yazi's own yank is still what the clipboard holds, or the clipboard can't represent it
	if not clip or s.foreign or same(clip, s) then
		return ya.emit("paste", opts)
	end

	reset_behavior()
	local kind = clip.cut and "move" or "copy"
	for _, path in ipairs(clip.paths) do
		local from = Url(path)
		local to = from.name and s.cwd:join(from.name)
		if to and not (from == to and (clip.cut or opts.force)) then
			ya.task(kind, { from = from, to = to, force = opts.force, follow = opts.follow }):spawn()
		end
	end

	-- Like Nautilus, a cut can only be pasted once
	if clip.cut then
		clear(s)
	end
end

function M:setup(opts)
	self.python = opts and opts.python or "python3"
	ps.sub("@yank", function() sync_yanked(self) end)
end

function M:entry(job)
	local action = job.args[1] or "paste"
	if action == "paste" then
		paste(job)
	else
		notify(string.format("Unknown action `%s`", action))
	end
end

HELPER = [==[
# fedora-clipboard.yazi helper: a stdlib-only Wayland data-control client.
#   copy [PID]      read {"items": [[mime, text], ...], "uris": [...]} JSON from stdin, own the clipboard,
#                   print daemon PID; with PID, do nothing unless that daemon of ours still owns the clipboard
#   paste MIME...   print {"types": [...], "data": {mime: text}} for the current clipboard
#   clear           clear the clipboard
#   release PID     stop our daemon PID (clears the clipboard if it still owns it)
# Exit status 2 means no Wayland data-control protocol is available.
import json, os, select, signal, socket, struct, sys, threading
from urllib.parse import unquote_to_bytes

MARKER = "fedora-clipboard.yazi helper"
MANAGERS = ("ext_data_control_manager_v1", "zwlr_data_control_manager_v1")
PORTAL_TYPES = ("application/vnd.portal.filetransfer", "application/vnd.portal.files")
FILE_TRANSFER = ("org.freedesktop.portal.Documents", "/org/freedesktop/portal/documents", "org.freedesktop.portal.FileTransfer")


class Unsupported(Exception):
    pass


def u32(v):
    return struct.pack("=I", v)


def string(s):
    b = s.encode() + b"\0"
    return u32(len(b)) + b + b"\0" * (-len(b) % 4)


class Reader:
    def __init__(self, data):
        self.data, self.pos = data, 0

    def u32(self):
        self.pos += 4
        return struct.unpack_from("=I", self.data, self.pos - 4)[0]

    def string(self):
        n = self.u32()
        s = self.data[self.pos : self.pos + max(n - 1, 0)]
        self.pos += n + (-n % 4)
        return s.decode(errors="replace")


class Clipboard:
    def __init__(self):
        name = os.environ.get("WAYLAND_DISPLAY")
        if not name:
            raise Unsupported("WAYLAND_DISPLAY is not set")
        path = name if name.startswith("/") else os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/"), name)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.sock.connect(path)
        except OSError as e:
            raise Unsupported(f"cannot connect to {path}: {e}")

        self.last_id, self.buf, self.fds, self.handlers = 1, b"", [], {1: self.on_display}
        self.globals, self.offers, self.selection = {}, {}, 0

        self.registry = self.new(self.on_registry)
        self.send(1, 1, u32(self.registry))  # wl_display.get_registry
        self.roundtrip()

        manager = next((m for m in MANAGERS if m in self.globals), None)
        if not manager or "wl_seat" not in self.globals:
            raise Unsupported("the compositor does not support the data-control protocol")
        self.seat = self.bind("wl_seat")
        self.manager = self.bind(manager)
        self.device = self.new(self.on_device)
        self.send(self.manager, 1, u32(self.device), u32(self.seat))  # get_data_device
        self.roundtrip()

    # --- Wire protocol
    def new(self, handler):
        self.last_id += 1
        self.handlers[self.last_id] = handler
        return self.last_id

    def send(self, obj, opcode, *args, fd=None):
        body = b"".join(args)
        msg = u32(obj) + u32((8 + len(body)) << 16 | opcode) + body
        if fd is None:
            self.sock.sendall(msg)
        else:
            socket.send_fds(self.sock, [msg], [fd])

    def dispatch(self):
        data, fds, _, _ = socket.recv_fds(self.sock, 65536, 28)
        if not data:
            raise EOFError("the compositor closed the connection")
        self.buf += data
        self.fds += fds
        while len(self.buf) >= 8:
            obj, word = struct.unpack_from("=II", self.buf)
            if len(self.buf) < word >> 16:
                break
            body, self.buf = self.buf[8 : word >> 16], self.buf[word >> 16 :]
            if handler := self.handlers.get(obj):
                handler(word & 0xFFFF, Reader(body))

    def roundtrip(self):
        done = []
        callback = self.new(lambda *_: done.append(True))
        self.send(1, 0, u32(callback))  # wl_display.sync
        while not done:
            self.dispatch()
        del self.handlers[callback]

    def bind(self, interface):
        name, _ = self.globals[interface]
        obj = self.new(None)
        self.send(self.registry, 0, u32(name), string(interface), u32(1), u32(obj))
        return obj

    # --- Events
    def on_display(self, opcode, r):
        if opcode == 0:  # error
            obj, code, message = r.u32(), r.u32(), r.string()
            raise RuntimeError(f"Wayland protocol error on object {obj} (code {code}): {message}")

    def on_registry(self, opcode, r):
        if opcode == 0:  # global
            name, interface, version = r.u32(), r.string(), r.u32()
            self.globals.setdefault(interface, (name, version))

    def on_device(self, opcode, r):
        if opcode == 0:  # data_offer
            offer = r.u32()
            types = self.offers[offer] = []
            self.handlers[offer] = lambda op, r: op == 0 and types.append(r.string())
        elif opcode == 1:  # selection
            self.drop_offer(self.selection)
            self.selection = r.u32()
        elif opcode == 3:  # primary_selection
            self.drop_offer(r.u32())
        elif opcode == 2:  # finished
            raise EOFError("the data device is gone")

    def drop_offer(self, offer):
        if offer in self.offers:
            del self.offers[offer], self.handlers[offer]
            self.send(offer, 1)  # destroy

    # --- Operations
    def types(self):
        return self.offers.get(self.selection, [])

    def receive(self, mime, timeout=3):
        r, w = os.pipe()
        try:
            self.send(self.selection, 0, string(mime), fd=w)  # receive
        finally:
            os.close(w)
        chunks = []
        with os.fdopen(r, "rb") as f:
            while select.select([f], [], [], timeout)[0] and (chunk := os.read(f.fileno(), 65536)):
                chunks.append(chunk)
        return b"".join(chunks).decode(errors="replace")

    def offer(self, items):
        data = {mime: text.encode() for mime, text in items}
        source = self.new(lambda op, r: self.on_source(data, op, r))
        self.send(self.manager, 0, u32(source))  # create_data_source
        for mime in data:
            self.send(source, 0, string(mime))  # offer
        self.send(self.device, 0, u32(source))  # set_selection
        self.roundtrip()

    def on_source(self, data, opcode, r):
        if opcode == 0:  # send
            mime, fd = r.string(), self.fds.pop(0)
            threading.Thread(target=write, args=(fd, data.get(mime, b"")), daemon=True).start()
        elif opcode == 1:  # cancelled
            raise EOFError("the selection was taken over")

    def clear(self):
        self.send(self.device, 0, u32(0))  # set_selection(null)
        self.roundtrip()


# --- Just enough of a D-Bus client to call methods with fds on the session bus
ALIGN = {"y": 1, "b": 4, "u": 4, "h": 4, "s": 4, "o": 4, "g": 1, "v": 1, "a": 4, "(": 8, "{": 8}


def types(sig):
    out, i = [], 0
    while i < len(sig):
        j = i
        while sig[j] == "a":
            j += 1
        depth = 0
        while True:
            depth += (sig[j] in "({") - (sig[j] in ")}")
            j += 1
            if depth == 0:
                break
        out.append(sig[i:j])
        i = j
    return out


def put(buf, t, v):
    buf += b"\0" * (-len(buf) % ALIGN[t[0]])
    if t == "y":
        buf.append(v)
    elif t in "buh":
        buf += struct.pack("<I", v)
    elif t in "so":
        b = v.encode()
        buf += struct.pack("<I", len(b)) + b + b"\0"
    elif t == "g":
        buf += bytes([len(v)]) + v.encode() + b"\0"
    elif t == "v":
        put(buf, "g", v[0])
        put(buf, v[0], v[1])
    elif t[0] == "a":
        at = len(buf)
        buf += b"\0" * 4
        buf += b"\0" * (-len(buf) % ALIGN[t[1]])
        start = len(buf)
        for item in v.items() if t[1] == "{" else v:
            put(buf, t[1:], item)
        struct.pack_into("<I", buf, at, len(buf) - start)
    else:  # struct or dict entry
        for sub, item in zip(types(t[1:-1]), v):
            put(buf, sub, item)


class Cursor:
    def __init__(self, data):
        self.data, self.pos, self.end = data, 0, "<" if data[:1] == b"l" else ">"

    def align(self, n):
        self.pos += -self.pos % n

    def u32(self):
        self.align(4)
        self.pos += 4
        return struct.unpack_from(self.end + "I", self.data, self.pos - 4)[0]

    def take(self, n):
        self.pos += n + 1
        return self.data[self.pos - n - 1 : self.pos - 1].decode(errors="replace")

    def value(self, sig):
        if sig in ("s", "o"):
            return self.take(self.u32())
        elif sig == "g":
            self.pos += 1
            return self.take(self.data[self.pos - 1])
        elif sig == "y":
            self.pos += 1
            return self.data[self.pos - 1]
        return self.u32()


class DBus:
    def __init__(self):
        addr = os.environ.get("DBUS_SESSION_BUS_ADDRESS") or f"unix:path={os.environ.get('XDG_RUNTIME_DIR')}/bus"
        params = dict(p.split("=", 1) for p in addr.split(";")[0].removeprefix("unix:").split(",") if "=" in p)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(params.get("path") or "\0" + params["abstract"])
        self.sock.sendall(b"\0AUTH EXTERNAL " + str(os.getuid()).encode().hex().encode() + b"\r\n")
        self.expect(b"OK ")
        self.sock.sendall(b"NEGOTIATE_UNIX_FD\r\n")
        self.expect(b"AGREE_UNIX_FD")
        self.sock.sendall(b"BEGIN\r\n")
        self.serial, self.buf = 0, b""
        self.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello")

    def expect(self, prefix):
        line = b""
        while not line.endswith(b"\r\n"):
            if not (byte := self.sock.recv(1)):
                raise EOFError("the session bus closed the connection")
            line += byte
        if not line.startswith(prefix):
            raise RuntimeError(f"D-Bus authentication failed: {line!r}")

    def call(self, dest, path, iface, member, sig="", args=(), fds=()):
        self.serial += 1
        body = bytearray()
        for t, v in zip(types(sig), args):
            put(body, t, v)
        fields = [(1, ("o", path)), (2, ("s", iface)), (3, ("s", member)), (6, ("s", dest))]
        if sig:
            fields.append((8, ("g", sig)))
        if fds:
            fields.append((9, ("u", len(fds))))
        msg = bytearray(b"l\1\0\1")
        put(msg, "u", len(body))
        put(msg, "u", self.serial)
        put(msg, "a(yv)", fields)
        msg += b"\0" * (-len(msg) % 8) + body
        socket.send_fds(self.sock, [msg], fds) if fds else self.sock.sendall(msg)
        return self.reply(self.serial)

    def reply(self, serial):
        while True:
            while len(self.buf) < 16 or len(self.buf) < self.size():
                if not (chunk := self.sock.recv(65536)):
                    raise EOFError("the session bus closed the connection")
                self.buf += chunk
            msg, self.buf = self.buf[: self.size()], self.buf[self.size() :]

            r, fields = Cursor(msg), {}
            r.pos = 16
            while r.pos < 16 + struct.unpack_from(r.end + "I", msg, 12)[0]:
                r.align(8)
                code = r.value("y")
                fields[code] = r.value(r.value("g"))
            r.align(8)
            body = r.value("s") if fields.get(8, "").startswith("s") else None

            if msg[1] in (2, 3) and fields.get(5) == serial:  # method return, error
                if msg[1] == 3:
                    raise RuntimeError(f"{fields.get(4)}: {body}")
                return body

    def size(self):
        end = "<" if self.buf[:1] == b"l" else ">"
        body, fields = struct.unpack_from(end + "I", self.buf, 4)[0], struct.unpack_from(end + "I", self.buf, 12)[0]
        return 16 + fields + (-fields % 8) + body


# Register files with the document portal like Dolphin does, so that sandboxed apps (Flatpak) can
# access them. The transfer lives as long as the D-Bus connection, i.e. as long as this daemon.
def transfer(uris):
    bus = DBus()
    key = bus.call(*FILE_TRANSFER, "StartTransfer", "a{sv}", [{"autostop": ("b", False)}])
    paths = [unquote_to_bytes(uri.removeprefix("file://")) for uri in uris]
    for i in range(0, len(paths), 16):  # The bus limits the number of fds per message
        fds = []
        try:
            for path in paths[i : i + 16]:
                fds.append(os.open(path, os.O_PATH | os.O_CLOEXEC))
            bus.call(*FILE_TRANSFER, "AddFiles", "saha{sv}", [key, range(len(fds)), {}], fds)
        finally:
            for fd in fds:
                os.close(fd)
    return bus, key


def write(fd, data):
    try:
        with open(fd, "wb") as f:
            f.write(data)
    except OSError:
        pass


def copy(owner=None):
    payload = json.load(sys.stdin)
    if owner and not ours(owner):
        return 0
    r, w = os.pipe()
    if pid := os.fork():
        os.close(w)
        with os.fdopen(r, "rb") as f:
            status = f.read()
        if status == b"ok":
            print(pid)
            return 0
        sys.stderr.write(status[1:].decode(errors="replace") or "the clipboard daemon died")
        return int(status[:1] or b"1")

    # Daemon: detach from Yazi and the terminal, then serve paste requests until replaced
    os.close(r)
    os.setsid()
    os.chdir("/")
    null = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(null, fd)
    try:
        clipboard, items = Clipboard(), payload["items"]
        try:
            clipboard.portal, key = transfer(payload["uris"])
            items += [[mime, key] for mime in PORTAL_TYPES]
        except Exception:
            pass  # Without the portal, only sandboxed apps miss out
        clipboard.offer(items)
    except Unsupported as e:
        os.write(w, b"2" + str(e).encode())
        os._exit(2)
    except Exception as e:
        os.write(w, b"1" + str(e).encode())
        os._exit(1)
    os.write(w, b"ok")
    os.close(w)
    try:
        while True:
            clipboard.dispatch()
    except Exception:
        for t in threading.enumerate():
            if t is not threading.current_thread():
                t.join(1)
        os._exit(0)


def paste(mimes):
    clipboard = Clipboard()
    types = clipboard.types()
    data = {m: clipboard.receive(m) for m in mimes if m in types}
    print(json.dumps({"types": types, "data": data}))
    return 0


# A daemon exits once its selection is taken over, so a live one still owns the clipboard
def ours(pid):
    try:
        with open(f"/proc/{int(pid)}/cmdline", "rb") as f:
            return MARKER.encode() in f.read()
    except (OSError, ValueError):
        return False


def release(pid):
    if ours(pid):
        os.kill(int(pid), signal.SIGTERM)
    return 0


def main(cmd, *args):
    if cmd == "copy":
        return copy(*args)
    elif cmd == "paste":
        return paste(args)
    elif cmd == "clear":
        Clipboard().clear()
        return 0
    elif cmd == "release":
        return release(args[0])
    sys.exit(f"unknown command: {cmd}")


try:
    sys.exit(main(*sys.argv[1:]))
except Unsupported as e:
    sys.stderr.write(str(e))
    sys.exit(2)
]==]

return M
