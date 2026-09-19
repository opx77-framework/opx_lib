--- Who else is here, and where.
-- @author dop42
--
--   for _, other in ipairs(Lib.Players.Nearby(20).value or {}) do ... end
--
-- Wraps `Open77.players.*`. NO PERMISSION: everything here is the identity and
-- placement of bodies the client is already rendering, so the platform gates
-- none of it.
--
-- THIS IS NOT `World.Nearby`, AND THE DIFFERENCE MATTERS. That one runs the
-- engine's targeting search around the local body and finds objects -- scenery,
-- crowd NPCs, traffic. This one walks REPLICATED PLAYER POSITIONS, so it takes
-- an `origin` and can ask about somewhere the player is not standing. Reach for
-- this when the answer is about people.
--
-- A PLAYER ID IS NOT AN ENTITY HANDLE. `playerId` is the network identity and
-- survives; `entity` is this client's local handle for the body and does not --
-- it is invalid the moment the body stops streaming. Persisting an entity id,
-- or sending one to the server as if it named a player, is the mistake the
-- platform warns about and the reason both are on every row rather than one.
--
-- PLAYERS WITHOUT A BODY ARE SKIPPED by `Nearby` and `Closest`, because they
-- have no position to sort by. `All` sees them, which is how a caller tells
-- "nobody is near" from "nobody is connected".

local Native = require('@opx_lib/client.native')
local Validate = require('@opx_lib/pure.validate')
local Result = require('@opx_lib/pure.result')

local Players = {}

--- No manifest permission is checked for this module.
Players.NEEDS = nil

--- Every player this client knows about, ascending by player id.
--
-- Includes players with no body, which is the point: it is the roster, not the
-- proximity search.
-- @author dop42
-- @param options table|nil
-- @return table a Result carrying an array
function Players.All(options)
	return Native.Call('players.all', Players.NEEDS, options)
end

--- The local player's own id.
-- @author dop42
-- @return table a Result carrying the id
function Players.LocalId()
	return Native.Call('players.localId', Players.NEEDS)
end

--- Players with a body within `radius`, nearest first.
--
-- Ties are broken by player id, so "closest" does not flicker between two
-- bodies standing on the same spot -- which is what makes it safe to drive a
-- prompt from. Each row is `{ playerId, entity, distance, position, name,
-- isLocal }`.
--
-- An empty array is an ANSWER: nobody qualified. It is Ok and not a refusal,
-- because a caller iterating it wants to draw nothing, not to handle an error.
-- @author dop42
-- @param radius number metres
-- @param options table|nil { origin, includeSelf, limit }
-- @return table a Result carrying an array
function Players.Nearby(radius, options)
	local metres = Validate.Number(radius, 0, 100000)
	if metres == nil then return Result.Err('invalid_radius', 'radius is not a number') end
	if options ~= nil and Validate.Table(options, 8) == nil then
		return Result.Err('invalid_options', 'options is not a plain table')
	end

	local found = Native.Call('players.nearby', Players.NEEDS, metres, options)
	if not found.ok and found.error == 'refused' then
		-- An empty result comes back falsy through the common path, and "nobody
		-- was near" is not a refusal.
		return Result.Ok({})
	end
	return found
end

--- The nearest player with a body, or a refusal saying nobody qualified.
-- @author dop42
-- @param options table|nil
-- @return table a Result carrying one row
function Players.Closest(options)
	local found = Native.Call('players.closest', Players.NEEDS, options)
	if not found.ok and found.error == 'refused' then
		return Result.Err('not_found', 'no other player has a body nearby')
	end
	return found
end

--- The entity handle of one player's body on this client.
--
-- Answers a refusal rather than nil when the body is not streamed, which is the
-- ordinary case for anyone far away -- and the case a caller most often forgets
-- to handle before passing the handle to an entity API.
-- @author dop42
-- @param playerId any
-- @return table a Result carrying the entity handle
function Players.Entity(playerId)
	if playerId == nil then return Result.Err('invalid_player', 'no player id given') end

	local found = Native.Call('players.entity', Players.NEEDS, playerId)
	if not found.ok and found.error == 'refused' then
		return Result.Err('no_body', 'that player has no streamed body on this client')
	end
	return found
end

--- The player a local entity handle belongs to, if it belongs to one.
-- @author dop42
-- @param entity any
-- @return table a Result carrying the player id
function Players.FromEntity(entity)
	if entity == nil then return Result.Err('invalid_entity', 'no entity given') end

	local found = Native.Call('players.fromEntity', Players.NEEDS, entity)
	if not found.ok and found.error == 'refused' then
		return Result.Err('not_a_player', 'that entity is not a player body')
	end
	return found
end

return Players
