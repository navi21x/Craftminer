-- The ragdoll itself: a Verlet body built from any object's look.
--
-- The core of the body is a rigid box (8 points: the torso found by
-- models.analyze, or the collisionbox for models without bones). Every limb
-- the rig found is a point on a fixed-length link from its pivot on the torso
-- (or on the end of the limb above it), swinging freely inside a cone around
-- its rest direction. Gravity, damping, friction, a little bounce, buoyancy in
-- liquids, and collisions against the real shape of nodes (engine raycasts,
-- so slabs, stairs and nodeboxes work). Every server step the simulation
-- drives the copy of the model: the entity follows the torso box, each limb
-- bone gets the rotation that turns its rest direction into its simulated one.
local R = ragdoll
local models = R.models

local SUB = 1 / 30                  -- simulation substep (s)
local ITER = 3                      -- constraint iterations per substep
local DAMP = 0.993                  -- velocity kept per substep (air)
local FRICTION = 0.74               -- horizontal velocity kept per substep while grounded
local LIMB_FRICTION = 0.91          -- (limb ends slide more easily: limp limbs splay)
local LIMB_DAMP = 0.935             -- limb swing kept per substep
local BOUNCE = 0.25
-- Joints: free in the inner part of their range; beyond SOFT (a fraction of
-- the limit) they get stiffer and stiffer up to the hard limit - a growing
-- friction in the joint: the swing is braked, and a slow one stops dead (it
-- holds its own weight there). Friction only takes energy away, so limbs
-- always come to rest.
local SOFT = 0.4
local SOFT_BRAKE = 0.5               -- swing lost per substep, at the limit
local SOFT_HOLD = 0.045              -- swing (nodes per substep) the joint stops dead, at the limit
local function gravity() return -2 * (tonumber(core.settings:get("movement_gravity")) or 9.81) end

local bodies = {}
R.bodies = bodies
R.stats = {us = 0, frames = 0}      -- Lua time spent simulating (for /ragdoll)

--------------------------------------------------------------------------------
-- Vector / matrix helpers (plain tables, x y z fields)
--------------------------------------------------------------------------------
local function v(x, y, z) return {x = x, y = y, z = z} end
local function add(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return v(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, k) return v(a.x * k, a.y * k, a.z * k) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function len(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
local function norm(a)
	local l = len(a)
	if l < 1e-9 then return v(0, 1, 0), 0 end
	return v(a.x / l, a.y / l, a.z / l), l
end
local function clamp(x, a, b) return x < a and a or (x > b and b or x) end

-- 3x3 row-major
local function m3_mul(a, b)
	local r = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}}
	for i = 1, 3 do for j = 1, 3 do
		r[i][j] = a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j]
	end end
	return r
end
local function m3_t(a) return {{a[1][1], a[2][1], a[3][1]}, {a[1][2], a[2][2], a[3][2]}, {a[1][3], a[2][3], a[3][3]}} end
local function m3_vec(m, a)
	return v(m[1][1] * a.x + m[1][2] * a.y + m[1][3] * a.z, m[2][1] * a.x + m[2][2] * a.y + m[2][3] * a.z,
		m[3][1] * a.x + m[3][2] * a.y + m[3][3] * a.z)
end
local I3 = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}

-- The rotation taking unit vector a to unit vector b (the shortest arc).
local function m3_between(a, b)
	local c = dot(a, b)
	if c > 0.99999 then return I3 end
	local ax = cross(a, b)
	if c < -0.99999 then
		-- half turn about any axis perpendicular to a
		ax = math.abs(a.x) < 0.9 and cross(a, v(1, 0, 0)) or cross(a, v(0, 1, 0))
		ax = norm(ax)
		local x, y, z = ax.x, ax.y, ax.z
		return {{2 * x * x - 1, 2 * x * y, 2 * x * z}, {2 * x * y, 2 * y * y - 1, 2 * y * z}, {2 * x * z, 2 * y * z, 2 * z * z - 1}}
	end
	local s = len(ax)
	local x, y, z = ax.x / s, ax.y / s, ax.z / s
	local t = 1 - c
	return {
		{t * x * x + c, t * x * y - s * z, t * x * z + s * y},
		{t * x * y + s * z, t * y * y + c, t * y * z - s * x},
		{t * x * z - s * y, t * y * z + s * x, t * z * z + c},
	}
end

-- Rotate vector a by angle t (radians) toward unit vector b in their plane.
local function swing_toward(a, b, t)
	local c = clamp(dot(a, b), -1, 1)
	local ang = math.acos(c)
	if ang < 1e-6 then return a end
	local perp = norm(sub(b, mul(a, c)))
	local k = math.min(t, ang)
	return add(mul(a, math.cos(k)), mul(perp, math.sin(k)))
end

-- Luanti entity rotation (x = pitch, y = yaw, z = roll) is Ry(-yaw) * Rx(-pitch)
-- * Rz(-roll) in standard matrices; its columns are the model's right, up and
-- forward axes in the world.
local function axes_from_rot(rot)
	local a, b, c = -(rot.y or 0), -(rot.x or 0), -(rot.z or 0)
	local ca, sa, cb, sb, cc, sc = math.cos(a), math.sin(a), math.cos(b), math.sin(b), math.cos(c), math.sin(c)
	local Ry = {{ca, 0, sa}, {0, 1, 0}, {-sa, 0, ca}}
	local Rx = {{1, 0, 0}, {0, cb, -sb}, {0, sb, cb}}
	local Rz = {{cc, -sc, 0}, {sc, cc, 0}, {0, 0, 1}}
	local m = m3_mul(m3_mul(Ry, Rx), Rz)
	return v(m[1][1], m[2][1], m[3][1]), v(m[1][2], m[2][2], m[3][2]), v(m[1][3], m[2][3], m[3][3])
end

local function rot_from_axes(right, up, fwd)
	local b = math.asin(clamp(-fwd.y, -1, 1))
	local a = math.atan2(fwd.x, fwd.z)
	local c = math.atan2(right.y, up.y)
	return v(-b, -a, -c)
end

-- Euler angles (radians) for a bone override: R = Rz(z) * Ry(y) * Rx(x).
local function euler_zyx(m)
	local y = math.asin(clamp(-m[3][1], -1, 1))
	local x, z
	if math.abs(m[3][1]) < 0.9999 then
		x = math.atan2(m[3][2], m[3][3])
		z = math.atan2(m[2][1], m[1][1])
	else
		x = math.atan2(-m[2][3], m[2][2])
		z = 0
	end
	return v(x, y, z)
end
R.math = {axes_from_rot = axes_from_rot, rot_from_axes = rot_from_axes, euler_zyx = euler_zyx,
	m3_between = m3_between, m3_mul = m3_mul, m3_t = m3_t}

--------------------------------------------------------------------------------
-- Nodes
--------------------------------------------------------------------------------
local liquid = {}
local walkable = {}
local full_solid = {}
local connected = {}                -- (boxes that depend on the neighbours: not cached)
core.register_on_mods_loaded(function()
	for name, def in pairs(core.registered_nodes) do
		if def.liquidtype and def.liquidtype ~= "none" then liquid[name] = def.liquid_viscosity or 1 end
		local dt = def.drawtype or "normal"
		if def.walkable ~= false then
			walkable[name] = true
			if not def.collision_box and not def.node_box
					and (dt == "normal" or dt == "glasslike" or dt == "glasslike_framed" or dt == "allfaces"
					or dt == "allfaces_optional" or dt == "glasslike_framed_optional") then
				full_solid[name] = true
			end
			local box = def.collision_box or (dt == "nodebox" and def.node_box)
			if type(box) == "table" and box.type == "connected" then connected[name] = true end
		end
	end
end)

local function round_pos(p) return {x = math.floor(p.x + 0.5), y = math.floor(p.y + 0.5), z = math.floor(p.z + 0.5)} end

local function node_at(p)
	local n = core.get_node_or_nil(round_pos(p))
	return n and n.name
end

-- A node's collision boxes (relative to it). Engines before 5.10 can't say:
-- there only full blocks count.
local CUBE = {{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}}
local box_cache = {}
local function boxes_of(np, node)
	local name = node.name
	if full_solid[name] then return CUBE end
	if not core.get_node_boxes then return nil end
	local key = not connected[name] and (name .. " " .. node.param2) or nil
	local bx = key and box_cache[key]
	if not bx then
		local ok, r = pcall(core.get_node_boxes, "collision_box", np, node)
		bx = ok and type(r) == "table" and r or {}
		if key then box_cache[key] = bx end
	end
	return bx
end

-- The solid box (relative to node np) point q is inside, or nil.
local function solid_at(q)
	local np = round_pos(q)
	local node = core.get_node_or_nil(np)
	if not node or not walkable[node.name] then return nil end
	local bx = boxes_of(np, node)
	if not bx then return nil end
	local lx, ly, lz = q.x - np.x, q.y - np.y, q.z - np.z
	for _, b in ipairs(bx) do
		if lx > b[1] and lx < b[4] and ly > b[2] and ly < b[5] and lz > b[3] and lz < b[6] then return b, np end
	end
	return nil
end

-- The way out of a solid box: its nearest face that opens onto free space,
-- favouring the side the rest of the body is on (out of a floor is up, out of
-- a ceiling is down - never out through the underside of a thin floor).
-- Returns axis, sign, distance and the face's coordinate.
local FACE_DIRS = {{"y", 1}, {"x", 1}, {"x", -1}, {"z", 1}, {"z", -1}, {"y", -1}}
local function exit_of(q, b, np, r, home)
	local l = {x = q.x - np.x, y = q.y - np.y, z = q.z - np.z}
	if home and solid_at(home) then home = nil end
	local best, bcost
	for _, f in ipairs(FACE_DIRS) do
		local axis, sign = f[1], f[2]
		local lo, hi = ({x = b[1], y = b[2], z = b[3]})[axis], ({x = b[4], y = b[5], z = b[6]})[axis]
		local face = sign > 0 and hi or lo
		local d = (face - l[axis]) * sign
		local bias
		if home then
			local toward = (home[axis] - (np[axis] + face)) * sign
			bias = toward > 0 and 0.5 or 3
			if axis == "y" and sign > 0 then bias = bias * 0.9 end
		else
			bias = (axis == "y") and (sign > 0 and 0.5 or 2.5) or 1
		end
		local cost = d * bias
		if not bcost or cost < bcost then
			local out = {x = q.x, y = q.y, z = q.z}
			out[axis] = np[axis] + face + sign * (r + 0.005)
			if not solid_at(out) then best, bcost = {axis, sign, d, np[axis] + face}, cost end
		end
	end
	-- (walled in: up, through whatever is above)
	best = best or {"y", 1, b[5] - l.y, np.y + b[5]}
	return best[1], best[2], best[3], best[4]
end

--------------------------------------------------------------------------------
-- Simulation
--------------------------------------------------------------------------------
-- The torso's frame: the best-fitting rigid placement of the box onto its 8
-- corners - the centroid, and the rotation from the polar decomposition of
-- the corners' covariance (no axis is favoured, so contacts on one corner
-- don't twist the box).
local function m3_inv_t(m)
	local a, b2, c = m[1][1], m[1][2], m[1][3]
	local d, e, f = m[2][1], m[2][2], m[2][3]
	local g, h, i = m[3][1], m[3][2], m[3][3]
	local A, B, C = e * i - f * h, -(d * i - f * g), d * h - e * g
	local det = a * A + b2 * B + c * C
	if math.abs(det) < 1e-12 then return nil end
	local k = 1 / det
	-- inverse transposed = cofactor matrix / det
	return {
		{A * k, B * k, C * k},
		{-(b2 * i - c * h) * k, (a * i - c * g) * k, -(a * h - b2 * g) * k},
		{(b2 * f - c * e) * k, -(a * f - c * d) * k, (a * e - b2 * d) * k},
	}
end

local function frame(b)
	local P = b.pts
	local c = v(0, 0, 0)
	for i = 1, 8 do c = add(c, P[i].x) end
	c = mul(c, 1 / 8)
	local A = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}}
	for i = 1, 8 do
		local q, d = sub(P[i].x, c), b.corner_n[i]
		A[1][1], A[1][2], A[1][3] = A[1][1] + q.x * d.x, A[1][2] + q.x * d.y, A[1][3] + q.x * d.z
		A[2][1], A[2][2], A[2][3] = A[2][1] + q.y * d.x, A[2][2] + q.y * d.y, A[2][3] + q.y * d.z
		A[3][1], A[3][2], A[3][3] = A[3][1] + q.z * d.x, A[3][2] + q.z * d.y, A[3][3] + q.z * d.z
	end
	-- polar decomposition (Higham): X <- (X + X^-T) / 2
	local X = A
	for _ = 1, 8 do
		local it = m3_inv_t(X)
		if not it then break end
		local nX = {}
		for r = 1, 3 do nX[r] = {(X[r][1] + it[r][1]) * 0.5, (X[r][2] + it[r][2]) * 0.5, (X[r][3] + it[r][3]) * 0.5} end
		X = nX
	end
	local right = norm(v(X[1][1], X[2][1], X[3][1]))
	local up = v(X[1][2], X[2][2], X[3][2])
	up = norm(sub(up, mul(right, dot(up, right))))
	local fwd = cross(right, up)
	return right, up, fwd, c
end


-- A limb's pivot in the simulation: its parent limb's end, or the point of
-- the torso box it hangs from (trilinear weights of the corners).
local function pivot_of(b, L)
	local P = b.pts
	if L.parent then return P[b.limbs[L.parent].tip].x end
	local piv = v(0, 0, 0)
	for i = 1, 8 do
		local w = L.w[i]
		if w > 0 then piv = add(piv, mul(P[i].x, w)) end
	end
	return piv
end

-- The surface a point is touching or about to hit this substep: a plane
-- (point, normal), found with one raycast along its move (or straight down
-- when it's resting within its radius of a floor).
local function first_wall(a, b2)
	local ok, ray = pcall(core.raycast, a, b2, false, false)
	if not ok or not ray then return nil end
	for hit in ray do
		if hit.type == "node" and hit.intersection_point then
			local n = hit.intersection_normal
			-- (a ray that starts inside a box hits it right there with no
			-- normal: that's no surface to rest on - see depenetrate)
			if n and (n.x ~= 0 or n.y ~= 0 or n.z ~= 0) and walkable[core.get_node(hit.under).name] then
				return hit.intersection_point, n
			end
		end
	end
	return nil
end

-- A point that was left inside a solid (it was killed in the ground or a
-- wall, or the solve pushed it in): out through the nearest open face, a
-- little at a time (a buried body rises out of the ground), without gaining
-- speed from it.
local MAX_PUSH = 0.15
local function depenetrate(pt, home)
	if not solid_at(pt.p) then return false end
	local b, np = solid_at(pt.x)
	if not b then return false end
	local axis, sign, d, face = exit_of(pt.x, b, np, pt.r, home)
	local need = d + pt.r + 0.005
	local move = math.min(need, MAX_PUSH)
	local x, p = v(pt.x.x, pt.x.y, pt.x.z), v(pt.p.x, pt.p.y, pt.p.z)
	x[axis], p[axis] = x[axis] + sign * move, p[axis] + sign * move
	if (x[axis] - p[axis]) * sign < 0 then p[axis] = x[axis] end   -- (no speed into it)
	pt.x, pt.p = x, p
	pt.cp, pt.cn, pt.cp2, pt.cn2 = nil, nil, nil, nil
	if move >= need - 1e-6 then
		-- out: that face is what it touches
		local cp, n = v(x.x, x.y, x.z), v(0, 0, 0)
		cp[axis], n[axis] = face, sign
		pt.cp, pt.cn = cp, n
	else
		pt.stuck = true
	end
	return true
end

-- During the solve: a point the constraints dragged into a solid (the rigid
-- torso turning a corner into a wall, a limb swung into the floor) gets the
-- face it went through as a contact, and is pushed back out.
local function catch_overlap(pt, home)
	if pt.stuck or pt.cp2 then return end
	local bx, np = solid_at(pt.x)
	if not bx then return end
	local axis, sign, d, face = exit_of(pt.x, bx, np, pt.r, home)
	if d > 0.5 then return end
	local cp, n = v(pt.x.x, pt.x.y, pt.x.z), v(0, 0, 0)
	cp[axis], n[axis] = face, sign
	if pt.cp then pt.cp2, pt.cn2 = cp, n else pt.cp, pt.cn = cp, n end
	local dd = (pt.x[axis] - face) * sign - pt.r
	if dd < 0 then pt.x = add(pt.x, mul(n, -dd)) end
end

local function find_contact(pt, home)
	pt.cp2, pt.cn2, pt.stuck = nil, nil, nil
	if depenetrate(pt, home) then return end
	local x, p = pt.x, pt.p
	local mv = sub(x, p)
	local dist = len(mv)
	local ip, n
	if dist > 1e-5 then
		ip, n = first_wall(p, add(x, mul(mv, pt.r / dist)))
	end
	-- (from above both where it was and where it's going, down past both:
	-- constraints may still pull it lower this substep - a plane only acts
	-- once the point reaches it, so the ray can look well below)
	local top, bot = math.max(x.y, p.y) + 0.02, math.min(x.y, p.y) - pt.r - 0.45
	if not ip then
		ip, n = first_wall(v(x.x, top, x.z), v(x.x, bot, x.z))
	elseif n.y < 0.55 then
		-- it hit a wall: what's under it counts too (a leg against a wall
		-- mustn't be pulled down through the floor)
		local ip2, n2 = first_wall(v(x.x, top, x.z), v(x.x, bot, x.z))
		if ip2 and n2.y >= 0.55 then pt.cp2, pt.cn2 = ip2, n2 end
	end
	if ip then pt.cp, pt.cn = ip, n else pt.cp, pt.cn = nil, nil end
end

-- keep a point on the outside of its contact planes
local function push_out(pt, cp, n)
	local d = (pt.x.x - cp.x) * n.x + (pt.x.y - cp.y) * n.y + (pt.x.z - cp.z) * n.z - pt.r
	if d < 0 then pt.x = add(pt.x, mul(n, -d)) end
end
local function enforce_contact(pt)
	if pt.cp then push_out(pt, pt.cp, pt.cn) end
	if pt.cp2 then push_out(pt, pt.cp2, pt.cn2) end
end

-- after the solve: lose the speed into the surface (a little bounce), friction
local function respond(pt, cp, n)
	local x, p = pt.x, pt.p
	local d = (x.x - cp.x) * n.x + (x.y - cp.y) * n.y + (x.z - cp.z) * n.z - pt.r
	if d > 0.01 then return end   -- (not actually touching)
	local vel = sub(x, p)
	local vn = dot(vel, n)
	if vn < 0 then
		local e = vn < -0.06 and BOUNCE or 0
		vel = sub(vel, mul(n, vn * (1 + e)))
	end
	local vt = sub(vel, mul(n, dot(vel, n)))
	local fr = pt.limb and LIMB_FRICTION or FRICTION
	if n.y > 0.55 then pt.ground = true else fr = math.min(fr, 0.9) end
	if len(vt) < 0.0015 then vt = v(0, 0, 0) end
	vel = add(mul(vt, fr), mul(n, dot(vel, n)))
	pt.p = sub(x, vel)
end
local function contact_response(pt)
	pt.ground = false
	if pt.cp then respond(pt, pt.cp, pt.cn) end
	if pt.cp2 then respond(pt, pt.cp2, pt.cn2) end
end

local function rigidify(b)
	local P = b.pts
	local right, up, fwd, center = frame(b)
	for i = 1, 8 do
		local d = b.corner_d[i]
		P[i].x = add(center, add(add(mul(right, d.x), mul(up, d.y)), mul(fwd, d.z)))
	end
end

-- how fast a limb's pivot is moving (its parent limb's end, or the torso there)
local function pivot_vel(b, L)
	local P = b.pts
	if L.parent then
		local pp = P[b.limbs[L.parent].tip]
		return sub(pp.x, pp.p)
	end
	local vp = v(0, 0, 0)
	for i = 1, 8 do
		local w = L.w[i]
		if w > 0 then vp = add(vp, mul(sub(P[i].x, P[i].p), w)) end
	end
	return vp
end

-- Friction in a stiff joint (f: 0 free .. 1 at the limit): the limb's swing
-- about its pivot is braked, and a slow one stops dead - it takes more to start
-- a stiff joint moving than to keep it moving.
local function joint_friction(b, L, tip, d, f)
	local vp = pivot_vel(b, L)
	local vrel = sub(sub(tip.x, tip.p), vp)
	local swing = sub(vrel, mul(d, dot(vrel, d)))
	local sp = len(swing)
	local hold = f * SOFT_HOLD
	if sp <= hold * 1.6 then
		vrel = sub(vrel, swing)
	else
		local keep = (1 - math.min(1, f * SOFT_BRAKE)) * (1 - hold / sp)
		vrel = sub(vrel, mul(swing, 1 - keep))
	end
	tip.p = sub(tip.x, add(vp, vrel))
end

-- How far a limb may bend the way it's bending: its front-back range and its
-- sideways range make an ellipse around the rest direction (in the body's
-- frame: front-back is the plane of the body's forward axis, or of its up axis
-- for limbs that point forward or back - heads on long necks, tails).
local function bend_limit(L, rest, d, up, fwd, range)
	local swing, side = L.max_angle * range, (L.side_angle or L.max_angle) * range
	local perp = sub(d, mul(rest, dot(d, rest)))
	local pl = len(perp)
	if pl < 1e-6 or math.abs(swing - side) < 1e-6 then return swing, pl > 1e-6 and mul(perp, 1 / pl) or nil end
	local u = mul(perp, 1 / pl)
	local f = sub(fwd, mul(rest, dot(fwd, rest)))
	if len(f) < 0.3 then f = sub(up, mul(rest, dot(up, rest))) end
	f = norm(f)
	local l = cross(rest, f)
	local c1, c2 = dot(u, f) / swing, dot(u, l) / side
	return 1 / math.sqrt(c1 * c1 + c2 * c2), u
end

-- A limb whose rest direction is in the ground (the legs of an animal lying
-- on its belly): the least-bent direction it can point without going through
-- the ground - legs fold forward or back, not out sideways. nil: no need.
local function floor_of(tip)
	if tip.cn and tip.cn.y >= 0.55 then return tip.cp, tip.cn end
	if tip.cn2 and tip.cn2.y >= 0.55 then return tip.cp2, tip.cn2 end
	return nil
end

local function ground_target(L, piv, tip, rest, d, up, fwd, range)
	local cp, n = floor_of(tip)
	if not cp then return nil end
	local hp = dot(sub(piv, cp), n)
	local m = clamp((tip.r - hp) / math.max(L.len, 1e-3), -1, 1)
	if dot(rest, n) >= m - 0.02 then return nil end
	local t1 = norm(math.abs(n.y) < 0.9 and cross(n, v(0, 1, 0)) or cross(n, v(1, 0, 0)))
	local t2 = cross(n, t1)
	local rad = math.sqrt(math.max(0, 1 - m * m))
	local best, bs, bd
	for i = 0, 15 do
		local a = i * math.pi / 8
		local dir = add(mul(n, m), mul(add(mul(t1, math.cos(a)), mul(t2, math.sin(a))), rad))
		local lim = bend_limit(L, rest, dir, up, fwd, range)
		local sv = math.acos(clamp(dot(dir, rest), -1, 1)) / math.max(lim, 1e-3)
		local near = dot(dir, d)
		-- (the least bent; between two about as good, the nearer)
		if not best or sv < bs * 0.95 or (sv < bs * 1.05 and near > bd) then best, bs, bd = dir, sv, near end
	end
	return best
end

-- the direction a limb hangs at rest, now (follows the torso, and the limb above)
local function rest_dir(b, L, right, up, fwd)
	local P = b.pts
	local function axes(l) return add(add(mul(right, l.x), mul(up, l.y)), mul(fwd, l.z)) end
	if L.parent then
		local pl = b.limbs[L.parent]
		local pdir = norm(sub(P[pl.tip].x, pivot_of(b, pl)))
		local prest = norm(rest_dir(b, pl, right, up, fwd))
		return m3_vec(m3_between(prest, pdir), axes(L.dir_l))
	end
	return axes(L.dir_l)
end

local function step(b, dt)
	local g = gravity() * dt * dt
	local P = b.pts
	-- move
	for _, pt in ipairs(P) do
		local x, p = pt.x, pt.p
		local vx, vy, vz = (x.x - p.x) * DAMP, (x.y - p.y) * DAMP, (x.z - p.z) * DAMP
		local acc = g
		if liquid[node_at(x) or ""] then
			-- in water: thick drag and floating
			vx, vy, vz = vx * 0.88, vy * 0.88, vz * 0.88
			acc = -g * 0.35
		end
		pt.p = v(x.x, x.y, x.z)
		pt.x = v(x.x + vx, x.y + vy + acc, x.z + vz)
	end
	-- what each point touches this substep
	-- (where the body is: the side to push stuck points out on)
	local home = v(0, 0, 0)
	for i = 1, 8 do home = add(home, P[i].x) end
	home = mul(home, 1 / 8)
	for _, pt in ipairs(P) do
		if pt.ghost then pt.cp, pt.cp2 = nil, nil else find_contact(pt, home) end
	end
	for _ = 1, ITER do
		-- the torso is a rigid box: fit it to the corners and restore its shape
		rigidify(b)
		-- limbs on their links. Limp limbs don't push the torso around (they
		-- couldn't hold a body up anyway); a limb further down shares the pull
		-- with the one above it.
		for _, L in ipairs(b.limbs) do
			local tip = P[L.tip]
			local piv = pivot_of(b, L)
			local d = sub(tip.x, piv)
			local l = len(d)
			if l > 1e-9 then
				local corr = mul(d, (l - L.len) / l)
				-- (unless the limb above is at its limit: a joint bent all the
				-- way is locked, the one below can't drag it further)
				if L.parent and not L.ghost and not b.limbs[L.parent].at_limit then
					local pp = P[b.limbs[L.parent].tip]
					tip.x = sub(tip.x, mul(corr, 0.7))
					pp.x = add(pp.x, mul(corr, 0.3))
				else
					tip.x = sub(tip.x, corr)
				end
			end
		end
		for _, pt in ipairs(P) do
			enforce_contact(pt)
			if not pt.ghost then catch_overlap(pt, home) end
		end
	end
	-- joint limits: a hard one, and growing resistance on the way to it
	if #b.limbs > 0 then
		local right, up, fwd = frame(b)
		local range, stiff = R.setting("joint_range", 1), R.setting("joint_stiffness", 1)
		for _, L in ipairs(b.limbs) do
			local tip = P[L.tip]
			local piv = pivot_of(b, L)
			local rest = norm(rest_dir(b, L, right, up, fwd))
			local d = norm(sub(tip.x, piv))
			local ang = math.acos(clamp(dot(d, rest), -1, 1))
			local limit, u = bend_limit(L, rest, d, up, fwd, range)
			if L.ghost then limit, u = L.max_angle, nil end
			local s = ang / math.max(limit, 1e-3)
			L.at_limit = ang > limit and not L.ghost
			-- (would the limb, pointing that way, be in the floor under it - or
			-- in any solid node, the floor unseen when it's already sunk in?)
			local fp, fn = floor_of(tip)
			local function in_floor(dir)
				local t = add(piv, mul(dir, L.len))
				if fp and dot(sub(t, fp), fn) < tip.r - 0.01 then return true end
				return solid_at(t) ~= nil
			end
			-- where the rest pose is out of reach below the ground, the limb is
			-- drawn round to the least bent way it can lie there instead
			local function lie(gently)
				local best = not L.ghost and ground_target(L, piv, tip, rest, d, up, fwd, range)
				if not best then return end
				local off = math.acos(clamp(dot(d, best), -1, 1))
				if off > 0.03 then
					local nx = add(piv, mul(swing_toward(d, best, off * gently), L.len))
					tip.p = add(tip.p, sub(nx, tip.x))
					tip.x = nx
				end
			end
			local gently = 0.2 * math.max(stiff, 0.2)
			if tip.ground and dot(sub(rest, d), tip.cn2 or tip.cn or v(0, 1, 0)) < 0 then
				-- resting on the ground, and the joint would push it into it
				lie(gently)
			elseif ang > limit then
				local tdir = swing_toward(d, rest, ang - limit)
				if in_floor(tdir) then
					lie(gently)
				else
					-- past the joint's limit: back onto it, losing most of the swing
					local nx = add(piv, mul(tdir, L.len))
					local delta = sub(nx, tip.x)
					local vel = sub(tip.x, tip.p)
					tip.x = nx
					-- (the speed out past the limit is gone - kept, a limb held
					-- on its limit would carry a speed it never has, and the limb
					-- below, damped toward it, would slide along forever)
					local dn, dl = norm(delta)
					if dl > 1e-9 then
						local vn = dot(vel, dn)
						if vn < 0 then vel = sub(vel, mul(dn, vn)) end
					end
					tip.p = sub(tip.x, mul(vel, 0.4))
					-- (and at its stiffest: no sliding round the edge of its range)
					if stiff > 0 and not L.ghost then joint_friction(b, L, tip, tdir, stiff) end
				end
			elseif s > SOFT and stiff > 0 and u and not L.ghost then
				-- bent far: stiffer the farther (quadratic from SOFT to the limit)
				joint_friction(b, L, tip, d, ((s - SOFT) / (1 - SOFT)) ^ 2 * stiff)
			elseif L.tone > 0 and not L.parent and ang > 0.02 and not tip.ground
					and not (L.child and P[b.limbs[L.child].tip].ground) then
				-- (root limbs only: tone down a chain feeds back on itself; and
				-- not once the limb below rests on the ground - a neck held up by
				-- its head would push the head along forever)
				-- muscle tone: a soft, damped spring toward the rest pose
				tip.x = add(piv, mul(swing_toward(d, rest, ang * L.tone * 0.5), L.len))
				tip.p = sub(tip.x, mul(sub(tip.x, tip.p), 0.9))
			end
			enforce_contact(tip)
			if not tip.ghost then catch_overlap(tip, home) end
		end
	end
	-- limp limbs swing down and stop: damp each limb's swing (relative to
	-- what it hangs from, so a flying body isn't slowed)
	for _, L in ipairs(b.limbs) do
		local tip = P[L.tip]
		local vp = pivot_vel(b, L)
		local vt = sub(tip.x, tip.p)
		tip.p = sub(tip.x, add(vp, mul(sub(vt, vp), LIMB_DAMP)))
	end
	local grounded = 0
	for _, pt in ipairs(P) do
		contact_response(pt)
		if pt.ground then grounded = grounded + 1 end
	end
	-- no standing corpses: a limp body can't balance on end (its spine would
	-- give). Resting with its long axis upright, it gets a firm shove over its
	-- thinnest side (a few tries at most).
	if grounded > 0 and b.elongated and b.t - (b.woke or 0) > 0.4 and (b.kicks or 0) < 4 and b.t >= (b.next_kick or 0)
			then
		local axes = {frame(b)}
		local axis = axes[b.long_axis]
		local fast = 0
		for i = 1, 8 do fast = math.max(fast, len(sub(P[i].x, P[i].p))) end
		if math.abs(axis.y) > 0.82 and fast < 0.02 then
			b.kicks = (b.kicks or 0) + 1
			b.next_kick = b.t + 0.7
			local top = axis.y > 0 and 1 or -1
			-- the thinner of the other two sides
			local ext = b.ext
			local thin, tk = nil, math.huge
			for k = 1, 3 do
				if k ~= b.long_axis and ext[k] < tk then thin, tk = k, ext[k] end
			end
			local dir = norm(v(axes[thin].x, 0, axes[thin].z))
			if math.random() < 0.5 then dir = mul(dir, -1) end
			-- turn it about the bottom edge on that side
			local edge, n = v(0, 0, 0), 0
			for i = 1, 8 do
				local d = b.corner_d[i]
				local along = ({d.x, d.y, d.z})[b.long_axis]
				if along * top < 0 and dot(sub(P[i].x, axes[4]), dir) > 0 then
					edge = add(edge, P[i].x)
					n = n + 1
				end
			end
			if n > 0 then
				edge = mul(edge, 1 / n)
				local omega = mul(cross(v(0, 1, 0), dir), 5)
				for i = 1, 8 do
					local vel = cross(omega, sub(P[i].x, edge))
					P[i].p = sub(P[i].x, mul(vel, dt))
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------
-- a bone, and its copies in models with the skeleton once per mesh
local function set_bone(b, bone, override)
	b.obj:set_bone_override(bone, override)
	local others = b.bone_aliases and b.bone_aliases[bone]
	if others then
		for _, name in ipairs(others) do b.obj:set_bone_override(name, override) end
	end
end

local function render(b, interp)
	local obj = b.obj
	local right, up, fwd, center = frame(b)
	local origin = sub(center, add(add(mul(right, b.center_l.x), mul(up, b.center_l.y)), mul(fwd, b.center_l.z)))
	obj:set_pos(origin)
	obj:set_rotation(rot_from_axes(right, up, fwd))
	-- (the engine lights an object by the brightest of its collisionbox's
	-- corners and centre: keep that box around the body - lying on the floor,
	-- the model's origin is often inside the ground, which would be pitch black)
	local mn, mx = v(math.huge, math.huge, math.huge), v(-math.huge, -math.huge, -math.huge)
	for i = 1, 8 do
		local q = sub(b.pts[i].x, origin)
		mn = v(math.min(mn.x, q.x), math.min(mn.y, q.y), math.min(mn.z, q.z))
		mx = v(math.max(mx.x, q.x), math.max(mx.y, q.y), math.max(mx.z, q.z))
	end
	local lb = b.light_box
	if not lb or math.abs(lb[1] - mn.x) + math.abs(lb[2] - mn.y) + math.abs(lb[3] - mn.z) + math.abs(lb[4] - mx.x)
			+ math.abs(lb[5] - mx.y) + math.abs(lb[6] - mx.z) > 0.3 then
		b.light_box = {mn.x, mn.y, mn.z, mx.x, mx.y + 0.1, mx.z}
		obj:set_properties({collisionbox = b.light_box})
	end
	if #b.limbs == 0 or not obj.set_bone_override then return end
	local P = b.pts
	local s = b.scale
	-- model-space directions (undo visual_size so rotations match the mesh)
	local function model_dir(w)
		local l = v(dot(w, right) / s.x, dot(w, up) / s.y, dot(w, fwd) / s.z)
		return norm(l)
	end
	for i, L in ipairs(b.limbs) do
		local piv = pivot_of(b, L)
		local dm = model_dir(sub(P[L.tip].x, piv))
		local parentD = L.parent and b.limbs[L.parent].D or I3
		local rest = m3_vec(parentD, L.dir_m)
		local E = m3_between(norm(rest), dm)
		L.D = m3_mul(E, parentD)
		-- the bone's own rotation, absolute (the frozen animation frame may
		-- hold the limb anywhere - a zombie's arms forward): its rest rotation
		-- turned by everything above it and itself, in its parent's space
		local Dp = parentD
		local local_rot = m3_mul(m3_mul(m3_mul(L.prot_t, m3_t(Dp)), m3_mul(L.D, L.prot)), L.lrot)
		local e = euler_zyx(local_rot)
		local last = L.sent
		if not last or math.abs(last.x - e.x) + math.abs(last.y - e.y) + math.abs(last.z - e.z) > 0.01 then
			L.sent = e
			set_bone(b, L.bone, {rotation = {vec = e, absolute = true, interpolation = interp}})
		end
	end
	for _, F in ipairs(b.followers or {}) do
		local L = b.limbs[F.leader]
		if L and L.D then
			local e = euler_zyx(m3_mul(m3_mul(m3_mul(F.prot_t, L.D), F.prot), F.lrot))
			local last = F.sent
			if not last or math.abs(last.x - e.x) + math.abs(last.y - e.y) + math.abs(last.z - e.z) > 0.01 then
				F.sent = e
				set_bone(b, F.bone, {rotation = {vec = e, absolute = true, interpolation = interp}})
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Building a body
--------------------------------------------------------------------------------
local function collisionbox_of(props)
	local cb = props.collisionbox or props.selectionbox or {-0.3, 0, -0.3, 0.3, 1.7, 0.3}
	return cb
end

-- snap: {props, pos, rot, vel, frame, texture_mod, hit = {dir, power}, children}
function R.build(obj, snap)
	local props = snap.props
	local vs = props.visual_size or {x = 1, y = 1}
	local scale = {x = (vs.x or 1) / 10, y = (vs.y or 1) / 10, z = (vs.z or vs.x or 1) / 10}
	local cb = collisionbox_of(props)
	local rig = props.visual == "mesh" and props.mesh and R.get_rig(props.mesh) or nil
	local prof = snap.profile or {}
	local bmin, bmax
	if rig and rig.box and not prof.rigid_only then
		bmin = v(rig.box.min[1] * scale.x, rig.box.min[2] * scale.y, rig.box.min[3] * scale.z)
		bmax = v(rig.box.max[1] * scale.x, rig.box.max[2] * scale.y, rig.box.max[3] * scale.z)
		-- (hidden extra geometry - armor layers, decorations - mustn't make the
		-- body bigger than the creature: keep it within its collisionbox height
		-- and not much wider)
		local half = math.max(math.abs(cb[1]), math.abs(cb[3]), math.abs(cb[4]), math.abs(cb[6]), 0.2)
		bmin.y, bmax.y = math.max(bmin.y, cb[2] - 0.1), math.min(bmax.y, cb[5] + 0.1)
		for _, a in ipairs({"x", "z"}) do
			bmin[a], bmax[a] = math.max(bmin[a], -half * 2.2), math.min(bmax[a], half * 2.2)
		end
	else
		-- no bones (or not a mesh): the collisionbox, a little smaller
		bmin = v(cb[1] * 0.9, cb[2], cb[3] * 0.9)
		bmax = v(cb[4] * 0.9, cb[5], cb[6] * 0.9)
		if props.visual == "mesh" and not rig then bmin.y = math.max(bmin.y, cb[2]) end
	end
	for _, a in ipairs({"x", "y", "z"}) do
		if bmax[a] - bmin[a] < 0.08 then
			local c = (bmax[a] + bmin[a]) / 2
			bmin[a], bmax[a] = c - 0.04, c + 0.04
		end
	end
	-- the box holds every limb's pivot (shoulders, hips, neck), so a pivot is
	-- exactly a blend of the corners
	if rig and not prof.rigid_only then
		for _, l in ipairs(rig.limbs) do
			if not l.parent and not l.ghost then
				local px, py, pz = l.pivot[1] * scale.x, l.pivot[2] * scale.y, l.pivot[3] * scale.z
				bmin.x, bmax.x = math.min(bmin.x, px), math.max(bmax.x, px)
				bmin.y, bmax.y = math.min(bmin.y, py), math.max(bmax.y, py)
				bmin.z, bmax.z = math.min(bmin.z, pz), math.max(bmax.z, pz)
			end
		end
	end
	local b = {obj = obj, pts = {}, limbs = {}, scale = scale, t = 0, acc = 0, quiet = 0}
	local alias = props.mesh and R.mesh_aliases and R.mesh_aliases[props.mesh]
	b.bone_aliases = alias and alias.bones
	b.center_l = mul(add(bmin, bmax), 0.5)
	local right, up, fwd = axes_from_rot(snap.rot or v(0, 0, 0))
	local pos = snap.pos
	local function world(l)
		return add(pos, add(add(mul(right, l.x), mul(up, l.y)), mul(fwd, l.z)))
	end
	local corner_l = {}
	for i = 0, 7 do
		local x, y, z = i % 2, math.floor(i / 2) % 2, math.floor(i / 4)
		corner_l[i + 1] = v(x == 1 and bmax.x or bmin.x, y == 1 and bmax.y or bmin.y, z == 1 and bmax.z or bmin.z)
		b.pts[i + 1] = {x = world(corner_l[i + 1]), r = 0.03}
	end
	b.corner_d, b.corner_n = {}, {}
	for i = 1, 8 do
		b.corner_d[i] = sub(corner_l[i], b.center_l)
		-- (normalised per axis for the fit, so a long flat box fits as well as a cube)
		local d = b.corner_d[i]
		local hx, hy, hz = (bmax.x - bmin.x) / 2, (bmax.y - bmin.y) / 2, (bmax.z - bmin.z) / 2
		b.corner_n[i] = v(d.x / hx, d.y / hy, d.z / hz)
	end
	-- (its longest side: a body mustn't come to rest standing on end)
	local ext = {bmax.x - bmin.x, bmax.y - bmin.y, bmax.z - bmin.z}
	b.long_axis = (ext[1] >= ext[2] and ext[1] >= ext[3]) and 1 or ((ext[2] >= ext[3]) and 2 or 3)
	b.ext = ext
	-- (only a body clearly longer one way can stand on end; a cube just sits)
	local sorted = {ext[1], ext[2], ext[3]}
	table.sort(sorted)
	b.elongated = sorted[3] > sorted[2] * 1.25
	-- limbs
	if rig and not prof.rigid_only then
		local tips_l = {}
		local has_child = {}
		for _, l in ipairs(rig.limbs) do
			if l.parent then has_child[l.parent] = true end
		end
		local avg_scale = (scale.x + scale.y + scale.z) / 3
		for li, l in ipairs(rig.limbs) do
			local skip = prof.skip_bones and prof.skip_bones[l.bone]
			if not skip and l.parent and not b.limbs[tips_l[l.parent] or -1] then skip = true end
			if not skip then
				local piv = v(l.pivot[1] * scale.x, l.pivot[2] * scale.y, l.pivot[3] * scale.z)
				local tipm = {l.pivot[1] + l.dir[1] * l.len, l.pivot[2] + l.dir[2] * l.len, l.pivot[3] + l.dir[3] * l.len}
				local tip = v(tipm[1] * scale.x, tipm[2] * scale.y, tipm[3] * scale.z)
				local dl, ll = norm(sub(tip, piv))
				-- the limb's end touches the ground with its real thickness; at the
				-- end of a chain the point sits that far in from the far end, so
				-- the limb's length doesn't grow (and a foot stands where it stood)
				local r = math.max(0.02, math.min((l.thick or 0) * avg_scale, ll * 0.4, 0.35))
				if not l.thick then r = math.max(0.02, math.min(0.08, ll * 0.15)) end
				if not has_child[li] and ll > 0.02 then
					local keep = math.max(ll - r, ll * 0.6)
					tip = add(piv, mul(dl, keep))
					ll = keep
				end
				if ll > 0.02 then
					local rot = l.rot
					local L = {bone = l.bone, pivot_l = piv, dir_l = dl, len = ll, dir_m = v(l.dir[1], l.dir[2], l.dir[3]),
						rot = rot, rot_t = m3_t(rot), lrot = l.lrot, prot = l.prot, prot_t = m3_t(l.prot), max_angle = l.max_angle, side_angle = l.side_angle or l.max_angle,
						tone = l.tone or 0, tip = #b.pts + 1, ghost = l.ghost}
					-- (a profile's max_angle caps the bone's range both ways)
					local cap = prof.max_angle and tonumber(prof.max_angle[l.bone])
					if cap then
						local k = cap / math.max(L.max_angle, 1e-3)
						L.max_angle, L.side_angle = cap, L.side_angle * k
					end
					if l.parent then
						L.parent = tips_l[l.parent]
						local pl = b.limbs[L.parent]
						pl.child = pl.child or (#b.limbs + 1)
					end
					-- where the pivot sits in the box (0..1 each way) -> corner weights
					local function frac(a)
						local span = bmax[a] - bmin[a]
						return span > 1e-6 and clamp((piv[a] - bmin[a]) / span, 0, 1) or 0.5
					end
					local u, vv, w = frac("x"), frac("y"), frac("z")
					L.w, L.wsum = {}, 0
					for ci = 0, 7 do
						local x, y, z = ci % 2, math.floor(ci / 2) % 2, math.floor(ci / 4)
						local wt = (x == 1 and u or 1 - u) * (y == 1 and vv or 1 - vv) * (z == 1 and w or 1 - w)
						L.w[ci + 1] = wt
						L.wsum = L.wsum + wt * wt
					end
					b.pts[#b.pts + 1] = {x = world(tip), r = r, ghost = l.ghost, limb = true}
					b.limbs[#b.limbs + 1] = L
					tips_l[li] = #b.limbs
					b.limb_of_rig = b.limb_of_rig or {}
					b.limb_of_rig[li] = #b.limbs
				end
			end
		end
	end
	-- overlay bones that move with a limb
	b.followers = {}
	if rig and not prof.rigid_only then
		for _, f in ipairs(rig.followers or {}) do
			local li = b.limb_of_rig and b.limb_of_rig[f.leader]
			if li then
				b.followers[#b.followers + 1] = {bone = f.bone, leader = li, lrot = f.lrot, prot = f.prot, prot_t = m3_t(f.prot)}
			end
		end
	end
	-- killed partly in the ground (or in a wall): the body starts on top of it.
	-- The smallest lift that frees every point, or failing that (a ceiling in
	-- the way) the one that frees the most; whatever's still stuck works its
	-- way out in the simulation.
	do
		local function stuck(dy)
			local n = 0
			for _, pt in ipairs(b.pts) do
				if not pt.ghost and solid_at(v(pt.x.x, pt.x.y + dy, pt.x.z)) then n = n + 1 end
			end
			return n
		end
		local now = stuck(0)
		if now > 0 then
			local lifts = {}
			for _, pt in ipairs(b.pts) do
				if not pt.ghost then
					local q = v(pt.x.x, pt.x.y, pt.x.z)
					for _ = 1, 4 do
						local bx, np = solid_at(q)
						if not bx then break end
						q.y = np.y + bx[5] + 0.01
						lifts[#lifts + 1] = q.y - pt.x.y
					end
				end
			end
			table.sort(lifts)
			local best, fewest = 0, now
			for _, dy in ipairs(lifts) do
				if dy > 2.5 then break end
				local n = stuck(dy)
				if n < fewest then best, fewest = dy, n end
				if n == 0 then break end
			end
			if best > 0 then
				for _, pt in ipairs(b.pts) do pt.x = v(pt.x.x, pt.x.y + best, pt.x.z) end
				pos = v(pos.x, pos.y + best, pos.z)
			end
		end
	end
	-- initial motion: the body's own velocity, the knockback of the killing
	-- hit (the game's own, see knockback.lua, or a guess from the damage), a
	-- blast that killed it, a tumble
	local vel = snap.vel or v(0, 0, 0)
	local hit = snap.hit or {}
	local scale = R.setting("impulse", 1)
	local blasts = snap.blasts or {}
	local push, power, hdir     -- push: every point's share of the knockback
	if #blasts > 0 then
		-- (thrown by the blast below; what the game set on the mob is part of it)
		vel, power = v(0, 0, 0), 0
	elseif snap.kb and R.knockback then
		push = R.knockback.launch(snap.kb, scale)
		power = len(push)
		hdir = power > 1e-3 and norm(push) or nil
		-- what it was doing apart from the knockback (the game may already have
		-- given it: then it's in the velocity it carries)
		if snap.kb.applied then
			vel = sub(vel, snap.kb.vel)
			if hdir then
				local along = dot(vel, hdir)
				if along < 0 then vel = sub(vel, mul(hdir, along)) end
			end
		end
		local sp = len(vel)
		if sp > 5 then vel = mul(vel, 5 / sp) end
	else
		power = math.min(tonumber(hit.power) or 0, 14) * scale
		hdir = hit.dir and len(hit.dir) > 1e-3 and norm(hit.dir) or nil
		-- (the mob API may already have knocked it back: cap what it carries
		-- in, and let the hit only add what the body isn't already doing)
		local sp = len(vel)
		if sp > 6 then vel = mul(vel, 6 / sp) end
		local extra = power
		if hdir then extra = math.max(0, power - math.max(0, dot(vel, hdir))) end
		push = mul(hdir or v(0, 0, 0), extra)
	end
	local flat = hdir and norm(v(hdir.x, 0, hdir.z))
	if not flat or (flat.x == 0 and flat.z == 0) then
		local a = math.random() * math.pi * 2
		flat = v(math.cos(a), 0, math.sin(a))
	end
	local h, w, d = bmax.y - bmin.y, bmax.x - bmin.x, bmax.z - bmin.z
	local spin
	local mag = (1.6 + math.random() * 1.0 + math.min(power, 14) * 0.3) * R.setting("spin", 1)
	-- (upright creatures - people, zombies - have a tall, narrow collisionbox)
	local cbw = math.max(cb[4] - cb[1], cb[6] - cb[3], 0.1)
	if (cb[5] - cb[2]) > cbw * 1.6 or h > math.max(w, d) * 1.2 then
		-- tall (people): topple the way the hit went
		spin = mul(cross(up, flat), mag + 1)
	else
		-- long and low (animals): roll onto a side
		local side = dot(flat, right) >= 0 and 1 or -1
		spin = mul(fwd, -mag * side)
	end
	local center = world(b.center_l)
	for i, pt in ipairs(b.pts) do
		local wgt = i <= 8 and 1 or 0.8
		local iv = add(mul(vel, 0.9), mul(push or v(0, 0, 0), wgt))
		if hit.splash then iv.y = iv.y + power * 0.5 * wgt end
		iv = add(iv, cross(spin, sub(pt.x, center)))
		iv = add(iv, v((math.random() - 0.5) * 0.4, math.random() * 0.2, (math.random() - 0.5) * 0.4))
		pt.p = sub(pt.x, mul(iv, SUB))
	end
	b.is_player = snap.is_player
	for _, bl in ipairs(blasts) do R._internal.blast_body(b, bl, false) end
	return b
end

--------------------------------------------------------------------------------
-- Life cycle
--------------------------------------------------------------------------------
-- Fading out: the body turns see-through over FADE seconds (it keeps
-- falling if it's still moving). Held items can't be see-through: they shrink
-- away instead. The opacity goes in steps, so every body of a kind shares the
-- same few textures on the client.
local FADE = 2
local FADE_STEPS = 12
local function fade(b)
	if b.fade then return end
	local obj = b.obj
	if not obj:is_valid() then b.dead = true return end
	b.fade, b.fade_level = 0, FADE_STEPS
	obj:set_properties({use_texture_alpha = true})
	b.parts = {}
	for _, c in ipairs(obj.get_children and obj:get_children() or {}) do
		local p = c:get_properties()
		if p then
			local vis = p.visual
			local shrink = vis == "wielditem" or vis == "item" or vis == "node" or vis == "upright_sprite"
			b.parts[#b.parts + 1] = {obj = c, size = p.visual_size, shrink = shrink, tm = c:get_texture_mod() or ""}
			if not shrink then c:set_properties({use_texture_alpha = true}) end
		end
	end
end

-- returns true once it's gone
local function fade_step(b, dtime)
	local obj = b.obj
	b.fade = b.fade + dtime
	local level = math.ceil((1 - b.fade / FADE) * FADE_STEPS)
	if level <= 0 then
		obj:remove()
		return true
	end
	if level ~= b.fade_level then
		b.fade_level = level
		local k = level / FADE_STEPS
		local alpha = math.floor(255 * k + 0.5)
		obj:set_texture_mod((b.texture_mod or "") .. "^[opacity:" .. alpha)
		for _, part in ipairs(b.parts) do
			if part.obj:is_valid() then
				if part.shrink then
					local s = part.size or {x = 1, y = 1, z = 1}
					part.obj:set_properties({visual_size = {x = (s.x or 1) * k, y = (s.y or 1) * k, z = (s.z or s.x or 1) * k}})
				else
					part.obj:set_texture_mod(part.tm .. "^[opacity:" .. alpha)
				end
			end
		end
	end
	return false
end

local function poof(b)
	local obj = b.obj
	if not obj:is_valid() then return end
	local p = obj:get_pos()
	for _ = 1, 14 do
		core.add_particle({
			pos = vector.offset(p, math.random() - 0.5, math.random() * 0.8, math.random() - 0.5),
			velocity = {x = math.random() - 0.5, y = math.random(), z = math.random() - 0.5},
			expirationtime = math.random(5, 10) / 10, size = math.random(3, 6), texture = "[fill:4x4:#d8d8d8^[opacity:200",
		})
	end
	obj:remove()
end

-- how: "fade" (the default), "poof" or "vanish"
function R.despawn(b, how)
	how = how or R.setting("despawn", "fade")
	if how == "poof" then
		b.dead = true
		poof(b)
	elseif how == "vanish" then
		b.dead = true
		if b.obj:is_valid() then b.obj:remove() end
	else
		fade(b)
	end
end

function R.add_body(b)
	bodies[#bodies + 1] = b
	-- too many: the oldest go (fading ones are on their way already)
	local max = R.setting("max", 30)
	local n = 0
	for _, o in ipairs(bodies) do
		if not o.fade and not o.dead then n = n + 1 end
	end
	for _, o in ipairs(bodies) do
		if n <= max then break end
		if not o.fade and not o.dead and o.obj:is_valid() then
			R.despawn(o)
			n = n - 1
		end
	end
	render(b, 0)
end

core.register_globalstep(function(dtime)
	local t0 = core.get_us_time()
	local life = R.setting("lifetime", 15)
	for i = #bodies, 1, -1 do
		local b = bodies[i]
		if not b.obj:is_valid() then
			table.remove(bodies, i)
		elseif b.dead then
			table.remove(bodies, i)
		elseif b.fade and fade_step(b, dtime) then
			table.remove(bodies, i)
		else
			b.t = b.t + dtime
			if life > 0 and b.t >= life and not b.fade then R.despawn(b) end
			if b.dead then
				table.remove(bodies, i)
			elseif not b.asleep then
				b.acc = b.acc + math.min(dtime, 0.25)
				while b.acc >= SUB do
					b.acc = b.acc - SUB
					step(b, SUB)
				end
				render(b, math.max(0.05, dtime * 1.2))
				-- settled (nothing moved more than a hair in 0.6 s): stop simulating
				b.quiet = b.quiet + dtime
				if b.quiet >= 0.6 then
					local moved = 0
					if b.snap_pts then
						for k, pt in ipairs(b.pts) do
							local s0 = b.snap_pts[k]
							local d = math.abs(pt.x.x - s0.x) + math.abs(pt.x.y - s0.y) + math.abs(pt.x.z - s0.z)
							if d > moved then moved = d end
						end
					else
						moved = 1
					end
					local awake_for = b.t - (b.woke or 0)
					if (awake_for > 1.2 and moved < 0.02) or awake_for > 8 then b.asleep = true end
					b.snap_pts = {}
					for k, pt in ipairs(b.pts) do b.snap_pts[k] = v(pt.x.x, pt.x.y, pt.x.z) end
					b.quiet = 0
				end
			end
		end
	end
	R.stats.us = R.stats.us + (core.get_us_time() - t0)
	R.stats.frames = R.stats.frames + 1
end)

-- A blast throws a body: each point away from the blast, the near side
-- harder (so it tumbles away), as hard as the game's explosion would throw
-- the creature. A body already lying there needs a clear line to the blast.
local function blast_body(b, bl, existing)
	b.blasted = b.blasted or {}
	if b.blasted[bl] then return end
	local _, _, _, c = frame(b)
	local launch = R.knockback and R.knockback.blast_launch(bl, c, b.is_player)
	if not launch then return end
	if existing then
		local ok, clear = pcall(core.line_of_sight, bl.pos, c)
		if ok and clear == false then
			-- (a corner of it may still stick out: try just above)
			local ok2, clear2 = pcall(core.line_of_sight, vector.offset(bl.pos, 0, 0.5, 0), vector.offset(c, 0, 0.4, 0))
			if not (ok2 and clear2) then return end
		end
	end
	b.blasted[bl] = true
	local dc = math.max(0.5, len(sub(c, bl.pos)))
	for _, pt in ipairs(b.pts) do
		local k = clamp(dc / math.max(0.5, len(sub(pt.x, bl.pos))), 0.7, 1.5)
		pt.p = sub(pt.p, mul(launch, k * SUB))
	end
	-- (awake again, if it had settled)
	b.asleep, b.quiet, b.snap_pts, b.woke, b.kicks = false, 0, nil, b.t, 0
end

R._internal = {step = function(b, dt) return step(b, dt or SUB) end, render = function(b, i) return render(b, i or 0) end,
	frame = function(b) return frame(b) end, SUB = SUB, solid_at = solid_at, FADE = FADE, blast_body = blast_body}

-- Where a ragdoll's body is (for death cams and the like), or nil once it's gone.
function R.body_pos(obj)
	for _, b in ipairs(bodies) do
		if b.obj == obj and obj:is_valid() then
			local _, _, _, c = frame(b)
			return vector.new(c.x, c.y, c.z)
		end
	end
	return nil
end
