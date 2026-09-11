battletanks = rawget(_G, "battletanks") or {}

math.randomseed(os.time())


battletanks.settings = {

    title                         = "BattleTanks v1.0.0",

    arena_center                  = { x = 0, y = 50, z = 0 }, -- built well above ground, self-contained
    arena_size                    = 101,                      -- floor is arena_size x arena_size (101x101) - needs to be uneven for fair distances
    wall_height                   = 10,                       -- height of the surrounding wall and internal maze obstacles
    floor_y_offset                = 0,                        -- floor sits at arena_center.y
    arena_apron                   = 10,                       -- extra flat stone margin built around the walled

    map_work_area = {
        min = { x = -100, y = 50, z = -100 },
        max = { x = 100, y = 100, z = 100 },
    },

    spawn_point_offsets = {
        { x = 0,   z = -40, dir_x = 0,  dir_z = 1 },  -- 1: north wall, center   -> faces south (opposite wall)
        { x = 0,   z = 40,  dir_x = 0,  dir_z = -1 }, -- 2: south wall, center   -> faces north (opposite wall)
        { x = -40, z = 0,   dir_x = 1,  dir_z = 0 },  -- 3: west wall, center    -> faces east (opposite wall)
        { x = 40,  z = 0,   dir_x = -1, dir_z = 0 },  -- 4: east wall, center    -> faces west (opposite wall)
        { x = 40,  z = -40, dir_x = 0,  dir_z = 1 },  -- 5: northeast corner     -> faces south
        { x = -40, z = 40,  dir_x = 0,  dir_z = -1 }, -- 6: southwest corner     -> faces north
        { x = -40, z = -40, dir_x = 1,  dir_z = 0 },  -- 7: northwest corner     -> faces east
        { x = 40,  z = 40,  dir_x = -1, dir_z = 0 },  -- 8: southeast corner     -> faces west
    },

    default_point_powerup_offsets = {
        { 0, 0 },
        { 10, 10 }, { 10, -10 }, { -10, 10 }, { -10, -10 },
        { 23, 23 }, { 23, -23 }, { -23, 23 }, { -23, -23 },
    },

    tiles                     = {
        arena_boundary_silver = "battletanks_tile_silver.png",
        arena_boundary_blue  = "battletanks_tile_blue.png",
    },

    -- In the same "x10" units set_attach expects (see entity.lua's
    -- turret comment) - real-world offset is this divided by 10, so
    -- {-3, 6, 0} here is {-0.3, 0.6, 0} nodes: a little to one side and
    -- up, but critically z=0 - directly over the body's own center along
    -- its forward axis, not behind it. This used to be z=5 (0.5 nodes
    -- back), inherited unchanged from the old lightcycle, where the rider
    -- sitting toward the rear of a long bike made sense. On the tank's
    -- now-square body that put the camera outside the hull entirely, and
    -- more importantly meant the *view* reaching a corner and the body's
    -- actual (server-side, grid-snapped) position reaching it were two
    -- different moments - you'd see yourself at the corner and turn, but
    -- the body itself, ahead of the camera, had already passed it,
    -- reliably turning a cell late.
    tank_attach_offset       = { x = -3, y = 6, z = 0 },

    tank_eye_height          = 1.0,

    -- Placeholder until dedicated turret art exists (see entity.lua) - position
    -- of the turret entity relative to the tank body it's attached to.
    turret_attach_offset      = { x = 0, y = 0.3, z = 0 },

    -- The world-anchored crosshair (see hud.lua's add_crosshair/
    -- update_crosshair) is placed at the actual point a shot fired right
    -- now would hit - a fixed-distance point sitting at shot height,
    -- below the camera, doesn't visually read as "the horizon" the way a
    -- true impact point does (increasingly so at close range, since the
    -- camera looks down at it more steeply than it would a distant point -
    -- classic parallax). This caps how far out that search looks before
    -- giving up and just showing the point at max range.
    crosshair_max_range        = 40,

    base_speed                = 6,    -- nodes/second, normal forward driving speed
    reverse_speed_multiplier  = 0.6,  -- reverse (hold S/down) is slower than driving forward
    boost_delta               = 0.30, -- +30% speed while the boost key (sneak/Shift) is held and the bar isn't empty
    boost_time                = 8,    -- seconds to fully drain the bar while boosting (bar only refills via a boost powerup pickup)

    move_check_ahead          = 0.35, -- how far ahead (nodes) to look for collisions each step

    mutual_elimination_grace  = 0.2,

    match_max_duration        = 180,

    night_time_of_day         = 0.2,

    sky_color                 = "#101010",

    sound                     = {
        engine_gain = 0.5,
        engine_max_hear_distance = 24,
        engine_pitch_normal = 1.0,
        engine_pitch_reverse = 0.8,
        engine_pitch_boost = 1.3,
        pickup_gain = 0.8,
        pickup_max_hear_distance = 20,
    },

    colors                    = { "red", "blue", "green", "yellow", "orange", "purple", "cyan", "white" },

    crash_effect              = {
        amount = 40,        -- number of spark particles in the burst
        time = 0.15,        -- how long the spawner stays active (short = instant burst)
        speed = 4,          -- outward velocity range (nodes/sec)
        min_lifetime = 0.3, -- seconds each spark exists for
        max_lifetime = 0.9,
        min_size = 0.8,
        max_size = 2.2,
    },

    rocket_blast_effect       = {
        -- Visible burst at a rocket's impact point, shown regardless of
        -- whether it actually caught a tank in the blast - a rocket that
        -- hits a bare wall should still clearly look like it detonated,
        -- not just silently vanish.
        amount = 40,
        time = 0.2,
        speed = 4,
        min_lifetime = 0.3,
        max_lifetime = 0.8,
        min_size = 1.0,
        max_size = 2.5,
    },

    placement_points             = { 25, 18, 15, 12, 10, 8, 6, 4, 2, 1 },

    point_powerups_enabled     = true,
    boost_powerups_enabled     = true,
    shield_powerups_enabled    = true,
    laser_powerups_enabled     = true,
    rocket_powerups_enabled    = true,
    point_powerup_value        = 3,   -- bonus match points awarded on pickup
    boost_powerup_interval     = 10,  -- seconds between boost powerup spawn attempts
    boost_powerup_lifetime     = 30,  -- seconds a spawned boost powerup lasts before vanishing unclaimed
    boost_powerup_max          = 5,   -- max unclaimed boost powerups on the arena at once - a spawn attempt is skipped (not queued or delayed) if the arena's already at this many, so lowering the interval is always safe from clutter
    shield_powerup_interval    = 8,   -- seconds between shield powerup spawn attempts
    shield_powerup_lifetime    = 30,  -- seconds a spawned shield powerup lasts before vanishing unclaimed
    shield_powerup_max         = 5,   -- see boost_powerup_max above
    laser_powerup_interval     = 7,  -- seconds between laser powerup spawn attempts
    laser_powerup_lifetime     = 30, -- seconds a spawned laser powerup lasts before vanishing unclaimed
    laser_powerup_max          = 5,  -- see boost_powerup_max above
    laser_per_pickup           = 10,  -- shots granted per laser powerup collected
    rocket_powerup_interval    = 8,  -- seconds between rocket powerup spawn attempts
    rocket_powerup_lifetime    = 30, -- seconds a spawned rocket powerup lasts before vanishing unclaimed
    rocket_powerup_max         = 5,  -- see boost_powerup_max above
    rocket_per_pickup          = 5,  -- shots granted per rocket powerup collected

    laser_speed_multiplier     = 4,   -- laser bolt speed, as a multiple of base_speed
    laser_cooldown             = 1,   -- minimum seconds between laser shots, per racer
    laser_lifetime             = 8,   -- seconds a bolt travels before despawning unclaimed (comfortably longer than crossing the whole arena)
    laser_max_bounces          = 5,   -- a bolt that bounces off this many walls without hitting anything despawns instead of bouncing again
    rocket_speed_multiplier    = 2,   -- rocket speed, as a multiple of base_speed
    rocket_cooldown            = 2,   -- minimum seconds between rocket, per racer
    rocket_lifetime            = 8,   -- seconds a rocket travels before despawning unclaimed (comfortably longer than crossing the whole arena)
    kill_by_shot_points        = 5,   -- bonus match points for eliminating another racer with a laser or rocket shot (on top of their own placement points)

    starting_laser             = 10, -- shots
    starting_rocket            = 5, -- shots
    starting_shield            = 1, -- charges (each one absorbs one incoming laser/rocket hit instead of derezzing you)
    starting_boost             = 30, -- bar charge, 0-100

    matches_per_session        = 5,

    bot_count                  = 0,
    bot_behavior               = "random",

    build_tool_range           = 10,
}

battletanks.players = {}

battletanks.storage = minetest.get_mod_storage()
