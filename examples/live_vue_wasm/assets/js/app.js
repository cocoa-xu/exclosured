import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { getHooks } from "live_vue";
import { ExclosuredHook } from "exclosured";

// Use Vite's glob import so LiveVue can resolve components by name.
// Keys are like "../vue/StatsChart.vue" which LiveVue matches against
// the v-component="StatsChart" attribute.
const vueComponents = import.meta.glob("../vue/**/*.vue", { eager: true });

const hooks = {
  ...getHooks(vueComponents),
  Exclosured: ExclosuredHook,
};

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: hooks,
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();
window.liveSocket = liveSocket;
