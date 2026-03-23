import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

const LANE_WIDTH = 80;
const ROAD_LEFT = 60;
const CAR_W = 40;
const CAR_H = 60;
const CANVAS_W = 400;
const CANVAS_H = 700;
const PLAYER_Y = 500; // player car screen position

function laneX(lane) {
  return ROAD_LEFT + lane * LANE_WIDTH + LANE_WIDTH / 2;
}

function simpleHash(str) {
  let h = 0;
  for (let i = 0; i < str.length; i++) {
    h = (Math.imul(31, h) + str.charCodeAt(i)) | 0;
  }
  return h >>> 0;
}

const RaceGame = {
  async mounted() {
    this.canvas = document.getElementById("game");
    this.ctx = this.canvas.getContext("2d");
    this.wasm = null;
    this.role = "player";
    this.playerId = "";
    this.lastFrame = 0;
    this.roadOffset = 0;
    this.nearestGap = null; // distance to nearest opponent (+ ahead, - behind)

    // Register events BEFORE async WASM load
    this.handleEvent("game:init", (d) => this._onInit(d));
    this.handleEvent("game:countdown", (d) => {
      if (this.wasm) this.wasm.set_countdown(d.remaining);
    });
    this.handleEvent("game:start", () => {
      if (this.wasm) this.wasm.set_phase(2);
    });
    this.handleEvent("game:tick", (d) => this._onTick(d));
    this.handleEvent("game:npc_spawn", (d) => {
      if (this.wasm) this.wasm.spawn_npc(d.id, d.lane, d.y_offset, d.speed);
    });
    this.handleEvent("game:collision_ack", (d) => {
      if (this.wasm) this.wasm.collision_ack(d.penalty_ms);
    });
    this.handleEvent("game:collision_reject", () => {
      if (this.wasm) this.wasm.collision_reject();
    });
    this.handleEvent("game:results", () => {
      if (this.wasm) this.wasm.set_phase(3);
    });
    this.handleEvent("game:phase", (d) => {
      const p = { lobby: 0, countdown: 1, racing: 2, results: 3 }[d.phase] ?? 0;
      if (this.wasm) this.wasm.set_phase(p);
    });
    this.handleEvent("game:player_joined", () => {});
    this.handleEvent("game:player_left", (d) => {
      if (this.wasm) this.wasm.remove_ghost(simpleHash(d.id));
    });
    this.handleEvent("game:spectate_target", (d) => {
      if (this.wasm) this.wasm.set_spectate_target(d.lane, d.distance);
    });

    // Keyboard
    this._onKeyDown = (e) => {
      if (!this.wasm) return;
      if (e.key === "ArrowLeft") {
        e.preventDefault();
        this.wasm.switch_lane(-1);
      } else if (e.key === "ArrowRight") {
        e.preventDefault();
        this.wasm.switch_lane(1);
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        this.pushEvent("spectator:cycle", { direction: "prev" });
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        this.pushEvent("spectator:cycle", { direction: "next" });
      }
    };
    document.addEventListener("keydown", this._onKeyDown);

    // Load WASM
    try {
      const name = "race_client";
      const mod = await import(`/wasm/${name}/${name}.js`);
      const wasm = await mod.default(`/wasm/${name}/${name}_bg.wasm`);
      window.__exclosured_wasm = wasm;
      window.__exclosured_memory = wasm.memory;
      this.wasm = wasm;
      this.memory = wasm.memory;
      this.pushEvent("wasm:ready", { module: "race_client" });
    } catch (e) {
      console.error("WASM load failed:", e);
      return;
    }

    // Throttled player state upload (20Hz)
    this._stateInterval = setInterval(() => {
      if (!this.wasm || this.role === "spectator") return;
      const phase = this.wasm.get_phase();
      if (phase !== 2) return;
      const ptr = this.wasm.get_player_state();
      const buf = new Float32Array(this.memory.buffer, ptr, 6);
      this.pushEvent("player:input", {
        lane: Math.round(buf[1]), // target lane
        distance: buf[3],
        speed: buf[4],
      });
    }, 50);

    // Start render loop
    this.lastFrame = performance.now();
    this._raf = requestAnimationFrame((t) => this._loop(t));
  },

  _readStr(ptr, len) {
    return new TextDecoder().decode(new Uint8Array(this.memory.buffer, ptr, len));
  },

  _onInit(data) {
    this.playerId = data.player_id;
    this.role = data.role;
    if (this.wasm) {
      const p = { lobby: 0, countdown: 1, racing: 2, results: 3 }[data.phase] ?? 0;
      this.wasm.set_phase(p);
      this.wasm.set_spectator(data.role === "spectator" ? 1 : 0);
      for (const npc of data.npcs || []) {
        this.wasm.spawn_npc(npc.id, npc.lane, npc.y_offset, npc.speed);
      }
    }
  },

  _onTick(data) {
    if (!this.wasm) return;
    if (data.remaining !== undefined) {
      this.wasm.set_remaining(data.remaining);
    }

    // Find my distance from the server data
    let myDist = 0;
    const me = (data.players || []).find((p) => p.id === this.playerId);
    if (me) myDist = me.distance;

    // Update ghosts and compute nearest opponent gap
    let nearestGap = null;
    for (const p of data.players || []) {
      if (p.id === this.playerId) continue;
      this.wasm.update_ghost(simpleHash(p.id), p.lane, p.distance, p.speed);
      const gap = p.distance - myDist;
      if (nearestGap === null || Math.abs(gap) < Math.abs(nearestGap)) {
        nearestGap = gap;
      }
    }
    this.nearestGap = nearestGap;
  },

  _loop(now) {
    const dt = Math.min((now - this.lastFrame) / 1000, 0.1);
    this.lastFrame = now;

    if (this.wasm) {
      this.wasm.tick(dt);
    }

    this._draw(dt);
    this._raf = requestAnimationFrame((t) => this._loop(t));
  },

  _draw(dt) {
    const ctx = this.ctx;
    const W = CANVAS_W;
    const H = CANVAS_H;
    const phase = this.wasm ? this.wasm.get_phase() : 0;

    // Background
    ctx.fillStyle = "#1a1a2e";
    ctx.fillRect(0, 0, W, H);

    // Road
    const roadW = LANE_WIDTH * 3;
    ctx.fillStyle = "#2a2a3e";
    ctx.fillRect(ROAD_LEFT, 0, roadW, H);

    // Lane dividers (scrolling)
    this.roadOffset = (this.roadOffset + dt * 300) % 40;
    ctx.strokeStyle = "#444";
    ctx.lineWidth = 2;
    ctx.setLineDash([15, 25]);
    for (let i = 1; i < 3; i++) {
      const x = ROAD_LEFT + i * LANE_WIDTH;
      ctx.beginPath();
      ctx.lineDashOffset = -this.roadOffset;
      ctx.moveTo(x, 0);
      ctx.lineTo(x, H);
      ctx.stroke();
    }
    ctx.setLineDash([]);

    // Road edges
    ctx.strokeStyle = "#feca57";
    ctx.lineWidth = 3;
    ctx.beginPath();
    ctx.moveTo(ROAD_LEFT, 0);
    ctx.lineTo(ROAD_LEFT, H);
    ctx.moveTo(ROAD_LEFT + roadW, 0);
    ctx.lineTo(ROAD_LEFT + roadW, H);
    ctx.stroke();

    if (phase === 0) {
      // Lobby
      ctx.fillStyle = "#feca57";
      ctx.font = "bold 28px 'Courier New', monospace";
      ctx.textAlign = "center";
      ctx.fillText("WAITING", W / 2, H / 2 - 20);
      ctx.fillStyle = "#888";
      ctx.font = "16px 'Courier New', monospace";
      ctx.fillText("for players...", W / 2, H / 2 + 10);
      return;
    }

    if (phase === 1) {
      // Countdown
      const cd = this.wasm ? this.wasm.get_countdown() : 0;
      ctx.fillStyle = "#feca57";
      ctx.font = "bold 72px 'Courier New', monospace";
      ctx.textAlign = "center";
      ctx.fillText(String(cd), W / 2, H / 2);
      ctx.fillStyle = "#888";
      ctx.font = "16px 'Courier New', monospace";
      ctx.fillText("GET READY", W / 2, H / 2 + 40);
      return;
    }

    if (phase === 3) {
      // Results
      ctx.fillStyle = "#feca57";
      ctx.font = "bold 28px 'Courier New', monospace";
      ctx.textAlign = "center";
      ctx.fillText("FINISH!", W / 2, H / 2 - 20);
      ctx.fillStyle = "#888";
      ctx.font = "14px 'Courier New', monospace";
      ctx.fillText("See results above", W / 2, H / 2 + 15);
      return;
    }

    // --- Racing phase ---

    // Get player state
    const pPtr = this.role === "spectator"
      ? this.wasm.get_spectate_state()
      : this.wasm.get_player_state();
    const pBuf = new Float32Array(this.memory.buffer, pPtr, 6);
    const myLane = pBuf[0];
    const targetLane = pBuf[1];
    const laneLerp = pBuf[2];
    const myDist = pBuf[3];
    const mySpeed = pBuf[4];
    const stunned = pBuf[5] > 0;

    // Player car position (interpolated between lanes)
    const carX = laneX(myLane) + (laneX(targetLane) - laneX(myLane)) * laneLerp;

    // Draw NPCs
    const npcPtr = this.wasm.get_npcs();
    const npcBuf = new Float32Array(this.memory.buffer, npcPtr, 1 + 64 * 3);
    const npcCount = npcBuf[0];
    for (let i = 0; i < npcCount; i++) {
      const off = 1 + i * 3;
      const npcLane = npcBuf[off + 1];
      const npcY = npcBuf[off + 2];
      const npcX = laneX(npcLane);
      // NPC screen Y relative to player scroll
      const screenY = PLAYER_Y - (npcY - 400);
      if (screenY > -CAR_H && screenY < H + CAR_H) {
        ctx.fillStyle = "#e74c3c";
        ctx.fillRect(npcX - CAR_W / 2, screenY - CAR_H / 2, CAR_W, CAR_H);
        ctx.fillStyle = "#c0392b";
        ctx.fillRect(npcX - CAR_W / 2 + 4, screenY - CAR_H / 2 + 4, CAR_W - 8, 12);
        ctx.fillRect(npcX - CAR_W / 2 + 4, screenY + CAR_H / 2 - 16, CAR_W - 8, 12);
      }
    }

    // Draw ghosts
    const gPtr = this.wasm.get_ghosts();
    const gBuf = new Float32Array(this.memory.buffer, gPtr, 1 + 32 * 5);
    const ghostCount = gBuf[0];
    for (let i = 0; i < ghostCount; i++) {
      const off = 1 + i * 5;
      const gLane = gBuf[off];
      const gDist = gBuf[off + 1];
      const gR = gBuf[off + 2];
      const gG = gBuf[off + 3];
      const gB = gBuf[off + 4];
      const gX = laneX(gLane);
      // Ghost screen Y: relative to player's distance
      const screenY = PLAYER_Y - (gDist - myDist) * 0.5;
      if (screenY > -CAR_H && screenY < H + CAR_H) {
        ctx.globalAlpha = 0.4;
        ctx.fillStyle = `rgb(${gR},${gG},${gB})`;
        ctx.fillRect(gX - CAR_W / 2, screenY - CAR_H / 2, CAR_W, CAR_H);
        ctx.globalAlpha = 1.0;
      }
    }

    // Draw player car
    if (stunned) {
      ctx.fillStyle = (Date.now() % 200 < 100) ? "#ff0000" : "#ff6b6b";
    } else {
      ctx.fillStyle = "#54a0ff";
    }
    ctx.fillRect(carX - CAR_W / 2, PLAYER_Y - CAR_H / 2, CAR_W, CAR_H);
    // Windshield
    ctx.fillStyle = "#1a1a2e";
    ctx.fillRect(carX - CAR_W / 2 + 6, PLAYER_Y - CAR_H / 2 + 6, CAR_W - 12, 14);
    // Taillights
    ctx.fillStyle = "#ff6b6b";
    ctx.fillRect(carX - CAR_W / 2 + 2, PLAYER_Y + CAR_H / 2 - 8, 8, 6);
    ctx.fillRect(carX + CAR_W / 2 - 10, PLAYER_Y + CAR_H / 2 - 8, 8, 6);

    // HUD
    const remaining = this.wasm.get_remaining();
    ctx.fillStyle = "#fff";
    ctx.font = "bold 14px 'Courier New', monospace";
    ctx.textAlign = "left";
    ctx.fillText(`${Math.floor(myDist)}m`, 10, 25);
    ctx.fillText(`${Math.floor(mySpeed)} px/s`, 10, 45);
    ctx.textAlign = "right";
    ctx.fillText(`${remaining}s`, W - 10, 25);

    // Nearest opponent gap
    if (this.nearestGap !== null && this.role !== "spectator") {
      const gap = this.nearestGap;
      const absGap = Math.abs(Math.floor(gap));
      const label = gap >= 0 ? `${absGap}m behind` : `${absGap}m ahead`;
      ctx.fillStyle = gap >= 0 ? "#ff6b6b" : "#7bed9f";
      ctx.font = "bold 13px 'Courier New', monospace";
      ctx.textAlign = "right";
      ctx.fillText(label, W - 10, 45);
    }

    if (this.role === "spectator") {
      ctx.fillStyle = "#feca5788";
      ctx.font = "bold 12px 'Courier New', monospace";
      ctx.textAlign = "center";
      ctx.fillText("SPECTATING", W / 2, 20);
    }

    if (stunned) {
      ctx.fillStyle = "#ff000044";
      ctx.fillRect(0, 0, W, H);
      ctx.fillStyle = "#ff6b6b";
      ctx.font = "bold 24px 'Courier New', monospace";
      ctx.textAlign = "center";
      ctx.fillText("CRASH!", W / 2, PLAYER_Y - 60);
    }
  },

  destroyed() {
    if (this._raf) cancelAnimationFrame(this._raf);
    if (this._stateInterval) clearInterval(this._stateInterval);
    document.removeEventListener("keydown", this._onKeyDown);
    this.wasm = null;
  },
};

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { RaceGame },
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();
window.liveSocket = liveSocket;
