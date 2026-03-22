//! Rust WASM hooks and utilities for the Private Analytics demo.
//!
//! This crate provides:
//!   - SQL syntax highlighting (LiveView hook)
//!   - HTML table rendering with pagination
//!   - PII detection and masking
//!   - Histogram computation and canvas drawing
//!   - Column profiling (numeric stats, text top values)
//!   - Data normalization (BigInt handling, null coercion)

pub mod sql_editor;
pub mod table_renderer;
pub mod pii_engine;
pub mod histogram;
pub mod column_profiler;
pub mod data_processor;

// Re-export key items
pub use sql_editor::{SqlEditorHook, highlight_sql};
pub use table_renderer::render_table_html;
pub use pii_engine::{mask_pii, mask_value, detect_pii_columns};
pub use histogram::{compute_histogram, draw_histogram};
pub use column_profiler::profile_column;
pub use data_processor::normalize_rows;
