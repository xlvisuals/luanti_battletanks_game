
local S = battletanks.settings

local WORK_MIN = S.map_work_area.min
local WORK_MAX = S.map_work_area.max

local MOD_SCHEMS_DIR = minetest.get_modpath("battletanks") .. "/schems"
local WORLD_SCHEMS_DIR = minetest.get_worldpath() .. "/battletanks_schems"

local FILENAME_PATTERN = "^(%d+)p_(%d+)x(%d+)_(.+)%.mts$"

local function titleize(s)
    s = s:gsub("_", " ")
    return (s:gsub("(%a)([%w']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end))
end

local function scan_schems_dir(dir, maps, seen)
    local files = minetest.get_dir_list(dir, false) or {}
    for _, filename in ipairs(files) do
        if not seen[filename] then
            local players, width, depth, name = filename:match(FILENAME_PATTERN)
            if players then
                seen[filename] = true
                local w, d = tonumber(width), tonumber(depth)
                table.insert(maps, {
                    key = filename, -- the filename itself is the stable, unique identifier
                    schematic = filename,
                    dir = dir, -- which of the two directories this map's file actually lives in
                    max_players = tonumber(players),
                    place_pos = {
                        x = S.arena_center.x - math.floor(w / 2),
                        y = S.arena_center.y,
                        z = S.arena_center.z - math.floor(d / 2),
                    },
                    display_name = players .. "P: " .. titleize(name),
                })
            elseif filename:match("%.mts$") then
                minetest.log("warning", "[battletanks] Skipping '" .. filename
                    .. "' in " .. dir .. " - doesn't match the naming convention "
                    .. "'<players>p_<width>x<depth>_<name>.mts', e.g. "
                    .. "'2p_120x120_my_map.mts'.")
            end
        end
    end
end

function battletanks.discover_maps()
    local maps = {}
    local seen = {}
    scan_schems_dir(MOD_SCHEMS_DIR, maps, seen)
    scan_schems_dir(WORLD_SCHEMS_DIR, maps, seen)

    table.sort(maps, function(a, b) return a.display_name < b.display_name end)
    return maps
end

local function find_map(key)
    for _, m in ipairs(battletanks.discover_maps()) do
        if m.key == key then return m end
    end
    return nil
end

local function clear_area(minp, maxp)
    local vm = minetest.get_voxel_manip()
    local emin, emax = vm:read_from_map(minp, maxp)
    local va = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
    local data = vm:get_data()
    local c_air = minetest.get_content_id("air")
    for i in va:iterp(minp, maxp) do
        data[i] = c_air
    end
    vm:set_data(data)
    vm:write_to_map()
end

function battletanks.load_map(map_key, on_done)
    local map = find_map(map_key)
    if not map then
        minetest.log("error", "[battletanks] load_map: unknown map key '" .. tostring(map_key) .. "'")
        if on_done then on_done(false) end
        return
    end

    minetest.log("action", "[battletanks] Loading map '" .. map.display_name .. "'...")

    minetest.emerge_area(WORK_MIN, WORK_MAX, function(_blockpos, _action, calls_remaining)
        if calls_remaining > 0 then return end

        clear_area(WORK_MIN, WORK_MAX)

        local schem_path = map.dir .. "/" .. map.schematic
        local ok = minetest.place_schematic(map.place_pos, schem_path, "0", nil, true) ~= nil

        if ok then
            battletanks.storage:set_string("current_map", map.key)
            minetest.log("action", "[battletanks] Map '" .. map.display_name .. "' loaded.")

            local bounds_ok = battletanks.rescan_arena_bounds()
            local spawn_count = #battletanks.spawn_points()

            local effective_max = math.min(map.max_players, spawn_count > 0 and spawn_count or map.max_players)
            if lobby_system.set_max_players then
                lobby_system.set_max_players(math.max(1, math.min(effective_max, #S.colors)))
            end

            if not bounds_ok then
                minetest.chat_send_all("[BattleTanks] Warning: map '" .. map.display_name
                    .. "' has no detectable boundary (battletanks:boundary nodes) - "
                    .. "collision and trail-clearing may not work correctly on it.")
            end
            if spawn_count == 0 then
                minetest.chat_send_all("[BattleTanks] Warning: map '" .. map.display_name
                    .. "' has no detectable spawn points (battletanks:spawnpad_1..8) - "
                    .. "nobody will be able to start a match on it.")
            elseif spawn_count ~= map.max_players then
                minetest.chat_send_all("[BattleTanks] Warning: map '" .. map.display_name
                    .. "' filename says " .. map.max_players .. " player(s), but "
                    .. spawn_count .. " spawn point(s) were actually found - using "
                    .. effective_max .. ".")
            end
        else
            minetest.log("error", "[battletanks] Failed to place schematic: " .. schem_path)
        end

        if on_done then on_done(ok) end
    end)
end

function battletanks.current_map_key()
    local key = battletanks.storage:get_string("current_map")
    if key ~= "" and find_map(key) then
        return key
    end
    local maps = battletanks.discover_maps()
    return maps[1] and maps[1].key or nil
end

function battletanks.ensure_map_loaded(on_done)
    if battletanks.storage:get_int("map_loaded") == 1 then
        minetest.emerge_area(WORK_MIN, WORK_MAX, function(_blockpos, _action, calls_remaining)
            if calls_remaining > 0 then return end
            battletanks.rescan_arena_bounds()
            if on_done then on_done() end
        end)
        return
    end
    local key = battletanks.current_map_key()
    if not key then
        minetest.log("info", "[battletanks] No valid .mts files found in schems/. Building default arena.")
        battletanks.build_arena(on_done)
        if on_done then on_done() end
        return
    end
    battletanks.load_map(key, function(ok)
        battletanks.storage:set_int("map_loaded", 1)
        if on_done then on_done() end
    end)
end


local function sanitize_map_name(raw)
    local s = (raw or ""):lower()
    s = s:gsub("[^%w]+", "_")
    s = s:gsub("^_+", ""):gsub("_+$", "")
    if s == "" then return nil end
    return s
end

function battletanks.export_map_prefix()
    local b = battletanks.arena_bounds()
    local players = #battletanks.spawn_points()
    local width = b.max_x - b.min_x + 1
    local depth = b.max_z - b.min_z + 1
    return players .. "p_" .. width .. "x" .. depth .. "_"
end

function battletanks.export_map_filename(raw_name)
    local sanitized = sanitize_map_name(raw_name)
    if not sanitized then
        return nil, "please enter a name with at least one letter or number in it"
    end
    local filename = battletanks.export_map_prefix() .. sanitized .. ".mts"

    for _, m in ipairs(battletanks.discover_maps()) do
        if m.key == filename then
            return nil, "a map named '" .. filename .. "' already exists - pick a different name"
        end
    end

    return filename
end

function battletanks.export_current_map(filename, on_done)
    local b = battletanks.arena_bounds()
    local p1 = { x = b.min_x, y = S.map_work_area.min.y, z = b.min_z }
    local p2 = { x = b.max_x, y = S.map_work_area.max.y, z = b.max_z }

    minetest.emerge_area(p1, p2, function(_blockpos, _action, calls_remaining)
        if calls_remaining > 0 then return end

        minetest.mkdir(WORLD_SCHEMS_DIR)
        local filepath = WORLD_SCHEMS_DIR .. "/" .. filename

        local ok = false
        local success, result = pcall(minetest.create_schematic, p1, p2, nil, filepath)
        if success and result then
            ok = true
        end

        if ok then
            minetest.log("action", "[battletanks] Saved current map to " .. filepath)
            if on_done then on_done(true, "Saved as '" .. filename .. "' - it's now available in the map dropdown.") end
        else
            minetest.log("error", "[battletanks] Failed to save map to " .. filepath
                .. (success and "" or (" (" .. tostring(result) .. ")")))
            if on_done then on_done(false, "Save failed - couldn't write " .. filename
                .. " (check the server log).") end
        end
    end)
end
