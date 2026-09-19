--- Colours: parsing one an operator typed, and deriving the rest from it.
-- @author dop42
--
--   local accent = Lib.Colour.Parse('#ff3b47')       --> { r = 255, g = 59, b = 71 }
--   local dim    = Lib.Colour.Shade(accent, -0.16)   --> the same hue, darker
--
-- WHAT THIS IS FOR. A server operator wants their own identity colour, and the
-- only thing they should have to supply is one hex. Everything else -- the dim
-- rung, the bright rung, the ground a panel sits on -- is derived, because
-- asking an operator for eight colours gets eight colours that do not belong to
-- each other.
--
-- PARSING IS STRICT AND THAT IS A SECURITY PROPERTY, not tidiness. A colour
-- from a config file is operator input, and it ends up in a stylesheet. If a
-- string can reach CSS, then `#f00;} html { display: none` reaches CSS too.
-- `Parse` therefore answers THREE INTEGERS and never a string: there is no path
-- from what an operator typed to what a page renders, because the typed form is
-- destroyed at the boundary. Whatever builds the `rgb()` builds it from
-- numbers it clamped itself.
--
-- HSL IS THE MIDDLE, not the interface. Deriving a ramp in RGB gives muddy
-- results -- halving each channel of a saturated red gives a brown, not a dark
-- red -- so every derivation below converts to HSL, moves one component, and
-- converts back. Callers never see it unless they ask.

local Colour = {}

--- A byte, clamped and rounded, never NaN.
local function byte(value)
	local number = tonumber(value)
	if number == nil or number ~= number then return 0 end
	if number < 0 then return 0 end
	if number > 255 then return 255 end
	return math.floor(number + 0.5)
end

--- Parses `#RRGGBB` into three integers, or nil.
--
-- The pattern is anchored and exact: six hex digits after one hash, nothing
-- before, nothing after, no three-digit shorthand and no alpha. Every
-- convenience there would be another shape to get wrong, and an operator who
-- typed `#f00` gets told so rather than silently getting a colour.
-- @author dop42
-- @param value any
-- @return table|nil { r, g, b }
function Colour.Parse(value)
	if type(value) ~= 'string' then return nil end
	if value:match('^#%x%x%x%x%x%x$') == nil then return nil end

	return {
		r = tonumber(value:sub(2, 3), 16),
		g = tonumber(value:sub(4, 5), 16),
		b = tonumber(value:sub(6, 7), 16),
	}
end

--- Three integers back into `#RRGGBB`.
--
-- For a log line or a debug read-out. NOT for building a stylesheet: see the
-- header -- a page should be handed numbers and compose the colour itself.
-- @author dop42
-- @param colour table { r, g, b }
-- @return string
function Colour.Hex(colour)
	if type(colour) ~= 'table' then return '#000000' end
	return ('#%02x%02x%02x'):format(byte(colour.r), byte(colour.g), byte(colour.b))
end

--- RGB to HSL. Hue in degrees, saturation and lightness in 0..1.
-- @author dop42
-- @param colour table { r, g, b }
-- @return table { h, s, l }
function Colour.ToHsl(colour)
	if type(colour) ~= 'table' then return { h = 0, s = 0, l = 0 } end

	local r, g, b = byte(colour.r) / 255, byte(colour.g) / 255, byte(colour.b) / 255
	local high = math.max(r, g, b)
	local low = math.min(r, g, b)
	local lightness = (high + low) / 2

	-- A grey has no hue to speak of, and the arithmetic below divides by the
	-- spread -- which is zero here.
	if high == low then return { h = 0, s = 0, l = lightness } end

	local spread = high - low
	local saturation = lightness > 0.5
		and spread / (2 - high - low)
		or spread / (high + low)

	local hue
	if high == r then
		hue = (g - b) / spread + (g < b and 6 or 0)
	elseif high == g then
		hue = (b - r) / spread + 2
	else
		hue = (r - g) / spread + 4
	end

	return { h = hue * 60, s = saturation, l = lightness }
end

--- HSL back to RGB.
-- @author dop42
-- @param hsl table { h, s, l }
-- @return table { r, g, b }
function Colour.FromHsl(hsl)
	if type(hsl) ~= 'table' then return { r = 0, g = 0, b = 0 } end

	local h = (tonumber(hsl.h) or 0) % 360 / 360
	local s = math.min(math.max(tonumber(hsl.s) or 0, 0), 1)
	local l = math.min(math.max(tonumber(hsl.l) or 0, 0), 1)

	if s == 0 then
		local grey = byte(l * 255)
		return { r = grey, g = grey, b = grey }
	end

	local function channel(p, q, t)
		if t < 0 then t = t + 1 end
		if t > 1 then t = t - 1 end
		if t < 1 / 6 then return p + (q - p) * 6 * t end
		if t < 1 / 2 then return q end
		if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
		return p
	end

	local q = l < 0.5 and l * (1 + s) or l + s - l * s
	local p = 2 * l - q

	return {
		r = byte(channel(p, q, h + 1 / 3) * 255),
		g = byte(channel(p, q, h) * 255),
		b = byte(channel(p, q, h - 1 / 3) * 255),
	}
end

--- The same colour, lighter or darker by a lightness offset.
--
-- Moves LIGHTNESS and leaves hue and saturation alone, which is what keeps a
-- derived rung recognisably the same colour. `by` is an absolute offset in
-- 0..1, so -0.16 is "sixteen points darker" and behaves the same whatever the
-- starting colour -- a multiplier would move a dark colour barely at all.
-- @author dop42
-- @param colour table { r, g, b }
-- @param by number -1..1
-- @return table { r, g, b }
function Colour.Shade(colour, by)
	local hsl = Colour.ToHsl(colour)
	hsl.l = math.min(math.max(hsl.l + (tonumber(by) or 0), 0), 1)
	return Colour.FromHsl(hsl)
end

--- The same colour, more or less saturated by a fraction of its own saturation.
--
-- A FRACTION and not an offset, unlike `Shade`, because saturation reads
-- proportionally: 0.75 means "three quarters as saturated" and does the same
-- visible thing to a vivid colour and a muted one. An offset would wash out the
-- muted one completely.
-- @author dop42
-- @param colour table
-- @param fraction number
-- @return table
function Colour.Saturate(colour, fraction)
	local hsl = Colour.ToHsl(colour)
	hsl.s = math.min(math.max(hsl.s * (tonumber(fraction) or 1), 0), 1)
	return Colour.FromHsl(hsl)
end

--- A blend of two colours, in RGB.
--
-- Deliberately RGB and not HSL: a blend is asking "what is between these two",
-- and interpolating hue takes the long way round the wheel half the time --
-- blending red into blue through green is not what anybody meant.
-- @author dop42
-- @param from table
-- @param to table
-- @param amount number 0..1
-- @return table
function Colour.Mix(from, to, amount)
	if type(from) ~= 'table' or type(to) ~= 'table' then return { r = 0, g = 0, b = 0 } end

	local at = math.min(math.max(tonumber(amount) or 0, 0), 1)
	return {
		r = byte(byte(from.r) + (byte(to.r) - byte(from.r)) * at),
		g = byte(byte(from.g) + (byte(to.g) - byte(from.g)) * at),
		b = byte(byte(from.b) + (byte(to.b) - byte(from.b)) * at),
	}
end

--- Perceived brightness, 0..1.
--
-- Weighted 0.299/0.587/0.114, not a plain average: the eye is far more
-- sensitive to green than to blue, so a plain average calls a saturated blue as
-- bright as a saturated green and picks the wrong text colour on both.
-- @author dop42
-- @param colour table
-- @return number
function Colour.Luminance(colour)
	if type(colour) ~= 'table' then return 0 end
	return (byte(colour.r) * 0.299 + byte(colour.g) * 0.587 + byte(colour.b) * 0.114) / 255
end

--- Whichever of two colours reads better on this one.
--
-- The one thing an operator-chosen accent actually breaks: black text on their
-- dark blue, or white text on their pale yellow. 0.55 rather than 0.5 because
-- the eye needs more contrast against a light ground than a dark one.
-- @author dop42
-- @param background table
-- @param onLight table|nil default black
-- @param onDark table|nil default white
-- @return table
function Colour.Contrast(background, onLight, onDark)
	local dark = onLight or { r = 0, g = 0, b = 0 }
	local light = onDark or { r = 255, g = 255, b = 255 }
	return Colour.Luminance(background) > 0.55 and dark or light
end

return Colour
