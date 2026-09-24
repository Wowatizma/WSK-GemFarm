local plugin_label   = 'wsk_gem_farmer'
local plugin_version = '0.1.8-test'

console.print('[WSK Farmer] Diablo II - Worldstone Keep (Hell) v' .. plugin_version)

local gui = {
    tree          = tree_node:new(0),
    enabled       = checkbox:new(false, get_hash(plugin_label .. '_enabled')),
    boss_wait     = slider_int:new(10, 120, 10, get_hash(plugin_label .. '_boss_wait')),
    reset_wait    = slider_int:new(1, 15, 3, get_hash(plugin_label .. '_reset_wait')),
    debug         = checkbox:new(true, get_hash(plugin_label .. '_debug')),
}

local last_ur_command = nil
local boss_departure = nil
local altar_clicks = 0
local altar_first_click = nil
local altar_baseline = {}
local altar_settled_at = nil
local altar_click_pos = nil

local STATE = {
    OUTSIDE       = 'outside / finding entrance',
    ENTERING      = 'entering dungeon',
    EXPLORE       = 'searching for boss portal',
    ENTER_BOSS    = 'entering boss room',
    FIND_ALTAR    = 'finding altar (return portal blacklisted)',
    WAIT_BOSS     = 'boss fight / loot wait',
    LEAVING       = 'leaving dungeon',
    RESETTING     = 'resetting dungeon',
}

local state                 = STATE.OUTSIDE
local state_started         = -1
local last_interact         = -100
local last_leave            = -100
local entrance_anchor       = nil
local return_portal_pos     = nil
local entrance_missing_at   = -1
local outside_confirmed_at  = -1
local reset_called          = false
local original_ur_enabled   = nil
local was_enabled           = false
local runs                  = 0
local status_detail         = ''

local ENTRANCE_NAME = 'S15_Portal_Dungeon_Rifts'
local GENERIC_PORTAL = 'Prefab_Portal_Dungeon_Generic'
local ALTAR_NAME = 'S15_Arreat_Summit_Altar_A_Gizmo'

local INTERACT_RANGE       = 3.0
local ACTOR_SCAN_RANGE     = 120.0
local ENTRANCE_IGNORE_DIST = 30.0
local RETURN_IGNORE_DIST   = 15.0
local ENTRY_STABLE_TIME    = 1.0
local TRANSITION_TIMEOUT   = 15.0
local INTERACT_COOLDOWN    = 2.0

local function now()
    return get_time_since_inject()
end

local function log(message)
    if gui.debug:get() then console.print('[WSK Farmer] ' .. message) end
end

local function set_state(next_state, detail)
    if state ~= next_state then
        state = next_state
        state_started = now()
        status_detail = detail or ''
        log('State: ' .. next_state .. (detail and (' - ' .. detail) or ''))
    elseif detail then
        status_detail = detail
    end
end

local function ur_available()
    return _G.UNIVERSAL_ROTATION ~= nil
        and type(_G.UNIVERSAL_ROTATION.set_enabled) == 'function'
end

local function remember_ur_state()
    if original_ur_enabled ~= nil or not ur_available() then return end
    if type(_G.UNIVERSAL_ROTATION.get_enabled) == 'function' then
        original_ur_enabled = _G.UNIVERSAL_ROTATION.get_enabled()
    else
        original_ur_enabled = true
    end
end

local function set_ur(value)
    remember_ur_state()
    if ur_available() and last_ur_command ~= value then
        _G.UNIVERSAL_ROTATION.set_enabled(value)
        last_ur_command = value
        log('Universal Rotation ' .. (value and 'enabled' or 'disabled'))
    end
end

local function restore_ur()
    if ur_available() and original_ur_enabled ~= nil then
        _G.UNIVERSAL_ROTATION.set_enabled(original_ur_enabled)
    end
    original_ur_enabled = nil
    last_ur_command = nil
end

local function actor_name(actor)
    local ok, value = pcall(function() return actor:get_skin_name() end)
    return ok and (value or '') or ''
end

local function actor_interactable(actor)
    local ok, value = pcall(function()
        if loot_manager and loot_manager.is_interactable_object then
            return loot_manager.is_interactable_object(actor)
        end
        return actor:is_interactable()
    end)
    return ok and value == true
end

local function find_actor(name, player_pos, max_range, predicate, include_inactive)
    local best, best_dist = nil, max_range or math.huge
    for _, actor in ipairs(actors_manager.get_all_actors()) do
        if actor_name(actor) == name and (include_inactive or actor_interactable(actor)) then
            local ok, pos = pcall(function() return actor:get_position() end)
            if ok and pos then
                local dist = pos:dist_to(player_pos)
                if dist < best_dist and (predicate == nil or predicate(actor, pos, dist)) then
                    best, best_dist = actor, dist
                end
            end
        end
    end
    return best, best_dist
end

local nav_stopped = false
local boss_arrival_since = nil
local near_altar_mode = false
local near_altar_move_at = -100
local function stop_batmobile()
    if not BatmobilePlugin or nav_stopped then return end
    nav_stopped = true
    BatmobilePlugin.pause(plugin_label)
    if BatmobilePlugin.stop_long_path then BatmobilePlugin.stop_long_path(plugin_label) end
    if BatmobilePlugin.clear_target then BatmobilePlugin.clear_target(plugin_label) end
end

local boss_nav_pos, boss_nav_time, boss_repath = nil, -100, -100
local heartbeat = -100
local function boss_navigation(altar, player_pos)
    nav_stopped = false
    if not boss_nav_pos or player_pos:dist_to(boss_nav_pos) > 1 then
        boss_nav_pos, boss_nav_time = player_pos, now()
    end
    if now() - boss_nav_time > 3 then
        BatmobilePlugin.reset_movement(plugin_label)
        boss_repath = -100
        boss_nav_time = now()
        log('Boss approach stalled; cleared movement and requesting fresh path')
        if altar and player_pos:dist_to(altar:get_position()) < 12 then
            pathfinder.force_move_raw(altar:get_position())
            return
        end
    end
    if altar then
        if now() - boss_repath >= 2 and not BatmobilePlugin.is_long_path_navigating() then
            boss_repath = now()
            local accepted = BatmobilePlugin.navigate_long_path(plugin_label, altar:get_position())
            log('Boss approach path requested; accepted=' .. tostring(accepted))
            if not accepted then pathfinder.request_move(altar:get_position()) end
        end
        -- Batmobile's own on_update drives long paths; do not overwrite its target.
    else
        BatmobilePlugin.resume(plugin_label)
        BatmobilePlugin.update(plugin_label)
        BatmobilePlugin.move(plugin_label)
    end
end

-- Boss-room discovery recovery: small oscillations are not exploration progress.
local search_origin, search_anchor = nil, nil
local search_anchor_time = 0
local search_recovery = false
local search_index = 0
local search_target = nil
local search_target_time = 0
local search_attempt_time = -100
local search_offsets = {
    {1,0}, {0,1}, {-1,0}, {0,-1},
    {0.707,0.707}, {-0.707,0.707}, {-0.707,-0.707}, {0.707,-0.707},
}
local function reset_boss_search(pos)
    -- Keep a copy: do not depend on a live player position object.
    search_origin = vec3:new(pos:x(), pos:y(), pos:z())
    search_anchor = search_origin
    search_anchor_time = now()
    search_recovery, search_index, search_target = false, 0, nil
    search_attempt_time = -100
end

local function stop_search_route()
    if search_target or search_recovery then
        nav_stopped = false
        stop_batmobile()
        BatmobilePlugin.reset_movement(plugin_label)
        search_target = nil
        search_recovery = false
        boss_repath = -100
    end
end

local function search_boss_room(pos)
    if not search_origin then reset_boss_search(pos) end
    if pos:dist_to(search_anchor) > 8 then
        search_anchor = vec3:new(pos:x(), pos:y(), pos:z())
        search_anchor_time = now()
    end
    if not search_recovery then
        if now() - search_anchor_time < 10 and now() - state_started < 20 then
            boss_navigation(nil, pos)
            return
        end
        nav_stopped = false
        stop_batmobile()
        BatmobilePlugin.reset(plugin_label)
        search_recovery = true
        log('Boss search recovery: confined movement or no altar after 20s; sampling reachable room points')
    end
    if search_target then
        if pos:dist_to(search_target) > 3 and now() - search_target_time < 8
            and BatmobilePlugin.is_long_path_navigating() then
            status_detail = 'boss search recovery: moving to point ' .. tostring(search_index)
            return
        end
        nav_stopped = false
        stop_batmobile()
        search_target = nil
    end
    if now() - search_attempt_time < 0.5 then return end
    search_attempt_time = now()
    if search_index >= 24 then
        log('Boss search recovery exhausted reachable-point candidates; stopping for inspection')
        gui.enabled:set(false)
        return
    end
    search_index = search_index + 1
    local direction = search_offsets[(search_index-1)%8+1]
    local radius = 18 + 12 * math.floor((search_index-1)/8)
    local candidate = vec3:new(search_origin:x()+direction[1]*radius,
        search_origin:y()+direction[2]*radius, search_origin:z())
    local reachable = BatmobilePlugin.get_closeby_node(plugin_label, candidate, 5)
    if not reachable or pos:dist_to(reachable) <= 3 then return end
    BatmobilePlugin.reset_movement(plugin_label)
    nav_stopped = false
    local accepted = BatmobilePlugin.navigate_long_path(plugin_label, reachable)
    log(string.format('Boss search point %d: path=%s pos=(%.1f, %.1f, %.1f)',
        search_index, tostring(accepted), reachable:x(), reachable:y(), reachable:z()))
    if accepted then
        search_target, search_target_time = reachable, now()
    else
        stop_batmobile()
    end
end

local function explore_with_batmobile()
    if not BatmobilePlugin then
        status_detail = 'ERROR: Batmobile must be loaded'
        return
    end
    nav_stopped = false
    BatmobilePlugin.set_priority(plugin_label, 'distance')
    BatmobilePlugin.resume(plugin_label)
    BatmobilePlugin.update(plugin_label)
    BatmobilePlugin.move(plugin_label)
end

local function move_to_actor(actor, dist)
    if dist <= INTERACT_RANGE then
        stop_batmobile()
        if now() - last_interact >= INTERACT_COOLDOWN then
            last_interact = now()
            interact_object(actor)
            return true
        end
        return false
    end

    if BatmobilePlugin then
        nav_stopped = false
        BatmobilePlugin.pause(plugin_label)
        local accepted = BatmobilePlugin.set_target(plugin_label, actor, dist <= 6.0)
        if accepted == false then pathfinder.request_move(actor:get_position()) end
        BatmobilePlugin.update(plugin_label)
        BatmobilePlugin.move(plugin_label)
    else
        pathfinder.request_move(actor:get_position())
    end
    return false
end

local function outside_entrance(player_pos)
    return find_actor(ENTRANCE_NAME, player_pos, ACTOR_SCAN_RANGE)
end

local function reset_run()
    stop_batmobile()
    if BatmobilePlugin then BatmobilePlugin.reset(plugin_label) end
    entrance_anchor = nil
    return_portal_pos = nil
    entrance_missing_at = -1
    outside_confirmed_at = -1
    reset_called = false
    last_interact = -100
    last_leave = -100
    boss_departure = nil
    boss_arrival_since = nil
    near_altar_mode = false
    near_altar_move_at = -100
    altar_clicks = 0
    altar_first_click = nil
    altar_settled_at = nil
    altar_click_pos = nil
    altar_baseline = {}
    last_ur_command = nil
    set_ur(true)
    set_state(STATE.OUTSIDE)
end

local function pulse()
    local enabled = gui.enabled:get()
    if not enabled then
        if was_enabled then
            stop_batmobile()
            restore_ur()
            log('Disabled; Universal Rotation restored')
        end
        was_enabled = false
        return
    end

    if not was_enabled then
        was_enabled = true
        remember_ur_state()
        reset_run()
        log('Enabled. Start near the Season 15 Worldstone Keep entrance.')
    end

    local player = get_local_player()
    if not player or player:is_dead() then
        if player and player:is_dead() then revive_at_checkpoint() end
        return
    end

    local player_pos = player:get_position()
    local t = now()
    if (state == STATE.ENTER_BOSS or state == STATE.FIND_ALTAR) and t - heartbeat >= 3 then
        heartbeat = t
        log(string.format('Boss diagnostic: %s; pos=(%.2f, %.2f, %.2f); %s',
            state, player_pos:x(), player_pos:y(), player_pos:z(), status_detail))
    end

    if state == STATE.OUTSIDE then
        set_ur(true)
        local door, dist = outside_entrance(player_pos)
        if not door then
            status_detail = 'Entrance not found within 120m'
            stop_batmobile()
            return
        end
        status_detail = string.format('entrance %.1fm', dist)
        if move_to_actor(door, dist) then
            set_state(STATE.ENTERING, 'entrance clicked')
        end

    elseif state == STATE.ENTERING then
        set_ur(true)
        local door = outside_entrance(player_pos)
        if door then
            entrance_missing_at = -1
            status_detail = string.format('waiting for load; outside entrance still visible')
        else
            if entrance_missing_at < 0 then entrance_missing_at = t end

            -- The outside actor can disappear briefly on the very next frame after
            -- interaction. Do not call that a completed load. The real dungeon spawn
            -- is confirmed by a stable absence plus its nearby generic return portal.
            local return_portal, return_dist = find_actor(
                GENERIC_PORTAL, player_pos, 20.0)
            local stable = (t - entrance_missing_at) >= ENTRY_STABLE_TIME

            if stable and return_portal then
                entrance_anchor = player_pos
                return_portal_pos = return_portal:get_position()
                if BatmobilePlugin then BatmobilePlugin.reset(plugin_label) end
                set_state(STATE.EXPLORE,
                    string.format('inside confirmed; return portal %.1fm blacklisted', return_dist))
                log(string.format(
                    'Dungeon entered after stable confirmation; return portal at %.1fm blacklisted',
                    return_dist))
            else
                status_detail = string.format(
                    'confirming load (stable %.1f/%.1fs, return portal %s)',
                    t - entrance_missing_at,
                    ENTRY_STABLE_TIME,
                    return_portal and string.format('%.1fm', return_dist) or 'not visible')
            end
        end

        if state == STATE.ENTERING and t - state_started >= TRANSITION_TIMEOUT then
            entrance_missing_at = -1
            set_state(STATE.OUTSIDE, 'entry confirmation timed out; retrying')
        end

    elseif state == STATE.EXPLORE then
        set_ur(true)
        local portal, dist = find_actor(GENERIC_PORTAL, player_pos, ACTOR_SCAN_RANGE,
            function(_, pos)
                local away_from_spawn = entrance_anchor == nil
                    or pos:dist_to(entrance_anchor) > ENTRANCE_IGNORE_DIST
                local away_from_return = return_portal_pos == nil
                    or pos:dist_to(return_portal_pos) > RETURN_IGNORE_DIST
                return away_from_spawn and away_from_return
            end)

        if portal then
            status_detail = string.format('boss portal candidate %.1fm', dist)
            if move_to_actor(portal, dist) then
                boss_departure = player_pos
                set_state(STATE.ENTER_BOSS, 'boss portal clicked')
                log('Boss portal clicked; ALL portals are now blacklisted for this run')
            end
        else
            status_detail = 'exploring; entrance portal ignored'
            explore_with_batmobile()
        end

    elseif state == STATE.ENTER_BOSS then
        stop_batmobile()
        local altar = find_actor(ALTAR_NAME, player_pos, ACTOR_SCAN_RANGE, nil, true)
        local moved = boss_departure and player_pos:dist_to(boss_departure) > 100
        -- Boss rooms occupy different world offsets each run. Confirm a sustained
        -- portal displacement, not proximity to one previously recorded coordinate.
        if altar or moved then
            boss_arrival_since = boss_arrival_since or t
        else
            boss_arrival_since = nil
        end
        if boss_arrival_since and t - boss_arrival_since >= 0.35 then
            if BatmobilePlugin then BatmobilePlugin.reset(plugin_label) end
            boss_nav_pos, boss_nav_time, boss_repath = nil, t, -100
            nav_stopped = false
            near_altar_mode = false
            reset_boss_search(player_pos)
            set_ur(true)
            set_state(STATE.FIND_ALTAR, 'arrival confirmed; combat enabled; portals blacklisted')
        elseif t - state_started >= 30 then
            log('Boss arrival not confirmed. Stopping; send this log and your position.')
            gui.enabled:set(false)
        else
            status_detail = 'waiting for boss-room arrival'
        end

    elseif state == STATE.FIND_ALTAR then
        set_ur(true)
        local altar, dist = find_actor(ALTAR_NAME, player_pos, ACTOR_SCAN_RANGE, nil, true)
        if altar and search_recovery then
            stop_search_route()
            log('Altar found during recovery; switching to pillar approach')
        end
        local summoned = false
        -- Use instance IDs: a pre-existing enemy or changing interactable flag
        -- cannot confirm a summon. Missing IDs fail closed and leave diagnostics.
        if altar_first_click then
            for _, enemy in ipairs(actors_manager.get_enemy_actors()) do
                local ok, id = pcall(function() return enemy:get_id() end)
                local name = actor_name(enemy)
                local enemy_ok, hostile = pcall(function() return enemy:is_enemy() end)
                local boss_ok, boss = pcall(function() return enemy:is_boss() end)
                local is_smoke = name:lower():find('runesmoke', 1, true) ~= nil
                if ok and id and id ~= 0 and not altar_baseline[id] and not is_smoke
                    and ((enemy_ok and hostile) or (boss_ok and boss))
                    and not enemy:is_dead()
                    and enemy:get_position():dist_to(altar_click_pos) < 35 then
                    summoned = true
                    log('New enemy after altar attempt: id=' .. tostring(id) .. ' skin=' .. actor_name(enemy))
                    break
                end
            end
        end
        if summoned then
            stop_batmobile()
            set_state(STATE.WAIT_BOSS, 'new enemy detected after altar attempt; combat/loot timer started')
        elseif t - state_started > 120 then
            log('Altar/summon timed out; stopping with rotation restored. Send console output.')
            gui.enabled:set(false)
        elseif altar then
            status_detail = string.format('altar %.1fm; clicks %d', dist, altar_clicks)
            if dist <= 2.5 then
                if near_altar_mode then
                    near_altar_mode = false
                    nav_stopped = false
                end
                stop_batmobile()
                if not altar_settled_at then altar_settled_at = t end
                if t - altar_settled_at >= 0.5 and t - last_interact >= 2 and altar_clicks < 8 then
                    last_interact = t
                    altar_clicks = altar_clicks + 1
                    if not altar_first_click then
                        altar_baseline = {}
                        for _, enemy in ipairs(actors_manager.get_enemy_actors()) do
                            local ok, id = pcall(function() return enemy:get_id() end)
                            if ok and id then altar_baseline[id] = true end
                        end
                        altar_click_pos = altar:get_position()
                        altar_first_click = t
                    end
                    local result = interact_object(altar)
                    log(string.format('Altar click %d at %.1fm; result=%s', altar_clicks, dist, tostring(result)))
                end
            else
                altar_settled_at = nil
                if dist <= 8 then
                    -- Hand off once, then let each movement request run rather than
                    -- cancelling/restarting Batmobile every frame.
                    if not near_altar_mode then
                        stop_batmobile()
                        near_altar_mode = true
                        near_altar_move_at = -100
                        log('Pillar close approach: continuous movement; no clicks until in range')
                    end
                    if t - near_altar_move_at >= 0.5 then
                        pathfinder.request_move(altar:get_position())
                        near_altar_move_at = t
                    end
                else
                    near_altar_mode = false
                    boss_navigation(altar, player_pos)
                end
            end
        else
            status_detail = 'exploring boss room for altar; portals blacklisted'
            search_boss_room(player_pos)
        end

    elseif state == STATE.WAIT_BOSS then
        stop_batmobile()
        set_ur(true)
        local wait = gui.boss_wait:get()
        local elapsed = t - state_started
        status_detail = string.format('combat/loot %.1f / %ds', elapsed, wait)
        if elapsed >= wait then
            set_ur(false)
            leave_dungeon()
            last_leave = t
            set_state(STATE.LEAVING, 'leave_dungeon() called')
        end

    elseif state == STATE.LEAVING then
        set_ur(false)
        stop_batmobile()
        local door = outside_entrance(player_pos)
        if door then
            outside_confirmed_at = t
            set_state(STATE.RESETTING, 'outside confirmed')
        elseif t - last_leave >= 5.0 then
            leave_dungeon()
            last_leave = t
            status_detail = 'leave_dungeon() retry'
            log('leave_dungeon() retry')
        end

    elseif state == STATE.RESETTING then
        set_ur(false)
        stop_batmobile()
        if outside_confirmed_at < 0 then outside_confirmed_at = t end
        local elapsed = t - outside_confirmed_at
        if elapsed < 0.5 then
            status_detail = 'settling outside'
        elseif not reset_called then
            reset_all_dungeons()
            reset_called = true
            status_detail = 'reset_all_dungeons() called'
            log('reset_all_dungeons() called')
        elseif elapsed >= (0.5 + gui.reset_wait:get()) then
            runs = runs + 1
            log('Reset complete; starting run ' .. tostring(runs + 1))
            reset_run()
        else
            status_detail = string.format('waiting after reset %.1fs', elapsed - 0.5)
        end
    end
end

on_update(function()
    local ok, err = pcall(function()
        pulse()
    end)
    if not ok then
        console.print('[WSK Farmer] ERROR: ' .. tostring(err))
        gui.enabled:set(false)
        pcall(stop_batmobile)
        restore_ur()
    end
end)

on_render_menu(function()
    if not gui.tree:push('Z | WSK Gem Farmer | v' .. plugin_version) then return end
    if BatmobilePlugin == nil then render_menu_header('Requires Batmobile (load it first)') end
    if not ur_available() then render_menu_header('Universal Rotation API not detected') end
    gui.enabled:render('Enable', 'Start outside, near S15_Portal_Dungeon_Rifts.')
    gui.boss_wait:render('Boss + loot wait (seconds)', 'Time after clicking the altar before leaving. Default: 10 seconds.')
    gui.reset_wait:render('Reset wait (seconds)', 'Time after reset_all_dungeons() before the next run.')
    gui.debug:render('Console logging', 'Print state changes and important actions.')
    render_menu_header('State: ' .. state)
    if status_detail ~= '' then render_menu_header('Detail: ' .. status_detail) end
    render_menu_header('Completed resets: ' .. tostring(runs))
    gui.tree:pop()
end)

on_render(function()
    if not gui.enabled:get() then return end
    local msg = 'WSK Farmer: ' .. state
    if status_detail ~= '' then msg = msg .. ' (' .. status_detail .. ')' end
    graphics.text_2d(msg, vec2:new(25, 80), 18, color_white(255))
end)

WSKGemFarmerPlugin = {
    get_state = function() return state, status_detail end,
    get_runs = function() return runs end,
    disable = function() gui.enabled:set(false) end,
}
