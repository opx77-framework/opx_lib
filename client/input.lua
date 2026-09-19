--- The keyboard: declaring actions on it, and reading it.
-- @author dop42
--
--   Lib.Input.On('job.cancel', 'Cancel the job', 'F6', function() ... end)
--   if Lib.Input.IsDown('LSHIFT') and not Lib.Input.IsCaptured() then ... end
--
-- Declaring and reading are one module because they are one subject and a
-- caller needs both in the same breath: an action is declared once, and the
-- code around it asks whether a surface has the keyboard before it acts.
--
-- THE CONSUMER MUST DECLARE `input.actions`. `Open77.input` is only installed
-- when the manifest grants it, so on a consumer who forgot, the namespace is
-- absent rather than refusing -- which is why every reader below checks that
-- the function is there before calling it.
--
-- WRITERS ANSWER A Result, READERS ANSWER THE SAFE VALUE. That split is
-- deliberate. `On` is a one-off with a real failure worth branching on, so it
-- answers a Result. `IsDown` runs inside a tick and is asked thousands of
-- times; a table per call there is garbage the collector did not need, and a
-- caller writing `if Lib.Input.IsDown('E').value then` is a caller who has been
-- made to work for nothing. It is the same argument `pure/validate.lua` makes
-- for answering nil instead of a Result.
--
-- A FAILED READ ANSWERS THE SAFE VALUE, NOT THE OPTIMISTIC ONE. For capture
-- that means CAPTURED: a key that fires while another surface owns the keyboard
-- types into somebody else's text box, which is worse than a key that does
-- nothing. Every reader below picks its fallback the same way.
--
-- MAPPINGS ARE RESOURCE-OWNED, and because this code runs in the consumer's VM
-- the owner is the CONSUMER. Two resources may declare the same id without
-- colliding, and neither can unregister the other's.

local Native = require('@opx_lib/client.native')
local Validate = require('@opx_lib/pure.validate')
local Result = require('@opx_lib/pure.result')

local Input = {}

--- The manifest permission a consumer must declare to use this module.
Input.NEEDS = 'input.actions'

--- The engine's ceiling, per resource. Documented, not enforced: the count
--- belongs to the consumer's VM and this module is never told about a
--- registration it did not make.
Input.LIMIT = 64

-- ── Declaring ────────────────────────────────────────────────────────────────

--- Declares a rebindable action.
--
-- The engine owns the registry and the per-frame dispatch, which is the reason
-- to use this rather than a polling thread: the mapping appears in the pause
-- menu's KEY BINDINGS tab, the player can rebind it, and the rebind survives.
-- A poll loop offers none of that and costs a tick forever.
--
-- The callback never fires while a page owns the keyboard. That is the engine's
-- rule, and it is the behaviour you want: a keybind that fired while the player
-- was typing into a WebUI input would be a bug in every resource at once.
--
-- `released` makes it a hold key, which is what push-to-talk and any "while
-- held" interaction need.
-- @author dop42
-- @param id string unique within the consumer's resource, at most 64 bytes
-- @param label string shown in the KEY BINDINGS tab, at most 96 bytes
-- @param key string a key name, e.g. 'F6', 'CAPSLOCK'
-- @param pressed function
-- @param released function|nil supplying it makes the action a hold
-- @return table a Result carrying the effective key: the saved rebind, else the default
function Input.On(id, label, key, pressed, released)
	-- The engine's own id alphabet. Checked here so a typo is refused by name
	-- rather than swallowed by a registration that quietly never fires.
	local name = Validate.Text(id, 64)
	if name == nil or name:match('^[%w_%.:%-]+$') == nil then
		return Result.Err('invalid_id',
			'an action id is letters, numbers, _ . : - and at most 64 bytes')
	end
	if Validate.Text(label, 96) == nil then
		return Result.Err('invalid_label', 'an action label is 1 to 96 bytes')
	end
	if Validate.Text(key, 32) == nil then
		return Result.Err('invalid_key', 'no key given')
	end
	if type(pressed) ~= 'function' then
		return Result.Err('invalid_handler', 'an action needs a function to run')
	end
	if released ~= nil and type(released) ~= 'function' then
		return Result.Err('invalid_handler', 'the release handler is not a function')
	end

	return Native.Call('input.registerKeyMapping', Input.NEEDS, {
		id = name,
		name = label,
		key = key,
		-- `hold` and a release callback state the same request twice, so it is
		-- derived rather than asked for: the two cannot disagree.
		hold = released ~= nil,
		onPressed = pressed,
		onReleased = released,
	})
end

--- Removes an action this consumer declared.
-- @author dop42
-- @param id string
-- @return table a Result
function Input.Off(id)
	local name = Validate.Text(id, 64)
	if name == nil then return Result.Err('invalid_id', 'no action id given') end
	return Native.Call('input.unregisterKeyMapping', Input.NEEDS, name)
end

--- Keeps one of the game's own actions off its key, or gives it back.
-- @author dop42
-- @param action string
-- @param blocked boolean
-- @return table a Result
function Input.Block(action, blocked)
	local name = Validate.Text(action, 64)
	if name == nil then return Result.Err('invalid_action', 'no action given') end
	return Native.Call('input.setNativeActionBlocked', Input.NEEDS, name, blocked == true)
end

-- ── Reading ──────────────────────────────────────────────────────────────────

--- Whether another surface holds the keyboard right now.
--
-- No input bridge at all means nothing can be capturing, so that answers false.
-- A reader that RAISES answers true -- the safe value, for the reason in the
-- header.
-- @author dop42
-- @return boolean
function Input.IsCaptured()
	local native = Native.Reach('input.isCaptured')
	if native == nil then return false end

	local read, captured = pcall(native)
	if not read then return true end
	return captured == true
end

--- Whether a key is held down now.
-- @author dop42
-- @param key string
-- @return boolean
function Input.IsDown(key)
	local native = Native.Reach('input.isDown')
	if native == nil then return false end

	-- The reader answers the state and, on a second return, a refusal: a key
	-- name it does not poll answers (nil, reason) rather than raising.
	local read, down, refusal = pcall(native, key)
	if not read or refusal ~= nil then return false end
	return down == true
end

--- The mouse cursor, or nil when it cannot be read.
-- @author dop42
-- @return table|nil with at least `inBounds` and `captured`
function Input.Cursor()
	local native = Native.Reach('input.cursor')
	if native == nil then return nil end

	local read, cursor = pcall(native)
	if not read or type(cursor) ~= 'table' then return nil end
	return cursor
end

--- The key a declared action answers to now, rebinds included.
-- @author dop42
-- @param action string the id it was declared under
-- @return string|nil nil when the key is unknown
function Input.KeyFor(action)
	local native = Native.Reach('input.keyFor')
	if native == nil then return nil end

	local read, key = pcall(native, action)
	if not read or type(key) ~= 'string' or key == '' then return nil end
	return key
end

--- Every key mapping the host knows, across all resources.
--
-- A failed read answers nil rather than an empty list. An empty list is a
-- truthful "nobody registered anything", and a caller that cached the last good
-- copy would wipe it over a read that simply did not happen.
-- @author dop42
-- @return table|nil list of { resource, id, key }
-- @return string|nil the failure
function Input.Mappings()
	local native = Native.Reach('input.mappings')
	if native == nil then return nil, 'no_input' end

	local read, list = pcall(native)
	if not read then return nil, tostring(list) end
	if type(list) ~= 'table' then return nil, 'malformed_answer' end
	return list, nil
end

return Input
