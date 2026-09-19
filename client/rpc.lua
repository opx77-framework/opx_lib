--- Calling another resource's client exports, checked at every level.
-- @author dop42
--
--   CreateThread(function()
--     local answer = Lib.Rpc.Call('open77_notifications', 'show', { message = 'Saved' })
--     if not answer.ok and answer.answered then ... end
--   end)
--
-- `Open77.exports.call` is the only way in: this platform installs no
-- `exports.<resource>:<name>()` proxy on the client. A call is a dispatch that
-- answers a promise, and the promise answers a table.
--
-- A CALL FAILS AT THREE SEPARATE LEVELS, and a caller that checks only the
-- first turns a remote error into a silent nil:
--
--   1. dispatch     the resource is not running, or `call` refused, so no
--                   promise came back -- nothing was ever asked
--   2. resolution   the promise settled with a reason -- it was asked and
--                   never answered
--   3. the answer   the remote answered, and refused
--
-- `answered` on the Result tells level 3 from levels 1 and 2: false means the
-- remote was unreachable and its state is UNKNOWN, true means it spoke and said
-- no. Only a caller that knows the difference may drop cached state on a
-- failure -- clearing a cache because the network hiccuped is how a UI empties
-- itself for no reason.
--
-- THE `await` SITS OUTSIDE EVERY pcall, deliberately. A yield is not safe
-- across a pcall boundary in this runtime, so only the dispatch is guarded.
-- `await` does not raise on a rejection in any case: it answers `nil, reason`,
-- which is an ordinary return and needs no guard.
--
-- IT SUSPENDS, so it runs inside a `CreateThread` and nowhere else.

local Native = require('@opx_lib/client.native')
local Validate = require('@opx_lib/pure.validate')
local Result = require('@opx_lib/pure.result')

local Rpc = {}

--- No manifest permission is checked for the dispatch itself; `Open77.exports`
--- is simply absent when the consumer's manifest granted no export access.
Rpc.NEEDS = nil

--- A Result that also says whether the remote itself answered.
local function refused(code, detail, answered)
	local held = Result.Err(code, detail)
	held.answered = answered
	return held
end

--- Whether a resource is running right now.
--
-- Guarded: a soft-dependency check must never take its caller down over a name
-- the host does not recognise.
-- @author dop42
-- @param resource string
-- @return boolean
function Rpc.IsRunning(resource)
	if type(resource) ~= 'string' then return false end
	local read, state = pcall(GetResourceState, resource)
	return read and state == 'running'
end

--- Calls one client export on another resource and reads its answer.
-- @author dop42
-- @param resource string
-- @param name string
-- @param ... any
-- @return table a Result; `answered` is true only when the remote itself refused
function Rpc.Call(resource, name, ...)
	if Validate.Text(resource, 64) == nil then
		return refused('invalid_resource', 'no resource name given', false)
	end
	if Validate.Text(name, 128) == nil then
		return refused('invalid_name', 'no export name given', false)
	end

	local call = Native.Reach('exports.call')
	if call == nil then
		-- Absent when the consumer's manifest granted no export access at all.
		return refused('no_exports', 'Open77.exports.call is not available', false)
	end
	if not Rpc.IsRunning(resource) then
		return refused('not_running', resource .. ' is not running', false)
	end

	-- Level 1: dispatch. Guarded, and the only thing that is.
	local dispatched, promise, reason = pcall(call, resource, name, ...)
	if not dispatched then return refused('dispatch_raised', tostring(promise), false) end
	if not promise then
		return refused(tostring(reason or 'not_dispatched'), 'the call was never sent', false)
	end
	if type(promise.await) ~= 'function' then
		return refused('no_promise', 'exports.call did not answer a promise', false)
	end

	-- Level 2: resolution. Outside the pcall, for the reason in the header.
	local answer, failed = promise:await()
	if failed then return refused(tostring(failed), 'the remote never answered', false) end

	-- Level 3: the answer. From here the remote spoke, so `answered` is true.
	if type(answer) ~= 'table' then
		return refused('malformed_answer', 'the remote answered something that is not a table', true)
	end
	if answer.ok ~= true then
		return refused(tostring(answer.error or 'refused'), tostring(answer.detail or ''), true)
	end

	local held = Result.Ok(answer)
	held.answered = true
	return held
end

return Rpc
