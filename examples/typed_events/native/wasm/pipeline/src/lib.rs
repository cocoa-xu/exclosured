use wasm_bindgen::prelude::*;

// Re-export alloc/dealloc for memory management from the host
pub use exclosured_guest::{alloc, dealloc};

// ---------------------------------------------------------------
// Event structs: each annotated with `/// exclosured:event` so that
// `use Exclosured.Events` generates matching Elixir structs with
// `from_payload/1` for type-safe deserialization.
// ---------------------------------------------------------------

/// exclosured:event
pub struct PipelineStarted {
    pub total_items: u32,
    pub stages: u32,
}

/// exclosured:event
pub struct StageComplete {
    pub stage_name: String,
    pub items_processed: u32,
    pub duration_ms: u32,
}

/// exclosured:event
pub struct ItemProcessed {
    pub item_id: u32,
    pub stage_name: String,
    pub result: String,
}

/// exclosured:event
pub struct PipelineFinished {
    pub total_processed: u32,
    pub total_duration_ms: u32,
    pub success_rate: f32,
}

// ---------------------------------------------------------------
// Pipeline execution
// ---------------------------------------------------------------

/// Run a data processing pipeline with the given number of items.
///
/// The pipeline has 3 stages: parse, validate, transform.
/// Typed events are emitted at each step so the LiveView can
/// track progress via proper Elixir structs.
#[wasm_bindgen]
pub fn run_pipeline(item_count: i32) -> i32 {
    let count = item_count as u32;
    let stage_names = ["parse", "validate", "transform"];
    let num_stages = stage_names.len() as u32;

    // Emit pipeline_started
    let started_payload = format!(
        r#"{{"total_items":{},"stages":{}}}"#,
        count, num_stages
    );
    exclosured_guest::emit("pipeline_started", &started_payload);

    let mut total_processed: u32 = 0;
    let mut total_duration: u32 = 0;
    let mut success_count: u32 = 0;

    for stage_name in &stage_names {
        let mut stage_items: u32 = 0;

        // Simulate processing time per stage (varies by stage)
        let base_duration: u32 = match *stage_name {
            "parse" => 3,
            "validate" => 5,
            "transform" => 4,
            _ => 2,
        };

        for item_id in 0..count {
            // Determine result based on stage and item
            let result = compute_result(*stage_name, item_id);

            if result == "ok" {
                success_count += 1;
            }

            // Emit item_processed for every 5th item to avoid flooding
            if item_id % 5 == 0 || item_id == count - 1 {
                let item_payload = format!(
                    r#"{{"item_id":{},"stage_name":"{}","result":"{}"}}"#,
                    item_id, stage_name, result
                );
                exclosured_guest::emit("item_processed", &item_payload);
            }

            stage_items += 1;
            total_processed += 1;
        }

        // Compute simulated duration for this stage
        let stage_duration = base_duration * count + (count / 3);
        total_duration += stage_duration;

        // Emit stage_complete
        let stage_payload = format!(
            r#"{{"stage_name":"{}","items_processed":{},"duration_ms":{}}}"#,
            stage_name, stage_items, stage_duration
        );
        exclosured_guest::emit("stage_complete", &stage_payload);
    }

    // Calculate success rate across all stages and items
    let total_attempts = count * num_stages;
    let success_rate = if total_attempts > 0 {
        success_count as f32 / total_attempts as f32
    } else {
        0.0
    };

    // Emit pipeline_finished
    let finished_payload = format!(
        r#"{{"total_processed":{},"total_duration_ms":{},"success_rate":{:.4}}}"#,
        total_processed, total_duration, success_rate
    );
    exclosured_guest::emit("pipeline_finished", &finished_payload);

    total_processed as i32
}

/// Compute a processing result for a given stage and item.
/// Most items succeed, but some fail during validation.
fn compute_result(stage: &str, item_id: u32) -> &'static str {
    match stage {
        "validate" => {
            // About 10% of items fail validation
            if item_id % 10 == 7 {
                "error"
            } else {
                "ok"
            }
        }
        "transform" => {
            // About 5% of items produce warnings
            if item_id % 20 == 13 {
                "warning"
            } else {
                "ok"
            }
        }
        _ => "ok",
    }
}
