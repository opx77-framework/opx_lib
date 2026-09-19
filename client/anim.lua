--- Emotes and animations, with the local-player trap handled.
-- @author dop42
--
--   Lib.Anim.Self('emote_sit', true)
--   Lib.Anim.On(entityId, 'emote_smoke')
--
-- THE TRAP THIS MODULE EXISTS FOR. `Open77.animations.play` does not work on
-- the local player: their body cannot hold a workspot. The platform's answer is
-- a second native, `playSelf`, which stands an invisible double in for the
-- length of the clip -- a genuinely different mechanism, not a special case.
-- A caller who reaches for `play(myEntity, ...)` gets a refusal that does not
-- explain any of that, so `On` detects the local body and says so.
--
-- NO PERMISSION IS CHECKED in either handler on this build. That is the
-- platform's decision and not a promise: `Anim.NEEDS` is nil, and a future
-- build that gates these would surface through the same rewritten refusal as
-- every other module here.

local Native = require('@opx_lib/client.native')
local Validate = require('@opx_lib/pure.validate')
local Result = require('@opx_lib/pure.result')

local Anim = {}

--- No manifest permission is checked for animations on this build.
Anim.NEEDS = nil

--- Plays an emote on the local player, through the stand-in body.
-- @author dop42
-- @param animation string
-- @param thirdPerson boolean|nil pull the camera out for the clip
-- @return table a Result
function Anim.Self(animation, thirdPerson)
	local name = Validate.Word(animation, 128)
	if name == nil then return Result.Err('invalid_animation', 'animation is not a single word') end
	return Native.Call('animations.playSelf', Anim.NEEDS, name, thirdPerson == true)
end

--- Plays an animation on another body.
--
-- Refuses the local player's own body with a code that names the fix, rather
-- than forwarding the engine's refusal -- which is correct but unexplaining.
-- Entity `0` IS the local body: the platform says so where it documents zones
-- attached to an entity, and it is the one entity id with a fixed meaning.
-- @author dop42
-- @param entity any an entity id, never the local player
-- @param animation string
-- @return table a Result
function Anim.On(entity, animation)
	if entity == nil then return Result.Err('invalid_entity', 'no entity given') end
	if entity == 0 then
		return Result.Err('is_local_player',
			'the local body cannot hold a workspot: use Anim.Self for the local player')
	end

	local name = Validate.Word(animation, 128)
	if name == nil then return Result.Err('invalid_animation', 'animation is not a single word') end

	return Native.Call('animations.play', Anim.NEEDS, entity, name)
end

return Anim
