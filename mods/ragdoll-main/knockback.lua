-- How hard each game would have knocked the body back, and explosions.
--
-- Most mob APIs check for death before their knockback, so a killed mob never
-- gets it. Here each API's own knockback formula is worked out for the
-- killing hit, along with how far that mob's own movement code would have
-- carried it (some brake hard, some let it slide), and the ragdoll is
-- launched to travel about as far.
--
-- A knockback is {vel = velocity the game gives (m/s), travel = horizontal
-- distance it would carry the mob (nodes, nil = just use vel), gravity = the
-- mob's gravity (for the same peak height), applied = true if the game had
-- already given it before the death (it's in the velocity the body inherits)}.
local R = ragdoll
local K = {}
R.knockback = K

local function hlen(v) return math.sqrt(v.x * v.x + v.z * v.z) end
local function clamp(x, a, b) return x < a and a or (x > b and b or x) end
local function gravity() return tonumber(core.settings:get("movement_gravity")) or 9.81 end

-- Some APIs brake a mob by a fixed factor every server step, so how far the
-- mob itself would slide depends on the server's step. A throw never does:
-- it's worked out as at 20 steps a second (the rate those games are made for).
local REF_STEP = 0.05

--------------------------------------------------------------------------------
-- How far a game's movement carries a knocked-back mob
--------------------------------------------------------------------------------
-- horizontal speed multiplied by `factor` every step (at REF_STEP), for `duration`
local function travel_damped(vh, factor, duration)
	local n = math.max(1, math.floor(duration / REF_STEP))
	return vh * REF_STEP * (1 - factor ^ n) / (1 - factor)
end

-- Minecraft physics (Mineclonia): per 1/20 s tick, gravity 0.08 b/t, air drag
-- 0.98 vertical, horizontal 0.91 in the air and 0.546 on the ground
local function travel_mc(vh, vy)
	local x, y, hx, hy = 0, 0, vh / 20, vy / 20
	for _ = 1, 100 do
		x, y = x + hx, y + hy
		local ground = y <= 0
		if ground then y, hy = 0, 0 end
		hy = (hy - 0.08) * 0.98
		hx = hx * (ground and 0.546 or 0.91)
		if ground and hx < 0.002 then break end
	end
	return x
end

--------------------------------------------------------------------------------
-- The launch: a knockback as the ragdoll's starting velocity
--------------------------------------------------------------------------------
-- A tumbling body launched at horizontal speed v (m/s) and lift u travels
-- about v * k(u, v) nodes (measured on many models: they roll and slide).
local function travel_factor(u, v) return 0.72 + 0.006 * math.min(v, 40) + 0.01 * u + 0.004 * u * u end

function K.launch(kb, scale)
	scale = scale or 1
	local v = kb.vel
	local vh = hlen(v)
	-- (bodies fall at twice the world's gravity: lift for the same peak height)
	local g_body = 2 * gravity()
	local u = math.max(0, v.y) * math.sqrt(g_body / (kb.gravity or gravity()))
	local s = vh
	if kb.travel then
		s = kb.travel / 0.8
		for _ = 1, 4 do s = kb.travel / travel_factor(u, s) end
	end
	s = math.min(s * scale, 60)
	u = math.min(u * math.sqrt(scale), 14)
	if vh < 1e-6 then return vector.new(0, u, 0) end
	return vector.new(v.x / vh * s, u, v.z / vh * s)
end

--------------------------------------------------------------------------------
-- Per game / API: the knockback the killing hit would have given
-- (rec: the hit - dir, damage, caps, puncher, tflp)
--------------------------------------------------------------------------------
local function horizontal_dir(rec, obj)
	local p, h = obj:get_pos(), rec.puncher and rec.puncher:get_pos()
	local d = (p and h) and vector.subtract(p, h) or rec.dir
	if not d then return nil end
	local l = hlen(d)
	if l < 1e-6 then return nil end
	return vector.new(d.x / l, 0, d.z / l)
end

-- (the game's rules give this hit no knockback)
local NONE = {vel = vector.zero()}

local function enchant(hitter, name)
	local e = rawget(_G, "mcl_enchanting")
	if not (e and e.get_enchantment and hitter and hitter:is_player()) then return 0 end
	local ok, lvl = pcall(e.get_enchantment, hitter:get_wielded_item(), name)
	return ok and tonumber(lvl) or 0
end

-- Players, any game: the game's own core.calculate_knockback (overrides
-- included - VoxeLibre's adds lift and enchantments through add_velocity
-- calls, caught here instead of touching the player).
function K.player(player, hitter, tflp, caps, dir, damage)
	local d = dir
	if hitter and hitter:get_pos() and player:get_pos() then d = vector.subtract(player:get_pos(), hitter:get_pos()) end
	if not d then return nil end
	local dist = vector.length(d)
	if dist > 0 then d = vector.divide(d, dist) end
	local caught = vector.zero()
	local proxy = setmetatable({}, {__index = function(_, k)
		if k == "add_velocity" then return function(_, v) caught = vector.add(caught, v) end end
		if k == "set_velocity" then return function() end end
		local f = player[k]
		if type(f) == "function" then return function(_, ...) return f(player, ...) end end
		return f
	end})
	local ok, k = pcall(core.calculate_knockback, proxy, hitter, tflp, caps, d, dist, damage)
	if not ok or type(k) ~= "number" then return nil end
	return {vel = vector.add(vector.multiply(d, k), caught)}
end

-- Mobs Redo: velocity (dir * kb, 2 up) on full punches, kb = damage (or the
-- tool's knockback group, +3 per Knockback enchantment level); the mob is
-- then left alone for 0.25 s and stops. (Its death check comes first.)
function K.mobs_redo(self, rec)
	if not rec.dir then return nil end
	if self.knock_back == false then return NONE end
	local caps = rec.caps or {}
	local interval = caps.full_punch_interval or 1.4
	if (rec.tflp or interval) < interval then return NONE end
	local kb = core.settings:get_bool("mobs_disable_damage_kb") and 1 or (tonumber(rec.damage) or 1)
	kb = (caps.damage_groups or {}).knockback or kb
	kb = kb + 3 * enchant(rec.puncher, "knockback")
	local v = self.object:get_velocity() or vector.zero()
	local up = (v.y > 0 or self.fly) and 0 or 2
	local vel = vector.new(rec.dir.x * kb, up, rec.dir.z * kb)
	return {vel = vel, travel = hlen(vel) * 0.25, gravity = math.abs(tonumber(self.fall_speed) or 10)}
end

-- VoxeLibre / MineClone2 (mcl_mobs): kb = 1.25 (or the tool's knockback
-- group), + 3 for hammers, + half the attacker's run speed, x the swing's
-- charge, + 3 per Knockback level, x 1.25 for a kill, x 20; 5.25 up. A dying
-- mob slides on, slowing x0.92 a step (at 20 steps a second), for its 1.5 s death.
function K.mcl_voxelibre(self, rec)
	if not rec.dir then return nil end
	if not self.knock_back then return NONE end
	local caps = rec.caps or {}
	local interval = caps.full_punch_interval or 1.4
	if interval == 0 then interval = 0.001 end
	local tflp = rec.tflp or interval
	local rate = math.min(tflp, interval) / interval
	local kb = (caps.damage_groups or {}).knockback or 1.25
	local v = self.object:get_velocity() or vector.zero()
	local hitter = rec.puncher
	local le = hitter and not hitter:is_player() and hitter:get_luaentity()
	if hitter and hitter:is_player() then
		kb = kb + 3 * core.get_item_group(hitter:get_wielded_item():get_name(), "hammer")
		local hv = hitter:get_velocity() or vector.zero()
		local dir_dot = hv.x * rec.dir.x + hv.z * rec.dir.z
		local pmag, mmag = hlen(hv), hlen(v)
		if dir_dot > 0 and mmag <= pmag * 0.625 then kb = kb + pmag / 2 end
		kb = kb * rate + 3 * enchant(hitter, "knockback")
	elseif le and le._knockback then
		kb = kb + le._knockback * 0.25
	end
	kb = kb * 1.25 * 20
	local up = (math.abs(v.y) > 0.1 or self.fly) and 0 or 5.25
	local vel = vector.new(rec.dir.x * kb, up, rec.dir.z * kb)
	return {vel = vel, travel = travel_damped(hlen(vel), 0.92, 1.5), gravity = 9.81 * 1.5}
end

-- Mineclonia: Minecraft's knockback - 0.4 blocks/tick away from the attacker,
-- then (Knockback level + attack-knockback attribute) / 2, + 0.5 for a
-- sprinting hit, the way the attacker faces; Minecraft's drag after.
function K.mcl_mineclonia(self, rec)
	local U = rawget(_G, "mcl_util")
	if not (U and U.calculate_knockback) then return nil end
	if not self.knock_back then return NONE end
	local d = horizontal_dir(rec, self.object)
	if not d then return nil end
	local ok, res = pcall(function()
		local standing = self.standing_on_walkable and self:standing_on_walkable() or false
		local resist = self.knockback_resistance
		local v = U.calculate_knockback(self.object:get_velocity() or vector.zero(), 0.4, resist, standing, d.x, d.z)
		local hitter = rec.puncher
		if hitter and hitter:is_player() then
			local extra = enchant(hitter, "knockback")
			if U.get_additional_knockback then extra = extra + (tonumber(U.get_additional_knockback(hitter)) or 0) end
			extra = extra / 2
			local sprint = rawget(_G, "mcl_sprint")
			if sprint and sprint.is_sprinting and sprint.is_sprinting(hitter:get_player_name()) then extra = extra + 0.5 end
			if extra > 0 then
				local yaw = hitter:get_look_horizontal()
				v = U.calculate_knockback(v, extra, resist, standing, -math.sin(yaw), math.cos(yaw))
			end
		end
		return v
	end)
	if not ok or not res then return nil end
	return {vel = res, travel = travel_mc(hlen(res), math.max(0, res.y)), gravity = 32}
end

-- mob_core: (dir * 4, 2 up) when on the ground, given before the damage.
function K.mob_core(self, rec)
	local d = horizontal_dir(rec, self.object)
	if not d then return nil end
	if not self.isonground then return NONE end
	return {vel = vector.new(d.x * 4, 2, d.z * 4), applied = true}
end

-- Creatura (Animalia): dir * clamp(damage / distance * 8, 0, 8), with 0.2
-- up, when touching the ground, given before the damage.
function K.creatura(self, rec)
	if not rec.dir then return nil end
	if not self.touching_ground then return NONE end
	local p, h = self.object:get_pos(), rec.puncher and rec.puncher:get_pos()
	local dist = (p and h) and math.max(vector.distance(p, h), 0.1) or 1
	local power = clamp((tonumber(rec.damage) or 0) / dist * 8, 0, 8)
	if power <= 0 then return NONE end
	return {vel = vector.new(rec.dir.x * power, 0.2 * power, rec.dir.z * power), applied = true}
end

-- all_mobs_api: dir * knockback * swing power, knockback_vertical up, less
-- the mob's knockback resistance, given before the damage.
function K.all_mobs_api(self, rec)
	local cfg = self.cfg
	if not cfg or not rec.dir then return nil end
	local caps = rec.caps or {}
	local power = clamp((rec.tflp or 1) / math.max(caps.full_punch_interval or 1, 0.1), 0.2, 1)
	local f = math.max(0, 1 - (cfg.knockback_resistance or 0))
	local kb, kv = (cfg.knockback or 4.5) * power * f, (cfg.knockback_vertical or 3.5) * power * f
	return {vel = vector.new(rec.dir.x * kb, kv, rec.dir.z * kb), applied = true}
end

--------------------------------------------------------------------------------
-- Explosions
--------------------------------------------------------------------------------
-- A blast: {pos, radius, speed = function(dist, is_player) -> m/s[, travel
-- model]}. Bodies already lying around are thrown at once; bodies of whatever
-- it kills (now, or within the next moment) are thrown as they appear.
local blasts = {}
local BLAST_TIME = 0.6
local BLAST_MAX = 25

local function prune()
	local now = core.get_us_time()
	for i = #blasts, 1, -1 do
		if now - blasts[i].t > BLAST_TIME * 1e6 then table.remove(blasts, i) end
	end
end

-- the launch a blast gives a body at `pos` (nil: out of reach)
function K.blast_launch(bl, pos, is_player)
	local off = vector.subtract(pos, bl.pos)
	local dist = vector.length(off)
	if dist > bl.radius + 0.5 then return nil end
	local d = math.max(1, dist)
	local speed, model = bl.speed(d, is_player)
	-- (some games throw loose items with their blasts far harder than any
	-- creature - Minetest Game's TNT, 60 m/s next to it: a body stops at 25)
	speed = math.min(tonumber(speed) or 0, BLAST_MAX)
	if speed <= 0 then return nil end
	local dir = dist > 1e-3 and vector.divide(off, dist) or vector.new(0, 1, 0)
	-- (the ground under a blast throws things up as well as away)
	if dir.y < 0.35 then
		dir.y = 0.35
		dir = vector.normalize(dir)
	end
	local vel = vector.multiply(dir, speed)
	local kb = {vel = vel}
	if model == "voxelibre" then
		kb.travel, kb.gravity = travel_damped(hlen(vel), 0.92, 1.5), 9.81 * 1.5
	elseif model == "mc" then
		kb.travel, kb.gravity = travel_mc(hlen(vel), math.max(0, vel.y)), 32
	end
	return K.launch(kb, R.setting("blast", 1))
end

-- Records a blast and throws the bodies around it. def: {pos, radius,
-- speed = function(dist, is_player)} or, simply, {pos, radius, power} (power:
-- m/s at one node away, falling off with distance).
function R.blast(def)
	if not def or not def.pos or not tonumber(def.radius) then return end
	local bl = {pos = vector.copy(def.pos), radius = tonumber(def.radius), speed = def.speed, t = core.get_us_time()}
	if not bl.speed then
		local power = tonumber(def.power) or bl.radius * 5
		bl.speed = function(dist) return power / dist end
	end
	prune()
	blasts[#blasts + 1] = bl
	for _, b in ipairs(R.bodies) do
		if b.obj:is_valid() and not b.dead then R._internal.blast_body(b, bl, true) end
	end
end

-- the recent blasts that reach `pos`
function K.blasts_at(pos)
	prune()
	local out = {}
	for _, bl in ipairs(blasts) do
		if vector.distance(pos, bl.pos) <= bl.radius + 1 then out[#out + 1] = bl end
	end
	return out
end
