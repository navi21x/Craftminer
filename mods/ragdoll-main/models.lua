-- Reading model files: the bones of a .b3d (or .gltf/.glb) model, where they
-- are in the rest pose, and which vertices they move. From that, `analyze`
-- works out a rig for any skinned model, without knowing the mob: the core
-- (the bones that carry most of the body) and the limbs hanging off it (legs,
-- arms, wings, tails, heads...), each limb's pivot, rest direction and length.
--
-- Matrices are 4x4, column-major (m[13..15] = translation), the same layout
-- and conventions as the engine's loaders (irr/src/CB3DMeshFileLoader.cpp):
-- a node's local matrix is T * R * S, where R is the TRANSPOSED matrix of the
-- quaternion stored in the file (w, x, y, z); vertices are moved into model
-- space by their mesh node's global matrix as they're read.
local M = {}

--------------------------------------------------------------------------------
-- Little-endian binary reading (Lua 5.1 / LuaJIT: no string.unpack)
--------------------------------------------------------------------------------
local byte, floor = string.byte, math.floor

local function f32(s, i)
	local b1, b2, b3, b4 = byte(s, i, i + 3)
	if not b4 then return 0 end
	local sign = b4 >= 128 and -1 or 1
	local exp = (b4 % 128) * 2 + floor(b3 / 128)
	local mant = ((b3 % 128) * 256 + b2) * 256 + b1
	if exp == 0 then
		if mant == 0 then return 0 end
		return sign * mant * 2 ^ -149
	elseif exp == 255 then
		return 0   -- inf / nan: treat as nothing
	end
	return sign * (1 + mant / 8388608) * 2 ^ (exp - 127)
end

local function i32(s, i)
	local b1, b2, b3, b4 = byte(s, i, i + 3)
	if not b4 then return 0 end
	local n = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
	if n >= 2147483648 then n = n - 4294967296 end
	return n
end

local function u16(s, i)
	local b1, b2 = byte(s, i, i + 1)
	return (b1 or 0) + (b2 or 0) * 256
end
M.f32, M.i32 = f32, i32

--------------------------------------------------------------------------------
-- Matrices
--------------------------------------------------------------------------------
local function mat_identity()
	return {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
end

local function mat_mul(a, b)
	local r = {}
	for c = 0, 3 do
		for row = 1, 4 do
			local s = 0
			for k = 0, 3 do s = s + a[k * 4 + row] * b[c * 4 + k + 1] end
			r[c * 4 + row] = s
		end
	end
	return r
end

local function mat_point(m, x, y, z)
	return m[1] * x + m[5] * y + m[9] * z + m[13],
		m[2] * x + m[6] * y + m[10] * z + m[14],
		m[3] * x + m[7] * y + m[11] * z + m[15]
end

-- T * R * S, R from quaternion (x, y, z, w); `transposed` like Irrlicht's
-- getMatrix_transposed (b3d) or not (glTF, already converted).
local function mat_trs(t, q, s, transposed)
	local x, y, z, w = q[1], q[2], q[3], q[4]
	local n = math.sqrt(x * x + y * y + z * z + w * w)
	if n < 1e-9 then x, y, z, w = 0, 0, 0, 1 else x, y, z, w = x / n, y / n, z / n, w / n end
	local m = {
		1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0,
		2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0,
		2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0,
		0, 0, 0, 1,
	}
	if transposed then
		m[2], m[5] = m[5], m[2]
		m[3], m[9] = m[9], m[3]
		m[7], m[10] = m[10], m[7]
	end
	for c = 0, 2 do
		local k = s[c + 1] or 1
		m[c * 4 + 1], m[c * 4 + 2], m[c * 4 + 3] = m[c * 4 + 1] * k, m[c * 4 + 2] * k, m[c * 4 + 3] * k
	end
	m[13], m[14], m[15] = t[1], t[2], t[3]
	return m
end

-- The rotation part of a global matrix (orthonormalized), as a row-major 3x3.
local function mat_rot3(m)
	local cols = {}
	for c = 0, 2 do
		local x, y, z = m[c * 4 + 1], m[c * 4 + 2], m[c * 4 + 3]
		local l = math.sqrt(x * x + y * y + z * z)
		if l < 1e-9 then l = 1 end
		cols[c + 1] = {x / l, y / l, z / l}
	end
	return {
		{cols[1][1], cols[2][1], cols[3][1]},
		{cols[1][2], cols[2][2], cols[3][2]},
		{cols[1][3], cols[2][3], cols[3][3]},
	}
end
M.mat_trs, M.mat_mul, M.mat_point = mat_trs, mat_mul, mat_point

--------------------------------------------------------------------------------
-- .b3d
--------------------------------------------------------------------------------
-- Returns {nodes = {{name, parent, children, global, weights = {[vid] = w}}...},
-- verts = {x1, y1, z1, x2, ...} in model space} or nil, error.
local function parse_b3d(data)
	if data:sub(1, 4) ~= "BB3D" then return nil, "not a b3d file" end
	local pos = 13   -- after "BB3D", length, version
	local nodes, verts = {}, {}
	local vstart = 0

	local function cstr()
		local e = data:find("\0", pos, true)
		if not e then return nil end
		local s = data:sub(pos, e - 1)
		pos = e + 1
		return s
	end

	local read_node
	local function read_mesh(node, stop)
		pos = pos + 4   -- brush id
		while pos + 8 <= stop do
			local tag, len = data:sub(pos, pos + 3), i32(data, pos + 4)
			pos = pos + 8
			local cend = pos + len
			if tag == "VRTS" then
				local flags, sets, size = i32(data, pos), i32(data, pos + 4), i32(data, pos + 8)
				pos = pos + 12
				local stride = 3 + (flags % 2 == 1 and 3 or 0) + (floor(flags / 2) % 2 == 1 and 4 or 0) + sets * size
				vstart = #verts / 3
				local g = node.global
				while pos + stride * 4 <= cend do
					local x, y, z = mat_point(g, f32(data, pos), f32(data, pos + 4), f32(data, pos + 8))
					verts[#verts + 1], verts[#verts + 2], verts[#verts + 3] = x, y, z
					pos = pos + stride * 4
				end
			end
			pos = cend
		end
		pos = stop
	end

	read_node = function(parent, stop)
		local name_pos = pos
		local name = cstr() or "?"
		local raw_tf = data:sub(pos, pos + 39)
		local t = {f32(data, pos), f32(data, pos + 4), f32(data, pos + 8)}
		local s = {f32(data, pos + 12), f32(data, pos + 16), f32(data, pos + 20)}
		-- file order w, x, y, z
		local q = {f32(data, pos + 28), f32(data, pos + 32), f32(data, pos + 36), f32(data, pos + 24)}
		pos = pos + 40
		local loc = mat_trs(t, q, s, true)
		local node = {name = name, parent = parent, children = {}, local_m = loc,
			global = parent and mat_mul(parent.global, loc) or loc, name_pos = name_pos, raw_tf = raw_tf}
		nodes[#nodes + 1] = node
		if parent then parent.children[#parent.children + 1] = node end
		while pos + 8 <= stop do
			local tag, len = data:sub(pos, pos + 3), i32(data, pos + 4)
			pos = pos + 8
			local cend = pos + len
			if len < 0 or cend > stop + 1 then return end
			if tag == "NODE" then
				read_node(node, cend)
			elseif tag == "MESH" then
				read_mesh(node, cend)
			elseif tag == "BONE" then
				node.bone, node.is_bone = true, true
				node.weights = node.weights or {}
				while pos + 8 <= cend do
					local vid, w = i32(data, pos) + vstart, f32(data, pos + 4)
					if w > 0 then node.weights[vid] = w end
					pos = pos + 8
				end
			end
			pos = cend
		end
		pos = stop
	end

	local file_end = 8 + i32(data, 5)
	while pos + 8 <= math.min(#data, file_end) do
		local tag, len = data:sub(pos, pos + 3), i32(data, pos + 4)
		pos = pos + 8
		local cend = pos + len
		if tag == "NODE" then read_node(nil, cend) end
		pos = cend
	end
	if #nodes == 0 then return nil, "no nodes" end
	return {nodes = nodes, verts = verts}
end
M.parse_b3d = parse_b3d

-- Some models have the skeleton once per mesh (body, saddle, armor, an overlay
-- layer), every copy with the same bone names. The engine moves only the first
-- bone of a name, so the ragdoll uses a copy of the model where the other
-- copies' bones get names of their own (same length: the first byte becomes
-- \1, \2...), and moves them all together.
-- Returns the renamed file data and {[bone name] = {other names}}, or nil.
local function same_bone(a, b)
	if a.raw_tf and b.raw_tf then
		if a.raw_tf ~= b.raw_tf then return false end
	else
		for i = 1, 16 do
			if math.abs((a.global[i] or 0) - (b.global[i] or 0)) > 1e-4 then return false end
		end
	end
	-- (is_bone: what the file says, whatever merging did since)
	local function up(n)
		n = n.parent
		while n and not (n.is_bone or n.bone) do n = n.parent end
		return n
	end
	local pa, pb = up(a), up(b)
	if not pa or not pb then return pa == pb end
	return pa.name == pb.name
end
function M.b3d_aliases(data, model)
	local first, copies, names = {}, {}, {}
	for _, n in ipairs(model.nodes) do names[n.name] = true end
	local any = false
	for _, n in ipairs(model.nodes) do
		if n.bone then
			local f = first[n.name]
			if not f then first[n.name] = n
			elseif same_bone(f, n) and #n.name > 0 then
				copies[n.name] = copies[n.name] or {}
				local list = copies[n.name]
				list[#list + 1] = n
				any = true
			end
		end
	end
	if not any then return nil end
	local parts, last = {}, 1
	local patches = {}
	local aliases = {}
	for name, list in pairs(copies) do
		for k, n in ipairs(list) do
			local alias
			for _, at in ipairs({1, #name}) do
				local a = name:sub(1, at - 1) .. string.char(k % 31 + 1) .. name:sub(at + 1)
				if not names[a] then alias = a break end
			end
			if alias then
				names[alias] = true
				patches[#patches + 1] = {n.name_pos, alias}
				aliases[name] = aliases[name] or {}
				table.insert(aliases[name], alias)
			end
		end
	end
	table.sort(patches, function(a, b) return a[1] < b[1] end)
	for _, p in ipairs(patches) do
		parts[#parts + 1] = data:sub(last, p[1] - 1)
		parts[#parts + 1] = p[2]
		last = p[1] + #p[2]
	end
	parts[#parts + 1] = data:sub(last)
	local out = table.concat(parts)
	if #out ~= #data then return nil end
	return out, aliases
end

--------------------------------------------------------------------------------
-- .gltf / .glb (skinned meshes: joints, their rest pose and vertex weights)
--------------------------------------------------------------------------------
local B64 = {}
do
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i = 1, 64 do B64[chars:byte(i)] = i - 1 end
end

local function b64decode(s)
	local out, acc, bits = {}, 0, 0
	for i = 1, #s do
		local v = B64[s:byte(i)]
		if v then
			acc = acc * 64 + v
			bits = bits + 6
			if bits >= 8 then
				bits = bits - 8
				local b = floor(acc / 2 ^ bits)
				out[#out + 1] = string.char(b)
				acc = acc - b * 2 ^ bits
			end
		end
	end
	return table.concat(out)
end

local COMPONENTS = {SCALAR = 1, VEC2 = 2, VEC3 = 3, VEC4 = 4, MAT4 = 16}
local CTYPE = {[5126] = {4, f32}, [5121] = {1, function(s, i) return byte(s, i) end},
	[5123] = {2, u16}, [5125] = {4, i32}}

local function parse_gltf(data, json_parse, dir_reader)
	local doc, bin
	if data:sub(1, 4) == "glTF" then
		-- binary container: JSON chunk then BIN chunk
		local p = 13
		while p + 8 <= #data do
			local len, ctype = i32(data, p), data:sub(p + 4, p + 7)
			local chunk = data:sub(p + 8, p + 7 + len)
			if ctype == "JSON" then doc = json_parse(chunk)
			elseif ctype == "BIN\0" then bin = chunk end
			p = p + 8 + len
		end
	else
		doc = json_parse(data)
	end
	if type(doc) ~= "table" or not doc.nodes then return nil, "bad gltf" end
	local buffers = {}
	for i, b in ipairs(doc.buffers or {}) do
		if b.uri then
			local b64 = b.uri:match("^data:.-;base64,(.*)$")
			buffers[i - 1] = b64 and b64decode(b64) or (dir_reader and dir_reader(b.uri))
		else
			buffers[i - 1] = bin
		end
	end
	local function accessor(idx)
		local a = doc.accessors and doc.accessors[idx + 1]
		if not a or not a.bufferView then return nil end
		local bv = doc.bufferViews[a.bufferView + 1]
		local buf = buffers[bv.buffer]
		if not buf then return nil end
		local ct = CTYPE[a.componentType]
		if not ct then return nil end
		local ncomp = COMPONENTS[a.type] or 1
		local stride = bv.byteStride or ct[1] * ncomp
		local base = (bv.byteOffset or 0) + (a.byteOffset or 0) + 1
		local out = {}
		for e = 0, a.count - 1 do
			local rec = {}
			for c = 0, ncomp - 1 do rec[c + 1] = ct[2](buf, base + e * stride + c * ct[1]) end
			if a.normalized and a.componentType == 5121 then
				for c = 1, ncomp do rec[c] = rec[c] / 255 end
			elseif a.normalized and a.componentType == 5123 then
				for c = 1, ncomp do rec[c] = rec[c] / 65535 end
			end
			out[e + 1] = rec
		end
		return out
	end

	-- node hierarchy; glTF is right-handed: like the engine, mirror Z
	-- (positions z -> -z, rotations (x, y, z, w) -> (-x, -y, z, w))
	local nodes = {}
	local parent_of = {}
	for i, n in ipairs(doc.nodes) do
		for _, c in ipairs(n.children or {}) do parent_of[c + 1] = i end
	end
	local built = {}
	local function build(i)
		if built[i] then return built[i] end
		local n = doc.nodes[i]
		local t = n.translation or {0, 0, 0}
		local r = n.rotation or {0, 0, 0, 1}
		local s = n.scale or {1, 1, 1}
		local loc
		if n.matrix then
			loc = {}
			for k = 1, 16 do loc[k] = n.matrix[k] end
			-- mirror Z: S * M * S with S = diag(1, 1, -1, 1)
			for k = 0, 3 do
				loc[k * 4 + 3] = -loc[k * 4 + 3]
				loc[8 + k + 1] = -loc[8 + k + 1]
			end
		else
			loc = mat_trs({t[1], t[2], -t[3]}, {-r[1], -r[2], r[3], r[4]}, s, false)
		end
		local p = parent_of[i]
		local node = {name = n.name or ("node" .. i), children = {}, local_m = loc}
		built[i] = node
		if p then
			local pn = build(p)
			node.parent = pn
			pn.children[#pn.children + 1] = node
			node.global = mat_mul(pn.global, loc)
		else
			node.global = loc
		end
		nodes[#nodes + 1] = node
		return node
	end
	for i = 1, #doc.nodes do build(i) end

	-- vertices (skinned meshes: the bind pose is the mesh as stored)
	local verts = {}
	for ni, n in ipairs(doc.nodes) do
		local mesh = n.mesh and doc.meshes and doc.meshes[n.mesh + 1]
		local skin = n.skin and doc.skins and doc.skins[n.skin + 1]
		if mesh then
			local g = skin and mat_identity() or built[ni].global
			for _, prim in ipairs(mesh.primitives or {}) do
				local at = prim.attributes or {}
				local P = at.POSITION and accessor(at.POSITION)
				if P then
					local J = skin and at.JOINTS_0 and accessor(at.JOINTS_0)
					local W = skin and at.WEIGHTS_0 and accessor(at.WEIGHTS_0)
					local vstart = #verts / 3
					for k, v in ipairs(P) do
						local x, y, z = mat_point(g, v[1], v[2], -v[3])
						verts[#verts + 1], verts[#verts + 2], verts[#verts + 3] = x, y, z
						if J and W and J[k] and W[k] then
							for c = 1, 4 do
								local w = W[k][c]
								local jn = skin.joints[(J[k][c] or 0) + 1]
								if w and w > 0 and jn and built[jn + 1] then
									local bn = built[jn + 1]
									bn.bone, bn.is_bone = true, true
									bn.weights = bn.weights or {}
									bn.weights[vstart + k - 1] = w
								end
							end
						end
					end
				end
			end
		end
	end
	for _, skin in ipairs(doc.skins or {}) do
		for _, j in ipairs(skin.joints or {}) do
			if built[j + 1] then built[j + 1].bone, built[j + 1].is_bone = true, true end
		end
	end
	return {nodes = nodes, verts = verts}
end
M.parse_gltf = parse_gltf

--------------------------------------------------------------------------------
-- Rig analysis
--------------------------------------------------------------------------------
-- Name hints: how far a limb may bend from its rest direction (radians) -
-- swing: in the body's front-back plane (a leg kicking, a head nodding);
-- side: sideways (a leg splaying out, a head tilting) - and how firmly it is
-- held there (tone). lower: the same for the next segment down the limb
-- (knees, forearms, tail tips). Bending gets harder towards the limit (see
-- body.lua), so bodies come to rest in poses a creature could hold.
local HINTS = {
	{"head", swing = 0.6, side = 0.4, tone = 0.10}, {"neck", swing = 0.45, side = 0.3, tone = 0.10},
	{"skull", swing = 0.6, side = 0.4, tone = 0.10}, {"jaw", swing = 0.25, side = 0.08, tone = 0.2},
	{"tail", swing = 0.9, side = 0.9, tone = 0.02, lower = {0.7, 0.7}},
	{"wing", swing = 0.7, side = 1.3, tone = 0.01, lower = {0.6, 0.9}},
	{"elytra", swing = 0.8, side = 0.8, tone = 0.05, cosmetic = true},
	{"elyra", swing = 0.8, side = 0.8, tone = 0.05, cosmetic = true},
	{"cape", swing = 1.6, side = 1.6, tone = 0.0, cosmetic = true},
	{"fin", swing = 0.7, side = 0.7, tone = 0.02}, {"ear", swing = 0.5, side = 0.3, tone = 0.08},
	{"arm", swing = 1.4, side = 0.9, tone = 0.0, lower = {1.0, 0.3}},
	{"hand", swing = 0.8, side = 0.4, tone = 0.0}, {"fore", swing = 1.0, side = 0.3, tone = 0.0},
	{"elbow", swing = 1.0, side = 0.3, tone = 0.0},
	{"leg", swing = 0.9, side = 0.3, tone = 0.01, lower = {0.9, 0.15}},
	{"thigh", swing = 0.9, side = 0.3, tone = 0.01, lower = {0.9, 0.15}},
	{"shin", swing = 0.9, side = 0.15, tone = 0.01}, {"knee", swing = 0.9, side = 0.15, tone = 0.01},
	{"foot", swing = 0.6, side = 0.3, tone = 0.01}, {"paw", swing = 0.6, side = 0.3, tone = 0.01},
	{"claw", swing = 0.6, side = 0.3, tone = 0.01},
	{"tentacle", swing = 1.2, side = 1.2, tone = 0.0, lower = {1.0, 1.0}},
}

-- the words in a bone name: "Front_Leg.R" -> front, leg, r; "HeadTop" -> head, top
local function words(name)
	local s = (name or ""):gsub("(%l)(%u)", "%1 %2"):lower():gsub("[^%a]+", " ")
	local out = {}
	for w in s:gmatch("%a+") do out[#out + 1] = w end
	return out
end

local function hint(name)
	local ws = words(name)
	for _, h in ipairs(HINTS) do
		for _, w in ipairs(ws) do
			-- whole word, or its plural / a longer form (legs, wings, tails, forearm...)
			if w == h[1] or (w:sub(1, #h[1]) == h[1] and #w <= #h[1] + 2) or (h[1] == "arm" and w == "forearm") then
				return h
			end
		end
	end
	return nil
end

local function vsub(a, b) return {a[1] - b[1], a[2] - b[2], a[3] - b[3]} end
local function vlen(a) return math.sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3]) end

-- rig = {
--   core = {[bone name] = true}, box = {min = {x,y,z}, max = {x,y,z}} (model units),
--   bounds = whole-model box,
--   limbs = {{bone, pivot = {x,y,z}, dir = unit {x,y,z}, len, thick (half width), parent (limb index or nil),
--             rot = 3x3 global rest rotation (row-major), max_angle (front-back), side_angle, tone}, ...},
-- }
function M.analyze(model)
	local verts = model.verts
	local nv = #verts / 3
	if nv == 0 then return nil end
	local function vpos(i) return {verts[i * 3 + 1], verts[i * 3 + 2], verts[i * 3 + 3]} end
	local bmin, bmax = {math.huge, math.huge, math.huge}, {-math.huge, -math.huge, -math.huge}
	for i = 0, nv - 1 do
		for c = 1, 3 do
			local v = verts[i * 3 + c]
			if v < bmin[c] then bmin[c] = v end
			if v > bmax[c] then bmax[c] = v end
		end
	end
	local size = vlen(vsub(bmax, bmin))
	local rig = {bounds = {min = bmin, max = bmax}, limbs = {}, core = {}}
	local elongation

	-- the skeleton once per mesh (see b3d_aliases): one bone per name, moving
	-- everything any of its copies moves
	do
		local first = {}
		for _, n in ipairs(model.nodes) do
			if n.bone then
				local f = first[n.name]
				if not f then first[n.name] = n
				elseif same_bone(f, n) then
					f.weights = f.weights or {}
					for vid, w in pairs(n.weights or {}) do
						if not f.weights[vid] or w > f.weights[vid] then f.weights[vid] = w end
					end
					n.bone = false   -- (the parsed model is only used for this)
				end
			end
		end
	end

	-- every vertex goes to the bone that moves it most
	local owner = {}
	local best = {}
	local bones = {}
	for _, n in ipairs(model.nodes) do
		if n.bone then
			bones[#bones + 1] = n
			for vid, w in pairs(n.weights or {}) do
				if not best[vid] or w > best[vid] then best[vid], owner[vid] = w, n end
			end
		end
	end
	if #bones == 0 then
		rig.box = rig.bounds
		return rig
	end
	for _, b in ipairs(bones) do b.own = {} end
	local assigned = 0
	for vid, b in pairs(owner) do
		b.own[#b.own + 1] = vid
		assigned = assigned + 1
	end
	if assigned == 0 then
		rig.box = rig.bounds
		return rig
	end
	-- subtree vertex counts (bones only; plain nodes pass their children through)
	local function bone_children(n)
		local out = {}
		for _, c in ipairs(n.children) do
			if c.bone then out[#out + 1] = c
			else for _, cc in ipairs(bone_children(c)) do out[#out + 1] = cc end end
		end
		return out
	end
	local function count(n)
		local c = #(n.own or {})
		n.bchildren = bone_children(n)
		for _, ch in ipairs(n.bchildren) do c = c + count(ch) end
		n.sub = c
		return c
	end
	local roots = {}
	for _, b in ipairs(bones) do
		local p = b.parent
		while p and not p.bone do p = p.parent end
		if not p then roots[#roots + 1] = b end
	end
	for _, r in ipairs(roots) do count(r) end
	local function sub_verts(n, out)
		for _, v in ipairs(n.own or {}) do out[#out + 1] = v end
		for _, ch in ipairs(n.bchildren or {}) do sub_verts(ch, out) end
		return out
	end
	local function pivot(n) return {n.global[13], n.global[14], n.global[15]} end
	-- how elongated a set of vertices is: largest / second principal variance
	elongation = function(list)
		if #list < 3 then return 1 end
		local mx, my, mz = 0, 0, 0
		for _, v in ipairs(list) do mx, my, mz = mx + verts[v * 3 + 1], my + verts[v * 3 + 2], mz + verts[v * 3 + 3] end
		mx, my, mz = mx / #list, my / #list, mz / #list
		local c = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}}
		for _, v in ipairs(list) do
			local d = {verts[v * 3 + 1] - mx, verts[v * 3 + 2] - my, verts[v * 3 + 3] - mz}
			for i = 1, 3 do for j = 1, 3 do c[i][j] = c[i][j] + d[i] * d[j] end end
		end
		local function power(m)
			local x = {0.577, 0.577, 0.577}
			local lam = 0
			for _ = 1, 30 do
				local y = {0, 0, 0}
				for i = 1, 3 do for j = 1, 3 do y[i] = y[i] + m[i][j] * x[j] end end
				lam = math.sqrt(y[1] * y[1] + y[2] * y[2] + y[3] * y[3])
				if lam < 1e-12 then return 0, x end
				x = {y[1] / lam, y[2] / lam, y[3] / lam}
			end
			return lam, x
		end
		local l1, v1 = power(c)
		local c2 = {}
		for i = 1, 3 do
			c2[i] = {}
			for j = 1, 3 do c2[i][j] = c[i][j] - l1 * v1[i] * v1[j] end
		end
		local l2 = power(c2)
		return l1 / math.max(l2, l1 * 1e-4)
	end

	-- own-vertex box volume of each bone (how much "body" it carries itself)
	for _, b in ipairs(bones) do
		local mn, mx = {math.huge, math.huge, math.huge}, {-math.huge, -math.huge, -math.huge}
		for _, v in ipairs(b.own) do
			for c = 1, 3 do
				local x = verts[v * 3 + c]
				if x < mn[c] then mn[c] = x end
				if x > mx[c] then mx[c] = x end
			end
		end
		b.vol = #b.own > 0 and math.max(1e-6, (mx[1] - mn[1]) * (mx[2] - mn[2]) * (mx[3] - mn[3])) or 0
		b.elong = elongation(b.own)
	end
	-- the core: the biggest body block that isn't named like a limb, its
	-- ancestors, and (below) children that are body segments too
	-- (the torso is the hub the limbs hang from: own vertices x branches)
	local seed, sscore
	for _, b in ipairs(bones) do
		local score = #b.own * (1 + #(b.bchildren or {}))
		if not hint(b.name) and (not seed or score > sscore) then seed, sscore = b, score end
	end
	seed = seed or roots[1]
	local core_vol = seed.vol
	local CORE_WORDS = {spine = true, body = true, torso = true, chest = true, pelvis = true, root = true, main = true,
		back = true, belly = true, breast = true, abdomen = true, waist = true, trunk = true, rib = true, ribs = true,
		hips = true, upperbody = true, backbody = true, bum = true}
	local function is_core(n)
		if hint(n.name) then return false end
		for _, w in ipairs(words(n.name)) do
			if CORE_WORDS[w] then return true end
		end
		-- unnamed: a chunky block of body (not a thin, long limb) of some size
		return n.elong < 1.6 and n.vol >= core_vol * 0.3
	end
	local core_list = {}
	local function grow(n)
		if rig.core[n.name] then return end
		rig.core[n.name] = true
		core_list[#core_list + 1] = n
		for _, ch in ipairs(n.bchildren) do
			if is_core(ch) then grow(ch) end
		end
	end
	local a = seed
	while a do
		rig.core[a.name] = true
		core_list[#core_list + 1] = a
		local p = a.parent
		while p and not p.bone do p = p.parent end
		a = p
	end
	for _, c in ipairs(table.copy and table.copy(core_list) or {unpack(core_list)}) do
		for _, ch in ipairs(c.bchildren) do
			if is_core(ch) then grow(ch) end
		end
	end

	-- limbs: non-core children of core bones big enough to matter, followed
	-- down their biggest child for up to three segments
	local limb_set = {}
	rig.followers = {}
	local function add_limb(n, parent_limb, depth)
		local vs = sub_verts(n, {})
		if #vs < math.max(4, assigned * 0.01) then return end
		local pv = pivot(n)
		local cx, cy, cz = 0, 0, 0
		for _, v in ipairs(vs) do
			cx, cy, cz = cx + verts[v * 3 + 1], cy + verts[v * 3 + 2], cz + verts[v * 3 + 3]
		end
		local cen = {cx / #vs, cy / #vs, cz / #vs}
		-- the next segment: the child with most of this limb's vertices
		local next_seg
		if depth < 3 then
			for _, ch in ipairs(n.bchildren) do
				if ch.sub >= #vs * 0.35 and (not next_seg or ch.sub > next_seg.sub) then next_seg = ch end
			end
		end
		local tip
		if next_seg then
			tip = pivot(next_seg)
			if vlen(vsub(tip, pv)) < size * 0.02 then next_seg, tip = nil, nil end
		end
		if not tip then
			-- the far end: along the centroid direction, the farthest vertex
			local d = vsub(cen, pv)
			local l = vlen(d)
			if l < size * 0.02 then return end   -- bone in the middle of its part: nothing to swing
			d = {d[1] / l, d[2] / l, d[3] / l}
			local far = 0
			for _, v in ipairs(vs) do
				local p = vpos(v)
				local proj = (p[1] - pv[1]) * d[1] + (p[2] - pv[2]) * d[2] + (p[3] - pv[3]) * d[3]
				if proj > far then far = proj end
			end
			tip = {pv[1] + d[1] * far, pv[2] + d[2] * far, pv[3] + d[3] * far}
		end
		local dir = vsub(tip, pv)
		local len = vlen(dir)
		if len < size * 0.02 then return end
		dir = {dir[1] / len, dir[2] / len, dir[3] / len}
		-- how thick it is: half its narrower width across the limb (what it
		-- rests on when it lies on the ground)
		local thick
		do
			local a = math.abs(dir[2]) < 0.9 and {0, 1, 0} or {1, 0, 0}
			local e1 = {dir[2] * a[3] - dir[3] * a[2], dir[3] * a[1] - dir[1] * a[3], dir[1] * a[2] - dir[2] * a[1]}
			local l1 = vlen(e1)
			e1 = {e1[1] / l1, e1[2] / l1, e1[3] / l1}
			local e2 = {dir[2] * e1[3] - dir[3] * e1[2], dir[3] * e1[1] - dir[1] * e1[3], dir[1] * e1[2] - dir[2] * e1[1]}
			local lo1, hi1, lo2, hi2 = math.huge, -math.huge, math.huge, -math.huge
			for _, vi in ipairs(next_seg and n.own or vs) do
				local p = vsub(vpos(vi), pv)
				local s1 = p[1] * e1[1] + p[2] * e1[2] + p[3] * e1[3]
				local s2 = p[1] * e2[1] + p[2] * e2[2] + p[3] * e2[3]
				if s1 < lo1 then lo1 = s1 end
				if s1 > hi1 then hi1 = s1 end
				if s2 < lo2 then lo2 = s2 end
				if s2 > hi2 then hi2 = s2 end
			end
			if hi1 >= lo1 and hi2 >= lo2 then thick = math.min(hi1 - lo1, hi2 - lo2) / 2 end
		end
		local h = hint(n.name)
		if not h then
			-- unnamed: pointing up = a head/neck (stiff), else a leg-like limb
			if dir[2] > 0.6 then h = {"head", swing = 0.5, side = 0.35, tone = 0.08}
			else h = {"limb", swing = 1.0, side = 0.45, tone = 0.01, lower = {0.9, 0.3}} end
		end
		local kind, tone, cosmetic = h[1], h.tone, h.cosmetic
		local max_angle, side_angle = h.swing, h.side
		if parent_limb and h.lower then max_angle, side_angle = h.lower[1], h.lower[2] end
		local par = n.parent
		-- an overlay bone sitting exactly on another limb (armor on an arm):
		-- it moves with that limb instead of on its own
		if not parent_limb then
			for li, other in ipairs(rig.limbs) do
				if not other.parent and vlen(vsub(other.pivot, pv)) < size * 0.03
						and other.dir[1] * dir[1] + other.dir[2] * dir[2] + other.dir[3] * dir[3] > 0.97 then
					rig.followers[#rig.followers + 1] = {bone = n.name, leader = li, lrot = mat_rot3(n.local_m),
						prot = par and mat_rot3(par.global) or {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}}
					limb_set[n] = true
					return
				end
			end
		end
		local limb = {bone = n.name, pivot = pv, dir = dir, len = len, thick = thick, rot = mat_rot3(n.global),
			lrot = mat_rot3(n.local_m), prot = par and mat_rot3(par.global) or {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}},
			parent = parent_limb, max_angle = max_angle, side_angle = side_angle, tone = tone, kind = kind, nverts = #vs,
			ghost = cosmetic or nil}   -- (capes, elytra: often hidden; never hold the body up)
		rig.limbs[#rig.limbs + 1] = limb
		limb_set[n] = true
		if next_seg then add_limb(next_seg, #rig.limbs, depth + 1) end
	end
	for _, c in ipairs(core_list) do
		for _, ch in ipairs(c.bchildren) do
			if not rig.core[ch.name] then add_limb(ch, nil, 1) end
		end
	end
	-- flat rigs (every bone a child of one plain node): the other top-level
	-- bones hang off the core too
	for _, r in ipairs(roots) do
		if not rig.core[r.name] and not limb_set[r] then add_limb(r, nil, 1) end
	end

	-- the core's box: every vertex not carried by a limb
	local in_limb = {}
	for n in pairs(limb_set) do
		for _, v in ipairs(n.own or {}) do in_limb[v] = true end
	end
	local cmin, cmax = {math.huge, math.huge, math.huge}, {-math.huge, -math.huge, -math.huge}
	local any = false
	for i = 0, nv - 1 do
		if not in_limb[i] then
			-- (limb subtrees below the first segment are in limb_set too)
			any = true
			for c = 1, 3 do
				local v = verts[i * 3 + c]
				if v < cmin[c] then cmin[c] = v end
				if v > cmax[c] then cmax[c] = v end
			end
		end
	end
	rig.box = any and {min = cmin, max = cmax} or rig.bounds
	-- limb sub-bones below the simulated segments ride along rigidly; their
	-- vertices still count for the limb, not the core
	local function mark(n)
		for _, v in ipairs(n.own or {}) do in_limb[v] = true end
		for _, ch in ipairs(n.bchildren or {}) do mark(ch) end
	end
	for n in pairs(limb_set) do mark(n) end
	cmin, cmax, any = {math.huge, math.huge, math.huge}, {-math.huge, -math.huge, -math.huge}, false
	for i = 0, nv - 1 do
		if not in_limb[i] then
			any = true
			for c = 1, 3 do
				local v = verts[i * 3 + c]
				if v < cmin[c] then cmin[c] = v end
				if v > cmax[c] then cmax[c] = v end
			end
		end
	end
	if any then rig.box = {min = cmin, max = cmax} end
	return rig
end

return M
