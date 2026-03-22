defmodule PrivateAnalyticsWeb.Components do
  @moduledoc """
  Inline WASM components using Maud for compile-time HTML generation.

  Demonstrates `defwasm` with the `deps:` option, pulling in the `maud` crate
  from crates.io. Maud validates HTML structure at compile time and auto-escapes
  all interpolated values. The generated HTML is returned as a string from WASM.
  """

  use Exclosured.Inline

  @doc """
  Render a stats card as HTML using Maud's compile-time HTML macro.

  Input JSON: {"title":"Query Stats","items":[["Rows","1000"],["Time","12ms"]]}
  Output: Safe, escaped HTML string written back into the input buffer.
  """
  defwasm :render_stats_card, args: [data: :binary], deps: [maud: "0.26"] do
    ~RUST"""
    use maud::html;

    fn find_value<'a>(json: &'a str, key: &str) -> Option<&'a str> {
        let pattern = format!("\"{}\":\"", key);
        let start = json.find(&pattern)? + pattern.len();
        let end = json[start..].find('"')? + start;
        Some(&json[start..end])
    }

    fn find_pairs(json: &str) -> Vec<(String, String)> {
        let mut pairs = Vec::new();
        let mut search = json;
        while let Some(start) = search.find("[\"") {
            let rest = &search[start + 2..];
            if let Some(mid) = rest.find("\",\"") {
                let label = &rest[..mid];
                let after = &rest[mid + 3..];
                if let Some(end) = after.find("\"]") {
                    let value = &after[..end];
                    pairs.push((label.to_string(), value.to_string()));
                    search = &after[end + 2..];
                    continue;
                }
            }
            break;
        }
        pairs
    }

    let input_str = match core::str::from_utf8(data) {
        Ok(s) => s,
        Err(_) => return -1,
    };

    let title = find_value(input_str, "title").unwrap_or("Stats");
    let items = find_pairs(input_str);

    let markup = html! {
        div class="stats-card" {
            div class="stats-card-title" { (title) }
            div class="stats-card-grid" {
                @for (label, value) in &items {
                    div class="stats-card-item" {
                        span class="stats-card-label" { (label.as_str()) }
                        span class="stats-card-value" { (value.as_str()) }
                    }
                }
            }
        }
    };

    let html_bytes = markup.into_string().into_bytes();
    let n = html_bytes.len().min(data.len());
    data[..n].copy_from_slice(&html_bytes[..n]);
    return n as i32;
    """
  end
end
