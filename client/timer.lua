--- Waiting, debouncing and throttling, without writing a thread each time.
-- @author dop42
--
--   Lib.Timer.After(2000, function() ... end)
--   local save = Lib.Timer.Debounce(500, writeToStore)
--
-- No permission: the scheduling globals are ungated. The module is separated
-- from the pure ones because it DOES touch the host -- `SetTimeout`,
-- `CreateThread` and `Wait` -- and because everything it returns is a closure,
-- which means none of it survives an export. It is for a consumer's own VM.
--
-- WHY DEBOUNCE AND THROTTLE ARE THE TWO. They are the difference between a
-- resource that costs nothing and one that floods: a state-bag handler, a
-- WebUI message pump and a tick-driven distance check all fire far more often
-- than the work behind them is worth doing. Written by hand each time, they are
-- also where the off-by-one lives -- a debounce that fires the first call as
-- well as the last, a throttle that drops the final call and never catches up.
--
--   Debounce: runs ONCE, after the calls stop. The last call wins.
--   Throttle: runs at most once per window, and the FIRST call goes straight
--             through -- a throttle that swallowed the first call would make a
--             button feel broken.

local Timer = {}

--- No manifest permission is needed for this module.
Timer.NEEDS = nil

--- Runs a function once, after a delay. Answers a handle for `Cancel`.
-- @author dop42
-- @param delay integer milliseconds
-- @param run function
-- @return any|nil a timer handle, or nil if the arguments were wrong
function Timer.After(delay, run)
	local ms = tonumber(delay)
	if ms == nil or ms ~= ms or ms < 0 or type(run) ~= 'function' then return nil end
	return SetTimeout(ms, run)
end

--- Cancels a timer from `After`.
-- @author dop42
-- @param handle any
-- @return boolean
function Timer.Cancel(handle)
	if handle == nil then return false end
	local ok = pcall(ClearTimeout, handle)
	return ok
end

--- Wraps a function so it runs only once the calls stop.
--
-- Each call restarts the clock; the arguments of the LAST call are the ones
-- that run. For anything where only the final state matters -- persisting a
-- setting a player is dragging, sending a search box's contents.
-- @author dop42
-- @param wait integer milliseconds of quiet before it runs
-- @param run function
-- @return function
function Timer.Debounce(wait, run)
	local ms = tonumber(wait) or 0
	local pending, latest

	return function(...)
		latest = table.pack(...)
		-- A generation counter rather than ClearTimeout: cancellation is not
		-- guaranteed to be free, and a stale timer that finds it is no longer
		-- the newest simply does nothing.
		pending = (pending or 0) + 1
		local mine = pending

		SetTimeout(ms, function()
			if mine ~= pending then return end
			run(table.unpack(latest, 1, latest.n))
		end)
	end
end

--- Wraps a function so it runs at most once per window.
--
-- The first call runs immediately. Calls inside the window are dropped, and the
-- LAST of them runs when the window closes -- so a stream of updates produces a
-- first frame and a final frame, never a stale one.
-- @author dop42
-- @param window integer milliseconds
-- @param run function
-- @return function
function Timer.Throttle(window, run)
	local ms = tonumber(window) or 0
	local open, trailing = false, nil

	local function close()
		if trailing ~= nil then
			local held = trailing
			trailing = nil
			run(table.unpack(held, 1, held.n))
			SetTimeout(ms, close)
			return
		end
		open = false
	end

	return function(...)
		if open then
			trailing = table.pack(...)
			return
		end
		open = true
		run(...)
		SetTimeout(ms, close)
	end
end

--- Waits until a test answers truthy, or the deadline passes.
--
-- Must run inside a CreateThread: it suspends. Answers what the test answered,
-- or nil on timeout -- so a caller can tell "it became true" from "it never
-- did", which a bare boolean cannot express.
-- @author dop42
-- @param test function
-- @param timeout integer|nil milliseconds, default 5000
-- @param interval integer|nil milliseconds between tries, default 50
-- @return any|nil
function Timer.Until(test, timeout, interval)
	if type(test) ~= 'function' then return nil end

	local deadline = tonumber(timeout) or 5000
	local step = tonumber(interval) or 50
	local waited = 0

	while waited <= deadline do
		local ok, answer = pcall(test)
		if ok and answer then return answer end
		-- Never absent: a spin without a Wait exhausts the client's per-resume
		-- instruction budget and the coroutine dies with no message.
		Wait(step)
		waited = waited + step
	end

	return nil
end

return Timer
