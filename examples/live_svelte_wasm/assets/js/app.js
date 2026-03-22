import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { getHooks } from "live_svelte";

// Import Svelte components explicitly (esbuild does not support import.meta.glob)
import MarkdownEditor from "../svelte/MarkdownEditor.svelte";

// Build the components map for LiveSvelte
const components = {
  MarkdownEditor,
};

let hooks = getHooks(components);

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: hooks,
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();
window.liveSocket = liveSocket;
