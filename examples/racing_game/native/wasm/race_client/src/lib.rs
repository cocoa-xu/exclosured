#![allow(static_mut_refs, dead_code)]

/// Racing game client: compute-mode WASM.
///
/// JS handles canvas rendering via requestAnimationFrame.
/// WASM owns game state: physics, collision detection, interpolation.
/// Server sends ticks at 20Hz; WASM interpolates to 60fps locally.

use core::cell::RefCell;
use exclosured_guest as exclosured;

const LANE_COUNT: u8 = 3;
const LANE_WIDTH: f32 = 80.0;
const CAR_W: f32 = 40.0;
const CAR_H: f32 = 60.0;
const ROAD_LEFT: f32 = 60.0;
const MAX_GHOSTS: usize = 32;
const MAX_NPCS: usize = 64;

#[derive(Clone, Copy)]
struct Ghost {
    active: bool,
    id_hash: u32,
    lane: u8,
    distance: f32,
    prev_distance: f32,
    target_distance: f32,
    lerp_t: f32,
    color: u32, // packed RGB
}

#[derive(Clone, Copy)]
struct Npc {
    active: bool,
    id: u32,
    lane: u8,
    y_world: f32,
    speed: f32,
}

struct GameState {
    phase: u8, // 0=lobby 1=countdown 2=racing 3=results

    // Player
    my_lane: u8,
    my_distance: f32,
    my_speed: f32,
    target_lane: u8,
    lane_lerp: f32,
    stunned: bool,
    stun_visual: f32,

    // Ghosts
    ghosts: [Ghost; MAX_GHOSTS],
    ghost_count: usize,

    // NPCs
    npcs: [Npc; MAX_NPCS],

    // State output
    pending_collision: i32,
    countdown: u32,
    remaining_sec: u32,

    // Spectator
    is_spectator: bool,
    spectate_distance: f32,
    spectate_lane: u8,

    // Timing
    race_time: f32,
}

thread_local! {
    static STATE: RefCell<GameState> = RefCell::new(GameState {
        phase: 0,
        my_lane: 1, my_distance: 0.0, my_speed: 200.0,
        target_lane: 1, lane_lerp: 1.0,
        stunned: false, stun_visual: 0.0,
        ghosts: [Ghost { active: false, id_hash: 0, lane: 1, distance: 0.0,
                         prev_distance: 0.0, target_distance: 0.0, lerp_t: 1.0, color: 0x54a0ff }; MAX_GHOSTS],
        ghost_count: 0,
        npcs: [Npc { active: false, id: 0, lane: 0, y_world: 0.0, speed: 0.0 }; MAX_NPCS],
        pending_collision: -1,
        countdown: 0, remaining_sec: 60,
        is_spectator: false, spectate_distance: 0.0, spectate_lane: 1,
        race_time: 0.0,
    });
}

// alloc/dealloc provided by exclosured_guest

// --- Game state setters (called from JS) ---

#[no_mangle]
pub extern "C" fn set_phase(phase: u32) {
    STATE.with(|s| {
        let mut g = s.borrow_mut();
        g.phase = phase as u8;
        if phase == 2 {
            // Racing started, reset
            g.my_distance = 0.0;
            g.my_speed = 200.0;
            g.my_lane = 1;
            g.target_lane = 1;
            g.lane_lerp = 1.0;
            g.stunned = false;
            g.pending_collision = -1;
            g.race_time = 0.0;
        }
    });
}

#[no_mangle]
pub extern "C" fn set_spectator(is_spec: u32) {
    STATE.with(|s| s.borrow_mut().is_spectator = is_spec != 0);
}

#[no_mangle]
pub extern "C" fn set_countdown(remaining: u32) {
    STATE.with(|s| s.borrow_mut().countdown = remaining);
}

#[no_mangle]
pub extern "C" fn set_remaining(remaining: u32) {
    STATE.with(|s| s.borrow_mut().remaining_sec = remaining);
}

/// Switch lane: direction -1 (left) or 1 (right)
#[no_mangle]
pub extern "C" fn switch_lane(direction: i32) {
    STATE.with(|s| {
        let mut g = s.borrow_mut();
        if g.phase != 2 || g.is_spectator || g.stunned { return; }
        let new_lane = (g.target_lane as i32 + direction).clamp(0, LANE_COUNT as i32 - 1) as u8;
        if new_lane != g.target_lane {
            g.target_lane = new_lane;
            g.lane_lerp = 0.0;
        }
    });
}

/// Spectator sets target to follow
#[no_mangle]
pub extern "C" fn set_spectate_target(lane: u8, distance: f32) {
    STATE.with(|s| {
        let mut g = s.borrow_mut();
        g.spectate_lane = lane;
        g.spectate_distance = distance;
    });
}

// --- Server tick updates ---

/// Update ghost (other player) positions. Called per player from JS.
#[no_mangle]
pub extern "C" fn update_ghost(id_hash: u32, lane: u8, distance: f32, _speed: f32) {
    STATE.with(|s| {
        let mut g = s.borrow_mut();
        // Find existing or allocate new slot
        let slot = g.ghosts.iter_mut().find(|gh| gh.active && gh.id_hash == id_hash);
        if let Some(ghost) = slot {
            ghost.prev_distance = ghost.distance;
            ghost.target_distance = distance;
            ghost.lane = lane;
            ghost.lerp_t = 0.0;
        } else if g.ghost_count < MAX_GHOSTS {
            let idx = g.ghosts.iter().position(|gh| !gh.active).unwrap_or(0);
            let color = hash_to_color(id_hash);
            g.ghosts[idx] = Ghost {
                active: true, id_hash, lane, distance, prev_distance: distance,
                target_distance: distance, lerp_t: 1.0, color,
            };
            g.ghost_count += 1;
        }
    });
}

/// Remove a ghost (player left)
#[no_mangle]
pub extern "C" fn remove_ghost(id_hash: u32) {
    STATE.with(|s| {
        let mut g = s.borrow_mut();
        if let Some(ghost) = g.ghosts.iter_mut().find(|gh| gh.active && gh.id_hash == id_hash) {
            ghost.active = false;
            g.ghost_count = g.ghost_count.saturating_sub(1);
        }
    });
}

/// Spawn an NPC obstacle (from server)
#[no_mangle]
pub extern "C" fn spawn_npc(id: u32, lane: u8, y_offset: f32, speed: f32) {
    STATE.with(|s| {
        let mut g = s.borrow_mut();
        if let Some(slot) = g.npcs.iter_mut().find(|n| !n.active) {
            *slot = Npc { active: true, id, lane, y_world: y_offset, speed };
        }
    });
}

/// Server confirmed collision, apply stun.
#[no_mangle]
pub extern "C" fn collision_ack(penalty_ms: u32) {
    STATE.with(|s| {
        let mut g = s.borrow_mut();
        g.stunned = true;
        g.stun_visual = penalty_ms as f32 / 1000.0;
        g.my_speed = 0.0;
    });
}

/// Server rejected collision, ignore.
#[no_mangle]
pub extern "C" fn collision_reject() {
    STATE.with(|s| s.borrow_mut().pending_collision = -1);
}

// --- Tick (called from JS requestAnimationFrame) ---

/// Advance game by dt seconds. Returns packed state for JS to read.
/// Returns: lane | (distance as bits << 8)
#[no_mangle]
pub extern "C" fn tick(dt: f32) -> f32 {
    STATE.with(|s| {
        let mut g = s.borrow_mut();
        let dt = dt.min(0.1);

        if g.phase != 2 { return 0.0; }
        g.race_time += dt;

        // Lane transition
        if g.lane_lerp < 1.0 {
            g.lane_lerp = (g.lane_lerp + dt * 8.0).min(1.0);
            if g.lane_lerp >= 1.0 {
                g.my_lane = g.target_lane;
            }
        }

        // Stun recovery visual
        if g.stunned {
            g.stun_visual -= dt;
            if g.stun_visual <= 0.0 {
                g.stunned = false;
                g.my_speed = 200.0;
            }
        }

        // Move player
        if !g.is_spectator {
            g.my_distance += g.my_speed * dt;
        }

        // Interpolate ghosts
        for ghost in g.ghosts.iter_mut().filter(|gh| gh.active) {
            ghost.lerp_t = (ghost.lerp_t + dt * 20.0).min(1.0);
            ghost.distance = lerp(ghost.prev_distance, ghost.target_distance, ghost.lerp_t);
        }

        // Move NPCs (relative to player's scroll)
        for npc in g.npcs.iter_mut().filter(|n| n.active) {
            npc.y_world += npc.speed * dt;
        }

        // Cull off-screen NPCs
        for npc in g.npcs.iter_mut() {
            if npc.active && npc.y_world > 2000.0 {
                npc.active = false;
            }
        }

        // Collision detection (only for players, not spectators)
        if !g.is_spectator && !g.stunned && g.pending_collision < 0 {
            let player_lane = if g.lane_lerp >= 1.0 { g.my_lane } else { g.target_lane };

            // Find collision (immutable borrow of npcs)
            let hit_npc_id = g.npcs.iter()
                .filter(|n| n.active && n.lane == player_lane)
                .find(|n| n.y_world > 400.0 && n.y_world < 400.0 + CAR_H + 20.0)
                .map(|n| n.id);

            // Apply collision (mutable borrow, no overlap)
            if let Some(npc_id) = hit_npc_id {
                g.pending_collision = npc_id as i32;
                g.stunned = true;
                g.stun_visual = 1.5;
                g.my_speed = 0.0;
                exclosured::emit("collision", &format!(r#"{{"npc_id":{}}}"#, npc_id));
            }
        }

        g.my_distance
    })
}

// --- Render data queries (called by JS to draw) ---

/// Get player state for rendering + server reporting
/// Returns ptr to a static buffer: [lane, target_lane, lane_lerp, distance, speed, stunned]
static mut PLAYER_BUF: [f32; 6] = [0.0; 6];

#[no_mangle]
pub extern "C" fn get_player_state() -> *const f32 {
    STATE.with(|s| {
        let g = s.borrow();
        unsafe {
            PLAYER_BUF[0] = g.my_lane as f32;
            PLAYER_BUF[1] = g.target_lane as f32;
            PLAYER_BUF[2] = g.lane_lerp;
            PLAYER_BUF[3] = g.my_distance;
            PLAYER_BUF[4] = g.my_speed;
            PLAYER_BUF[5] = if g.stunned { 1.0 } else { 0.0 };
            PLAYER_BUF.as_ptr()
        }
    })
}

/// Get ghost render data. Returns ptr to buffer:
/// [count, (lane, distance, color_r, color_g, color_b) * count]
static mut GHOST_BUF: [f32; 1 + MAX_GHOSTS * 5] = [0.0; 1 + MAX_GHOSTS * 5];

#[no_mangle]
pub extern "C" fn get_ghosts() -> *const f32 {
    STATE.with(|s| {
        let g = s.borrow();
        unsafe {
            let mut i = 0;
            for ghost in g.ghosts.iter().filter(|gh| gh.active) {
                let off = 1 + i * 5;
                GHOST_BUF[off] = ghost.lane as f32;
                GHOST_BUF[off + 1] = ghost.distance;
                GHOST_BUF[off + 2] = ((ghost.color >> 16) & 0xFF) as f32;
                GHOST_BUF[off + 3] = ((ghost.color >> 8) & 0xFF) as f32;
                GHOST_BUF[off + 4] = (ghost.color & 0xFF) as f32;
                i += 1;
            }
            GHOST_BUF[0] = i as f32;
            GHOST_BUF.as_ptr()
        }
    })
}

/// Get NPC render data. Returns ptr to buffer:
/// [count, (id, lane, y_world) * count]
static mut NPC_BUF: [f32; 1 + MAX_NPCS * 3] = [0.0; 1 + MAX_NPCS * 3];

#[no_mangle]
pub extern "C" fn get_npcs() -> *const f32 {
    STATE.with(|s| {
        let g = s.borrow();
        unsafe {
            let mut i = 0;
            for npc in g.npcs.iter().filter(|n| n.active) {
                let off = 1 + i * 3;
                NPC_BUF[off] = npc.id as f32;
                NPC_BUF[off + 1] = npc.lane as f32;
                NPC_BUF[off + 2] = npc.y_world;
                i += 1;
            }
            NPC_BUF[0] = i as f32;
            NPC_BUF.as_ptr()
        }
    })
}

/// Get pending collision NPC id (-1 if none). Consumed on read.
#[no_mangle]
pub extern "C" fn get_pending_collision() -> i32 {
    STATE.with(|s| {
        let mut g = s.borrow_mut();
        let id = g.pending_collision;
        g.pending_collision = -1;
        id
    })
}

/// Get countdown value
#[no_mangle]
pub extern "C" fn get_countdown() -> u32 {
    STATE.with(|s| s.borrow().countdown)
}

/// Get remaining race seconds
#[no_mangle]
pub extern "C" fn get_remaining() -> u32 {
    STATE.with(|s| s.borrow().remaining_sec)
}

/// Get current phase
#[no_mangle]
pub extern "C" fn get_phase() -> u32 {
    STATE.with(|s| s.borrow().phase as u32)
}

/// Get spectator state
#[no_mangle]
pub extern "C" fn get_spectate_state() -> *const f32 {
    STATE.with(|s| {
        let g = s.borrow();
        unsafe {
            PLAYER_BUF[0] = g.spectate_lane as f32;
            PLAYER_BUF[1] = g.spectate_lane as f32;
            PLAYER_BUF[2] = 1.0;
            PLAYER_BUF[3] = g.spectate_distance;
            PLAYER_BUF[4] = 0.0;
            PLAYER_BUF[5] = 0.0;
            PLAYER_BUF.as_ptr()
        }
    })
}

// --- Helpers ---

fn lerp(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}

fn hash_to_color(h: u32) -> u32 {
    let colors: [u32; 8] = [
        0x54a0ff, 0xff6b6b, 0xfeca57, 0x48dbfb,
        0xff9ff3, 0x5f27cd, 0x01a3a4, 0xf368e0,
    ];
    colors[(h as usize) % colors.len()]
}

fn lane_x(lane: u8) -> f32 {
    ROAD_LEFT + (lane as f32) * LANE_WIDTH + LANE_WIDTH / 2.0
}
