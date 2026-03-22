//! Server-side table HTML rendering.
//!
//! Builds a complete `<table>` innerHTML string with `<thead>` and `<tbody>`
//! from JSON column and row data with pagination support.

use serde_json::Value;
use wasm_bindgen::prelude::*;

use crate::sql_editor::push_escaped_str;

/// Render a page of results as an HTML table string.
/// columns: JSON array of column names
/// rows: JSON array of row objects
/// page: current page number (1-based)
/// page_size: rows per page
/// Returns: complete `<table>` innerHTML string with thead and tbody
#[wasm_bindgen]
pub fn render_table_html(columns_json: &str, rows_json: &str, page: u32, page_size: u32) -> String {
    let columns: Vec<String> = match serde_json::from_str::<Value>(columns_json) {
        Ok(Value::Array(arr)) => arr
            .iter()
            .filter_map(|v| v.as_str().map(|s| s.to_string()))
            .collect(),
        _ => return "<table><tbody><tr><td>Invalid columns JSON</td></tr></tbody></table>".to_string(),
    };

    let rows: Vec<Value> = match serde_json::from_str::<Value>(rows_json) {
        Ok(Value::Array(arr)) => arr,
        _ => return "<table><tbody><tr><td>Invalid rows JSON</td></tr></tbody></table>".to_string(),
    };

    let page = if page == 0 { 1 } else { page };
    let page_size = if page_size == 0 { 25 } else { page_size };

    let start = ((page - 1) * page_size) as usize;
    let end = (start + page_size as usize).min(rows.len());

    let mut html = String::with_capacity(4096);

    // Table header
    html.push_str("<thead><tr>");
    // Cursor column (empty, JS fills in cursor dots)
    html.push_str("<th class=\"cursor-header\"></th>");
    for col in &columns {
        html.push_str("<th>");
        push_escaped_str(&mut html, col);
        html.push_str("</th>");
    }
    html.push_str("</tr></thead>");

    // Table body
    html.push_str("<tbody>");

    if start < rows.len() {
        for (idx, row) in rows[start..end].iter().enumerate() {
            html.push_str("<tr>");
            // Empty cursor cell (JS adds cursor dots here)
            html.push_str("<td class=\"cursor-cell\"></td>");

            for col in &columns {
                html.push_str("<td>");
                let cell_value = row.get(col.as_str());
                match cell_value {
                    Some(Value::String(s)) => push_escaped_str(&mut html, s),
                    Some(Value::Number(n)) => html.push_str(&n.to_string()),
                    Some(Value::Bool(b)) => html.push_str(if *b { "true" } else { "false" }),
                    Some(Value::Null) | None => {
                        html.push_str("<span class=\"null-value\">NULL</span>");
                    }
                    Some(other) => {
                        let s = other.to_string();
                        push_escaped_str(&mut html, &s);
                    }
                }
                html.push_str("</td>");
            }
            html.push_str("</tr>");
        }
    }

    html.push_str("</tbody>");
    html
}
