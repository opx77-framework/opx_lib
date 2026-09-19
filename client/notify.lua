--- Toasts, in one line instead of five.
-- @author dop42
--
--   Lib.Notify.Show('BOUNTY CLAIMED')
--   Lib.Notify.Preset('action_blocked')
--
-- Wraps `Open77.hud.notify`, which writes to Cyberpunk's own five-second side
-- notification rather than to a WebUI surface. That is the reason to prefer it:
-- it looks native, and it costs no browser and no resource dependency.
--
-- THE CONSUMER MUST DECLARE `ui.vanilla.hud`. Permissions are read from the
-- calling resource's manifest, and the caller here is the consumer -- so this
-- library cannot declare it on their behalf. `Notify.NEEDS` carries the name so
-- a consumer can preflight it; a call that fails for want of it answers a
-- Result whose detail is the manifest line to add.
--
-- THE DURATION IS THE ENGINE'S. Five seconds, not configurable, and a caller
-- who wants their own timing wants a WebUI toast instead. Saying so here is
-- cheaper than a `duration` argument that is silently ignored.

local Native = require('@opx_lib/client.native')
local Validate = require('@opx_lib/pure.validate')
local Result = require('@opx_lib/pure.result')

local Notify = {}

--- The manifest permission a consumer must declare to use this module.
Notify.NEEDS = 'ui.vanilla.hud'

--- The channels `Clear` accepts. There is ONE vanilla slot per channel, so
--- clearing empties whatever is in it, including another resource's toast.
Notify.CHANNELS = { 'ingame', 'menu' }

--- Queues a toast.
-- @author dop42
-- @param text string
-- @param options table|nil `replace` to overwrite what is on screen
-- @return table a Result
function Notify.Show(text, options)
	-- Bounded here rather than at the native, so a caller learns which of their
	-- own values was wrong instead of reading `false` back from the engine.
	local line = Validate.Text(text, 512)
	if line == nil then return Result.Err('invalid_text', 'notify text is empty or over 512 bytes') end
	if options ~= nil and Validate.Table(options, 8) == nil then
		return Result.Err('invalid_options', 'notify options is not a plain table')
	end
	return Native.Call('hud.notify', Notify.NEEDS, line, options)
end

--- Queues a toast that replaces whatever is on screen instead of queueing.
-- @author dop42
-- @param text string
-- @return table a Result
function Notify.Replace(text)
	return Notify.Show(text, { replace = true })
end

--- Shows one of the engine's own localized notifications.
--
-- A preset carries its own localized title, which is why `text` is not required
-- alongside it -- and why a preset is the right choice for a refusal the game
-- itself has wording for.
-- @author dop42
-- @param preset string
-- @return table a Result
function Notify.Preset(preset)
	local name = Validate.Word(preset, 64)
	if name == nil then return Result.Err('invalid_preset', 'preset is not a single word') end
	return Native.Call('hud.notify', Notify.NEEDS, nil, { preset = name })
end

--- Empties a vanilla notification channel.
-- @author dop42
-- @param channel string|nil 'ingame' (default) or 'menu'
-- @return table a Result
function Notify.Clear(channel)
	local named = channel == nil and 'ingame' or Validate.OneOf(channel, Notify.CHANNELS)
	if named == nil then return Result.Err('invalid_channel', 'channel is not ingame or menu') end
	return Native.Call('hud.clearNotify', Notify.NEEDS, named)
end

return Notify
