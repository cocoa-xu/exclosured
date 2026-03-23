/**
 * OT (Operational Transformation) client engine.
 *
 * Operation format: array of components
 *   - positive int N: retain N characters
 *   - string S: insert S
 *   - negative int N: delete |N| characters
 *
 * Example: [5, "hello", -3, 10]
 */

// -- Codepoint helpers --------------------------------------------------------
// All positions are measured in Unicode codepoints (not UTF-16 code units)
// to match the Elixir server which uses String.codepoints/1.

function cpArray(str) { return Array.from(str); }
function cpLen(str) { return Array.from(str).length; }
function cpSlice(str, start, end) { return Array.from(str).slice(start, end).join(""); }

// -- Apply --------------------------------------------------------------------

export function applyOp(doc, op) {
  const chars = cpArray(doc);
  let pos = 0;
  let result = [];
  for (const comp of op) {
    if (typeof comp === "number" && comp > 0) {
      result.push(chars.slice(pos, pos + comp).join(""));
      pos += comp;
    } else if (typeof comp === "string") {
      result.push(comp);
    } else if (typeof comp === "number" && comp < 0) {
      pos += Math.abs(comp);
    }
  }
  if (pos !== chars.length) {
    throw new Error(`OT apply: pos ${pos} != doc length ${chars.length}`);
  }
  return result.join("");
}

// -- Transform ----------------------------------------------------------------

export function transform(opA, opB, priority = "left") {
  const a = normalize(opA);
  const b = normalize(opB);
  let ia = 0, ib = 0;
  let aPrime = [], bPrime = [];

  // Mutable copies for splitting components
  let aComp = ia < a.length ? a[ia++] : null;
  let bComp = ib < b.length ? b[ib++] : null;

  while (aComp !== null || bComp !== null) {
    // A inserts
    if (typeof aComp === "string") {
      aPrime.push(aComp);
      bPrime.push(cpLen(aComp));
      aComp = ia < a.length ? a[ia++] : null;
      continue;
    }

    // B inserts
    if (typeof bComp === "string") {
      aPrime.push(cpLen(bComp));
      bPrime.push(bComp);
      bComp = ib < b.length ? b[ib++] : null;
      continue;
    }

    if (aComp === null || bComp === null) {
      throw new Error("OT transform: operation length mismatch");
    }

    // Both retain
    if (aComp > 0 && bComp > 0) {
      const min = Math.min(aComp, bComp);
      aPrime.push(min);
      bPrime.push(min);
      aComp = aComp - min || (ia < a.length ? a[ia++] : null);
      bComp = bComp - min || (ib < b.length ? b[ib++] : null);
      if (aComp === 0) aComp = ia < a.length ? a[ia++] : null;
      if (bComp === 0) bComp = ib < b.length ? b[ib++] : null;
    }
    // A deletes, B retains
    else if (aComp < 0 && bComp > 0) {
      const min = Math.min(-aComp, bComp);
      aPrime.push(-min);
      // B skips deleted chars
      aComp = -aComp - min ? -((-aComp) - min) : (ia < a.length ? a[ia++] : null);
      bComp = bComp - min || (ib < b.length ? b[ib++] : null);
      if (aComp === 0) aComp = ia < a.length ? a[ia++] : null;
      if (bComp === 0) bComp = ib < b.length ? b[ib++] : null;
    }
    // A retains, B deletes
    else if (aComp > 0 && bComp < 0) {
      const min = Math.min(aComp, -bComp);
      bPrime.push(-min);
      aComp = aComp - min || (ia < a.length ? a[ia++] : null);
      bComp = -bComp - min ? -((-bComp) - min) : (ib < b.length ? b[ib++] : null);
      if (aComp === 0) aComp = ia < a.length ? a[ia++] : null;
      if (bComp === 0) bComp = ib < b.length ? b[ib++] : null;
    }
    // Both delete
    else if (aComp < 0 && bComp < 0) {
      const min = Math.min(-aComp, -bComp);
      aComp = -aComp - min ? -((-aComp) - min) : (ia < a.length ? a[ia++] : null);
      bComp = -bComp - min ? -((-bComp) - min) : (ib < b.length ? b[ib++] : null);
      if (aComp === 0) aComp = ia < a.length ? a[ia++] : null;
      if (bComp === 0) bComp = ib < b.length ? b[ib++] : null;
    }
  }

  return [compact(aPrime), compact(bPrime)];
}

// -- Compose ------------------------------------------------------------------

export function compose(opA, opB) {
  const a = normalize(opA);
  const b = normalize(opB);
  let ia = 0, ib = 0;
  let result = [];

  let aComp = ia < a.length ? a[ia++] : null;
  let bComp = ib < b.length ? b[ib++] : null;

  while (aComp !== null || bComp !== null) {
    // A deletes — pass through, doesn't consume B
    if (typeof aComp === "number" && aComp < 0) {
      result.push(aComp);
      aComp = ia < a.length ? a[ia++] : null;
      continue;
    }

    // B inserts — pass through, doesn't consume A
    if (typeof bComp === "string") {
      result.push(bComp);
      bComp = ib < b.length ? b[ib++] : null;
      continue;
    }

    if (aComp === null || bComp === null) {
      throw new Error("OT compose: operation length mismatch");
    }

    // A inserts, B retains
    if (typeof aComp === "string" && typeof bComp === "number" && bComp > 0) {
      const aLen = cpLen(aComp);
      const min = Math.min(aLen, bComp);
      result.push(cpSlice(aComp, 0, min));
      aComp = aLen - min > 0 ? cpSlice(aComp, min) : (ia < a.length ? a[ia++] : null);
      bComp = bComp - min || (ib < b.length ? b[ib++] : null);
      if (bComp === 0) bComp = ib < b.length ? b[ib++] : null;
    }
    // A inserts, B deletes — cancel out
    else if (typeof aComp === "string" && typeof bComp === "number" && bComp < 0) {
      const aLen = cpLen(aComp);
      const delLen = -bComp;
      const min = Math.min(aLen, delLen);
      aComp = aLen - min > 0 ? cpSlice(aComp, min) : (ia < a.length ? a[ia++] : null);
      bComp = delLen - min > 0 ? -(delLen - min) : (ib < b.length ? b[ib++] : null);
      if (bComp === 0) bComp = ib < b.length ? b[ib++] : null;
    }
    // Both retain
    else if (aComp > 0 && bComp > 0) {
      const min = Math.min(aComp, bComp);
      result.push(min);
      aComp = aComp - min || (ia < a.length ? a[ia++] : null);
      bComp = bComp - min || (ib < b.length ? b[ib++] : null);
      if (aComp === 0) aComp = ia < a.length ? a[ia++] : null;
      if (bComp === 0) bComp = ib < b.length ? b[ib++] : null;
    }
    // A retains, B deletes
    else if (aComp > 0 && bComp < 0) {
      const min = Math.min(aComp, -bComp);
      result.push(-min);
      aComp = aComp - min || (ia < a.length ? a[ia++] : null);
      bComp = -bComp - min ? -((-bComp) - min) : (ib < b.length ? b[ib++] : null);
      if (aComp === 0) aComp = ia < a.length ? a[ia++] : null;
      if (bComp === 0) bComp = ib < b.length ? b[ib++] : null;
    }
  }

  return compact(result);
}

// -- Diff ---------------------------------------------------------------------

export function fromDiff(oldText, newText) {
  const oldCps = cpArray(oldText);
  const newCps = cpArray(newText);

  let prefixLen = 0;
  while (
    prefixLen < oldCps.length &&
    prefixLen < newCps.length &&
    oldCps[prefixLen] === newCps[prefixLen]
  ) {
    prefixLen++;
  }

  let oldSuffix = 0;
  let newSuffix = 0;
  while (
    oldSuffix < oldCps.length - prefixLen &&
    newSuffix < newCps.length - prefixLen &&
    oldCps[oldCps.length - 1 - oldSuffix] === newCps[newCps.length - 1 - newSuffix]
  ) {
    oldSuffix++;
    newSuffix++;
  }

  const ops = [];
  if (prefixLen > 0) ops.push(prefixLen);

  const delCount = oldCps.length - prefixLen - oldSuffix;
  if (delCount > 0) ops.push(-delCount);

  const insText = newCps.slice(prefixLen, newCps.length - newSuffix).join("");
  if (insText.length > 0) ops.push(insText);

  if (oldSuffix > 0) ops.push(oldSuffix);

  return compact(ops);
}

// -- Cursor transform ---------------------------------------------------------

export function transformCursor(cursor, op) {
  let pos = 0;
  let newCursor = cursor;
  for (const comp of op) {
    if (pos >= cursor) break;
    if (typeof comp === "number" && comp > 0) {
      pos += comp;
    } else if (typeof comp === "string") {
      newCursor += cpLen(comp);
    } else if (typeof comp === "number" && comp < 0) {
      const del = Math.abs(comp);
      if (pos + del <= cursor) {
        newCursor -= del;
      } else {
        newCursor -= cursor - pos;
      }
      pos += del;
    }
  }
  return Math.max(0, newCursor);
}

// -- Helpers ------------------------------------------------------------------

function normalize(op) {
  return op.filter((c) => c !== 0 && c !== "");
}

function compact(op) {
  const result = [];
  for (const comp of op) {
    if (comp === 0 || comp === "") continue;
    const last = result.length > 0 ? result[result.length - 1] : null;
    if (typeof comp === "number" && comp > 0 && typeof last === "number" && last > 0) {
      result[result.length - 1] += comp;
    } else if (typeof comp === "number" && comp < 0 && typeof last === "number" && last < 0) {
      result[result.length - 1] += comp;
    } else if (typeof comp === "string" && typeof last === "string") {
      result[result.length - 1] += comp;
    } else {
      result.push(comp);
    }
  }
  return result;
}


// -- Client state machine ----------------------------------------------------

/**
 * OT Client implementing the standard 3-state protocol:
 *   Synchronized → AwaitingConfirm → AwaitingWithBuffer
 *
 * Usage:
 *   const client = new OTClient(doc, version, sendFn)
 *   client.applyLocal(op)        // user edited
 *   client.applyServer(op)       // received remote op
 *   client.serverAck(version)    // server confirmed our op
 *   client.resync(doc, version)  // full resync from server
 */
export class OTClient {
  constructor(doc, version, sendFn) {
    this.doc = doc;
    this.version = version;
    this.send = sendFn; // (version, op) => void
    this.state = "synchronized"; // | "awaitingConfirm" | "awaitingWithBuffer"
    this.pending = null;  // op sent to server, awaiting ack
    this.buffer = null;   // buffered local op (composed)
    this.onRemoteOp = null; // callback: (op) => void — for updating UI
    this.onResync = null;   // callback: (doc) => void — for full reset
  }

  /** Apply a locally-generated operation */
  applyLocal(op) {
    this.doc = applyOp(this.doc, op);

    switch (this.state) {
      case "synchronized":
        this.send(this.version, op);
        this.pending = op;
        this.state = "awaitingConfirm";
        break;

      case "awaitingConfirm":
        this.buffer = op;
        this.state = "awaitingWithBuffer";
        break;

      case "awaitingWithBuffer":
        this.buffer = compose(this.buffer, op);
        break;
    }
  }

  /** Server acknowledged our pending op */
  serverAck(version) {
    this.version = version;

    switch (this.state) {
      case "awaitingConfirm":
        this.pending = null;
        this.state = "synchronized";
        break;

      case "awaitingWithBuffer":
        this.send(this.version, this.buffer);
        this.pending = this.buffer;
        this.buffer = null;
        this.state = "awaitingConfirm";
        break;

      default:
        console.warn("OTClient: unexpected ack in state", this.state);
    }
  }

  /** Apply a remote operation from another client (already transformed by server) */
  applyServer(serverOp) {
    switch (this.state) {
      case "synchronized":
        this.doc = applyOp(this.doc, serverOp);
        this.version++;
        if (this.onRemoteOp) this.onRemoteOp(serverOp);
        break;

      case "awaitingConfirm": {
        const [pendingPrime, serverPrime] = transform(this.pending, serverOp);
        this.pending = pendingPrime;
        this.doc = applyOp(this.doc, serverPrime);
        this.version++;
        if (this.onRemoteOp) this.onRemoteOp(serverPrime);
        break;
      }

      case "awaitingWithBuffer": {
        const [pendingPrime, serverPrime1] = transform(this.pending, serverOp);
        const [bufferPrime, serverPrime2] = transform(this.buffer, serverPrime1);
        this.pending = pendingPrime;
        this.buffer = bufferPrime;
        this.doc = applyOp(this.doc, serverPrime2);
        this.version++;
        if (this.onRemoteOp) this.onRemoteOp(serverPrime2);
        break;
      }
    }
  }

  /** Full resync — server sent authoritative state */
  resync(doc, version) {
    this.doc = doc;
    this.version = version;
    this.pending = null;
    this.buffer = null;
    this.state = "synchronized";
    if (this.onResync) this.onResync(doc);
  }
}
