defmodule LiveSvelteWasmWeb.EditorLive do
  use Phoenix.LiveView
  import LiveSvelte

  @default_markdown """
  # Welcome to the Markdown Editor

  This editor uses **pulldown-cmark** compiled to WebAssembly via Exclosured,
  with math rendering powered by KaTeX. Every keystroke triggers WASM parsing
  in sub-millisecond time.

  ## Tech Stack

  - **Elixir** (LiveView) manages state and syncs between users
  - **Svelte** (LiveSvelte) renders the split-pane editor UI
  - **Rust** (pulldown-cmark via `defwasm`) parses markdown to HTML in the browser
  - **JavaScript** (KaTeX) renders math expressions from the HTML output

  ## Math Support

  Inline math: $E = mc^2$ and $a^2 + b^2 = c^2$.

  The quadratic formula: $x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$

  Display math with double dollars:

  $$\\int_{0}^{1} x^2 \\, dx = \\frac{1}{3}$$

  Euler's identity: $e^{i\\pi} + 1 = 0$

  A sum: $$\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}$$

  ## Code Example

  ```rust
  fn main() {
      println!("Hello from Rust!");
  }
  ```

  ## Blockquote

  > Markdown parsing happens entirely in the browser.
  > No server round-trips needed for rendering.

  ## Table

  | Technology | Role |
  |------------|------|
  | Elixir | Server state, LiveView |
  | Svelte | Editor UI component |
  | Rust/WASM | Markdown parsing |
  | KaTeX | Math rendering |

  ---

  Try editing this text to see the **live preview** update instantly!
  """

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       markdown: String.trim(@default_markdown),
       wasm_ready: false
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.svelte name="MarkdownEditor" props={%{markdown: @markdown}} ssr={false} />
    """
  end

  @impl true
  def handle_event("update_markdown", %{"text" => text}, socket) do
    {:noreply, assign(socket, markdown: text)}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}
end
