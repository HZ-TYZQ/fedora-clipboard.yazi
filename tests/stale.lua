-- Run from the repository root with Lua or LuaJIT. All clipboard and task I/O is mocked.
table.unpack = table.unpack or unpack
utf8 = utf8 or { len = function(s) return #s end } -- Test paths are ASCII.

local GNOME = "x-special/gnome-copied-files"
local plugin, on_yank, queue, tasks, notices, clipboard, encoded, fail_copy, fail_read

local url_mt = {
	__tostring = function(u) return u.path end,
	__eq = function(a, b) return a.path == b.path end,
	__index = { join = function(u, name) return Url(u.path .. "/" .. name) end },
}
function Url(path)
	return setmetatable({ path = path, name = path:match("[^/]+$"), spec = { kind = "regular" } }, url_mt)
end

ya = {
	async = function(fn, ...) queue[#queue + 1] = { fn, ... } end,
	percent_encode = function(s) return s end,
	percent_decode = function(s) return s end,
	json_encode = function(value) encoded = value; return "json" end,
	json_decode = function() return { data = clipboard } end,
	notify = function(value) notices[#notices + 1] = value end,
	emit = function() end,
	task = function(kind, args)
		return { spawn = function() tasks[#tasks + 1] = { kind = kind, from = args.from.path } end }
	end,
}
ps = { sub = function(_, fn) on_yank = fn end }
cx = { active = { current = { cwd = Url("/dest") } }, tasks = { behavior = { reset = function() end } } }

Command = setmetatable({ PIPED = 1, NULL = 2 }, { __call = function()
	local cmd = {}
	function cmd:arg(args) self.args = args; return self end
	function cmd:stdin() return self end
	function cmd:stdout() return self end
	function cmd:stderr() return self end
	function cmd:spawn() return self end
	function cmd:write_all() end
	function cmd:flush() end
	function cmd:wait_with_output()
		local action = self.args[4]
		if (action == "copy" and fail_copy) or (action == "paste" and fail_read) then
			return { status = { success = false, code = 1 }, stderr = "simulated failure" }
		end
		if action == "copy" then
			clipboard = {}
			for _, item in ipairs(encoded.items) do clipboard[item[1]] = item[2] end
		end
		return { status = { success = true }, stdout = action == "copy" and "12345\n" or "json" }
	end
	return cmd
end })

local function run()
	while #queue > 0 do
		local call = table.remove(queue, 1)
		call[1](table.unpack(call, 2))
	end
end

local function yank(paths)
	local entries = {}
	for i, path in ipairs(paths) do entries[i] = { url = Url(path) } end
	cx.yanked = setmetatable(entries, { __index = { is_cut = false } })
	on_yank()
end

local function fresh(read_fails)
	queue, tasks, notices, clipboard = {}, {}, {}, { [GNOME] = "cut\nfile:///old.txt" }
	fail_copy, fail_read = true, read_fails
	plugin = dofile("main.lua")
	plugin:setup()
	yank({ "/new.txt" })
	plugin:entry { args = { "push" } }
	run()
end

local function paste(path, kind)
	tasks = {}
	plugin:entry { args = { "paste" } }
	run()
	assert(#tasks == 1 and tasks[1].from == path and tasks[1].kind == kind,
		"unexpected paste: " .. (tasks[1] and tasks[1].from or "no task"))
end

local function external(path)
	clipboard = { [GNOME] = "cut\nfile://" .. path }
end

fresh(false)
paste("/new.txt", "copy")
external("/later.txt")
paste("/later.txt", "move")
print("PASS: failed sync protects old cut files and accepts later clipboard changes")

fresh(true)
-- Further read failures must not execute any file tasks.
plugin:entry { args = { "paste" } }
run()
assert(#tasks == 0 and #notices == 2)
fail_read = false
paste("/new.txt", "copy") -- First successful read remains conservative.
paste("/new.txt", "copy") -- The same old clipboard must still be ignored.
external("/recovered.txt")
paste("/recovered.txt", "move")
external("/another.txt")
paste("/another.txt", "move")
print("PASS: transient read failure recovers without moving stale cut files")

fresh(true)
fail_read, clipboard = false, {}
paste("/new.txt", "copy")
external("/after-text.txt")
paste("/after-text.txt", "move")
print("PASS: recovery also works when the first successful read contains no files")

fresh(true)
fail_copy, fail_read = false, false
plugin:entry { args = { "push" } }
run()
external("/after-retry.txt")
paste("/after-retry.txt", "move")
print("PASS: successful retry clears the unknown clipboard state")

fresh(true)
fail_read = false
yank({})
run()
external("/after-unyank.txt")
paste("/after-unyank.txt", "move")
print("PASS: unyank clears the unknown clipboard state")
