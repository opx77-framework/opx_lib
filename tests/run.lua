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
		and Lib.Async and Lib.World and Lib.Players and Lib.Blip and Lib.Store and true)
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
		Lib.Manifest() == 'permissions { "input.actions", "network.events", '
			.. '"ui.vanilla.hud", "ui.vanilla.map", "world.markers", "world.query" }')
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
section('marker')
do
	install({
		['markers.create'] = function() return '18446744073709551615' end,
		['markers.update'] = function() return true end,
		['markers.remove'] = function() return true end,
		['markers.clear'] = function() return true end,
	})

	local made = Lib.Marker.Place({ x = 1.5, y = 2.5, z = 3.5 }, { radius = 1.5 })
	check('Place answers the handle as the string it is',
		made.ok and made.value == '18446744073709551615')
	check('and forwards the options', lastCall().args[1].radius == 1.5)
	check('and rebuilds the position rather than passing the caller table',
		lastCall().args[1].position.x == 1.5)

	Lib.Marker.Place({ x = 0, y = 0, z = 0 }, { position = { x = 99, y = 99, z = 99 } })
	check('options cannot smuggle in a second position',
		lastCall().args[1].position.x == 0)

	local before = #recorded
	check('a position that is not finite is refused',
		Lib.Marker.Place({ x = 0 / 0, y = 0, z = 0 }).error == 'invalid_position')
	check('a missing position is refused', Lib.Marker.Place(nil).error == 'invalid_position')
	check('and neither reached the platform', #recorded == before)

	check('Move patches', Lib.Marker.Move('1', { visible = false }).ok)
	check('Remove takes a handle', Lib.Marker.Remove('1').ok)
	check('Clear takes nothing', Lib.Marker.Clear().ok)
	check('the module states the permission it needs', Lib.Marker.NEEDS == 'world.markers')
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

print(('\n%d checks, %d failed'):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
