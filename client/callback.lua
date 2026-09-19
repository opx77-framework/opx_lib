--- Asking the server a question, and answering its questions.
-- @author dop42
--
--   local answer = Lib.Callback.AskAwait('getStock', 'medkit')
--   if answer.ok then print(answer.value) end
--
-- Wraps `Open77.net.*`. The consumer must declare `network.events`.
--
-- A CALLBACK BELONGS TO A RESOURCE, and the resource is the CONSUMER, because
-- this code runs in their VM. `Ask('getStock')` from resource `shop` reaches
-- the handler that resource `shop` registered on the server -- not opx_lib's,
-- which do not exist, and not another consumer's. Two resources may use the
-- same callback name through this module and never meet. To reach a different
-- resource on purpose, name it: `Ask({ resource = 'other', name = 'x' })`.
--
-- A CALLBACK IS A REQUEST, NEVER A GRANT. The server half must re-validate
-- everything, exactly as a net-event handler must: the arguments are whatever
-- this machine chose to send. Nothing in this module makes a client's question
-- trustworthy, and a server handler written as though it did is the bug this
-- paragraph exists to prevent.
--
-- `AskAwait` SUSPENDS, so it must be called from inside a CreateThread. Calling
-- it on the main body of a script is the one mistake this API invites, and it
-- shows up as a resource that never finishes starting.

local Native = require('@opx_lib/client.native')
local Validate = require('@opx_lib/pure.validate')
local Result = require('@opx_lib/pure.result')

local Callback = {}

--- The manifest permission a consumer must declare to use this module.
Callback.NEEDS = 'network.events'

--- The engine's default deadline, in milliseconds, and its accepted range.
Callback.TIMEOUT = 10000
Callback.TIMEOUT_MIN = 100
Callback.TIMEOUT_MAX = 120000

--- A callback name, or a targeting table, or nil.
local function target(name)
	if type(name) == 'string' then return Validate.Text(name, 128) end
	if Validate.Table(name, 8) == nil then return nil end
	if Validate.Text(name.name, 128) == nil then return nil end
	return name
end

--- Asks the server and answers a Result carrying the promise.
--
-- The promise is handed back rather than awaited so a caller may fire several
-- questions and await them together. `AskAwait` is the one-question case.
-- @author dop42
-- @param name string|table a name, or { resource, name, timeout }
-- @param ... any up to 29 arguments, 48 KiB per frame
-- @return table a Result carrying an Open77.Promise
function Callback.Ask(name, ...)
	local asked = target(name)
	if asked == nil then
		return Result.Err('invalid_name', 'a callback name is a string or { name = ... }')
	end
	return Native.Call('net.call', Callback.NEEDS, asked, ...)
end

--- Asks the server and waits for the answer. Must run inside a CreateThread.
--
-- `value` is the handler's FIRST return value, which is what almost every
-- handler has. A handler that returns several is not lost: `values` is the
-- packed list, `n` and all. Two fields rather than one ambiguous field, because
-- a Result whose shape changed with the callee's arity would be unusable.
--
-- THE `await` IS NOT WRAPPED IN A pcall, and that is not an oversight twice
-- over. First, `await` does not raise on a rejection: it answers
-- `nil, reason` -- callback_timeout and callback_not_found arrive as ordinary
-- returns. Second, a yield is not safe across a pcall boundary in this runtime,
-- so guarding it would trade a failure mode that does not exist for one that
-- does.
-- @author dop42
-- @param name string|table
-- @param ... any
-- @return table a Result
function Callback.AskAwait(name, ...)
	local pending = Callback.Ask(name, ...)
	if not pending.ok then return pending end

	local promise = pending.value
	if type(promise) ~= 'table' or type(promise.await) ~= 'function' then
		return Result.Err('no_promise', 'Open77.net.call did not answer a promise')
	end

	local held = table.pack(promise:await())

	-- A rejection is `nil` plus the reason. A handler that legitimately answered
	-- nil is indistinguishable from one that failed, which is the platform's
	-- shape and not something this module can improve on -- so the reason
	-- decides, and an answer with no reason is an answer.
	if held[1] == nil and held[2] ~= nil then
		return Result.Err(tostring(held[2]), 'the server never answered')
	end

	local answer = Result.Ok(held[1])
	answer.values = held
	return answer
end

--- Answers a question the server asks with callClient.
--
-- The handler receives the call's arguments and no source: the caller is always
-- the server. Whatever it returns becomes the answer; raising rejects the
-- server's promise with the error text.
-- @author dop42
-- @param name string
-- @param handler function
-- @return table a Result
function Callback.Answer(name, handler)
	local named = Validate.Text(name, 128)
	if named == nil then return Result.Err('invalid_name', 'no callback name given') end
	if type(handler) ~= 'function' then
		return Result.Err('invalid_handler', 'a callback needs a function to answer with')
	end
	return Native.Call('net.register', Callback.NEEDS, named, handler)
end

--- Stops answering a question.
-- @author dop42
-- @param name string
-- @return table a Result
function Callback.Silence(name)
	local named = Validate.Text(name, 128)
	if named == nil then return Result.Err('invalid_name', 'no callback name given') end
	return Native.Call('net.unregister', Callback.NEEDS, named)
end

return Callback
