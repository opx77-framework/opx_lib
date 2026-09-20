--- Loads the library the way a consumer does and checks what it answers.
-- @author dop42
--
--   lua tests/run.lua        from the resource root
--
-- TWO PIECES OF MACHINERY, AND NO MORE.
--
-- THE FIRST IS A `require` SHIM. The platform resolves `@opx_lib/pure.thing`
-- against a delivered file set, which exists only in a running client;
-- off-platform there is nothing to resolve it, so `require` is replaced with one
-- that maps the provider-qualified name onto this checkout. That also makes the
-- provider-qualified rule testable: a module that forgot `@opx_lib/` and wrote
-- `require('pure.table')` fails here, because the shim refuses a name it
-- cannot attribute -- which is what the platform does to a consumer, where the
-- short form would search THEIR resource.
--
-- THE SECOND IS A FAKE HOST: an `Open77` table built from a map of paths to
-- functions, plus `CreateThread`/`Wait`/`SetTimeout` on real coroutines. The
-- wrapper modules are testable at all only because none of them captures a
-- native at load time -- they resolve by name, at call time, which is the rule
-- `client/native.lua` argues for. The fake is proof that the rule is kept: a
-- module that captured `Open77.hud.notify` at import would read nil here and
-- every one of its checks would fail.

local failures, checks = 0, 0

local function check(label, ok, detail)
	checks = checks + 1
	if ok then
		print(('  ok   %s'):format(label))
	else
		failures = failures + 1
		print(('  FAIL %s%s'):format(label, detail and ('  -- ' .. tostring(detail)) or ''))
	end
end

local function section(name) print(('\n== %s'):format(name)) end

-- ── the require shim ─────────────────────────────────────────────────────────
local loaded = {}
local realRequire = require

local function shim(name)
	if type(name) ~= 'string' then return nil, 'invalid_module_name' end

	local module = name:match('^@opx_lib/(.+)$')
	if module == nil then
		if name == '@opx_lib' then module = 'init' else
			-- A bare name would search the CONSUMER's resource on the platform.
			-- Inside this library that is always a mistake, so it is one here too.
			return nil, ('unqualified require(%q): use @opx_lib/<module>'):format(name)
		end
	end

	if loaded[module] ~= nil then return loaded[module] end

	local path = module:gsub('%.', '/') .. '.lua'
	local chunk, why = loadfile(path)
	if chunk == nil then return nil, why end

	local value = chunk()
	if value == nil then value = true end
	loaded[module] = value
	return value
end

-- ── the fake host ────────────────────────────────────────────────────────────
local recorded = {}

--- Builds an `Open77` table from `{ ['hud.notify'] = function(...) ... end }`,
--- recording every call so a test can assert what reached the platform.
local function install(handlers)
	recorded = {}
	local root = {}

	for path, answer in pairs(handlers or {}) do
		local parts = {}
		for part in path:gmatch('[^%.]+') do parts[#parts + 1] = part end

		local held = root
		for index = 1, #parts - 1 do
			held[parts[index]] = held[parts[index]] or {}
			held = held[parts[index]]
		end

		held[parts[#parts]] = function(...)
			recorded[#recorded + 1] = { path = path, args = table.pack(...) }
			return answer(...)
		end
	end

	_G.Open77 = root
end

local function lastCall() return recorded[#recorded] end

-- Threads on real coroutines, stepped by hand. `Wait` yields, so a poll loop
-- advances exactly one iteration per `step()` and a test can watch each edge.
local threads = {}
local timeouts = {}

_G.CreateThread = function(run)
	local thread = coroutine.create(run)
	threads[#threads + 1] = thread
	coroutine.resume(thread)
end
_G.Wait = function() coroutine.yield() end
_G.SetTimeout = function(delay, run)
	timeouts[#timeouts + 1] = { delay = delay, run = run }
	return #timeouts
end
_G.ClearTimeout = function(handle)
	if timeouts[handle] then timeouts[handle].run = nil end
end

local function step()
	for _, thread in ipairs(threads) do
		if coroutine.status(thread) == 'suspended' then coroutine.resume(thread) end
	end
end

--- Fires every timer queued so far, in order, and empties the queue.
local function fireTimers()
	local pending = timeouts
	timeouts = {}
	for _, timer in ipairs(pending) do
		if timer.run then timer.run() end
	end
end

-- ── load ─────────────────────────────────────────────────────────────────────
require = shim
local Lib = shim('@opx_lib')
require = realRequire

if type(Lib) ~= 'table' then
	print('the library did not load: ' .. tostring(Lib))
	os.exit(1)
end

section('the library')
do
	check('every pure module is on the table',
		Lib.Result and Lib.Validate and Lib.Table and Lib.String and Lib.Text
		and Lib.Math and Lib.Class and Lib.Locale and Lib.Permission
		and Lib.Array and Lib.Colour and true)
	check('every client module is on the table',
		Lib.Native and Lib.Timer and Lib.Character and Lib.Notify and Lib.Anim
		and Lib.Input and Lib.Marker and Lib.Callback and Lib.Zone and Lib.Rpc
		and Lib.Async and Lib.World and Lib.Players and Lib.Blip and Lib.Store
		and Lib.Camera and Lib.Screen and true)
	check('it carries its own version', type(Lib.VERSION) == 'string')
	check('loading it touched no native', next(recorded) == nil)
end

-- ── Result ───────────────────────────────────────────────────────────────────
section('result')
do
	local R = Lib.Result

	local empty = R.Ok(nil)
	check('an Ok carrying nil is still ok', empty.ok == true and empty.value == nil)

	local failed = R.Err('no-row', 'the table was empty')
	check('an Err carries a branchable code', failed.ok == false and failed.error == 'no-row')

	check('a copy off an export is still recognised',
		R.Is({ ok = true, value = 1 }) and not R.Is({ value = 1 }))

	check('Or answers the fallback for a failure and the value for an answer',
		R.Or(failed, 'fallback') == 'fallback' and R.Or(R.Ok(7), 'fallback') == 7)

	local doubled = R.Map(R.Ok(21), function(value) return value * 2 end)
	check('Map runs on a value', doubled.ok and doubled.value == 42)

	local skipped = R.Map(failed, function() error('never') end)
	check('Map passes a failure through untouched and does not call the mapper',
		skipped.error == 'no-row')

	local raised = R.Map(R.Ok(1), function() error('boom') end)
	check('a raise inside Map is a failure, not an unwind',
		raised.ok == false and raised.error == 'map-raised')
end

-- ── Validate ─────────────────────────────────────────────────────────────────
section('validate')
do
	local V = Lib.Validate

	check('a number in range answers', V.Number('3.5', 0, 10) == 3.5)
	check('a number out of range does not', V.Number(11, 0, 10) == nil)
	check('NaN is refused', V.Number(0 / 0, 0, 10) == nil)
	check('infinity is refused', V.Number(math.huge, 0, math.huge) == nil)

	check('a whole float narrows to an integer', V.Integer(3.0, 1, 10) == 3)
	check('a fractional value is refused rather than rounded', V.Integer(3.4, 1, 10) == nil)

	check('text is bounded in bytes', V.Text('abc', 3) == 'abc' and V.Text('abcd', 3) == nil)
	check('an empty string is not text', V.Text('', 10) == nil)

	check('a word accepts an identifier', V.Word('crate.small_2-a') == 'crate.small_2-a')
	check('a word refuses a path', V.Word('base\\weapons\\x.mesh') == nil)
	check('a word refuses a space', V.Word('two words') == nil)

	check('OneOf takes a set', V.OneOf('trunk', { trunk = true }) == 'trunk')
	check('OneOf takes a list', V.OneOf('trunk', { 'trunk', 'glovebox' }) == 'trunk')
	check('OneOf refuses what is not in it', V.OneOf('boot', { 'trunk' }) == nil)

	check('a table is bounded by entry count, map keys included',
		V.Table({ a = 1, b = 2 }, 2) ~= nil and V.Table({ a = 1, b = 2, c = 3 }, 2) == nil)
	check('a table with a metatable did not come from outside',
		V.Table(setmetatable({}, {})) == nil)
end

-- ── Table ────────────────────────────────────────────────────────────────────
section('table')
do
	local T = Lib.Table

	local original = { a = 1, nested = { deep = { 'x' } } }
	local copy = T.Copy(original)
	copy.nested.deep[1] = 'y'
	check('a copy shares nothing with its original', original.nested.deep[1] == 'x')

	local cyclic = { name = 'root' }
	cyclic.self = cyclic
	local copied = T.Copy(cyclic)
	check('a cycle copies to the same shape rather than recursing',
		copied.self == copied and copied.name == 'root')

	check('Same compares content and not identity', T.Same({ a = { 1, 2 } }, { a = { 1, 2 } }))
	check('Same sees a key the other side does not have',
		not T.Same({ a = 1 }, { a = 1, b = 2 }) and not T.Same({ a = 1, b = 2 }, { a = 1 }))

	check('Keys is sorted, so two walks agree',
		table.concat(T.Keys({ b = 1, a = 1, c = 1 }), ',') == 'a,b,c')
	check('Keys does not raise on mixed types', #T.Keys({ [1] = true, x = true }) == 2)

	check('Count counts map keys, where # answers zero',
		T.Count({ a = 1, b = 2 }) == 2 and #({ a = 1, b = 2 }) == 0)

	local frozen = T.Freeze({ value = 1 })
	check('a frozen table reads through', frozen.value == 1)
	check('and raises on a write rather than dropping it',
		select(1, pcall(function() frozen.value = 2 end)) == false)
end

-- ── String ───────────────────────────────────────────────────────────────────
section('string')
do
	local S = Lib.String

	check('Trim takes both ends', S.Trim('  hello  ') == 'hello')
	check('Trim of whitespace is empty', S.Trim('   ') == '')

	check('Clean replaces every control character', S.Clean('a\nb\tc') == 'a b c')
	check('Clean caps and marks the cut', S.Clean('abcdefgh', 5, '...') == 'ab...')
	check('a replacement is a space, so two words do not become one',
		S.Clean('two\nwords') == 'two words')

	local fields = S.Split('a,,b', ',')
	check('Split keeps an empty field, so the numbering survives',
		#fields == 3 and fields[2] == '')
	check('the separator is literal and not a pattern',
		table.concat(S.Split('a.b', '.'), '|') == 'a|b')

	check('Starts does not allocate a prefix',
		S.Starts('opx_lib', 'opx') and not S.Starts('x', 'opx'))

	check('a signature is stable', S.Signature('payload') == S.Signature('payload'))
	check('and differs for different text', S.Signature('a') ~= S.Signature('b'))
	check('and stays inside 32 bits', S.Signature(string.rep('long', 64)) <= 0xFFFFFFFF)
end

-- ── Math ─────────────────────────────────────────────────────────────────────
section('math')
do
	local M = Lib.Math

	check('Clamp holds the range', M.Clamp(15, 0, 10) == 10 and M.Clamp(-1, 0, 10) == 0)
	check('Clamp answers the low bound for NaN rather than passing it on',
		M.Clamp(0 / 0, 0, 10) == 0)

	check('Round goes to places', M.Round(3.14159, 2) == 3.14)
	-- The reason Round is not `floor(n + 0.5)`: that answers -2 here.
	check('Round is symmetric about zero', M.Round(-2.5) == -3 and M.Round(2.5) == 3)

	check('Lerp walks between two numbers', M.Lerp(0, 10, 0.5) == 5)
	check('and clamps, so an unclamped ratio cannot overshoot',
		M.Lerp(0, 10, 2) == 10 and M.Lerp(0, 10, -1) == 0)

	check('Distance is 3-D',
		M.Distance({ x = 0, y = 0, z = 0 }, { x = 3, y = 4, z = 0 }) == 5)
	check('a malformed point answers nil and never 0', M.Distance(nil, {}) == nil)
	check('Distance2D ignores height, which 3-D distance does not',
		M.Distance2D({ x = 0, y = 0, z = 0 }, { x = 3, y = 4, z = 99 }) == 5)
	check('Near compares against a radius',
		M.Near({ x = 0, y = 0 }, { x = 3, y = 4 }, 5) and not M.Near({ x = 0, y = 0 }, { x = 3, y = 4 }, 4))
end

-- ── Locale ───────────────────────────────────────────────────────────────────
section('locale')
do
	local L = Lib.Locale

	check('Load counts what it accepted', L.Load({ greet = 'Hello %s', n = '%d items' }) == 2)
	check('and refuses a non-string value without raising',
		L.Load({ ok = 'yes', bad = 42 }) == 1)

	L.Load({ greet = 'Hello %s', n = '%d items' })
	check('Get formats', L.Get('greet', 'V') == 'Hello V')
	check('Get with no arguments answers the raw line', L.Get('greet') == 'Hello %s')

	-- The design decision of the module: a gap nobody reports versus a key
	-- somebody reports the first time they see it.
	check('a missing key answers the key, never an empty string', L.Get('nope') == 'nope')
	check('a bad format answers the key rather than raising', L.Get('n', 'not a number') == 'n')

	check('Has answers for a key it holds', L.Has('greet') and not L.Has('nope'))
	check('Set adds one', L.Set('extra', 'x') and L.Get('extra') == 'x')
end

-- ── Text ─────────────────────────────────────────────────────────────────────
section('text')
do
	local T = Lib.Text
	-- 'e' with an acute accent: two bytes, one character. The whole reason this
	-- module is separate from String.
	local accented = 'caf\xC3\xA9'

	check('the fixture really is multi-byte', #accented == 5 and T.Length(accented) == 4)

	-- THE DISTINCTION THE MODULE EXISTS FOR, stated as a check: String bounds
	-- bytes, Text bounds characters, and on this string they disagree.
	check('String cuts it short, because it counts bytes',
		Lib.String.Clean(accented, 4) == 'caf\xC3')
	check('Text keeps all four characters, because it counts characters',
		T.Clean(accented, 4) == accented)

	check('Clean cuts at a character and appends the ellipsis',
		T.Clean('abcdef', 3, '...') == 'abc...')
	check('Clean replaces control characters', T.Clean('a\nb', 10) == 'a b')
	check('Clean stringifies a number rather than refusing it', T.Clean(42, 10) == '42')
	check('Clean answers nil for something that is not text', T.Clean({}, 10) == nil)

	-- Never through the middle of a character: the result would not be valid
	-- UTF-8, and renderers disagree about what to do with that.
	check('Bytes never splits a character',
		T.Bytes(accented, 4) == 'caf' and T.Bytes(accented, 5) == accented)
	check('Bytes leaves a short string alone', T.Bytes('ab', 10) == 'ab')

	check('Span measures the bytes of the first n characters',
		T.Span(accented, 3) == 3 and T.Span(accented, 4) == 5)

	check('Slug lowercases and joins words', T.Slug('My Shop') == 'my-shop')
	check('and refuses rather than mangles', T.Slug('bad/slug') == nil)

	check('Rest joins the words from a position on',
		T.Rest({ 'me', 'walks', 'in', 'slowly' }, 2) == 'walks in slowly')

	check('Switch reads the synonyms',
		T.Switch('on') == true and T.Switch('0') == false)
	-- nil and not false: "they asked for off" is not "they did not say".
	check('and answers nil for a word that says neither', T.Switch('maybe') == nil)
end

-- ── Array ────────────────────────────────────────────────────────────────────
section('array')
do
	local A = Lib.Array
	local rows = { { id = 1, team = 'a' }, { id = 2, team = 'b' }, { id = 3, team = 'a' } }

	check('Filter keeps what passes',
		#A.Filter(rows, function(r) return r.team == 'a' end) == 2)
	check('Map walks in order',
		table.concat(A.Map(rows, function(r) return r.id end), ',') == '1,2,3')

	local found, at = A.Find(rows, function(r) return r.id == 2 end)
	check('Find answers the value and the index', found.id == 2 and at == 2)
	check('and nil when nothing matches', A.Find(rows, function() return false end) == nil)

	check('Any and All read as they say',
		A.Any(rows, function(r) return r.id == 3 end)
		and A.All(rows, function(r) return r.id > 0 end))
	-- Vacuous truth, and it has to be: folding an empty list of conditions is true.
	check('All of an empty list is true', A.All({}, function() return false end))

	check('Fold accumulates',
		A.Fold(rows, function(sum, r) return sum + r.id end, 0) == 6)
	check('Reverse copies', table.concat(A.Reverse({ 1, 2, 3 }), ',') == '3,2,1')

	-- The reason Sorted exists: table.sort is in place, and a list that arrived
	-- from somewhere may be being read elsewhere.
	local original = { 3, 1, 2 }
	local sorted = A.Sorted(original)
	check('Sorted does not disturb the caller order',
		table.concat(sorted, ',') == '1,2,3' and table.concat(original, ',') == '3,1,2')

	check('Unique drops duplicates', #A.Unique({ 1, 2, 2, 3, 1 }) == 3)
	-- Without `by`, two rows describing the same thing are two tables and
	-- neither is a duplicate of the other.
	check('and needs a key for tables',
		#A.Unique(rows) == 3
		and #A.Unique(rows, function(r) return r.team end) == 2)

	local grouped = A.GroupBy(rows, function(r) return r.team end)
	check('GroupBy buckets by a derived key', #grouped.a == 2 and #grouped.b == 1)

	check('Take is bounded by the list', #A.Take({ 1, 2 }, 10) == 2)

	local list = { 'a', 'b', 'c' }
	check('Push appends and answers the length', A.Push(list, 'd') == 4)
	check('Remove takes the first match', A.Remove(list, 'b') and #list == 3)
	-- The point of table.remove over a nil write: a hole stops # and ipairs.
	check('and closes the hole rather than leaving one',
		table.concat(list, ',') == 'a,c,d')
	check('Remove answers false when nothing matched', A.Remove(list, 'zz') == false)
	check('Holds finds a value', A.Holds(list, 'c') and not A.Holds(list, 'b'))

	check('nothing raises on a value that is not a list',
		#A.Map(nil, function() end) == 0 and #A.Filter('nope', function() end) == 0)
end

-- ── Colour ───────────────────────────────────────────────────────────────────
section('colour')
do
	local C = Lib.Colour
	local red = C.Parse('#ff3b47')

	check('Parse answers three integers', red.r == 255 and red.g == 59 and red.b == 71)

	-- STRICT, and it is a security property: a colour from a config file is
	-- operator input, and a string that reaches CSS can carry a stylesheet.
	check('a CSS injection attempt is refused',
		C.Parse('#f00;}html{display:none') == nil)
	check('three-digit shorthand is refused rather than guessed', C.Parse('#f00') == nil)
	check('a missing hash is refused', C.Parse('ff3b47') == nil)
	check('an alpha channel is refused', C.Parse('#ff3b47ff') == nil)
	check('a non-string is refused', C.Parse(255) == nil)

	check('Hex round-trips', C.Hex(red) == '#ff3b47')

	local hsl = C.ToHsl(red)
	check('ToHsl answers a hue in degrees', hsl.h > 350 or hsl.h < 10)
	local back = C.FromHsl(hsl)
	-- Round-tripping through HSL costs at most a byte to rounding.
	check('and FromHsl comes back within a byte',
		math.abs(back.r - red.r) <= 1 and math.abs(back.g - red.g) <= 1
		and math.abs(back.b - red.b) <= 1)

	check('a grey has no hue and does not divide by zero',
		C.ToHsl({ r = 128, g = 128, b = 128 }).s == 0)
	check('and comes back grey', C.FromHsl({ h = 0, s = 0, l = 0.5 }).r == 128)

	local darker = C.Shade(red, -0.2)
	check('Shade darkens', C.Luminance(darker) < C.Luminance(red))
	-- The whole reason derivation goes through HSL: halving RGB channels of a
	-- saturated red gives a brown, not a dark red. The hue must survive.
	check('and keeps the hue', math.abs(C.ToHsl(darker).h - hsl.h) < 1)
	check('Shade clamps at the ends',
		C.Luminance(C.Shade(red, 5)) == 1 and C.Luminance(C.Shade(red, -5)) == 0)

	check('Saturate is a fraction, so it works on a muted colour too',
		C.ToHsl(C.Saturate(red, 0.5)).s < hsl.s)

	local mixed = C.Mix({ r = 0, g = 0, b = 0 }, { r = 255, g = 255, b = 255 }, 0.5)
	check('Mix walks between two colours', mixed.r == 128)
	check('and clamps the amount',
		C.Mix({ r = 0, g = 0, b = 0 }, { r = 255, g = 255, b = 255 }, 9).r == 255)

	-- Weighted, not averaged: the eye is far more sensitive to green than blue.
	check('Luminance weights green above blue',
		C.Luminance({ r = 0, g = 255, b = 0 }) > C.Luminance({ r = 0, g = 0, b = 255 }))

	check('Contrast picks dark text on a pale ground',
		C.Contrast({ r = 250, g = 250, b = 200 }).r == 0)
	check('and light text on a dark one',
		C.Contrast({ r = 20, g = 20, b = 40 }).r == 255)
end

-- ── Class ────────────────────────────────────────────────────────────────────
section('class')
do
	local Class = Lib.Class

	local Zone = Class('Zone')
	function Zone:init(radius) self.radius = radius end
	function Zone:holds(distance) return distance <= self.radius end

	local zone = Zone(10)
	check('an instance carries what init assigned', zone.radius == 10)
	check('and answers its methods', zone:holds(5) and not zone:holds(20))
	check('the class names itself', tostring(Zone) == 'class Zone')

	local Circle = Class('Circle', Zone)
	local circle = Circle(3)
	check('a subclass inherits init', circle.radius == 3)
	check('and inherits methods', circle:holds(1))

	check('Holds answers for the class', Zone.Holds(zone))
	check('and for a parent of the instance', Zone.Holds(circle))
	check('and refuses a plain table', not Zone.Holds({ radius = 1 }))

	function Circle:holds(distance) return Zone.holds(self, distance) and distance > 0 end
	check('an override may name the parent implementation explicitly',
		circle:holds(1) and not circle:holds(0))

	check('a class needs a name', select(1, pcall(Class)) == false)
end

-- ── Native ───────────────────────────────────────────────────────────────────
section('native')
do
	local N = Lib.Native

	_G.Open77 = nil
	check('with no platform at all, Reach refuses rather than raising',
		select(2, N.Reach('hud.notify')) == 'open77_unavailable')
	check('and a call is an ordinary Result, not a crash',
		N.Call('hud.notify', nil, 'x').error == 'open77_unavailable')

	install({
		['hud.notify'] = function() return true end,
		['markers.create'] = function() return '18446744073709551615' end,
		['zones.contains'] = function() return false end,
	})

	check('Reach walks a dotted path', type(N.Reach('hud.notify')) == 'function')
	check('a namespace that is not there is not found',
		select(2, N.Reach('nope.missing')) == 'native_not_found')
	check('a path that lands on a table is not a native',
		select(2, N.Reach('hud')) == 'native_not_found')

	check('a truthy answer becomes an Ok', N.Call('hud.notify', nil, 'x').ok)
	-- The handle is a decimal string and must arrive unconverted.
	check('the answer is passed through untouched',
		N.Call('markers.create', nil, {}).value == '18446744073709551615')

	install({
		['hud.notify'] = function() return false, 'hud_unavailable_on_this_host' end,
		['markers.create'] = function() return nil, 'permission_denied:world.markers' end,
		['boom.now'] = function() error('exploded') end,
	})

	check('a false answer becomes an Err carrying the native reason',
		N.Call('hud.notify', 'ui.vanilla.hud', 'x').error == 'hud_unavailable_on_this_host')

	local denied = N.Call('markers.create', 'world.markers', {})
	check('a permission refusal is rewritten under one code',
		denied.error == 'permission_denied')
	-- The whole point of the rewrite: the consumer cannot read our source to
	-- work out which permission a helper needed, so the detail says it.
	check('and the detail names the manifest line to add',
		denied.detail:find('permission "world.markers"', 1, true) ~= nil)

	check('a native that raises is a Result and not an unwind',
		N.Call('boom.now', nil).error == 'native_raised')
end

-- ── Permission ───────────────────────────────────────────────────────────────
section('permission')
do
	local P = Lib.Permission

	local needs = P.Of({
		A = { NEEDS = 'b.two' },
		B = { NEEDS = 'a.one' },
		C = { NEEDS = 'a.one' },
		D = { NEEDS = nil },
		E = 'not a module',
	})
	check('it reads NEEDS off each module', needs.A == 'b.two' and needs.B == 'a.one')
	check('and skips a module that needs nothing', needs.D == nil and needs.E == nil)

	local list = P.List(needs)
	check('List dedupes and sorts, so two runs print the same line',
		#list == 2 and list[1] == 'a.one' and list[2] == 'b.two')

	check('Line is pasteable',
		P.Line(needs) == 'permissions { "a.one", "b.two" }')
	check('and is nil when nothing is needed, so a caller prints nothing',
		P.Line({}) == nil)

	-- The property that keeps the list honest: it is derived from the modules
	-- themselves, so a new wrapper appears here without anyone editing a list.
	check('the library derives its own needs from its own modules',
		Lib.NEEDS.Notify == 'ui.vanilla.hud'
		and Lib.NEEDS.Marker == 'world.markers'
		and Lib.NEEDS.Input == 'input.actions'
		and Lib.NEEDS.Callback == 'network.events')
	check('a pure module contributes nothing to the manifest line',
		Lib.NEEDS.Table == nil and Lib.NEEDS.Math == nil)
	check('Manifest answers the whole line',
		Lib.Manifest() == 'permissions { "camera.script", "input.actions", '
			.. '"network.events", "screen.effects", "ui.vanilla.hud", '
			.. '"ui.vanilla.map", "world.markers", "world.query" }')
	check('and a module added this release appears in it without anyone '
		.. 'editing a list by hand',
		Lib.NEEDS.Camera == 'camera.script' and Lib.NEEDS.Screen == 'screen.effects')
end

-- ── Notify ───────────────────────────────────────────────────────────────────
section('notify')
do
	install({
		['hud.notify'] = function() return true end,
		['hud.clearNotify'] = function() return true end,
	})

	check('Show sends the text', Lib.Notify.Show('hello').ok and lastCall().args[1] == 'hello')
	check('Replace asks for replacement rather than queueing',
		Lib.Notify.Replace('x').ok and lastCall().args[2].replace == true)
	check('Preset sends a preset and no text',
		Lib.Notify.Preset('action_blocked').ok
		and lastCall().args[1] == nil and lastCall().args[2].preset == 'action_blocked')

	local before = #recorded
	check('empty text is refused', Lib.Notify.Show('').error == 'invalid_text')
	check('over-long text is refused', Lib.Notify.Show(string.rep('x', 513)).error == 'invalid_text')
	check('and neither reached the platform', #recorded == before)

	check('Clear defaults to the ingame channel',
		Lib.Notify.Clear().ok and lastCall().args[1] == 'ingame')
	check('and refuses a channel that does not exist',
		Lib.Notify.Clear('sidebar').error == 'invalid_channel')

	check('the module states the permission it needs', Lib.Notify.NEEDS == 'ui.vanilla.hud')
end

-- ── Anim ─────────────────────────────────────────────────────────────────────
section('anim')
do
	install({
		['animations.playSelf'] = function() return true end,
		['animations.play'] = function() return true end,
	})

	check('Self plays through the stand-in body',
		Lib.Anim.Self('emote_sit', true).ok
		and lastCall().path == 'animations.playSelf' and lastCall().args[2] == true)
	check('thirdPerson is always a boolean, never nil',
		Lib.Anim.Self('emote_sit').ok and lastCall().args[2] == false)
	check('an animation name is a single word', Lib.Anim.Self('two words').error == 'invalid_animation')

	local before = #recorded
	-- The trap the module exists for: the local body cannot hold a workspot.
	check('On refuses the local body with a code that names the fix',
		Lib.Anim.On(0, 'emote_smoke').error == 'is_local_player')
	check('and does not bother the platform with it', #recorded == before)

	check('On plays on another body', Lib.Anim.On(42, 'emote_smoke').ok
		and lastCall().path == 'animations.play')
	check('animations need no permission on this build', Lib.Anim.NEEDS == nil)
end

-- ── Input ────────────────────────────────────────────────────────────────────
section('input: declaring')
do
	install({
		['input.registerKeyMapping'] = function() return 'F6' end,
		['input.unregisterKeyMapping'] = function() return true end,
		['input.setNativeActionBlocked'] = function() return true end,
	})

	local made = Lib.Input.On('job.cancel', 'Cancel the job', 'F6', function() end)
	check('On answers the effective key', made.ok and made.value == 'F6')
	check('and sends the spec table', lastCall().args[1].id == 'job.cancel')
	check('hold is false without a release handler', lastCall().args[1].hold == false)

	Lib.Input.On('ptt', 'Push to talk', 'CAPSLOCK', function() end, function() end)
	check('and true with one, derived so the two cannot disagree',
		lastCall().args[1].hold == true)

	local before = #recorded
	check('an id outside the engine alphabet is refused',
		Lib.Input.On('bad id!', 'x', 'F6', function() end).error == 'invalid_id')
	check('a missing handler is refused',
		Lib.Input.On('ok.id', 'x', 'F6', nil).error == 'invalid_handler')
	check('a label over 96 bytes is refused',
		Lib.Input.On('ok.id', string.rep('x', 97), 'F6', function() end).error == 'invalid_label')
	check('and none of them reached the platform', #recorded == before)

	check('Off unregisters by id', Lib.Input.Off('job.cancel').ok)
	check('Block takes an action and a boolean',
		Lib.Input.Block('jump', true).ok and lastCall().args[2] == true)
	check('the module states the permission it needs', Lib.Input.NEEDS == 'input.actions')
end

section('input: reading')
do
	install({
		['input.isCaptured'] = function() return true end,
		['input.isDown'] = function(key) return key == 'E' end,
		['input.cursor'] = function() return { inBounds = true, captured = false } end,
		['input.keyFor'] = function() return 'F7' end,
		['input.mappings'] = function() return { { resource = 'r', id = 'a', key = 'F1' } } end,
	})

	-- Readers answer the plain value, not a Result: they run inside a tick, and
	-- a table per call there is garbage the collector did not need.
	check('IsCaptured answers a bare boolean', Lib.Input.IsCaptured() == true)
	check('IsDown answers a bare boolean',
		Lib.Input.IsDown('E') == true and Lib.Input.IsDown('Q') == false)
	check('Cursor answers the table', Lib.Input.Cursor().inBounds == true)
	check('KeyFor answers the effective key', Lib.Input.KeyFor('a') == 'F7')
	check('Mappings answers the list', #Lib.Input.Mappings() == 1)

	install({
		['input.isCaptured'] = function() error('bridge exploded') end,
		['input.isDown'] = function() return nil, 'unknown_key' end,
		['input.cursor'] = function() return 'not a table' end,
		['input.keyFor'] = function() return '' end,
		['input.mappings'] = function() return 'not a table' end,
	})

	-- The header's rule: a failed read answers the SAFE value, not the
	-- optimistic one. A key firing while another surface owns the keyboard
	-- types into somebody else's text box.
	check('a reader that raises answers captured, the safe value',
		Lib.Input.IsCaptured() == true)
	check('a key the host does not poll is not down', Lib.Input.IsDown('NOPE') == false)
	check('a malformed cursor is nil', Lib.Input.Cursor() == nil)
	check('an empty key is nil and not an empty string', Lib.Input.KeyFor('a') == nil)
	-- nil and not {}: an empty list is a truthful "nobody registered anything",
	-- and a caller holding the last good copy would wipe it over a failed read.
	check('a malformed mappings answer is nil with a reason',
		select(1, Lib.Input.Mappings()) == nil
		and select(2, Lib.Input.Mappings()) == 'malformed_answer')

	_G.Open77 = {}
	check('with no input bridge, nothing is capturing', Lib.Input.IsCaptured() == false)
	check('and no key is down', Lib.Input.IsDown('E') == false)
	check('and Mappings says why', select(2, Lib.Input.Mappings()) == 'no_input')
end

-- ── Marker ───────────────────────────────────────────────────────────────────
section('marker: the catalogue')
do
	check('the eight documented shapes are the ones the door accepts',
		#Lib.Marker.SHAPES == 8 and Lib.Marker.SHAPES[1] == 'ring'
		and Lib.Marker.SHAPES[8] == 'sphere')
	check('and the four documented palettes',
		#Lib.Marker.STYLES == 4 and Lib.Marker.STYLES[1] == 'interaction'
		and Lib.Marker.STYLES[4] == 'danger')
	check('the platform quotas are written down',
		Lib.Marker.LIMIT == 64 and Lib.Marker.SLOTS == 256
		and Lib.Marker.MAX_EXTENT == 200 and Lib.Marker.ALPHA == 180)

	install({ ['markers.shapes'] = function() return { 'ring', 'sphere' } end })
	local shapes = Lib.Marker.Shapes()
	check('Shapes asks the build rather than answering the static list',
		shapes.ok and #shapes.value == 2)
	check('and sends nothing with it', lastCall().args.n == 0)

	-- The asymmetry that matters: everything else in the namespace is gated on
	-- world.markers and shapes() is gated on nothing, so a refusal from it must
	-- NOT be rewritten into "add world.markers", which would fix nothing.
	install({
		['markers.shapes'] = function() return nil, 'permission_denied:world.markers' end,
		['markers.create'] = function() return nil, 'permission_denied:world.markers' end,
	})
	local refused = Lib.Marker.Shapes()
	check('a refusal from the ungated call is passed through unrewritten',
		refused.error == 'permission_denied:world.markers'
		and refused.detail:find('add permission', 1, true) == nil)
	local gated = Lib.Marker.Place({ x = 0, y = 0, z = 0 })
	check('while a gated one still names the manifest line to add',
		gated.error == 'permission_denied'
		and gated.detail:find('permission "world.markers"', 1, true) ~= nil)
	check('and the module states that permission for Lib.Manifest()',
		Lib.Marker.NEEDS == 'world.markers')
	check('while recording which of its functions needs none',
		Lib.Marker.UNGATED[1] == 'Shapes')

	_G.Open77 = {}
	check('on a build without the catalogue native, Shapes says so rather '
		.. 'than answering a confident wrong list',
		Lib.Marker.Shapes().error == 'native_not_found')
end

section('marker: the door')
do
	install({
		['markers.create'] = function() return '18446744073709551615' end,
		['markers.update'] = function() return true end,
		['markers.remove'] = function() return true end,
		['markers.clear'] = function() return true end,
	})

	local function placed(options)
		return Lib.Marker.Place({ x = 0, y = 0, z = 0 }, options)
	end
	local function sent() return lastCall().args[1] end

	local made = Lib.Marker.Place({ x = 1.5, y = 2.5, z = 3.5 }, { radius = 1.5 })
	check('Place answers the handle as the string it is',
		made.ok and made.value == '18446744073709551615')
	check('and forwards the options', sent().radius == 1.5)
	check('and rebuilds the position rather than passing the caller table',
		sent().position.x == 1.5)

	Lib.Marker.Place({ x = 0, y = 0, z = 0 }, { position = { x = 99, y = 99, z = 99 } })
	check('options cannot smuggle in a second position', sent().position.x == 0)

	local before = #recorded
	check('a position that is not finite is refused',
		Lib.Marker.Place({ x = 0 / 0, y = 0, z = 0 }).error == 'invalid_position')
	check('a missing position is refused by the platform\'s own word for it',
		Lib.Marker.Place(nil).error == 'position_required')
	check('and neither reached the platform', #recorded == before)

	-- Shapes and styles: refused here, by name, and without a native call.
	before = #recorded
	local badShape = placed({ shape = 'sqaure' })
	check('an unknown shape is refused with the platform\'s code',
		badShape.error == 'unsupported_shape')
	check('and the refusal lists the eight that would have worked',
		badShape.detail:find('checkpoint', 1, true) ~= nil)
	local badStyle = placed({ style = 'warning' })
	check('an unknown style is refused with the platform\'s code',
		badStyle.error == 'unknown_marker_style')
	check('and neither reached the platform', #recorded == before)
	check('every documented shape is accepted', (function()
		for _, shape in ipairs(Lib.Marker.SHAPES) do
			if not placed({ shape = shape }).ok then return false end
		end
		return true
	end)())
	check('every documented style is accepted', (function()
		for _, style in ipairs(Lib.Marker.STYLES) do
			if not placed({ style = style }).ok then return false end
		end
		return true
	end)())

	-- Each bound at both ends, from the documented options table.
	check('radius holds at 0.1 and 50', placed({ radius = 0.1 }).ok
		and placed({ radius = 50 }).ok)
	check('and is refused just outside either end, by name',
		placed({ radius = 0.09 }).error == 'invalid_radius'
		and placed({ radius = 50.01 }).error == 'invalid_radius')
	check('height holds at 0.01 and 100', placed({ height = 0.01 }).ok
		and placed({ height = 100 }).ok)
	check('and is refused just outside either end, by name',
		placed({ height = 0.009 }).error == 'invalid_height'
		and placed({ height = 100.01 }).error == 'invalid_height')
	check('each scale axis holds at 0.01 and 100',
		placed({ scale = { x = 0.01, y = 0.01, z = 0.01 } }).ok
		and placed({ radius = 0.1, scale = { x = 100, y = 100, z = 100 } }).ok)
	check('and each axis is refused just outside either end',
		placed({ scale = { x = 0.009 } }).error == 'invalid_scale'
		and placed({ scale = { y = 100.01 } }).error == 'invalid_scale'
		and placed({ scale = { z = 0 } }).error == 'invalid_scale')
	check('maxDistance holds at 1 and 500', placed({ maxDistance = 1 }).ok
		and placed({ maxDistance = 500 }).ok)
	check('and is refused just outside either end',
		placed({ maxDistance = 0.99 }).error == 'invalid_distance'
		and placed({ maxDistance = 500.01 }).error == 'invalid_distance')
	check('minDistance holds at zero and is refused below it',
		placed({ minDistance = 0 }).ok
		and placed({ minDistance = -0.01 }).error == 'invalid_distance')

	-- Cross-field, using the documented defaults for what a create omitted.
	check('a minDistance at or past the default maxDistance is refused',
		placed({ minDistance = 100 }).error == 'invalid_distance'
		and placed({ minDistance = 99.9 }).ok)
	check('and the pair is checked when both are given',
		placed({ minDistance = 40, maxDistance = 30 }).error == 'invalid_distance'
		and placed({ minDistance = 20, maxDistance = 30 }).ok)
	check('a patch naming only one of the pair is left to the engine, which '
		.. 'holds the stored other half',
		Lib.Marker.Move('1', { minDistance = 400 }).ok)

	local huge = placed({ radius = 50, scale = { x = 5 } })
	check('an effective dimension over the 200 m cap is refused',
		huge.error == 'invalid_scale' and huge.detail:find('200 m cap', 1, true) ~= nil)

	-- Colour.
	check('colour channels hold at 0 and 255',
		placed({ color = { r = 0, g = 0, b = 0, a = 0 } }).ok
		and placed({ color = { r = 255, g = 255, b = 255, a = 255 } }).ok)
	check('and are refused just outside either end',
		placed({ color = { r = -1, g = 0, b = 0 } }).error == 'invalid_color'
		and placed({ color = { r = 0, g = 256, b = 0 } }).error == 'invalid_color'
		and placed({ color = { r = 0, g = 0, b = 0, a = 256 } }).error == 'invalid_color')
	placed({ color = { r = 1, g = 2, b = 3 } })
	check('an omitted alpha is left to the engine rather than filled in here',
		sent().color.a == nil)
	placed({ color = '#ff3b47' })
	check('a hex string is converted to the bytes the native wants',
		sent().color.r == 255 and sent().color.g == 59 and sent().color.b == 71)
	check('a malformed hex string is refused',
		placed({ color = '#f00' }).error == 'invalid_color')
	Lib.Marker.Move('1', { color = false })
	check('color = false survives the door, because that is how a palette is '
		.. 'restored', lastCall().args[2].color == false)

	-- Everything else.
	check('a rotation is accepted unwrapped, because the engine wraps it',
		placed({ rotation = { z = 450 } }).ok)
	check('but a rotation that is not finite is refused',
		placed({ rotation = { z = 0 / 0 } }).error == 'invalid_rotation')
	local typo = placed({ colour = { r = 1, g = 2, b = 3 } })
	check('a misspelled field is named rather than silently ignored',
		typo.error == 'unknown_field' and typo.detail:find('colour', 1, true) ~= nil)
	check('visible must be a boolean',
		placed({ visible = false }).ok and placed({ visible = 0 }).error == 'invalid_argument')

	-- The quota.
	install({ ['markers.create'] = function() return nil, 'quota_exceeded' end })
	local full = Lib.Marker.Place({ x = 0, y = 0, z = 0 })
	check('the quota refusal is rewritten to say what the numbers are',
		full.error == 'quota_exceeded' and full.detail:find('64', 1, true) ~= nil
		and full.detail:find('256', 1, true) ~= nil)
end

section('marker: the handle')
do
	install({
		['markers.update'] = function() return true end,
		['markers.remove'] = function() return true end,
		['markers.clear'] = function() return true end,
		['markers.get'] = function() return { id = '1', rendered = true } end,
	})

	local big = '18446744073709551615'
	Lib.Marker.Remove(big)
	check('a 64-bit handle reaches the platform as the exact string it was',
		lastCall().args[1] == big and type(lastCall().args[1]) == 'string')
	Lib.Marker.Move(big, { visible = true })
	check('and so does the one a patch names', lastCall().args[1] == big)
	Lib.Marker.Get(big)
	check('and the one a read names', lastCall().args[1] == big)

	local before = #recorded
	check('a handle that was run through tonumber is refused at the door',
		Lib.Marker.Remove(tonumber(big)).error == 'invalid_marker_id')
	check('and so is one that is not a decimal string at all',
		Lib.Marker.Remove('marker-1').error == 'invalid_marker_id'
		and Lib.Marker.Get('').error == 'invalid_marker_id'
		and Lib.Marker.Await(nil).error == 'invalid_marker_id')
	check('and none of them reached the platform', #recorded == before)

	check('Move patches', Lib.Marker.Move('1', { visible = false }).ok)
	check('an empty patch is refused rather than spent on a native call',
		Lib.Marker.Move('1', {}).error == 'invalid_argument')
	check('Remove takes a handle', Lib.Marker.Remove('1').ok)
	check('Clear takes nothing', Lib.Marker.Clear().ok)
end

section('marker: did it actually draw')
do
	-- The three snapshot fields the whole module is written around. `failed`
	-- is tested before `visible` on purpose: a marker can be both.
	check('a failed snapshot reads as failed even when it is visible',
		Lib.Marker.State({ failed = true, visible = true, rendered = false }) == 'failed')
	check('an invisible one that loaded reads as hidden',
		Lib.Marker.State({ failed = false, visible = false, rendered = true }) == 'hidden')
	check('an attached one reads as rendered',
		Lib.Marker.State({ rendered = true, visible = true }) == 'rendered')
	check('and anything else is pending, which honestly conflates streaming '
		.. 'with distance culling',
		Lib.Marker.State({ rendered = false, visible = true }) == 'pending')
	check('a build whose snapshot carries no failed field cannot claim success',
		Lib.Marker.State({ rendered = false }) == 'pending')
	check('and something that is not a snapshot is not guessed at',
		Lib.Marker.State(nil) == 'unknown' and Lib.Marker.State('1') == 'unknown')

	local fleet = {
		{ id = '1', rendered = true, visible = true },
		{ id = '2', rendered = false, visible = true },
		{ id = '3', rendered = false, visible = true, failed = true,
			error = 'marker_assets_missing' },
	}
	install({ ['markers.list'] = function() return fleet end })

	local all = Lib.Marker.List()
	check('List annotates every snapshot with its state',
		all.ok and all.value[1].state == 'rendered' and all.value[2].state == 'pending'
		and all.value[3].state == 'failed')
	check('and leaves the platform\'s own fields alone, so a newer build\'s '
		.. 'extra ones survive', all.value[3].error == 'marker_assets_missing')
	check('Count answers what the platform owns for this resource',
		Lib.Marker.Count().value == 3)

	local broken = Lib.Marker.Failures()
	check('Failures separates "it never loaded" from "you cannot see it"',
		broken.ok and #broken.value == 1 and broken.value[1].id == '3')

	install({ ['markers.list'] = function() return {} end })
	check('and an empty result is an answer, not a refusal',
		Lib.Marker.Failures().ok and #Lib.Marker.Failures().value == 0)

	-- Await: the point of the module. Runs in a thread because it suspends.
	install({ ['markers.get'] = function() return { id = '7', rendered = true } end })
	local drew = 'unset'
	CreateThread(function() drew = Lib.Marker.Await('7') end)
	check('Await resolves as soon as the mesh is attached',
		drew ~= 'unset' and drew.ok and drew.value.state == 'rendered')

	install({ ['markers.get'] = function()
		return { id = '7', visible = false, rendered = false }
	end })
	CreateThread(function() drew = Lib.Marker.Await('7') end)
	check('a marker the caller turned off resolves rather than waiting forever',
		drew.ok and drew.value.state == 'hidden')

	install({ ['markers.get'] = function()
		return { id = '7', failed = true, error = 'marker_streaming_timeout' }
	end })
	CreateThread(function() drew = Lib.Marker.Await('7') end)
	check('a marker that failed to load answers the reason it failed, so a '
		.. 'handle never passes for a marker',
		not drew.ok and drew.error == 'marker_streaming_timeout'
		and drew.detail:find('failed to load', 1, true) ~= nil)

	install({ ['markers.get'] = function() return { id = '7', failed = true } end })
	CreateThread(function() drew = Lib.Marker.Await('7') end)
	check('and a failure with no reason still fails rather than succeeding',
		not drew.ok and drew.error == 'marker_load_failed')

	install({ ['markers.get'] = function() return nil, 'not_found' end })
	CreateThread(function() drew = Lib.Marker.Await('7') end)
	check('a marker that is gone stops the wait instead of spending it',
		not drew.ok and drew.error == 'not_found')

	install({ ['markers.get'] = function()
		return { id = '7', rendered = false, visible = true }
	end })
	drew = 'unset'
	CreateThread(function() drew = Lib.Marker.Await('7', 200) end)
	check('one that never draws is still pending when the wait starts', drew == 'unset')
	step(); step(); step(); step()
	check('and times out with the platform\'s own word for it',
		drew ~= 'unset' and not drew.ok and drew.error == 'marker_streaming_timeout')
end

-- ── Callback ─────────────────────────────────────────────────────────────────
section('callback')
do
	-- A stand-in for Open77.Promise, and its contract is the one the platform
	-- documents: `await` answers `resolved value, or nil; rejection reason`. It
	-- does NOT raise on a rejection. An earlier version of this fake raised, and
	-- the module was written to match the fake rather than the platform -- the
	-- tests passed and the code was wrong.
	local function promise(...)
		local held = table.pack(...)
		return { await = function() return table.unpack(held, 1, held.n) end }
	end

	install({
		['net.call'] = function() return promise(7, 'extra') end,
		['net.register'] = function() return true end,
		['net.unregister'] = function() return true end,
	})

	local asked = Lib.Callback.Ask('getStock', 'medkit')
	check('Ask hands back the promise rather than awaiting it', asked.ok
		and type(asked.value.await) == 'function')
	check('and forwards the arguments', lastCall().args[2] == 'medkit')

	local answer = Lib.Callback.AskAwait('getStock', 'medkit')
	check('AskAwait answers the first return value', answer.ok and answer.value == 7)
	-- Two fields rather than one ambiguous one: a Result whose shape changed
	-- with the callee's arity would be unusable.
	check('and keeps the rest, so a multi-value handler is not lost',
		answer.values.n == 2 and answer.values[2] == 'extra')

	check('a targeting table is accepted',
		Lib.Callback.Ask({ resource = 'other', name = 'x' }).ok)
	check('a nameless table is not', Lib.Callback.Ask({ resource = 'other' }).error == 'invalid_name')

	-- A rejection arrives as (nil, reason) -- an ordinary return, which is why
	-- the await is not wrapped in a pcall.
	install({ ['net.call'] = function() return promise(nil, 'callback_timeout') end })
	local late = Lib.Callback.AskAwait('slow')
	check('a rejection is a Result carrying the platform reason',
		late.ok == false and late.error == 'callback_timeout')

	-- The ambiguity the platform hands us and this module cannot remove: a
	-- handler that legitimately answered nil looks like one that failed. The
	-- reason decides, so an answer with no reason is an answer.
	install({ ['net.call'] = function() return promise(nil) end })
	check('a handler that answered nil with no reason is an answer, not a failure',
		Lib.Callback.AskAwait('empty').ok == true)

	install({ ['net.call'] = function() return true end })
	check('an answer that is not a promise is refused',
		Lib.Callback.AskAwait('odd').error == 'no_promise')

	install({ ['net.register'] = function() return true end })
	check('Answer registers a handler', Lib.Callback.Answer('confirm', function() end).ok)
	check('and refuses a handler that is not a function',
		Lib.Callback.Answer('confirm', 'nope').error == 'invalid_handler')
	check('the module states the permission it needs', Lib.Callback.NEEDS == 'network.events')
end

-- ── Zone ─────────────────────────────────────────────────────────────────────
section('zone')
do
	local inside = false

	install({
		['zones.contains'] = function() return inside end,
		['character.position'] = function() return 1.0, 2.0, 3.0 end,
	})

	-- THE CASE THE WHOLE `Result` TYPE EXISTS FOR. `contains` answers a real
	-- boolean, so `false` is an ANSWER -- the point is outside -- and routing it
	-- through the falsy-means-refused convention would turn every negative test
	-- into an error.
	local out = Lib.Zone.Contains({ radius = 5 }, { x = 0, y = 0, z = 0 })
	check('outside is an answer and not a refusal', out.ok == true and out.value == false)

	inside = true
	check('inside is an answer too',
		Lib.Zone.Contains({ radius = 5 }, { x = 0, y = 0, z = 0 }).value == true)

	install({ ['zones.contains'] = function() return nil, 'unknown_shape' end })
	check('only nil is a refusal, and it carries the platform reason',
		Lib.Zone.Contains({ shape = 'blob' }, {}).error == 'unknown_shape')

	check('Character.Position packs the three returns into a point',
		(function()
			install({ ['character.position'] = function() return 1.0, 2.0, 3.0 end })
			local at = Lib.Character.Position()
			return at.ok and at.value.x == 1.0 and at.value.z == 3.0
		end)())
	check('and refuses before the character exists',
		(function()
			install({ ['character.position'] = function() return nil end })
			return Lib.Character.Position().error == 'no_character'
		end)())

	-- Watching.
	inside = false
	install({
		['zones.contains'] = function() return inside end,
		['character.position'] = function() return 0.0, 0.0, 0.0 end,
	})

	local entered, exited = 0, 0
	local watch = Lib.Zone.Watch({ radius = 5 }, {
		onEnter = function() entered = entered + 1 end,
		onExit = function() exited = exited + 1 end,
	})
	check('Watch answers a handle', watch.ok and watch.value ~= nil)
	check('and counts as one running watch', Lib.Zone.Count() == 1)

	inside = true
	step()
	check('entering fires onEnter once', entered == 1 and exited == 0)
	step()
	check('and staying inside fires nothing further', entered == 1 and exited == 0)

	inside = false
	step()
	check('leaving fires onExit', entered == 1 and exited == 1)

	check('Unwatch removes it', Lib.Zone.Unwatch(watch.value).ok and Lib.Zone.Count() == 0)
	check('and removing it twice is a refusal, not a silent success',
		Lib.Zone.Unwatch(watch.value).error == 'no_such_watch')

	-- A player already standing inside when the watch is made must still get an
	-- onEnter: seeding `inside` from a test at creation time would skip it, and
	-- after a resource reload that is most zones.
	inside = true
	local late = 0
	local second = Lib.Zone.Watch({ radius = 5 }, { onEnter = function() late = late + 1 end })
	step()
	check('a player already inside when the watch is made still gets onEnter', late == 1)
	Lib.Zone.Unwatch(second.value)

	local raised = 0
	install({
		['zones.contains'] = function() return true end,
		['character.position'] = function() return 0.0, 0.0, 0.0 end,
	})
	local bad = Lib.Zone.Watch({ radius = 5 }, { onEnter = function() error('handler blew up') end })
	local good = Lib.Zone.Watch({ radius = 5 }, { onEnter = function() raised = raised + 1 end })
	step()
	check('a handler that raises does not stop the shared thread',
		raised == 1 and Lib.Zone.Count() == 2)
	Lib.Zone.Unwatch(bad.value)
	Lib.Zone.Unwatch(good.value)

	check('a watch with no handlers is refused',
		Lib.Zone.Watch({ radius = 5 }, {}).error == 'no_handlers')
	check('a handler that is not a function is refused',
		Lib.Zone.Watch({ radius = 5 }, { onEnter = 'nope' }).error == 'invalid_handlers')
	check('zones need no permission', Lib.Zone.NEEDS == nil)
end

-- ── Rpc ──────────────────────────────────────────────────────────────────────
section('rpc')
do
	local function promise(...)
		local held = table.pack(...)
		return { await = function() return table.unpack(held, 1, held.n) end }
	end

	local state = 'running'
	_G.GetResourceState = function() return state end

	install({ ['exports.call'] = function() return promise({ ok = true, value = 7 }) end })
	local answer = Lib.Rpc.Call('other', 'thing', 1, 2)
	check('a good call answers the remote table', answer.ok and answer.value.value == 7)
	check('and forwards the arguments', lastCall().args[3] == 1 and lastCall().args[4] == 2)

	-- THE THREE LEVELS. `answered` is the whole point: only at level 3 does the
	-- caller know the remote's state, so only then may it drop a cache.
	state = 'stopped'
	local down = Lib.Rpc.Call('other', 'thing')
	check('level 1: a resource that is not running never got asked',
		down.error == 'not_running' and down.answered == false)

	state = 'running'
	install({ ['exports.call'] = function() return nil, 'access_denied' end })
	check('level 1: a refused dispatch is not an answer',
		Lib.Rpc.Call('other', 'thing').answered == false)

	install({ ['exports.call'] = function() return promise(nil, 'call_timeout') end })
	local late = Lib.Rpc.Call('other', 'thing')
	check('level 2: a promise that settled with a reason is not an answer',
		late.error == 'call_timeout' and late.answered == false)

	install({ ['exports.call'] = function() return promise({ ok = false, error = 'no_stock' }) end })
	local said = Lib.Rpc.Call('other', 'thing')
	-- The distinction that matters: the remote spoke and said no, so its state
	-- IS known and a caller may act on the refusal.
	check('level 3: the remote refused, and that is an answer',
		said.error == 'no_stock' and said.answered == true)

	install({ ['exports.call'] = function() return promise('not a table') end })
	check('a malformed answer is still an answer',
		Lib.Rpc.Call('other', 'thing').error == 'malformed_answer')

	_G.Open77 = {}
	check('with no exports bridge the call never leaves',
		Lib.Rpc.Call('other', 'thing').error == 'no_exports')

	check('a nameless call is refused', Lib.Rpc.Call('other', '').error == 'invalid_name')
	check('rpc needs no permission of its own', Lib.Rpc.NEEDS == nil)
end

-- ── World ────────────────────────────────────────────────────────────────────
section('world')
do
	install({
		['world.raycast'] = function() return { hit = true, material = 'concrete', distance = 4.2 } end,
		['world.nearby'] = function() return { { kind = 'npc', distance = 3 } } end,
		['world.nearest'] = function() return nil end,
		['world.groundZ'] = function() return 18.0 end,
	})

	local from, to = { x = 0, y = 0, z = 0 }, { x = 10, y = 0, z = 0 }
	local hit = Lib.World.Ray(from, to)
	check('Ray answers the trace', hit.ok and hit.value.material == 'concrete')
	check('Blocked reduces it to the question callers had', Lib.World.Blocked(from, to) == true)

	install({ ['world.raycast'] = function() return { hit = false } end })
	-- A clear line is an answer about the world, not an error to handle.
	check('a miss is an Ok carrying hit = false',
		Lib.World.Ray(from, to).ok and Lib.World.Ray(from, to).value.hit == false)
	check('and Blocked says false', Lib.World.Blocked(from, to) == false)

	install({ ['world.raycast'] = function() return nil, 'permission_denied:world.query' end })
	-- The safe value: a prompt that appears through a wall is worse than one
	-- that does not appear.
	check('a refused read answers not blocked, the safe value',
		Lib.World.Blocked(from, to) == false)

	local before = #recorded
	check('a bad from is refused', Lib.World.Ray(nil, to).error == 'invalid_from')
	check('a bad to is refused', Lib.World.Ray(from, { x = 0 / 0 }).error == 'invalid_to')
	check('and neither reached the platform', #recorded == before)

	install({
		['world.nearby'] = function() return { { kind = 'npc' } } end,
		['world.nearest'] = function() return nil end,
		['world.groundZ'] = function() return 18.0 end,
	})
	check('Nearby passes the radius and the filter',
		Lib.World.Nearby(30, 'puppet').ok
		and lastCall().args[1] == 30 and lastCall().args[2] == 'puppet')
	check('a radius over the engine ceiling is refused',
		Lib.World.Nearby(5000).error == 'invalid_radius')
	check('and a radius of zero is too', Lib.World.Nearby(0).error == 'invalid_radius')

	-- Nothing found is not a refusal to diagnose; it is its own answer.
	check('Nearest says not_found rather than forwarding a bare refusal',
		Lib.World.Nearest(30).error == 'not_found')

	check('GroundZ answers a height', Lib.World.GroundZ({ x = 1, y = 2, z = 3 }).value == 18.0)
	check('the module states the permission it needs', Lib.World.NEEDS == 'world.query')
end

-- ── Players ──────────────────────────────────────────────────────────────────
section('players')
do
	install({
		['players.all'] = function() return { { playerId = 1 }, { playerId = 2 } } end,
		['players.localId'] = function() return 1 end,
		['players.nearby'] = function() return { { playerId = 2, distance = 4.0 } } end,
		['players.closest'] = function() return { playerId = 2 } end,
		['players.entity'] = function() return 77 end,
		['players.fromEntity'] = function() return 2 end,
	})

	check('All is the roster', #Lib.Players.All().value == 2)
	check('LocalId answers our own id', Lib.Players.LocalId().value == 1)
	check('Nearby sorts by distance', Lib.Players.Nearby(20).value[1].distance == 4.0)
	check('Closest answers one row', Lib.Players.Closest().value.playerId == 2)
	check('Entity maps a player to a body', Lib.Players.Entity(2).value == 77)
	check('FromEntity maps back', Lib.Players.FromEntity(77).value == 2)

	install({
		['players.nearby'] = function() return {} end,
		['players.closest'] = function() return nil end,
		['players.entity'] = function() return nil end,
	})
	-- An empty search is an answer: the caller iterating it wants to draw
	-- nothing, not to handle an error.
	check('nobody nearby is an Ok carrying an empty list',
		Lib.Players.Nearby(20).ok and #Lib.Players.Nearby(20).value == 0)
	check('but Closest wanted one row, so absence is a refusal',
		Lib.Players.Closest().error == 'not_found')
	-- The ordinary case for anyone far away, and the one callers forget.
	check('a player with no streamed body is named as such',
		Lib.Players.Entity(2).error == 'no_body')

	check('a bad radius is refused', Lib.Players.Nearby('far').error == 'invalid_radius')
	check('players need no permission', Lib.Players.NEEDS == nil)
end

-- ── Blip ─────────────────────────────────────────────────────────────────────
section('blip')
do
	install({
		['blips.create'] = function() return '18446744073709551615' end,
		['blips.update'] = function() return true end,
		['blips.remove'] = function() return true end,
		['blips.setActive'] = function() return true end,
		['blips.track'] = function() return true end,
		['blips.list'] = function() return {} end,
		['blips.clear'] = function() return true end,
	})

	local pin = Lib.Blip.Place({ x = 10, y = 20, z = 30 }, { label = 'Race', routable = true })
	check('Place answers the handle as the string it is',
		pin.ok and pin.value == '18446744073709551615')
	check('and forwards the options', lastCall().args[1].label == 'Race')
	-- position and entity are exclusive at the native, and a spec carrying both
	-- is refused with a reason that does not say which to drop.
	check('a positional blip never carries an entity', lastCall().args[1].entity == nil)

	Lib.Blip.Follow(42, { label = 'Target', position = { x = 1, y = 1, z = 1 } })
	check('an attached blip never carries a position',
		lastCall().args[1].entity == 42 and lastCall().args[1].position == nil)

	check('a bad position is refused', Lib.Blip.Place({ x = 1 }).error == 'invalid_position')
	check('a missing entity is refused', Lib.Blip.Follow(nil).error == 'invalid_entity')

	check('Move patches', Lib.Blip.Move('1', { label = 'x' }).ok)
	check('SetActive toggles without removing',
		Lib.Blip.SetActive('1', false).ok and lastCall().args[2] == false)
	check('Track selects it', Lib.Blip.Track('1').ok)
	check('Remove takes a handle', Lib.Blip.Remove('1').ok)
	check('List answers what we own', Lib.Blip.List().ok)
	check('Clear takes nothing', Lib.Blip.Clear().ok)
	check('the module states the permission it needs', Lib.Blip.NEEDS == 'ui.vanilla.map')
end

-- ── Store ────────────────────────────────────────────────────────────────────
section('store')
do
	local held = { hud_position = 'bottom_right' }
	install({
		['kvp.get'] = function(key) return held[key] end,
		['kvp.set'] = function(key, value) held[key] = value; return true end,
		['kvp.delete'] = function(key)
			local existed = held[key] ~= nil
			held[key] = nil
			return existed
		end,
		['kvp.keys'] = function() return { 'hud_position' } end,
	})

	-- A preference read always has an answer in mind for "not set", so it takes
	-- a fallback rather than making the caller unwrap a Result.
	check('Get answers the stored value', Lib.Store.Get('hud_position') == 'bottom_right')
	check('and the fallback when absent', Lib.Store.Get('nope', 'top_left') == 'top_left')
	check('Has tells absence from a value equal to the fallback',
		Lib.Store.Has('hud_position') and not Lib.Store.Has('nope'))

	check('Set persists', Lib.Store.Set('tab', 'map').ok and held.tab == 'map')
	check('a number is fine', Lib.Store.Set('size', 3).ok)
	check('a boolean is fine', Lib.Store.Set('seen', true).ok)
	-- No table storage on purpose: a caller who wants one is describing state
	-- the server should own.
	check('a table is refused', Lib.Store.Set('x', {}).error == 'invalid_value')
	check('an infinite number is refused', Lib.Store.Set('x', math.huge).error == 'invalid_value')
	check('an empty key is refused', Lib.Store.Set('', 'x').error == 'invalid_key')

	check('Delete says whether anything was there',
		Lib.Store.Delete('tab').value == true)
	-- Deleting what is already gone is a success, not a failure.
	check('and deleting a missing key is still Ok',
		Lib.Store.Delete('tab').ok and Lib.Store.Delete('tab').value == false)

	check('Keys lists them', #Lib.Store.Keys().value == 1)
	check('the store needs no permission', Lib.Store.NEEDS == nil)
end

-- ── Async ────────────────────────────────────────────────────────────────────
section('async')
do
	local function promise(...)
		local held = table.pack(...)
		return { await = function() return table.unpack(held, 1, held.n) end }
	end

	local all = Lib.Async.All({ promise('a'), promise('b'), promise('c') })
	check('All answers every value, positionally',
		all.ok and all.value[1] == 'a' and all.value[3] == 'c' and all.value.n == 3)
	check('an empty list is an empty answer', Lib.Async.All({}).ok)

	-- `at` matters: a caller holding five promises otherwise learns only that
	-- something went wrong.
	local failed = Lib.Async.All({ promise('a'), promise(nil, 'callback_timeout'), promise('c') })
	check('All fails on the first rejection and names which',
		failed.ok == false and failed.error == 'callback_timeout' and failed.at == 2)

	local wrong = Lib.Async.All({ promise('a'), 'not a promise' })
	check('a non-promise is refused by index',
		wrong.error == 'not_a_promise' and wrong.at == 2)

	-- The other half: one stall being down should grey out one stall.
	local settled = Lib.Async.Settled({ promise('a'), promise(nil, 'gone'), promise('c') })
	check('Settled never fails and reports each outcome',
		settled.ok
		and settled.value[1].ok and settled.value[1].value == 'a'
		and settled.value[2].ok == false and settled.value[2].error == 'gone'
		and settled.value[3].value == 'c')

	check('async needs no permission', Lib.Async.NEEDS == nil)
end

-- ── Camera ───────────────────────────────────────────────────────────────────
-- A promise the fake host hands back. `awaited` is what proves a blend was
-- actually waited on rather than merely returned, which is the difference
-- between "the view was released" and "the view is back".
local function promise(...)
	local held = table.pack(...)
	local it = { awaited = false }
	it.await = function(self)
		local me = self or it
		me.awaited = true
		return table.unpack(held, 1, held.n)
	end
	return it
end

section('camera: what the platform said')
do
	local C = Lib.Camera

	check('the four shake presets are the ones the door accepts',
		#C.SHAKES == 4 and C.SHAKES[1] == 'hand' and C.SHAKES[4] == 'earthquake')
	check('and the four phases a shot passes through',
		#C.PHASES == 4 and C.PHASES[1] == 'idle' and C.PHASES[3] == 'holding')
	check('the platform quotas and bounds are written down',
		C.LIMIT == 16 and C.CLIENT_LIMIT == 64 and C.RANGE == 250
		and C.MIN_FOV == 5 and C.MAX_FOV == 170 and C.MAX_BLEND == 60000
		and C.MAX_AMPLITUDE == 4.0 and C.SHAKE_MS == 500)
	check('and the follow offsets, in the target\'s own frame',
		C.FOLLOW.distance[2] == 100 and C.FOLLOW.height[1] == -50
		and C.FOLLOW.side[2] == 50)

	-- The release rules, which are the reason the module exists.
	local rules = 0
	for _ in pairs(C.RELEASES) do rules = rules + 1 end
	check('every documented release rule has a sentence', rules == 9
		and C.RELEASES.resource_stopped ~= nil and C.RELEASES.player_died ~= nil
		and C.RELEASES.camera_superseded ~= nil and C.RELEASES.world_exit ~= nil)
	check('and the one that costs a caller their definitions says so',
		C.RELEASES.resource_error:find('re-create', 1, true) ~= nil)
	check('Why turns a token into that sentence',
		C.Why('player_died') == C.RELEASES.player_died)
	check('and passes a token it has never heard of through rather than '
		.. 'inventing a meaning for it',
		C.Why('some_newer_build_reason'):find('some_newer_build_reason', 1, true) ~= nil)

	check('the module states its permission for Lib.Manifest()',
		C.NEEDS == 'camera.script')
	check('while recording which of its functions need none',
		C.UNGATED[1] == 'Ray' and C.UNGATED[2] == 'Owner')

	-- The same asymmetry marker has: a refusal from the ungated call must not
	-- be rewritten into "add camera.script", which would fix nothing.
	install({
		['camera.unproject'] = function() return nil, 'permission_denied:camera.script' end,
		['camera.create'] = function() return nil, 'permission_denied:camera.script' end,
	})
	local ray = C.Ray(0.5, 0.5)
	check('a refusal from the ungated call is passed through unrewritten',
		ray.error == 'permission_denied:camera.script'
		and ray.detail:find('add permission', 1, true) == nil)
	local gated = C.Create({ position = { x = 0, y = 0, z = 0 } })
	check('while a gated one names the manifest line to add',
		gated.error == 'permission_denied'
		and gated.detail:find('permission "camera.script"', 1, true) ~= nil)

	_G.Open77 = {}
	check('on a build without the namespace, the module says so rather than '
		.. 'raising inside a consumer\'s handler',
		C.Create({ position = { x = 0, y = 0, z = 0 } }).error == 'native_not_found'
		and C.Take(1).error == 'native_not_found'
		and C.Release().error == 'native_not_found')
end

section('camera: the door')
do
	local C = Lib.Camera

	install({
		['camera.create'] = function() return 3 end,
		['camera.setTransform'] = function() return true end,
		['camera.lookAt'] = function() return true end,
		['camera.attach'] = function() return true end,
		['camera.detachFrom'] = function() return true end,
		['camera.destroy'] = function() return true end,
	})
	local function made(spec) return C.Create(spec) end
	local function sent() return lastCall().args[1] end

	local cam = C.Create({ position = { x = 1.5, y = 2.5, z = 3.5 }, fov = 45 })
	check('Create answers the id the platform gave', cam.ok and cam.value == 3)
	check('and rebuilds the position rather than passing the caller\'s table',
		sent().position.x == 1.5 and sent().fov == 45)

	local before = #recorded
	check('a camera with neither a position nor an attachTo is refused, '
		.. 'because it has no pose at all',
		made({ fov = 45 }).error == 'invalid_camera_position')
	check('but an attachTo alone is a camera', made({ attachTo = 0 }).ok)
	check('a position that is not finite is refused by the platform\'s word',
		made({ position = { x = 0 / 0, y = 0, z = 0 } }).error == 'invalid_camera_position')
	check('and the two refusals never reached the platform', #recorded == before + 1)

	-- The field of view, at both ends, plus the documented escape hatch.
	check('fov holds at 5 and 170', made({ position = { x = 0, y = 0, z = 0 }, fov = 5 }).ok
		and made({ position = { x = 0, y = 0, z = 0 }, fov = 170 }).ok)
	check('and is refused just outside either end, by name',
		made({ position = { x = 0, y = 0, z = 0 }, fov = 4.99 }).error == 'invalid_camera_fov'
		and made({ position = { x = 0, y = 0, z = 0 }, fov = 170.01 }).error == 'invalid_camera_fov')
	C.Create({ position = { x = 0, y = 0, z = 0 }, fov = 0 })
	check('zero is not five degrees: it means leave the engine\'s own alone, '
		.. 'and it reaches the engine as zero', sent().fov == 0)
	check('a fov that is not a number at all is refused',
		made({ position = { x = 0, y = 0, z = 0 }, fov = '45' }).error == 'invalid_camera_fov')

	-- lookAt is the one field where a number and a table are both legal.
	C.Create({ position = { x = 0, y = 0, z = 0 }, lookAt = 0 })
	check('entity 0 is the local player and survives the door as the number it is',
		sent().lookAt == 0)
	check('a negative entity is refused as the entity it meant to be',
		made({ position = { x = 0, y = 0, z = 0 }, lookAt = -1 }).error == 'invalid_entity_id')
	check('a look-at point is refused by the look-at\'s own word',
		made({ position = { x = 0, y = 0, z = 0 }, lookAt = { x = 0, y = 0 } }).error
			== 'invalid_camera_look_at'
		and made({ position = { x = 0, y = 0, z = 0 }, lookAt = 'up' }).error
			== 'invalid_camera_look_at')

	-- Rotation: two forms, told apart by w.
	check('a quaternion is accepted whole',
		made({ position = { x = 0, y = 0, z = 0 },
			rotation = { x = 0, y = 0, z = 0, w = 1 } }).ok)
	check('but three quarters of one is a typo, not a rotation',
		made({ position = { x = 0, y = 0, z = 0 },
			rotation = { x = 0, y = 0, w = 1 } }).error == 'invalid_camera_rotation')
	check('Euler degrees take any subset and are not range-checked, because '
		.. 'the engine wraps them',
		made({ position = { x = 0, y = 0, z = 0 }, rotation = { yaw = 450 } }).ok)
	check('but a NaN angle is refused rather than pointed nowhere',
		made({ position = { x = 0, y = 0, z = 0 }, rotation = { yaw = 0 / 0 } }).error
			== 'invalid_camera_rotation')
	check('an empty rotation table is not a rotation',
		made({ position = { x = 0, y = 0, z = 0 }, rotation = {} }).error
			== 'invalid_camera_rotation')

	local both = made({ position = { x = 0, y = 0, z = 0 }, lookAt = 0,
		rotation = { yaw = 90 } })
	check('a rotation and a lookAt in one definition are two aims, so the '
		.. 'caller is made to pick rather than one winning silently',
		both.error == 'invalid_camera_rotation'
		and both.detail:find('two different aims', 1, true) ~= nil)

	local typo = made({ position = { x = 0, y = 0, z = 0 }, lookat = 0 })
	check('a misspelled field is named rather than silently ignored',
		typo.error == 'invalid_camera_options' and typo.detail:find('lookat', 1, true) ~= nil)

	-- Move: the table form, and the narrower field set.
	check('Move patches a live camera', C.Move(3, { position = { x = 1, y = 2, z = 3 } }).ok)
	check('and takes a fov with it, which the positional form cannot',
		C.Move(3, { fov = 60 }).ok and lastCall().args[2].fov == 60)
	check('an empty patch is refused by the platform\'s own word rather than '
		.. 'spent on a native call',
		C.Move(3, {}).error == 'empty_camera_transform')
	check('and a field only a create has is refused there',
		C.Move(3, { attachTo = 0 }).error == 'invalid_camera_options')

	-- The id is a number here, unlike a marker's decimal string.
	check('a camera id that was run through tostring is refused at the door',
		C.Destroy('3').error == 'invalid_camera_id'
		and C.Move(3.5, { fov = 60 }).error == 'invalid_camera_id'
		and C.Destroy(0).error == 'invalid_camera_id')

	check('Attach needs both arguments, so nobody reaches the no-argument '
		.. 'call that restores the player\'s own camera by accident',
		C.Attach(3).error == 'invalid_entity_id' and C.Attach(3, 0).ok)
	check('and an offset, when given, is a finite point in the parent frame',
		C.Attach(3, 0, { x = 0, y = -1, z = 1 }).ok
		and C.Attach(3, 0, { x = 0 / 0, y = 0, z = 0 }).error == 'invalid_camera_offset')
	check('DetachFrom takes an id', C.DetachFrom(3).ok)
	check('Destroy takes an id', C.Destroy(3).ok)

	install({ ['camera.create'] = function() return nil, 'camera_budget_exhausted' end })
	local full = C.Create({ position = { x = 0, y = 0, z = 0 } })
	check('the budget refusal is rewritten to say what the numbers are',
		full.error == 'camera_budget_exhausted'
		and full.detail:find('16', 1, true) ~= nil and full.detail:find('64', 1, true) ~= nil)
end

section('camera: the blend, at both ends')
do
	local C = Lib.Camera
	install({
		['camera.activate'] = function() return true end,
		['camera.deactivate'] = function() return true end,
	})

	check('blendMs holds at 0 and 60000',
		C.Take(1, { blendMs = 0 }).ok and C.Take(1, { blendMs = 60000 }).ok)
	check('and is refused just outside either end, by the platform\'s word',
		C.Take(1, { blendMs = -1 }).error == 'invalid_blend_ms'
		and C.Take(1, { blendMs = 60001 }).error == 'invalid_blend_ms')
	check('a numeric string is not a number, and neither is NaN or infinity',
		C.Take(1, { blendMs = '600' }).error == 'invalid_blend_ms'
		and C.Take(1, { blendMs = 0 / 0 }).error == 'invalid_blend_ms'
		and C.Take(1, { blendMs = math.huge }).error == 'invalid_blend_ms')
	check('and half a millisecond is not a whole number of them',
		C.Take(1, { blendMs = 1.5 }).error == 'invalid_blend_ms')
	check('the same bound guards the hand-back',
		C.Release({ blendMs = 60000 }).ok
		and C.Release({ blendMs = 60001 }).error == 'invalid_blend_ms')
	check('and an option neither call has is refused by name',
		C.Take(1, { blendms = 400 }).error == 'invalid_camera_options'
		and C.Release({ holdMs = 400 }).error == 'invalid_camera_options')
end

section('camera: who has the view')
do
	local C = Lib.Camera

	install({ ['resource.name'] = function() return 'open77_shop' end })
	check('State answers free when nobody holds the view',
		C.State({ held = false }) == 'free' and C.State({ holder = '' }) == 'free')
	check('mine when the holder is us', C.State({ held = true, holder = 'open77_shop' }) == 'mine')
	check('and theirs when it is somebody else',
		C.State({ held = true, holder = 'open77_creator' }) == 'theirs')
	check('and it decides on the NAME, so it is right under either reading of '
		.. '`held` -- the two sources disagree about that field',
		C.State({ held = false, holder = 'open77_creator' }) == 'theirs')
	check('anything that is not a snapshot is not guessed at',
		C.State(nil) == 'unknown' and C.State('open77_shop') == 'unknown')

	install({ ['camera.cameras'] = function()
		return { held = true, holder = 'open77_creator', phase = 'holding', cameras = {} }
	end })
	check('a build that will not say its own name answers the honestly vague '
		.. '"held" rather than guessing whose it is',
		C.State({ held = true, holder = 'open77_creator' }) == 'held')

	local snap = C.Cameras()
	check('Cameras annotates the snapshot with that state',
		snap.ok and snap.value.state == 'held')
	check('and leaves the platform\'s own fields alone, so a newer build\'s '
		.. 'extra ones survive', snap.value.phase == 'holding')

	local holder = C.Holder()
	check('Holder answers the one question a camera_held_by refusal leaves you '
		.. 'asking', holder.ok and holder.value == 'open77_creator')

	install({ ['camera.cameras'] = function() return { held = false, cameras = {} } end })
	local free = C.Holder()
	check('and Ok(nil) when the view is free, which is an answer and not a '
		.. 'failure', free.ok and free.value == nil)
end

section('camera: a refusal that names the holder')
do
	local C = Lib.Camera

	install({
		['camera.activate'] = function() return false, 'camera_held_by:open77_creator' end,
		['camera.cameras'] = function() return { held = true, holder = 'open77_creator' } end,
	})
	local refused = C.Take(1)
	check('the platform\'s own parameterised code survives as the code',
		refused.error == 'camera_held_by:open77_creator')
	check('and the holder is lifted out of it, onto the Result and into the detail',
		refused.holder == 'open77_creator'
		and refused.detail:find('open77_creator has the view', 1, true) ~= nil)
	check('without spending a native call to learn what the code already said',
		lastCall().path == 'camera.activate')

	install({
		['camera.activate'] = function() return false, 'camera_held' end,
		['camera.cameras'] = function() return { held = true, holder = 'open77_creator' } end,
	})
	local bare = C.Take(1)
	check('the bare refusal is worth one extra read, because "somebody has the '
		.. 'view" is not actionable and a name is',
		bare.error == 'camera_held' and bare.holder == 'open77_creator'
		and lastCall().path == 'camera.cameras')

	install({
		['camera.activate'] = function() return false, 'camera_held' end,
		['camera.cameras'] = function() return nil, 'camera_unavailable_on_this_host' end,
	})
	local quiet = C.Take(1)
	check('and when the build will not say either, it says that rather than '
		.. 'inventing a holder',
		quiet.holder == nil and quiet.detail:find('would not say which', 1, true) ~= nil)

	install({ ['camera.follow'] = function() return nil, 'camera_held_by:open77_admin' end })
	check('follow is refused the same way, because it is not a new way to hold '
		.. 'the view', C.Follow(0).holder == 'open77_admin')

	-- The one refusal the engine cannot name for itself.
	install({ ['camera.activate'] = function() return false, 'invalid_argument' end })
	local far = C.Take(1)
	check('activate\'s bare invalid_argument is rewritten into the streaming '
		.. 'ceiling, which is the only thing left it can mean',
		far.error == 'invalid_argument' and far.detail:find('250 m', 1, true) ~= nil
		and far.detail:find('move the player', 1, true) ~= nil)
end

section('camera: the promise that comes second')
do
	local C = Lib.Camera

	local blend = promise(true)
	install({
		['camera.activate'] = function() return true, blend end,
		['camera.deactivate'] = function() return true, blend end,
		['camera.follow'] = function() return 7, blend end,
		['camera.unfollow'] = function() return true, blend end,
	})

	local took = C.Take(1, { blendMs = 600 })
	check('the Result carries the native\'s FIRST return, untouched',
		took.ok and took.value == true)
	check('and the promise -- which Native.Call would have dropped -- rides '
		.. 'along under blend', took.blend == blend)
	check('Release carries one too', C.Release({ blendMs = 400 }).blend == blend)
	local followed = C.Follow(0, { distance = 5.0 })
	check('and Follow answers the camera id with the blend beside it',
		followed.ok and followed.value == 7 and followed.blend == blend)
	check('as does Unfollow', C.Unfollow().blend == blend)

	install({ ['camera.activate'] = function() return true end })
	local cut = C.Take(1)
	check('a cut settles before the call returns and hands back no promise',
		cut.ok and cut.blend == nil)
	check('and awaiting what a cut gave you is Ok, so no call site needs an if',
		C.Await(cut.blend).ok)

	local landed = promise(true)
	check('Await resolves when the blend lands', C.Await(landed).ok and landed.awaited)

	local died = C.Await(promise(nil, 'player_died'))
	check('a release rejects the promise rather than dropping it, so the '
		.. 'coroutine that was going to tidy up wakes up',
		not died.ok and died.error == 'player_died')
	check('and the reason arrives as the sentence, not just the token',
		died.detail == Lib.Camera.RELEASES.player_died)
end

section('camera: the release guarantee')
do
	local C = Lib.Camera
	local handBack

	local function host(activate, deactivate)
		install({
			['camera.activate'] = activate,
			['camera.deactivate'] = deactivate or function()
				handBack = promise(true)
				return true, handBack
			end,
		})
	end

	-- 1. The ordinary path.
	handBack = nil
	host(function() return true, promise(true) end)
	local ran = false
	local shot = C.Shot(1, { blendMs = 600 }, function()
		ran = true
		return 'done'
	end)
	check('Shot runs the body while it holds the view and answers what the '
		.. 'body answered', ran and shot.ok and shot.value == 'done')
	check('and the view is handed back', lastCall().path == 'camera.deactivate')
	check('and the hand-back blend is AWAITED, so when Shot returns the view '
		.. 'is on the player\'s eyes and not halfway there',
		handBack ~= nil and handBack.awaited and shot.released == true)
	check('the hand-back defaults to the blend the take used, because a shot '
		.. 'that eases in and cuts out is the thing a player notices',
		lastCall().args[1].blendMs == 600)

	-- 2. The path the platform's own rules do not cover.
	handBack = nil
	host(function() return true, promise(true) end)
	local raised = C.Shot(1, { blendMs = 0 }, function() error('the UI blew up') end)
	check('a body that RAISES still gives the view back -- the case a live '
		.. 'resource is in, which no release rule covers',
		lastCall().path == 'camera.deactivate' and raised.released == true)
	check('and the raise is reported rather than swallowed or unwound',
		not raised.ok and raised.error == 'shot_raised'
		and raised.detail:find('the UI blew up', 1, true) ~= nil)

	-- 3. Released underneath us before the shot was ever up.
	handBack = nil
	host(function() return true, promise(nil, 'camera_superseded') end)
	local never = C.Shot(1, { blendMs = 600 }, function()
		ran = 'body ran anyway'
		return true
	end)
	check('a blend that never lands means the shot never happened, so the '
		.. 'body does not run over a view somebody else now owns',
		not never.ok and never.error == 'camera_superseded' and ran ~= 'body ran anyway')
	check('and the view is still handed back on the way out',
		lastCall().path == 'camera.deactivate')

	-- 4. Something released it first. That is success, not failure.
	host(function() return true, promise(true) end,
		function() return false, 'camera_not_active' end)
	local already = C.Shot(1, nil, function() return 1 end)
	check('a hand-back refused with camera_not_active is the outcome we wanted: '
		.. 'a release rule got there first and the view is already back',
		already.ok and already.released == true)

	-- 5. A hand-back refused for any other reason is NOT quietly a success.
	host(function() return true, promise(true) end,
		function() return false, 'camera_unavailable_on_this_host' end)
	local stuck = C.Shot(1, nil, function() return 1 end)
	check('but any other refusal is reported, because a view that did not come '
		.. 'back is the whole thing this module is about',
		stuck.ok and stuck.released == false)

	-- 6. A take that was refused never claims to have released anything.
	install({ ['camera.activate'] = function() return false, 'camera_unavailable' end })
	local before = #recorded
	local no = C.Shot(1, nil, function() return 1 end)
	check('a refused take is passed straight back and nothing is handed back, '
		.. 'because nothing was taken',
		no.error == 'camera_unavailable' and no.released == nil and #recorded == before + 1)

	-- The door on Shot itself.
	host(function() return true, promise(true) end)
	check('Shot(cam, fn) is the same call as Shot(cam, nil, fn)',
		C.Shot(1, function() return 'short' end).value == 'short')
	check('and something that is not a function is refused before the view is '
		.. 'ever taken', C.Shot(1, nil, 'not a function').error == 'invalid_body')
	check('as is an option Shot does not have',
		C.Shot(1, { holdMs = 10 }, function() end).error == 'invalid_camera_options')
	check('releaseMs overrides the take\'s blend when the caller wants a '
		.. 'different one', (function()
			C.Shot(1, { blendMs = 600, releaseMs = 120 }, function() end)
			return lastCall().args[1].blendMs == 120
		end)())
end

section('camera: shake and the ungated ray')
do
	local C = Lib.Camera
	install({
		['camera.shake'] = function() return true end,
		['camera.stopShake'] = function() return true end,
		['camera.unproject'] = function() return { origin = {}, direction = {} } end,
	})

	check('every documented preset is accepted', (function()
		for _, preset in ipairs(C.SHAKES) do
			if not C.Shake(1, preset).ok then return false end
		end
		return true
	end)())
	local unknown = C.Shake(1, 'wobble')
	check('an unknown preset is refused here, one native call early, and the '
		.. 'refusal lists the four that would have worked',
		unknown.error == 'invalid_shake_preset'
		and unknown.detail:find('earthquake', 1, true) ~= nil)
	check('amplitude holds at 0 and 4', C.Shake(1, 'hand', 0).ok and C.Shake(1, 'hand', 4).ok)
	check('and is refused just outside either end',
		C.Shake(1, 'hand', -0.01).error == 'invalid_shake_argument'
		and C.Shake(1, 'hand', 4.01).error == 'invalid_shake_argument')
	check('a duration is whole milliseconds, not a numeric string',
		C.Shake(1, 'hand', 1.0, '500').error == 'invalid_shake_argument')
	C.Shake(nil, 'explosion', 2.0, 1000)
	check('and omitting the id shakes whichever camera you hold',
		lastCall().args[1] == nil and lastCall().args[2] == 'explosion')

	check('StopShake takes an id', C.StopShake(1).ok)

	check('the screen point holds at 0 and 1', C.Ray(0, 0).ok and C.Ray(1, 1).ok)
	check('and is refused just outside either end, by the platform\'s word',
		C.Ray(-0.01, 0.5).error == 'invalid_screen_point'
		and C.Ray(0.5, 1.01).error == 'invalid_screen_point'
		and C.Ray(0.5, 0 / 0).error == 'invalid_screen_point')
end

-- ── Screen ───────────────────────────────────────────────────────────────────
section('screen: what the platform said')
do
	local S = Lib.Screen

	check('the catalogue currently contains exactly one preset',
		#S.PRESETS == 1 and S.PRESETS[1] == 'fade')
	check('the documented bounds are written down',
		S.MAX_FADE_MS == 10000 and S.MAX_HOLD_MS == 30000
		and S.MIN_TIMEOUT_MS == 1000 and S.MAX_TIMEOUT_MS == 60000
		and S.TIMEOUT_MARGIN_MS == 500 and S.ALPHA == 255)
	check('and the defaults, which are for checking and never sent',
		S.DEFAULTS.durationMs == 500 and S.DEFAULTS.holdMs == 250
		and S.DEFAULTS.fadeInMs == 500)
	check('the three phases nothing follows are the terminal set',
		S.TERMINAL.finished and S.TERMINAL.cancelled and S.TERMINAL.failed
		and S.TERMINAL.covered == nil)
	check('and the reason that is ours rather than the engine\'s is explained, '
		.. 'because the engine calls it completed',
		S.REASONS.never_covered:find('without ever reaching black', 1, true) ~= nil)
	check('Why turns a token into that sentence, and passes an unknown through',
		S.Why('timeout') == S.REASONS.timeout
		and S.Why('newer_reason'):find('newer_reason', 1, true) ~= nil)
	check('the module states its permission for Lib.Manifest()',
		S.NEEDS == 'screen.effects')

	_G.Open77 = {}
	check('on a build without the namespace the module says so',
		S.FadeOut().error == 'native_not_found'
		and S.Catalog().error == 'native_not_found')
	check('and IsFaded fails to true, because a wrong false is what stacks two '
		.. 'fades on one player', S.IsFaded() == true)
end

section('screen: the door')
do
	local S = Lib.Screen
	install({
		['screen.fadeOut'] = function() return '12' end,
		['screen.fadeIn'] = function() return true end,
		['screen.transition'] = function() return '13' end,
	})
	local function sent() return lastCall().args[#lastCall().args] end

	check('durationMs holds at 0 and 10000',
		S.FadeOut({ durationMs = 0 }).ok and S.FadeOut({ durationMs = 10000 }).ok)
	check('and is refused just outside either end, under the platform\'s own '
		.. 'parameterised code',
		S.FadeOut({ durationMs = -1 }).error == 'invalid_screen_option:durationMs'
		and S.FadeOut({ durationMs = 10001 }).error == 'invalid_screen_option:durationMs')
	check('a numeric string is not a number, and neither is NaN or infinity',
		S.FadeOut({ durationMs = '500' }).error == 'invalid_screen_option:durationMs'
		and S.FadeOut({ durationMs = 0 / 0 }).error == 'invalid_screen_option:durationMs'
		and S.FadeOut({ durationMs = math.huge }).error == 'invalid_screen_option:durationMs')
	check('and durations are integer milliseconds, not fractions of one',
		S.FadeOut({ durationMs = 500.5 }).error == 'invalid_screen_option:durationMs')

	check('holdMs holds at 0 and 30000',
		S.Transition('fade', { holdMs = 0, timeoutMs = 2000 }).ok
		and S.Transition('fade', { holdMs = 30000, timeoutMs = 31600 }).ok)
	check('and is refused just past its own end, which is not the fade bound',
		S.Transition('fade', { holdMs = 30001 }).error == 'invalid_screen_option:holdMs')
	check('fadeInMs holds at 0 and 10000 and is refused past it',
		S.Transition('fade', { fadeInMs = 10000 }).ok
		and S.Transition('fade', { fadeInMs = 10001 }).error
			== 'invalid_screen_option:fadeInMs')

	check('timeoutMs holds at 1000 and 60000',
		S.FadeOut({ durationMs = 400, timeoutMs = 1000 }).ok
		and S.FadeOut({ timeoutMs = 60000 }).ok)
	check('and is refused just outside either end',
		S.FadeOut({ timeoutMs = 999 }).error == 'invalid_screen_option:timeoutMs'
		and S.FadeOut({ timeoutMs = 60001 }).error == 'invalid_screen_option:timeoutMs')

	-- The cross-field rule, using the documented defaults for what was omitted.
	local short = S.Transition('fade', { timeoutMs = 1249 })
	check('a deadline that does not clear the sequence it bounds is refused '
		.. 'with the platform\'s own word',
		short.error == 'screen_timeout_too_short')
	check('and the refusal states the sum, which is the one number the engine '
		.. 'does not give you', short.detail:find('1250 ms', 1, true) ~= nil)
	check('the margin is exactly 500 ms, at both sides of the line',
		S.Transition('fade', { timeoutMs = 1750 }).ok
		and S.Transition('fade', { timeoutMs = 1749 }).error == 'screen_timeout_too_short')
	check('a fadeOut is checked against the outgoing fade alone, because the '
		.. 'return it will get is not this call\'s to know',
		S.FadeOut({ durationMs = 2000, timeoutMs = 2500 }).ok
		and S.FadeOut({ durationMs = 2000, timeoutMs = 2499 }).error
			== 'screen_timeout_too_short')

	-- The option sets differ per call, and that is the point.
	check('fadeIn takes a duration and nothing else, because a hold there is a '
		.. 'hold nobody ever performs',
		S.FadeIn('12', { durationMs = 400 }).ok
		and S.FadeIn('12', { holdMs = 400 }).error == 'invalid_screen_option:holdMs')
	local unknown = S.FadeOut({ duration = 400 })
	check('an unknown option is named, not ignored',
		unknown.error == 'invalid_screen_option:duration'
		and unknown.detail:find('durationMs', 1, true) ~= nil)

	-- Colour.
	check('colour channels hold at 0 and 255',
		S.FadeOut({ color = { r = 0, g = 0, b = 0 } }).ok
		and S.FadeOut({ color = { r = 255, g = 255, b = 255 } }).ok)
	check('and are refused just outside either end',
		S.FadeOut({ color = { r = -1 } }).error == 'invalid_screen_color'
		and S.FadeOut({ color = { g = 256 } }).error == 'invalid_screen_color')
	check('alpha is not a range: 255 is the only value this API has',
		S.FadeOut({ color = { r = 0, a = 255 } }).ok
		and S.FadeOut({ color = { r = 0, a = 254 } }).error == 'invalid_screen_color')
	S.FadeOut({ color = '#ff3b47' })
	check('a hex string is converted to the bytes the native wants, as it is '
		.. 'everywhere else in this library',
		sent().color.r == 255 and sent().color.g == 59 and sent().color.b == 71)
	check('and a malformed one is refused',
		S.FadeOut({ color = '#f00' }).error == 'invalid_screen_color')
	S.FadeOut({ color = { r = 12 } })
	check('an omitted channel is left to the engine rather than filled in here',
		sent().color.g == nil and sent().color.a == nil)

	-- Presets.
	check('the one preset in the catalogue is accepted', S.Transition('fade').ok)
	check('a preset the platform knows but has not landed is forwarded, so the '
		.. 'caller reads "not yet" and not "misspelled"',
		S.Transition('glitch').ok and lastCall().args[1] == 'glitch')
	local nonsense = S.Transition('sparkle')
	check('while a name nobody has is refused here, naming the one that works',
		nonsense.error == 'unsupported_screen_preset'
		and nonsense.detail:find('fade', 1, true) ~= nil)

	-- Ids are opaque strings and are never interpreted.
	check('an id that was run through tonumber is refused at the door',
		S.FadeIn(12).error == 'invalid_transition_id'
		and S.Cancel(nil).error == 'invalid_transition_id'
		and S.State('').error == 'invalid_transition_id')
end

section('screen: the slot is single and shared')
do
	local S = Lib.Screen

	install({
		['screen.fadeOut'] = function() return nil, 'screen_busy' end,
		['screen.transition'] = function() return nil, 'screen_busy' end,
	})
	local taken = S.FadeOut({ durationMs = 400 })
	check('a second request answers the platform\'s own screen_busy',
		taken.error == 'screen_busy')
	check('and the refusal says the slot is shared with the server relay, '
		.. 'which is the cause a client resource cannot see',
		taken.detail:find('server relay', 1, true) ~= nil
		and taken.detail:find('isFaded', 1, true) ~= nil)
	check('transition is refused the same way, from the same slot',
		S.Transition('fade').error == 'screen_busy')

	install({ ['screen.fadeOut'] = function() return nil, 'native_screen_busy' end })
	local vanilla = S.FadeOut()
	check('a fade the GAME owns is a different answer and a different remedy',
		vanilla.error == 'native_screen_busy'
		and vanilla.detail:find('will not clear it', 1, true) ~= nil)
end

section('screen: the promise that comes second')
do
	local S = Lib.Screen

	local covered, restored, finished = promise({ black = true }), promise(true), promise(true)
	install({
		['screen.fadeOut'] = function() return '12', covered end,
		['screen.fadeIn'] = function() return true, restored end,
		['screen.transition'] = function() return '13', finished end,
	})

	local out = S.FadeOut({ durationMs = 400 })
	check('the Result carries the opaque id, exactly as the native gave it',
		out.ok and out.value == '12')
	check('and the promise -- which Native.Call would have dropped -- rides '
		.. 'along, named for what it settles on', out.covered == covered)
	check('fadeIn keeps its own true and names its promise for the image '
		.. 'coming back',
		S.FadeIn('12').value == true and S.FadeIn('12').restored == restored)
	check('and a transition names its promise for the end of the sequence, '
		.. 'which is not when the screen turns black',
		S.Transition('fade').finished == finished)

	local black = S.Await(out.covered)
	check('Await resolves with the state table the event carries',
		black.ok and black.value.black == true and covered.awaited)
	check('and a nil promise is Ok, so no call site needs an if',
		S.Await(nil).ok)

	local ended = S.Await(promise(nil, 'never_covered'))
	check('a transition that ended some other way rejects rather than parking '
		.. 'the coroutine that was going to call fadeIn',
		not ended.ok and ended.error == 'never_covered')
	check('and the reason arrives as the sentence, which for this one is the '
		.. 'only way to read it', ended.detail == Lib.Screen.REASONS.never_covered)
end

section('screen: the reads, owned and unowned')
do
	local S = Lib.Screen

	install({ ['screen.isFaded'] = function() return true end })
	check('IsFaded answers the screen, whoever covered it', S.IsFaded() == true)
	install({ ['screen.isFaded'] = function() return false end })
	check('and false is an ANSWER -- the screen is clear -- which is why it '
		.. 'cannot go through Native.Call', S.IsFaded() == false)
	install({ ['screen.isFaded'] = function() return nil, 'screen_unavailable' end })
	check('a guarded backend that will not say answers true, not false: a '
		.. 'wrong false is exactly what stacks two fades', S.IsFaded() == true)
	install({ ['screen.isFaded'] = function() error('boom') end })
	check('and so does a read that raises', S.IsFaded() == true)

	install({ ['screen.nativeState'] = function()
		return { faded = false, fading = true, remainingMs = 120 }
	end })
	local native = S.NativeState()
	check('NativeState keeps the distinction IsFaded gives up, so a caller can '
		.. 'wait for an incoming fade instead of racing it',
		native.ok and native.value.fading == true and native.value.faded == false)

	check('Over reads the terminal phases',
		S.Over({ phase = 'finished' }) and S.Over({ phase = 'cancelled' })
		and S.Over({ phase = 'failed' }))
	check('and the live ones are not over',
		not S.Over({ phase = 'fading_out' }) and not S.Over({ phase = 'covered' })
		and not S.Over({ phase = 'fading_in' }))
	check('a phase from a newer build reads as NOT over, which keeps the id '
		.. 'and risks one redundant fadeIn -- the other direction risks a '
		.. 'screen nobody ever restores',
		not S.Over({ phase = 'something_new' }) and not S.Over(nil))

	install({ ['screen.state'] = function()
		return { id = '12', phase = 'covered', black = true, elapsedMs = 650 }
	end })
	local mine = S.State('12')
	check('State annotates the owner-scoped snapshot with that answer',
		mine.ok and mine.value.over == false)
	check('and leaves the platform\'s own fields alone',
		mine.value.elapsedMs == 650 and mine.value.black == true)

	install({ ['screen.catalog'] = function()
		return { fade = { available = true, backend = 'native_quest_fade' } }
	end })
	local catalogue = S.Catalog()
	check('Catalog asks the build rather than answering the static list',
		catalogue.ok and catalogue.value.fade.available == true)
end

section('screen: the image comes back')
do
	local S = Lib.Screen
	local restored

	local function host(fadeOut, fadeIn)
		install({
			['screen.fadeOut'] = fadeOut,
			['screen.fadeIn'] = fadeIn or function()
				restored = promise(true)
				return true, restored
			end,
		})
	end

	-- 1. The ordinary path.
	restored = nil
	host(function() return '12', promise({ black = true }) end)
	local ran = false
	local hidden = S.Black({ durationMs = 400, fadeInMs = 250 }, function()
		ran = true
		return 'moved'
	end)
	check('Black runs the body once the screen is actually black and answers '
		.. 'what the body answered', ran and hidden.ok and hidden.value == 'moved')
	check('and the image is handed back', lastCall().path == 'screen.fadeIn')
	check('with fadeInMs lifted out of the fadeOut options, where it is not a '
		.. 'field, and spent on the return', lastCall().args[2].durationMs == 250)
	check('and the return is AWAITED, so when Black returns the image is back',
		restored ~= nil and restored.awaited and hidden.restored == true)
	check('the fadeIn is given the id the fadeOut answered',
		lastCall().args[1] == '12')

	-- 2. The path the safety deadline would otherwise have to cover.
	restored = nil
	host(function() return '12', promise({ black = true }) end)
	local raised = S.Black(nil, function() error('the teleport threw') end)
	check('a body that RAISES still gives the image back, rather than leaving '
		.. 'the player staring at black until the deadline expires',
		lastCall().path == 'screen.fadeIn' and raised.restored == true)
	check('and the raise is reported rather than swallowed',
		not raised.ok and raised.error == 'screen_body_raised'
		and raised.detail:find('the teleport threw', 1, true) ~= nil)

	-- 3. It never went black, so the body must not run in plain view.
	host(function() return '12', promise(nil, 'native_interrupted') end)
	local never = S.Black(nil, function()
		ran = 'body ran in plain view'
		return true
	end)
	check('a fade that never reaches black does not run a body written to '
		.. 'happen unseen',
		not never.ok and never.error == 'native_interrupted'
		and ran ~= 'body ran in plain view')
	check('and it still tries to restore on the way out',
		lastCall().path == 'screen.fadeIn')

	-- 4. Already over. That is the outcome we wanted.
	host(function() return '12', promise({ black = true }) end,
		function() return false, 'transition_not_active' end)
	local over = S.Black(nil, function() return 1 end)
	check('a return refused because the transition is already over is a '
		.. 'success: the image is back either way',
		over.ok and over.restored == true)

	-- 5. Any other refusal is not quietly a success.
	host(function() return '12', promise({ black = true }) end,
		function() return false, 'not_owner' end)
	local wrong = S.Black(nil, function() return 1 end)
	check('but a return refused for any other reason is reported',
		wrong.ok and wrong.restored == false)

	-- 6. Nothing was covered, so nothing is restored.
	install({ ['screen.fadeOut'] = function() return nil, 'screen_busy' end })
	local before = #recorded
	local busy = S.Black(nil, function() return 1 end)
	check('a refused fade is passed straight back and nothing is restored, '
		.. 'because nothing was covered',
		busy.error == 'screen_busy' and busy.restored == nil and #recorded == before + 1)

	host(function() return '12', promise({ black = true }) end)
	check('Black(fn) is the same call as Black(nil, fn)',
		S.Black(function() return 'short' end).value == 'short')
	check('and something that is not a function is refused before the screen '
		.. 'is ever covered', S.Black(nil, 'not a function').error == 'invalid_body')
end

-- ── Timer ────────────────────────────────────────────────────────────────────
section('timer')
do
	local T = Lib.Timer

	timeouts = {}
	local ran = 0
	check('After takes a delay and a function', T.After(100, function() ran = ran + 1 end) ~= nil)
	check('a negative delay is refused', T.After(-1, function() end) == nil)
	check('a missing function is refused', T.After(100, nil) == nil)
	fireTimers()
	check('and it runs when the timer fires', ran == 1)

	-- Debounce: the LAST call wins, once, after the calls stop.
	timeouts = {}
	local saw = {}
	local debounced = T.Debounce(50, function(value) saw[#saw + 1] = value end)
	debounced('a')
	debounced('b')
	debounced('c')
	check('a debounce queues one timer per call', #timeouts == 3)
	fireTimers()
	check('but only the last call runs', #saw == 1 and saw[1] == 'c')

	-- Throttle: the FIRST call goes straight through, or a button feels broken.
	timeouts = {}
	local hits = {}
	local throttled = T.Throttle(50, function(value) hits[#hits + 1] = value end)
	throttled('first')
	check('the first call runs immediately', #hits == 1 and hits[1] == 'first')
	throttled('dropped')
	throttled('last')
	check('calls inside the window do not run yet', #hits == 1)
	fireTimers()
	check('and the last of them runs when the window closes',
		#hits == 2 and hits[2] == 'last')

	-- Until suspends, so it runs in a thread.
	local flag, got = false, 'unset'
	CreateThread(function() got = T.Until(function() return flag end, 1000, 10) end)
	check('Until waits while the test is false', got == 'unset')
	flag = true
	step()
	check('and answers what the test answered', got == true)

	local timedOut = 'unset'
	CreateThread(function() timedOut = T.Until(function() return false end, 20, 10) end)
	step(); step(); step()
	check('a test that never passes answers nil, which is distinguishable from false',
		timedOut == nil)

	check('timers need no permission', T.NEEDS == nil)
end


-- ── the version is stated in three places ───────────────────────────────────
-- `boot/server.lua` CANNOT read it from anywhere: the dedicated-server sandbox
-- has no `require`, so the one line it logs carries a literal. That literal was
-- already stale once -- 0.2.0 against a 0.3.0 library -- and the only symptom
-- would have been an operator reading the wrong version out of their journal
-- while chasing something else.
section('the version')
do
	local function grab(path, pattern)
		local handle = io.open(path, 'r')
		local body = handle and handle:read('a') or ''
		if handle then handle:close() end
		return body:match(pattern)
	end

	local entry = grab('init.lua', "Lib%.VERSION = '([%d%.]+)'")
	local manifest = grab('open77.lua', '\nversion "([%d%.]+)"')
	local boot = grab('boot/server.lua', "local VERSION = '([%d%.]+)'")

	check('init.lua states one', entry ~= nil, tostring(entry))
	check('and the manifest agrees', manifest == entry,
		('manifest %s vs entry %s'):format(tostring(manifest), tostring(entry)))
	check('and so does the line the server logs', boot == entry,
		('boot %s vs entry %s'):format(tostring(boot), tostring(entry)))
end


-- ── the platform is read, not raw-read ──────────────────────────────────────
-- This shipped as `rawget(_G, 'Open77')` and it was wrong twice: `rawget` skips
-- a metatable, and `_G` is not necessarily the chunk's `_ENV`. A host that
-- exposes the namespace through an `__index` accessor, or that hands a resource
-- its own environment, made EVERY wrapper in this library answer
-- `open77_unavailable` -- and a consumer's feature simply stopped, with no
-- refusal anybody could see. It cost a live server its name tags.
section('the platform namespace is reached the ordinary way')
do
	local N = Lib.Native

	-- Nothing on _G itself; the namespace exists only behind a metatable, which
	-- is exactly the arrangement `rawget` could not see.
	local held = rawget(_G, 'Open77')
	rawset(_G, 'Open77', nil)
	local hadMeta = getmetatable(_G)
	setmetatable(_G, { __index = function(_, key)
		if key == 'Open77' then return { hud = { notify = function() return true end } } end
		return nil
	end })

	local reached = N.Reach('hud.notify')
	local answered = N.Call('hud.notify', nil, 'x')

	setmetatable(_G, hadMeta)
	rawset(_G, 'Open77', held)

	check('a namespace behind a metatable is found', type(reached) == 'function',
		tostring(reached))
	check('and a call through it succeeds rather than refusing',
		answered.ok == true, answered.error)

	-- The other half: genuinely absent is still absent, and still never raises.
	local kept = rawget(_G, 'Open77')
	rawset(_G, 'Open77', nil)
	local missing = { N.Reach('hud.notify') }
	rawset(_G, 'Open77', kept)

	check('and a platform that is really not there still answers nil',
		missing[1] == nil and missing[2] == 'open77_unavailable')
end

print(('\n%d checks, %d failed'):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
