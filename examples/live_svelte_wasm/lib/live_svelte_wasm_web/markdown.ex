defmodule LiveSvelteWasmWeb.Markdown do
  @moduledoc """
  Inline WASM module that uses the pulldown-cmark Rust crate
  to parse Markdown into HTML entirely in the browser.

  The compiled WASM is loaded by the Svelte component and called
  on every keystroke for sub-millisecond rendering.
  """

  use Exclosured.Inline

  defwasm :parse_markdown, args: [input: :binary], deps: ["pulldown-cmark": "0.12"] do
    ~S"""
    use pulldown_cmark::{Parser, Options, html::push_html};

    // The buffer may be larger than the actual markdown content.
    // Trim trailing null bytes to find the real input.
    let end = input.iter().rposition(|&b| b != 0).map_or(0, |i| i + 1);
    let md = match core::str::from_utf8(&input[..end]) {
        Ok(s) => s,
        Err(_) => return -1,
    };

    // Enable common markdown extensions
    let mut options = Options::empty();
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TASKLISTS);
    let parser = Parser::new_ext(md, options);
    let mut html_output = String::new();
    push_html(&mut html_output, parser);

    let bytes = html_output.as_bytes();
    let n = bytes.len().min(input.len());
    input[..n].copy_from_slice(&bytes[..n]);
    return n as i32;
    """
  end
end
