
local S = battletanks.settings

local cached_bounds = nil

function battletanks.rescan_arena_bounds()
    local y0 = S.arena_center.y
    local scan_y = y0 + 1
    local wmin, wmax = S.map_work_area.min, S.map_work_area.max

    local min_x, max_x, min_z, max_z = nil, nil, nil, nil
    for x = wmin.x, wmax.x do
        for z = wmin.z, wmax.z do
            if minetest.get_node({ x = x, y = scan_y, z = z }).name == "battletanks:boundary" then
                if not min_x or x < min_x then min_x = x end
                if not max_x or x > max_x then max_x = x end
                if not min_z or z < min_z then min_z = z end
                if not max_z or z > max_z then max_z = z end
            end
        end
    end

    if not min_x then
        minetest.log("warning", "[battletanks] rescan_arena_bounds: no battletanks:boundary "
            .. "nodes found in the working area - keeping previous bounds (if any). Does the "
            .. "loaded map actually contain boundary nodes?")
        return false
    end

    cached_bounds = { min_x = min_x, max_x = max_x, min_z = min_z, max_z = max_z, y0 = y0 }
    minetest.log("action", "[battletanks] Arena bounds: x " .. min_x .. ".." .. max_x
        .. ", z " .. min_z .. ".." .. max_z)
    return true
end

local function fallback_bounds()
    local c = S.arena_center
    local half = math.floor(S.arena_size / 2)
    return { min_x = c.x - half, max_x = c.x + half, min_z = c.z - half, max_z = c.z + half, y0 = c.y }
end

local function bounds()
    return cached_bounds or fallback_bounds()
end
battletanks.arena_bounds = bounds

function battletanks.lobby_pos()
    local b = bounds()
    return { x = S.arena_center.x, y = b.y0 + 1, z = S.arena_center.z }
end

local function build_arena_now()
    local b = bounds()
    local apron = S.arena_apron

    minetest.log("action", "[battletanks] Placing " .. S.arena_size .. "x"
        .. S.arena_size .. " arena (+" .. apron .. " block safety apron)...")

    for x = b.min_x - apron, b.max_x + apron do
        for z = b.min_z - apron, b.max_z + apron do
            minetest.set_node({ x = x, y = b.y0, z = z }, { name = "battletanks:boundary" })
        end
    end

    for x = b.min_x, b.max_x do
        for z = b.min_z, b.max_z do
            if x == b.min_x or x == b.max_x or z == b.min_z or z == b.max_z then
                for h = 1, S.wall_height do
                    minetest.set_node({ x = x, y = b.y0 + h, z = z }, { name = "battletanks:boundary" })
                end
            end
        end
    end

    for i, sp in ipairs(S.spawn_point_offsets) do
        local pos = vector.round({
            x = S.arena_center.x + sp.x,
            y = b.y0,
            z = S.arena_center.z + sp.z,
        })
        local param2 = minetest.dir_to_facedir({ x = sp.dir_x, y = 0, z = sp.dir_z })
        minetest.set_node(pos, { name = "battletanks:spawnpad_" .. i, param2 = param2 })
    end

    for _, offset in ipairs(S.default_point_powerup_offsets) do
        local pos = vector.round({
            x = S.arena_center.x + offset[1],
            y = b.y0 + 1,
            z = S.arena_center.z + offset[2],
        })
        minetest.set_node(pos, { name = "battletanks:powerup_point_spawner" })
    end

    minetest.log("action", "[battletanks] Arena placement done.")
end

local pending_callbacks = nil

function battletanks.build_arena(on_done)
    if pending_callbacks then
        table.insert(pending_callbacks, on_done)
        return
    end
    pending_callbacks = { on_done }

    local b = bounds()
    local apron = S.arena_apron
    local minp = { x = b.min_x - apron, y = b.y0 - 1, z = b.min_z - apron }
    local maxp = { x = b.max_x + apron, y = b.y0 + S.wall_height + 1, z = b.max_z + apron }

    minetest.emerge_area(minp, maxp, function(_blockpos, _action, calls_remaining)
        if calls_remaining <= 0 then
            build_arena_now()
            local callbacks = pending_callbacks
            pending_callbacks = nil
            for _, cb in ipairs(callbacks) do
                if cb then cb() end
            end
        end
    end)
end

function battletanks.ensure_arena(on_done)
    if battletanks.storage:get_int("arena_built") == 1 then
        if on_done then on_done() end
        return
    end
    battletanks.build_arena(function()
        battletanks.storage:set_int("arena_built", 1)
        if on_done then on_done() end
    end)
end

function battletanks.force_rebuild_arena(on_done)
    battletanks.build_arena(function()
        battletanks.storage:set_int("arena_built", 1)
        if on_done then on_done() end
    end)
end

function battletanks.spawn_points()
    local b = bounds()
    local scan_y = b.y0
    local spawn_y = b.y0 + 1

    local found = {}
    for x = b.min_x, b.max_x do
        for z = b.min_z, b.max_z do
            local pos = { x = x, y = scan_y, z = z }
            local node = minetest.get_node(pos)
            local n = node.name:match("^battletanks:spawnpad_(%d)$")
            if n then
                found[tonumber(n)] = { pos = pos, param2 = node.param2 }
            end
        end
    end

    local points = {}
    for i = 1, 8 do
        local f = found[i]
        if f then
            local dir = minetest.facedir_to_dir(f.param2)
            table.insert(points, {
                pos = { x = f.pos.x, y = spawn_y, z = f.pos.z },
                yaw = minetest.dir_to_yaw(dir),
            })
        end
    end
    return points
end

function battletanks.is_pit(x, z)
    return minetest.get_node({ x = x, y = S.arena_center.y, z = z }).name == "air"
end

local STRAY_DYNAMIC_POWERUP_NAMES = {
    ["battletanks:powerup_boost"] = true,
    ["battletanks:powerup_shield"] = true,
    ["battletanks:powerup_laser"] = true,
    ["battletanks:powerup_rocket"] = true,
}

function battletanks.clear_stray_dynamic_powerups()
    local b = bounds()
    local y = b.y0 + 1
    for x = b.min_x, b.max_x do
        for z = b.min_z, b.max_z do
            local pos = { x = x, y = y, z = z }
            if STRAY_DYNAMIC_POWERUP_NAMES[minetest.get_node(pos).name] then
                minetest.set_node(pos, { name = "air" })
            end
        end
    end
end
