-----------------------------------------------------------------------
-- continent_profile_worldgen/mapgen.lua
--
-- Experimental profile-based terrain generator.
--
-- Macro terrain:
--   1. Domain-warp X/Z coordinates.
--   2. Measure normalized elliptical distance from the continent center.
--   3. Feed that distance through one continuous elevation profile.
--
-- The same curve therefore defines:
--   summit -> mountains -> uplands -> plains -> coast
--   -> shelf -> continental slope -> deep ocean.
--
-- Current tuned preview defaults:
--   coastline ellipse: 26.0 km x 24.8 km
--   ellipse rotation: -8 degrees
--   warp amplitude: 6 km
--   warp feature size: ~4 km
--   micro warp: 5 nodes at ~32-node feature scale
--   post-profile terrain roughness: disabled for this test build
--
-- Climate/biome generation is intentionally excluded from this build.
--
-- Small offshore islands caused by aggressive coordinate warping are
-- intentional; the design goal is one dominant mainland, not zero islands.
-----------------------------------------------------------------------

local SEA_LEVEL = 0

local CFG = {
	radius_x = 26000,
	radius_z = 24800,
	rotation = math.rad(-8),

	warp_amplitude = 6000,

}

local ROT_C = math.cos(CFG.rotation)
local ROT_S = math.sin(CFG.rotation)

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

-----------------------------------------------------------------------
-- Sea-to-summit macro profile
--
-- q = 0.0 : center / summit
-- q = 1.0 : designed coastline
-- q > 1.0 : ocean
--
-- This is the same control-point profile used in the accepted browser
-- preview.  A monotone cubic Hermite interpolation avoids sharp corners
-- while preserving the intended shape between points.
-----------------------------------------------------------------------

local PROFILE_POINTS = {
	{0.000,  3800},
	{0.040,  3500},
	{0.100,  2900},
	{0.180,  2100},
	{0.280,  1350},
	{0.400,   850},
	{0.520,   600},
	{0.650,   430},
	{0.760,   300},
	{0.850,   200},
	{0.920,   110},
	{0.970,    35},
	{1.000,     0},
	{1.020,   -35},
	{1.045,  -120},
	{1.070,  -220},
	{1.095,  -800},
	{1.125, -1800},
	{1.170, -3000},
	{1.300, -3500},
	{1.500, -3600},
}

local function build_monotone_curve(points)
	local n = #points
	local widths = {}
	local slopes = {}
	local tangents = {}

	for i = 1, n - 1 do
		local width = points[i + 1][1] - points[i][1]
		widths[i] = width
		slopes[i] =
			(points[i + 1][2] - points[i][2])
			/ width
	end

	tangents[1] = slopes[1]
	tangents[n] = slopes[n - 1]

	for i = 2, n - 1 do
		local d0 = slopes[i - 1]
		local d1 = slopes[i]

		if d0 == 0 or d1 == 0 or d0 * d1 <= 0 then
			tangents[i] = 0
		else
			local h0 = widths[i - 1]
			local h1 = widths[i]
			local w1 = 2 * h1 + h0
			local w2 = h1 + 2 * h0

			tangents[i] =
				(w1 + w2)
				/ (w1 / d0 + w2 / d1)
		end
	end

	return {
		points = points,
		tangents = tangents,
	}
end

local PROFILE = build_monotone_curve(PROFILE_POINTS)

local function eval_profile(q)
	local points = PROFILE.points
	local tangents = PROFILE.tangents
	local n = #points

	if q <= points[1][1] then
		return points[1][2]
	end

	if q >= points[n][1] then
		return points[n][2]
	end

	-- The table is tiny, so a linear interval search is cheaper and
	-- simpler than maintaining extra indexing structures.
	local i = 1
	while q > points[i + 1][1] do
		i = i + 1
	end

	local x0 = points[i][1]
	local x1 = points[i + 1][1]
	local y0 = points[i][2]
	local y1 = points[i + 1][2]

	local width = x1 - x0
	local t = (q - x0) / width
	local t2 = t * t
	local t3 = t2 * t

	return
		(2 * t3 - 3 * t2 + 1) * y0
		+ (t3 - 2 * t2 + t) * width * tangents[i]
		+ (-2 * t3 + 3 * t2) * y1
		+ (t3 - t2) * width * tangents[i + 1]
end

-----------------------------------------------------------------------
-- Domain warp
--
-- These are deliberately strong, fairly small-scale warps because that
-- produced the best preview results.  They deform the coastline AND the
-- mountain profile together instead of adding unrelated mountain blobs.
-----------------------------------------------------------------------

local NP_WARP_X = {
	offset = 0,
	scale = 1,
	spread = {x = 4000, y = 4000, z = 4000},
	seed = 17321,
	octaves = 3,
	persistence = 0.52,
	lacunarity = 2.0,
	flags = "defaults",
}

local NP_WARP_Z = {
	offset = 0,
	scale = 1,
	spread = {x = 4000, y = 4000, z = 4000},
	seed = 28493,
	octaves = 3,
	persistence = 0.52,
	lacunarity = 2.0,
	flags = "defaults",
}

local NP_MICRO_WARP_X = {
	offset = 0,
	scale = 1,
	spread = {x = 32, y = 32, z = 32},
	seed = 54181,
	octaves = 2,
	persistence = 0.50,
	lacunarity = 2.0,
	flags = "defaults",
}

local NP_MICRO_WARP_Z = {
	offset = 0,
	scale = 1,
	spread = {x = 32, y = 32, z = 32},
	seed = 58733,
	octaves = 2,
	persistence = 0.50,
	lacunarity = 2.0,
	flags = "defaults",
}

local noise_maps = {}
local noise_size_x
local noise_size_z

local warp_x_values = {}
local warp_z_values = {}
local micro_warp_x_values = {}
local micro_warp_z_values = {}

local function prepare_noise_maps(size_x, size_z)
	if
		noise_maps.warp_x
		and noise_size_x == size_x
		and noise_size_z == size_z
	then
		return
	end

	local size = {
		x = size_x,
		y = size_z,
	}

	noise_maps.warp_x =
		core.get_value_noise_map(NP_WARP_X, size)

	noise_maps.warp_z =
		core.get_value_noise_map(NP_WARP_Z, size)

	noise_maps.micro_warp_x =
		core.get_value_noise_map(NP_MICRO_WARP_X, size)

	noise_maps.micro_warp_z =
		core.get_value_noise_map(NP_MICRO_WARP_Z, size)

	noise_size_x = size_x
	noise_size_z = size_z
end

local function terrain_sample(x, z, warp_x, warp_z, micro_warp_x, micro_warp_z)
	-- Clamp because octave summation may very occasionally exceed the
	-- nominal [-1, +1] range.
	warp_x = clamp(warp_x, -1, 1)
	warp_z = clamp(warp_z, -1, 1)
	micro_warp_x = clamp(micro_warp_x, -1, 1)
	micro_warp_z = clamp(micro_warp_z, -1, 1)

	local xw =
		x
		+ warp_x * CFG.warp_amplitude
		+ micro_warp_x * 5

	local zw =
		z
		+ warp_z * CFG.warp_amplitude
		+ micro_warp_z * 5

	-- Rotate into the ellipse frame.
	local xr = xw * ROT_C - zw * ROT_S
	local zr = xw * ROT_S + zw * ROT_C

	local nx = xr / CFG.radius_x
	local nz = zr / CFG.radius_z

	local q = math.sqrt(nx * nx + nz * nz)
	local height = eval_profile(q)

	-- Keep the accepted natural maximum near 3.8 km.
	if height > 3800 then
		height = 3800
	end

	return math.floor(height + 0.5), q
end

-----------------------------------------------------------------------
-- Content IDs
--
-- Only mapgen_stone and mapgen_water_source are required by modern
-- non-v6 games.  Other surfaces gracefully fall back if a game does not
-- provide the older optional aliases.
-----------------------------------------------------------------------

local function resolve_registered_node(name)
	local seen = {}

	while name and not seen[name] do
		if core.registered_nodes[name] then
			return name
		end

		seen[name] = true

		local target = core.registered_aliases[name]
		if type(target) ~= "string" or target == "" then
			return nil
		end

		name = target
	end

	return nil
end

local function optional_content_id(names, fallback)
	for _, name in ipairs(names) do
		local resolved = resolve_registered_node(name)

		if resolved then
			-- get_content_id() expects an already registered node. Do not use
			-- it to probe optional aliases: unknown names raise an error.
			return core.get_content_id(resolved)
		end
	end

	return fallback
end

local C_AIR = core.CONTENT_AIR

local C_STONE =
	optional_content_id(
		{"mapgen_stone", "default:stone"},
		core.CONTENT_UNKNOWN
	)

if C_STONE == core.CONTENT_UNKNOWN then
	error(
		"[continent_profile_worldgen] No usable stone node was found. " ..
		"The active game must register mapgen_stone or another supported stone fallback."
	)
end

local C_WATER =
	optional_content_id(
		{"mapgen_water_source", "default:water_source"},
		core.CONTENT_UNKNOWN
	)

if C_WATER == core.CONTENT_UNKNOWN then
	error(
		"[continent_profile_worldgen] No usable water node was found. " ..
		"The active game must register mapgen_water_source or another supported water fallback."
	)
end

local C_DIRT =
	optional_content_id(
		{"mapgen_dirt", "default:dirt"},
		C_STONE
	)

local C_GRASS =
	optional_content_id(
		{"mapgen_dirt_with_grass", "default:dirt_with_grass"},
		C_DIRT
	)

local C_SAND =
	optional_content_id(
		{"mapgen_sand", "default:sand"},
		C_DIRT
	)


-----------------------------------------------------------------------
-- Reused buffers
-----------------------------------------------------------------------

local data = {}
local surface_height = {}
local surface_q = {}

-----------------------------------------------------------------------
-- Generation
-----------------------------------------------------------------------

core.register_on_generated(function(vmanip, minp, maxp, blockseed)
	local size_x = maxp.x - minp.x + 1
	local size_z = maxp.z - minp.z + 1

	prepare_noise_maps(size_x, size_z)

	local noise_origin = {
		x = minp.x,
		y = minp.z,
	}

	warp_x_values =
		noise_maps.warp_x:get_2d_map_flat(
			noise_origin,
			warp_x_values
		)

	warp_z_values =
		noise_maps.warp_z:get_2d_map_flat(
			noise_origin,
			warp_z_values
		)

	micro_warp_x_values =
		noise_maps.micro_warp_x:get_2d_map_flat(
			noise_origin,
			micro_warp_x_values
		)

	micro_warp_z_values =
		noise_maps.micro_warp_z:get_2d_map_flat(
			noise_origin,
			micro_warp_z_values
		)

	-------------------------------------------------------------------
	-- Build one macro terrain sample per X/Z column.
	-------------------------------------------------------------------

	local ni = 1

	for z = minp.z, maxp.z do
		for x = minp.x, maxp.x do
			local height, q =
				terrain_sample(
					x,
					z,
					warp_x_values[ni],
					warp_z_values[ni],
					micro_warp_x_values[ni],
					micro_warp_z_values[ni]
				)

			surface_height[ni] = height
			surface_q[ni] = q

			ni = ni + 1
		end
	end

	-------------------------------------------------------------------
	-- Fill the mapgen VoxelManip.
	-------------------------------------------------------------------

	local emin, emax = vmanip:get_emerged_area()
	local area =
		VoxelArea:new({
			MinEdge = emin,
			MaxEdge = emax,
		})

	data = vmanip:get_data(data)

	for z = minp.z, maxp.z do
		local row_base = (z - minp.z) * size_x

		for y = minp.y, maxp.y do
			local vi = area:index(minp.x, y, z)

			for x = minp.x, maxp.x do
				local ci =
					row_base
					+ (x - minp.x)
					+ 1

				local top = surface_height[ci]
				local q = surface_q[ci]

				if y <= top then
					if top <= SEA_LEVEL then
						-- Ocean floor sediment.
						if y >= top - 3 then
							data[vi] = C_SAND
						else
							data[vi] = C_STONE
						end

					else
						-- Land.
						local coastal =
							top <= 8
							or (q >= 0.985 and top <= 25)

						if coastal then
							if y >= top - 4 then
								data[vi] = C_SAND
							else
								data[vi] = C_STONE
							end

						elseif y == top then
							data[vi] = C_GRASS

						elseif y >= top - 4 then
							data[vi] = C_DIRT

						else
							data[vi] = C_STONE
						end
					end

				elseif y <= SEA_LEVEL then
					data[vi] = C_WATER

				else
					data[vi] = C_AIR
				end

				vi = vi + 1
			end
		end
	end

	vmanip:set_data(data)

	-- Singlenode generated lighting before our terrain existed.
	vmanip:set_lighting(
		{day = 0, night = 0},
		minp,
		maxp
	)
	vmanip:calc_lighting()
end)
