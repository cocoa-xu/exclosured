import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { ExclosuredHook } from "../../../../npm/index.mjs";

const FramePulse = {
  mounted() {
    this.frames = 0;
    this.lastSample = performance.now();
    this.fpsLabel = this.el.querySelector("[data-fps]");
    this.dot = this.el.querySelector("[data-dot]");
    this.rafId = requestAnimationFrame((timestamp) => this.tick(timestamp));
  },

  tick(timestamp) {
    this.frames += 1;

    if (timestamp - this.lastSample >= 500) {
      const fps = Math.round((this.frames * 1000) / (timestamp - this.lastSample));
      if (this.fpsLabel) this.fpsLabel.textContent = `${fps} fps`;
      if (this.dot) this.dot.style.transform = `translateX(${Math.min(fps, 60)}px)`;
      this.frames = 0;
      this.lastSample = timestamp;
    }

    this.rafId = requestAnimationFrame((nextTimestamp) => this.tick(nextTimestamp));
  },

  destroyed() {
    cancelAnimationFrame(this.rafId);
  },
};

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { Exclosured: ExclosuredHook, FramePulse },
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();
window.liveSocket = liveSocket;
