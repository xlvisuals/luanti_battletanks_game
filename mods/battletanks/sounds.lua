
battletanks.sounds = {}

local S = battletanks.settings.sound
local engine_handles = {}

function battletanks.sounds.start_engine_loop(obj, name, pitch)
    if engine_handles[name] then return end
    engine_handles[name] = minetest.sound_play("battletanks_loop", {
        object = obj, gain = S.engine_gain, loop = true,
        max_hear_distance = S.engine_max_hear_distance,
        pitch = pitch or S.engine_pitch_normal,
    })
end

function battletanks.sounds.set_engine_pitch(obj, name, pitch)
    if engine_handles[name] then
        minetest.sound_stop(engine_handles[name])
        engine_handles[name] = nil
    end
    battletanks.sounds.start_engine_loop(obj, name, pitch)
end

function battletanks.sounds.stop_engine_loop(name)
    if engine_handles[name] then
        minetest.sound_stop(engine_handles[name])
        engine_handles[name] = nil
    end
end

function battletanks.sounds.play_point_pickup(pos)
    minetest.sound_play("pickup_point", {
        pos = pos, gain = S.pickup_gain, max_hear_distance = S.pickup_max_hear_distance,
    }, true)
end

function battletanks.sounds.play_boost_pickup(pos)
    minetest.sound_play("pickup_boost", {
        pos = pos, gain = S.pickup_gain, max_hear_distance = S.pickup_max_hear_distance,
    }, true)
end

function battletanks.sounds.play_shield_pickup(pos)
    minetest.sound_play("pickup_shield", {
        pos = pos, gain = S.pickup_gain, max_hear_distance = S.pickup_max_hear_distance,
    }, true)
end

function battletanks.sounds.play_shield_break(pos)
    minetest.sound_play("shield_break", {
        pos = pos, gain = S.pickup_gain, max_hear_distance = S.pickup_max_hear_distance,
    }, true)
end

function battletanks.sounds.play_laser_pickup(pos)
    minetest.sound_play("pickup_laser", {
        pos = pos, gain = S.pickup_gain, max_hear_distance = S.pickup_max_hear_distance,
    }, true)
end

function battletanks.sounds.play_rocket_pickup(pos)
    minetest.sound_play("pickup_rocket", {
        pos = pos, gain = S.pickup_gain, max_hear_distance = S.pickup_max_hear_distance,
    }, true)
end

function battletanks.sounds.play_rocket_explosion(pos)
    minetest.sound_play("rocket_explosion", {
        pos = pos, gain = S.pickup_gain, max_hear_distance = S.pickup_max_hear_distance,
    }, true)
end

function battletanks.sounds.play_shoot_laser(pos)
    minetest.sound_play("shoot_laser", {
        pos = pos, gain = S.pickup_gain, max_hear_distance = S.pickup_max_hear_distance,
    }, true)
end

function battletanks.sounds.play_shoot_rocket(pos)
    minetest.sound_play("shoot_rocket", {
        pos = pos, gain = S.pickup_gain, max_hear_distance = S.pickup_max_hear_distance,
    }, true)
end

minetest.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    if engine_handles[name] then
        minetest.sound_stop(engine_handles[name])
        engine_handles[name] = nil
    end
end)
