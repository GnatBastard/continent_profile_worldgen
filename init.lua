local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)

if core.get_mapgen_setting("mg_name") ~= "singlenode" then
	core.log("warning",
		"[continent_profile_worldgen] This mod is designed for singlenode mapgen.")
end

core.set_mapgen_setting("water_level", "0", true)
core.register_mapgen_script(modpath .. "/mapgen.lua")

-- Same geometry/noise parameters as mapgen.lua.
local CFG = {
	radius_x = 26000,
	radius_z = 24800,
	rotation = math.rad(-8),
	warp_amplitude = 6000,
}
local ROT_C = math.cos(CFG.rotation)
local ROT_S = math.sin(CFG.rotation)

local NP_WARP_X = {
	offset = 0, scale = 1,
	spread = {x = 4000, y = 4000, z = 4000},
	seed = 17321, octaves = 3,
	persistence = 0.52, lacunarity = 2.0,
	flags = "defaults",
}
local NP_WARP_Z = {
	offset = 0, scale = 1,
	spread = {x = 4000, y = 4000, z = 4000},
	seed = 28493, octaves = 3,
	persistence = 0.52, lacunarity = 2.0,
	flags = "defaults",
}

local NP_MICRO_WARP_X = {
	offset = 0, scale = 1,
	spread = {x = 32, y = 32, z = 32},
	seed = 54181, octaves = 2,
	persistence = 0.50, lacunarity = 2.0,
	flags = "defaults",
}
local NP_MICRO_WARP_Z = {
	offset = 0, scale = 1,
	spread = {x = 32, y = 32, z = 32},
	seed = 58733, octaves = 2,
	persistence = 0.50, lacunarity = 2.0,
	flags = "defaults",
}

local PROFILE_POINTS = {
	{0.000,3800},{0.040,3500},{0.100,2900},{0.180,2100},
	{0.280,1350},{0.400,850},{0.520,600},{0.650,430},
	{0.760,300},{0.850,200},{0.920,110},{0.970,35},
	{1.000,0},{1.020,-35},{1.045,-120},{1.070,-220},
	{1.095,-800},{1.125,-1800},{1.170,-3000},
	{1.300,-3500},{1.500,-3600},
}

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local function build_curve(points)
	local n = #points
	local widths, slopes, tangents = {}, {}, {}

	for i = 1, n - 1 do
		widths[i] = points[i + 1][1] - points[i][1]
		slopes[i] = (points[i + 1][2] - points[i][2]) / widths[i]
	end

	tangents[1] = slopes[1]
	tangents[n] = slopes[n - 1]

	for i = 2, n - 1 do
		local d0, d1 = slopes[i - 1], slopes[i]
		if d0 == 0 or d1 == 0 or d0 * d1 <= 0 then
			tangents[i] = 0
		else
			local h0, h1 = widths[i - 1], widths[i]
			local w1, w2 = 2 * h1 + h0, h1 + 2 * h0
			tangents[i] = (w1 + w2) / (w1 / d0 + w2 / d1)
		end
	end

	return {points = points, tangents = tangents}
end

local PROFILE = build_curve(PROFILE_POINTS)

local function eval_profile(q)
	local p, m = PROFILE.points, PROFILE.tangents
	local n = #p

	if q <= p[1][1] then return p[1][2] end
	if q >= p[n][1] then return p[n][2] end

	local i = 1
	while q > p[i + 1][1] do i = i + 1 end

	local x0, x1 = p[i][1], p[i + 1][1]
	local y0, y1 = p[i][2], p[i + 1][2]
	local w = x1 - x0
	local t = (q - x0) / w
	local t2, t3 = t * t, t * t * t

	return
		(2*t3 - 3*t2 + 1) * y0
		+ (t3 - 2*t2 + t) * w * m[i]
		+ (-2*t3 + 3*t2) * y1
		+ (t3 - t2) * w * m[i + 1]
end

local warp_x_noise
local warp_z_noise
local micro_warp_x_noise
local micro_warp_z_noise

local function ensure_spawn_noise()
	if warp_x_noise then return end

	-- Noise objects are intentionally created lazily, after mapgen has
	-- initialized. Luanti documents these as world-specific noise objects.
	warp_x_noise = core.get_value_noise(NP_WARP_X)
	warp_z_noise = core.get_value_noise(NP_WARP_Z)
	micro_warp_x_noise = core.get_value_noise(NP_MICRO_WARP_X)
	micro_warp_z_noise = core.get_value_noise(NP_MICRO_WARP_Z)
end

local function sample_terrain(x, z)
	ensure_spawn_noise()

	local wx = clamp(warp_x_noise:get_2d({x = x, y = z}), -1, 1)
	local wz = clamp(warp_z_noise:get_2d({x = x, y = z}), -1, 1)
	local mwx = clamp(micro_warp_x_noise:get_2d({x = x, y = z}), -1, 1)
	local mwz = clamp(micro_warp_z_noise:get_2d({x = x, y = z}), -1, 1)

	local xw = x + wx * CFG.warp_amplitude + mwx * 5
	local zw = z + wz * CFG.warp_amplitude + mwz * 5

	local xr = xw * ROT_C - zw * ROT_S
	local zr = xw * ROT_S + zw * ROT_C

	local q = math.sqrt(
		(xr / CFG.radius_x) ^ 2
		+ (zr / CFG.radius_z) ^ 2
	)

	return eval_profile(q), q
end

local cached_spawn

local function find_coastal_spawn()
	if cached_spawn then
		return vector.copy(cached_spawn)
	end

	local best, best_score
	best_score = math.huge

	-- Try coastlines all around the mainland. Strong domain warping may
	-- create small islands; by scanning outward from the center we target
	-- the first/mainland coast rather than an offshore island.
	for d = 0, 23 do
		local angle = d / 24 * math.pi * 2
		local dx, dz = math.cos(angle), math.sin(angle)

		for radius = 18000, 30500, 80 do
			local x, z = dx * radius, dz * radius
			local h, q = sample_terrain(x, z)

			if h >= 3 and h <= 16 and q < 1 then
				local outward_h = sample_terrain(x + dx * 96, z + dz * 96)
				local side_h = sample_terrain(x - dz * 96, z + dx * 96)

				local score =
					math.abs(h - outward_h)
					+ 0.65 * math.abs(h - side_h)
					+ 0.35 * math.abs(h - 8)
					+ 150 * math.abs(1 - q)

				if score < best_score then
					best_score = score
					best = {
						x = math.floor(x + 0.5),
						y = math.floor(h + 2.5),
						z = math.floor(z + 0.5),
					}
				end

				break
			elseif h < 0 then
				break
			end
		end
	end

	if not best then
		best = {x = 25000, y = 12, z = 0}
		core.log("warning",
			"[continent_profile_worldgen] Coastal spawn search fell back to default.")
	end

	cached_spawn = best
	core.log("action", string.format(
		"[continent_profile_worldgen] Coastal spawn: (%d, %d, %d)",
		best.x, best.y, best.z))

	return vector.copy(best)
end

core.register_on_newplayer(function(player)
	player:set_pos(find_coastal_spawn())
end)

core.register_on_respawnplayer(function(player)
	player:set_pos(find_coastal_spawn())
	return true
end)
