//! SQL syntax highlighter implemented as a LiveView hook.
//!
//! Provides `SqlEditorHook` (a stateful struct bound to a DOM container) and
//! the pure `highlight_sql` function that tokenises SQL and wraps keywords,
//! functions, strings, numbers, and comments in `<span>` elements.

use wasm_bindgen::prelude::*;
use web_sys::{HtmlElement, HtmlTextAreaElement};

#[wasm_bindgen]
pub struct SqlEditorHook {
    container: HtmlElement,
    push_event: js_sys::Function,
    textarea: Option<HtmlTextAreaElement>,
    display: Option<HtmlElement>,
}

#[wasm_bindgen]
impl SqlEditorHook {
    #[wasm_bindgen(constructor)]
    pub fn new(container: HtmlElement, push_event: js_sys::Function) -> Self {
        Self {
            container,
            push_event,
            textarea: None,
            display: None,
        }
    }

    /// Called when the hook element is mounted in the DOM.
    /// Sets up the SQL editor with syntax highlighting overlay.
    pub fn mounted(&mut self) {
        let _document = web_sys::window().unwrap().document().unwrap();

        // Find or create textarea and display overlay
        self.textarea = self.container
            .query_selector("textarea")
            .ok()
            .flatten()
            .map(|el| el.dyn_into::<HtmlTextAreaElement>().unwrap());

        self.display = self.container
            .query_selector(".sql-display")
            .ok()
            .flatten()
            .map(|el| el.dyn_into::<HtmlElement>().unwrap());

        // Initial highlight
        if let (Some(textarea), Some(display)) = (&self.textarea, &self.display) {
            let sql = textarea.value();
            display.set_inner_html(&highlight_sql(&sql));
        }

        // Set up input event listener via closure
        if let Some(textarea) = &self.textarea {
            let display = self.display.clone();
            let push_event = self.push_event.clone();

            let closure = Closure::wrap(Box::new(move |_event: web_sys::Event| {
                let textarea = web_sys::window().unwrap().document().unwrap()
                    .query_selector("textarea#sql-editor").ok().flatten()
                    .map(|el| el.dyn_into::<HtmlTextAreaElement>().unwrap());

                if let Some(textarea) = &textarea {
                    let sql = textarea.value();

                    // Update syntax highlighting
                    if let Some(display) = &display {
                        display.set_inner_html(&highlight_sql(&sql));
                    }

                    // Push event to LiveView
                    let _ = push_event.call2(
                        &JsValue::NULL,
                        &JsValue::from_str("update_sql"),
                        &JsValue::from_str(&format!(r#"{{"value":"{}"}}"#,
                            sql.replace('\\', "\\\\").replace('"', "\\\"")
                        )),
                    );
                }
            }) as Box<dyn FnMut(web_sys::Event)>);

            textarea.add_event_listener_with_callback(
                "input",
                closure.as_ref().unchecked_ref(),
            ).unwrap();

            // Sync scroll
            let display_scroll = self.display.clone();
            let scroll_closure = Closure::wrap(Box::new(move |_event: web_sys::Event| {
                let textarea = web_sys::window().unwrap().document().unwrap()
                    .query_selector("textarea#sql-editor").ok().flatten()
                    .map(|el| el.dyn_into::<HtmlTextAreaElement>().unwrap());

                if let (Some(textarea), Some(display)) = (&textarea, &display_scroll) {
                    display.set_scroll_top(textarea.scroll_top());
                    display.set_scroll_left(textarea.scroll_left());
                }
            }) as Box<dyn FnMut(web_sys::Event)>);

            textarea.add_event_listener_with_callback(
                "scroll",
                scroll_closure.as_ref().unchecked_ref(),
            ).unwrap();

            // Ctrl/Cmd+Enter to run query
            let push_run = self.push_event.clone();
            let key_closure = Closure::wrap(Box::new(move |event: web_sys::KeyboardEvent| {
                if (event.ctrl_key() || event.meta_key()) && event.key() == "Enter" {
                    event.prevent_default();
                    let textarea = web_sys::window().unwrap().document().unwrap()
                        .query_selector("textarea#sql-editor").ok().flatten()
                        .map(|el| el.dyn_into::<HtmlTextAreaElement>().unwrap());

                    if let Some(textarea) = &textarea {
                        let sql = textarea.value();
                        let _ = push_run.call2(
                            &JsValue::NULL,
                            &JsValue::from_str("submit_query"),
                            &JsValue::from_str(&format!(r#"{{"sql":"{}"}}"#,
                                sql.replace('\\', "\\\\").replace('"', "\\\"")
                            )),
                        );
                    }
                }
            }) as Box<dyn FnMut(web_sys::KeyboardEvent)>);

            textarea.add_event_listener_with_callback(
                "keydown",
                key_closure.as_ref().unchecked_ref(),
            ).unwrap();

            // Prevent closures from being dropped (they must live as long as the DOM)
            closure.forget();
            scroll_closure.forget();
            key_closure.forget();
        }
    }

    /// Called when LiveView re-renders the parent element.
    pub fn updated(&self) {
        // Re-highlight if content changed externally
        if let (Some(textarea), Some(display)) = (&self.textarea, &self.display) {
            let sql = textarea.value();
            display.set_inner_html(&highlight_sql(&sql));
        }
    }

    /// Handle an event from the LiveView server.
    pub fn on_event(&self, event: &str, payload: &str) {
        match event {
            "set_sql" => {
                // Server wants to set the SQL content (e.g., viewer receiving owner's query)
                if let (Some(textarea), Some(display)) = (&self.textarea, &self.display) {
                    textarea.set_value(payload);
                    display.set_inner_html(&highlight_sql(payload));
                }
            }
            _ => {}
        }
    }

    /// Get the current SQL content.
    pub fn get_sql(&self) -> String {
        self.textarea.as_ref().map(|t| t.value()).unwrap_or_default()
    }

    /// Highlight SQL and update the display overlay directly.
    pub fn highlight(&self) {
        if let (Some(textarea), Some(display)) = (&self.textarea, &self.display) {
            let sql = textarea.value();
            display.set_inner_html(&highlight_sql(&sql));
        }
    }
}

/// Pure function: highlight SQL syntax into HTML spans.
/// This runs entirely in WASM. No JS regex engine involved.
#[wasm_bindgen]
pub fn highlight_sql(sql: &str) -> String {
    let mut result = String::with_capacity(sql.len() * 2);
    let chars: Vec<char> = sql.chars().collect();
    let len = chars.len();
    let mut i = 0;

    while i < len {
        let ch = chars[i];

        // Single-line comment: -- to end of line
        if ch == '-' && i + 1 < len && chars[i + 1] == '-' {
            result.push_str("<span class=\"kw-comment\">");
            while i < len && chars[i] != '\n' {
                push_escaped(&mut result, chars[i]);
                i += 1;
            }
            result.push_str("</span>");
            continue;
        }

        // String literal: 'text'
        if ch == '\'' {
            result.push_str("<span class=\"kw-str\">");
            push_escaped(&mut result, ch);
            i += 1;
            while i < len {
                push_escaped(&mut result, chars[i]);
                if chars[i] == '\'' {
                    i += 1;
                    break;
                }
                i += 1;
            }
            result.push_str("</span>");
            continue;
        }

        // Number: digits (including decimals)
        if ch.is_ascii_digit() || (ch == '.' && i + 1 < len && chars[i + 1].is_ascii_digit()) {
            result.push_str("<span class=\"kw-num\">");
            while i < len && (chars[i].is_ascii_digit() || chars[i] == '.') {
                result.push(chars[i]);
                i += 1;
            }
            result.push_str("</span>");
            continue;
        }

        // Identifier or keyword: [a-zA-Z_]
        if ch.is_ascii_alphabetic() || ch == '_' {
            let start = i;
            while i < len && (chars[i].is_ascii_alphanumeric() || chars[i] == '_') {
                i += 1;
            }
            let word: String = chars[start..i].iter().collect();
            let upper = word.to_uppercase();

            if is_keyword(&upper) {
                result.push_str("<span class=\"kw\">");
                push_escaped_str(&mut result, &word);
                result.push_str("</span>");
            } else if is_function(&upper) {
                result.push_str("<span class=\"kw-fn\">");
                push_escaped_str(&mut result, &word);
                result.push_str("</span>");
            } else {
                push_escaped_str(&mut result, &word);
            }
            continue;
        }

        // Everything else: pass through
        push_escaped(&mut result, ch);
        i += 1;
    }

    result
}

pub fn is_keyword(word: &str) -> bool {
    matches!(word,
        "SELECT" | "FROM" | "WHERE" | "AND" | "OR" | "NOT" | "IN" | "IS" | "NULL" |
        "LIKE" | "BETWEEN" | "EXISTS" | "JOIN" | "INNER" | "LEFT" | "RIGHT" | "OUTER" |
        "FULL" | "CROSS" | "ON" | "AS" | "ORDER" | "BY" | "ASC" | "DESC" | "GROUP" |
        "HAVING" | "LIMIT" | "OFFSET" | "UNION" | "ALL" | "DISTINCT" | "INSERT" |
        "INTO" | "VALUES" | "UPDATE" | "SET" | "DELETE" | "CREATE" | "TABLE" | "DROP" |
        "ALTER" | "INDEX" | "VIEW" | "WITH" | "CASE" | "WHEN" | "THEN" | "ELSE" | "END" |
        "TRUE" | "FALSE" | "REPLACE" | "IF" | "USING" | "NATURAL" | "RECURSIVE" |
        "EXCEPT" | "INTERSECT" | "OVER" | "PARTITION" | "WINDOW" | "ROWS" | "RANGE" |
        "UNBOUNDED" | "PRECEDING" | "FOLLOWING" | "CURRENT" | "ROW" | "FILTER"
    )
}

pub fn is_function(word: &str) -> bool {
    matches!(word,
        "COUNT" | "SUM" | "AVG" | "MIN" | "MAX" | "COALESCE" | "NULLIF" |
        "CAST" | "ROUND" | "ABS" | "UPPER" | "LOWER" | "LENGTH" | "TRIM" |
        "SUBSTR" | "SUBSTRING" | "CONCAT" | "REPLACE" | "NOW" | "DATE" |
        "EXTRACT" | "YEAR" | "MONTH" | "DAY" | "HOUR" | "MINUTE" | "SECOND" |
        "ROW_NUMBER" | "RANK" | "DENSE_RANK" | "LAG" | "LEAD" | "FIRST_VALUE" |
        "LAST_VALUE" | "NTH_VALUE" | "NTILE" | "PERCENT_RANK" | "CUME_DIST" |
        "STRING_AGG" | "ARRAY_AGG" | "BOOL_AND" | "BOOL_OR" | "MEDIAN" |
        "STDDEV" | "VARIANCE" | "READ_PARQUET" | "READ_CSV_AUTO" | "READ_JSON_AUTO" |
        "TYPEOF" | "LIST" | "STRUCT" | "MAP" | "UNNEST" | "GENERATE_SERIES"
    )
}

pub fn push_escaped(result: &mut String, ch: char) {
    match ch {
        '&' => result.push_str("&amp;"),
        '<' => result.push_str("&lt;"),
        '>' => result.push_str("&gt;"),
        '"' => result.push_str("&quot;"),
        _ => result.push(ch),
    }
}

pub fn push_escaped_str(result: &mut String, s: &str) {
    for ch in s.chars() {
        push_escaped(result, ch);
    }
}
