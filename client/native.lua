--- Calling an Open77 native from inside a library, and what that costs.
-- @author dop42
--
-- THE ONE FACT THIS MODULE EXISTS FOR. `require` runs this code in the
-- CONSUMER's VM -- "permissions and budget", in the platform's own words. A
-- native called from here is therefore charged to whoever imported us: their
-- manifest is what the permission check reads, their instruction budget pays
-- for the call, and every resource-owned handle that comes back belongs to
-- them. A marker this library creates is the consumer's marker; their
-- `Open77.markers.clear` removes it and nobody else's does.
--
-- That asymmetry is what makes a wrapper library possible at all. It has one
-- sharp edge: a consumer who forgot the permission learns about it as
-- `permission_denied:<name>`, at CALL time, mid-gameplay, from a line inside
-- somebody else's library. Every refusal below is rewritten into one that names
-- the manifest line to add, because the consumer cannot read our source to
-- work out which permission a helper needed.
--
-- NOTHING IS CAPTURED AT LOAD TIME. Writing `local notify = Open77.hud.notify`
-- at the top of a module reads the table once, at import: a module imported
-- before the namespace exists holds `nil` for the rest of the session, and the
-- failure surfaces as `attempt to call a nil value` far from the cause. It also
-- makes the module untestable off-platform, where there is no `Open77` at all.
-- Every call resolves its native by name, through `Reach`, at call time.

local Result = require('@opx_lib/pure.result')

local Native = {}

--- Resolves a dotted native path against the live `Open77` table.
--
-- By NAME and at CALL time, for the reason in the header. Answers the function
-- or `nil` plus a code, never raises: a namespace missing because the consumer
-- runs an older build is an ordinary refusal, not a crash in their event
-- handler.
-- @author dop42
-- @param path string e.g. 'hud.notify'
-- @return function|nil, string|nil
function Native.Reach(path)
	-- AN ORDINARY GLOBAL READ, and the word `rawget` being absent here is the
	-- whole point. This was `rawget(_G, 'Open77')`, which is wrong twice over:
	-- `rawget` skips a metatable, so a host exposing the namespace through an
	-- `__index` accessor answers nil; and `_G` is not necessarily the chunk's
	-- `_ENV`, so a host that hands a resource its own environment answers nil
	-- again. Either way every wrapper in this library silently takes its
	-- absent-native path and a consumer's feature just stops, with no refusal
	-- anybody can see.
	--
	-- It bought nothing. Reading a global that is not there yields nil in Lua;
	-- it never raises, which is the only thing `rawget` could have been guarding
	-- against. A plain read goes through `_ENV` and is correct under every
	-- arrangement a host can choose.
	local root = Open77
	if type(root) ~= 'table' then return nil, 'open77_unavailable' end

	local held = root
	for part in path:gmatch('[^%.]+') do
		if type(held) ~= 'table' then return nil, 'native_not_found' end
		held = held[part]
	end

	if type(held) ~= 'function' then return nil, 'native_not_found' end
	return held
end

--- Calls a native and answers a Result.
--
-- NORMALISES THE TWO CONVENTIONS the platform uses. Some natives answer
-- `true|false, reason`; others answer `value|nil, reason`. Both mean "failed"
-- with a falsy first return, so one rule covers them: falsy is a refusal
-- carrying `reason`, anything else is the answer.
--
-- That rule is WRONG for a native whose answer is legitimately `false` --
-- `Open77.zones.contains` is the one in this library -- and such a native must
-- not come through here. It is the same trap `modules/result.lua` was written
-- about, met from the other side.
--
-- `permission` is the manifest permission the native is gated on, or nil when
-- the handler checks none. It is used only to rewrite the refusal.
-- @author dop42
-- @param path string
-- @param permission string|nil
-- @param ... any
-- @return table a Result
function Native.Call(path, permission, ...)
	local native, missing = Native.Reach(path)
	if native == nil then
		return Result.Err(missing, ('Open77.%s is not available on this build'):format(path))
	end

	-- Guarded: a native that raises inside a library takes down a consumer's
	-- handler, and they cannot see the line that did it.
	local held = table.pack(pcall(native, ...))
	if not held[1] then
		return Result.Err('native_raised', ('Open77.%s raised: %s'):format(path, tostring(held[2])))
	end

	local answer, reason = held[2], held[3]
	if answer == nil or answer == false then
		return Native.Refusal(path, permission, reason)
	end
	return Result.Ok(answer)
end

--- Turns a native's refusal into one the consumer can act on.
--
-- A missing permission is the only refusal a library can diagnose better than
-- the platform can, because the platform does not know which of the consumer's
-- helpers needed it. Naming the exact manifest line turns a mid-session mystery
-- into a one-line edit.
-- @author dop42
-- @param path string
-- @param permission string|nil
-- @param reason any
-- @return table a Result
function Native.Refusal(path, permission, reason)
	local code = type(reason) == 'string' and reason or 'refused'

	if permission ~= nil and code:find('permission_denied', 1, true) then
		return Result.Err('permission_denied', ('Open77.%s needs permission "%s": add '
			.. 'permission "%s" to your open77.lua -- permissions are checked against '
			.. 'the calling resource, so opx_lib cannot declare it for you')
			:format(path, permission, permission))
	end

	return Result.Err(code, ('Open77.%s refused'):format(path))
end

return Native
