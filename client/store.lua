--- Small values that survive a relaunch, on this machine, for this server.
-- @author dop42
--
--   Lib.Store.Set('hud_position', 'bottom_right')
--   local where = Lib.Store.Get('hud_position', 'top_left')
--
-- Wraps `Open77.kvp.*`. No permission.
--
-- READ THE NAMESPACE BEFORE USING IT, because it decides what this is for. The
-- store is keyed by CONNECTION ADDRESS and by RESOURCE. Connecting to
-- `1.2.3.4:11777` and to `localhost:11777` therefore makes two independent
-- stores even when both reach the same server, and two resources never see each
-- other's keys.
--
-- SO THIS IS NOT A DATABASE AND NOT AN IDENTITY. It lives on the player's disk,
-- the player can edit it, and it does not follow them to another machine.
-- Anything the server must be able to trust belongs on the server. What this is
-- genuinely good at is the per-machine preference: where the HUD sits, whether
-- a hint has been dismissed, which tab was open last -- things that should
-- survive a relaunch and that nobody would cheat by editing.
--
-- VALUES ARE TYPED AND SMALL: a string, a signed integer, a finite number or a
-- boolean, inside a 1 MiB quota per resource. There is no table storage, on
-- purpose -- a caller who wants one is describing state the server should own,
-- or should encode it themselves and accept that they are storing a string.

local Native = require('@opx_lib/client.native')
local Validate = require('@opx_lib/pure.validate')
local Result = require('@opx_lib/pure.result')

local Store = {}

--- No manifest permission is checked for this module.
Store.NEEDS = nil

--- Reads one value, or the fallback when it is not there.
--
-- Answers the value directly rather than a Result, and takes a fallback. A
-- preference read is the one call where the caller always has an answer in mind
-- for "not set", and making them unwrap a Result to write `or 'top_left'` is
-- ceremony for nothing. `Has` is there for the caller who genuinely needs to
-- tell absence from a stored value that happens to equal the fallback.
-- @author dop42
-- @param key string
-- @param fallback any answered when the key is absent or unreadable
-- @return any
function Store.Get(key, fallback)
	local named = Validate.Text(key, 128)
	if named == nil then return fallback end

	local native = Native.Reach('kvp.get')
	if native == nil then return fallback end

	local read, value = pcall(native, named)
	if not read or value == nil then return fallback end
	return value
end

--- Whether a key is stored at all.
-- @author dop42
-- @param key string
-- @return boolean
function Store.Has(key)
	local sentinel = {}
	return Store.Get(key, sentinel) ~= sentinel
end

--- Persists one typed value.
--
-- A write can genuinely fail -- a bad type, or the resource's 1 MiB quota -- and
-- a caller that silently lost a preference has a bug nobody will report, so
-- this one answers a Result.
-- @author dop42
-- @param key string
-- @param value string|number|integer|boolean
-- @return table a Result
function Store.Set(key, value)
	local named = Validate.Text(key, 128)
	if named == nil then return Result.Err('invalid_key', 'a store key is 1 to 128 bytes') end

	local kind = type(value)
	if kind ~= 'string' and kind ~= 'number' and kind ~= 'boolean' then
		return Result.Err('invalid_value',
			'a store value is a string, a number or a boolean -- never a table')
	end
	if kind == 'number' and (value ~= value or value == math.huge or value == -math.huge) then
		return Result.Err('invalid_value', 'a store value must be a finite number')
	end

	return Native.Call('kvp.set', Store.NEEDS, named, value)
end

--- Deletes one key.
--
-- Answers Ok either way, with `value` saying whether anything was there:
-- deleting a key that is already gone is a success, not a failure, and every
-- caller that treated it as one had to write the check twice.
-- @author dop42
-- @param key string
-- @return table a Result carrying whether the key existed
function Store.Delete(key)
	local named = Validate.Text(key, 128)
	if named == nil then return Result.Err('invalid_key', 'no store key given') end

	local native = Native.Reach('kvp.delete')
	if native == nil then return Result.Err('native_not_found', 'Open77.kvp.delete is not available') end

	local ran, existed = pcall(native, named)
	if not ran then return Result.Err('native_raised', tostring(existed)) end
	return Result.Ok(existed == true)
end

--- Every key this consumer has stored under a prefix, sorted.
-- @author dop42
-- @param prefix string|nil
-- @return table a Result carrying an array of keys
function Store.Keys(prefix)
	return Native.Call('kvp.keys', Store.NEEDS, prefix or '')
end

return Store
