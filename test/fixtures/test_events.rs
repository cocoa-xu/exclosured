use serde::Serialize;

/// exclosured:event
#[derive(Serialize)]
pub struct ProgressEvent {
    pub percent: u32,
    pub stage: String,
}

// This struct has no annotation, should be ignored
pub struct InternalState {
    pub counter: u32,
}

/// exclosured:event
pub struct CollisionEvent {
    pub npc_id: u32,
    pub player_lane: u8,
    pub speed: f32,
}

/// exclosured:event
pub struct SimpleFlag {
    pub active: bool,
    pub label: String,
    pub tags: Vec<String>,
    pub score: Option<f64>,
}
