--- Waiting on several answers at once.
-- @author dop42
--
--   CreateThread(function()
--     local stock = Lib.Callback.Ask('getStock', 'medkit')
--     local price = Lib.Callback.Ask('getPrice', 'medkit')
--     local both = Lib.Async.All({ stock.value, price.value })
--   end)
--
-- WHY SEQUENTIAL AWAITS ARE STILL PARALLEL, which is the whole trick and the
-- reason this module is ten lines rather than a scheduler. A promise is already
-- IN FLIGHT the moment it was created -- `Callback.Ask` sent the question
-- before it returned. Awaiting three of them one after another therefore costs
-- the SLOWEST, not the sum: by the time the first answers, the other two have
-- been travelling for exactly as long.
--
-- So the rule is: create every promise first, THEN pass them here. Creating one
-- inside the loop that awaits would serialise them, and that is the only way to
-- get this wrong.
--
-- BUILT ONLY ON `await`. The platform's promise also has `:next()` and
-- `:status()`, and a `Race` or a `Timeout` would need them -- but their exact
-- contracts are not something this library has verified, and a combinator built
-- on a guessed one fails in somebody else's resource. Two functions that are
-- certainly right beat four that are probably right.
--
-- IT SUSPENDS, so it runs inside a `CreateThread` and nowhere else.

local Result = require('@opx_lib/pure.result')

local Async = {}

--- No manifest permission is checked for this module.
Async.NEEDS = nil

--- Whether a value is something this module can await.
local function awaitable(value)
	return type(value) == 'table' and type(value.await) == 'function'
end

--- Waits for every promise, and fails as soon as one does.
--
-- Answers Ok with a packed list of first values, positionally matching the
-- input. On a failure it answers the reason and `at`, the index that failed --
-- without which a caller holding five promises learns only that something went
-- wrong.
--
-- The promises after a failure are NOT awaited. They are still in flight and
-- still cost nothing extra; abandoning them is the point of failing fast.
-- @author dop42
-- @param promises table a list of promises
-- @return table a Result carrying a list, plus `at` on failure
function Async.All(promises)
	if type(promises) ~= 'table' then
		return Result.Err('invalid_promises', 'pass a list of promises')
	end

	local values = { n = #promises }
	for index = 1, #promises do
		local promise = promises[index]
		if not awaitable(promise) then
			local failed = Result.Err('not_a_promise',
				('entry %d is not a promise'):format(index))
			failed.at = index
			return failed
		end

		local value, reason = promise:await()
		if value == nil and reason ~= nil then
			local failed = Result.Err(tostring(reason),
				('promise %d never answered'):format(index))
			failed.at = index
			return failed
		end
		values[index] = value
	end

	return Result.Ok(values)
end

--- Waits for every promise and reports all of them, successes and failures.
--
-- The other half of `All`, and the one to reach for when a partial answer is
-- still useful -- six shop stalls, and one being down should grey out one stall
-- rather than the whole screen. Nothing here fails: the Result is always Ok and
-- the per-entry Results carry the outcomes.
-- @author dop42
-- @param promises table a list of promises
-- @return table a Result carrying a list of Results
function Async.Settled(promises)
	if type(promises) ~= 'table' then
		return Result.Err('invalid_promises', 'pass a list of promises')
	end

	local out = { n = #promises }
	for index = 1, #promises do
		local promise = promises[index]
		if not awaitable(promise) then
			out[index] = Result.Err('not_a_promise', ('entry %d is not a promise'):format(index))
		else
			local value, reason = promise:await()
			if value == nil and reason ~= nil then
				out[index] = Result.Err(tostring(reason), 'that promise never answered')
			else
				out[index] = Result.Ok(value)
			end
		end
	end

	return Result.Ok(out)
end

return Async
