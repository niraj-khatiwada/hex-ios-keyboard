import * as Hex from "@kitlangton/hex"
import { Bonjour } from "bonjour-service"
import { randomBytes, randomUUID } from "node:crypto"
import { appendFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { homedir, hostname, networkInterfaces } from "node:os"
import { join } from "node:path"
import QRCode from "qrcode"

const APP_NAME = "hex-ios-keyboard"
const PORT = Number(process.env.PORT ?? 8787)
const HEX_BIN = process.env.HEX_BIN ?? "/Applications/Hex.app/Contents/MacOS/hex"
const LANGUAGE = process.env.HEX_LANGUAGE ?? "en"
const MAX_BYTES = 32 * 1024 * 1024

const DATA_DIR = join(homedir(), ".config", APP_NAME)
const AUDIO_DIR = join(DATA_DIR, "audio")
const HISTORY_FILE = join(DATA_DIR, "history.jsonl")
mkdirSync(AUDIO_DIR, { recursive: true })

// Shared secret so other devices on the Wi-Fi can't use the Mac's transcriber.
function loadToken(): string {
  if (process.env.HEX_KEYBOARD_TOKEN) return process.env.HEX_KEYBOARD_TOKEN
  const file = join(DATA_DIR, "token")
  const legacy = join(homedir(), ".config", "voice-keyboard", "token")
  for (const path of [file, legacy]) {
    if (existsSync(path)) {
      const token = readFileSync(path, "utf8").trim()
      writeFileSync(file, token + "\n", { mode: 0o600 })
      return token
    }
  }
  const token = randomBytes(4).toString("hex")
  writeFileSync(file, token + "\n", { mode: 0o600 })
  return token
}
const TOKEN = loadToken()

// MARK: Model choice

const SETTINGS_FILE = join(DATA_DIR, "settings.json")
const DEFAULT_MODEL: Hex.ModelId = "parakeet_unified_en"

function loadSettings(): { model?: Hex.ModelId } {
  try {
    return JSON.parse(readFileSync(SETTINGS_FILE, "utf8"))
  } catch {
    return {}
  }
}

// HEX_MODEL wins when set; otherwise the model picked on the dashboard; otherwise Parakeet.
let activeModel: Hex.ModelId = (process.env.HEX_MODEL as Hex.ModelId) ?? loadSettings().model ?? DEFAULT_MODEL

function saveModel(model: Hex.ModelId) {
  writeFileSync(SETTINGS_FILE, JSON.stringify({ ...loadSettings(), model }, null, 2) + "\n")
}

// MARK: Status shown on the dashboard

type HexState =
  | { state: "starting" }
  | { state: "downloading"; percent: number }
  | { state: "loading" }
  | { state: "ready"; pid: number }
  | { state: "error"; message: string }

let hexState: HexState = { state: "starting" }
let phone: { lastSeen: number; ip: string } | undefined
// When the phone last opened its live connection; the dashboard's Reconnect popup watches this.
let phoneConnectedAt = 0

// Live connections from the iPhone app. Status is pushed the moment it changes, and a closed
// socket tells the phone the server is gone right away.
type Socket = import("bun").ServerWebSocket<{ ip: string }>
const sockets = new Set<Socket>()

// Friendly names ("Parakeet Unified English"), filled in whenever the model list is read.
const modelNames = new Map<string, string>()

function statusMessage() {
  return JSON.stringify({
    type: "status",
    model: activeModel,
    modelName: modelNames.get(activeModel) ?? activeModel,
    hex: hexState.state,
    ready: hexState.state === "ready",
  })
}

function setHexState(next: HexState) {
  hexState = next
  const message = statusMessage()
  for (const ws of sockets) ws.send(message)
}

// MARK: Hex host

// One Hex helper process for the server's lifetime. It can list, download and load models, so
// switching models doesn't need a new process; the loaded model stays warm between clips.
let host: Hex.HexHost | undefined
let hostStarting: Promise<Hex.HexHost> | undefined
let preparedModel: Hex.ModelId | undefined

function getHost(): Promise<Hex.HexHost> {
  if (host) return Promise.resolve(host)
  hostStarting ??= Hex.create({ command: [HEX_BIN, "service", "--embedded"] })
    .then((h) => {
      host = h
      return h
    })
    .finally(() => {
      hostStarting = undefined
    })
  return hostStarting
}

async function resetHost() {
  const h = host
  host = undefined
  preparedModel = undefined
  await h?.close().catch(() => {})
}

// The native service rejects concurrent requests, so model loads and clips run one at a time.
let queue: Promise<unknown> = Promise.resolve()
function enqueue<T>(job: () => Promise<T>): Promise<T> {
  const run = queue.then(job, job)
  queue = run.catch(() => {})
  return run
}

/** Downloads (if needed) and loads `model`, then makes it the one clips use. */
async function prepareModel(model: Hex.ModelId) {
  setHexState({ state: "starting" })
  try {
    const h = await getHost()
    setHexState({ state: "loading" })
    await h.client.models.prepare(model, {
      language: LANGUAGE,
      // Only installed models get here, so Hex's brief "downloading" check is just loading.
      onProgress: () => setHexState({ state: "loading" }),
    })
    preparedModel = model
    if (!modelNames.has(model)) await installedModels().catch(() => {})
    setHexState({ state: "ready", pid: h.pid })
    console.log(`[hex] ready: model=${model} pid=${h.pid}`)
  } catch (err) {
    setHexState({ state: "error", message: String((err as Error)?.message ?? err) })
    throw err
  }
}

function switchModel(model: Hex.ModelId) {
  activeModel = model
  saveModel(model)
  return enqueue(() => prepareModel(model))
}

async function transcribe(wav: Uint8Array) {
  return enqueue(async () => {
    if (preparedModel !== activeModel) await prepareModel(activeModel)
    const h = await getHost()
    try {
      return await h.client.transcribe({ audio: { data: wav, contentType: "audio/wav" }, model: activeModel, language: LANGUAGE })
    } catch (err) {
      // A dead helper won't recover; start a fresh one. An ordinary request error leaves it be.
      const alive = await h.client.health().then(() => true, () => false)
      if (!alive) {
        await resetHost()
        enqueue(() => prepareModel(activeModel)).catch(() => {})
      }
      throw err
    }
  })
}

/** Models already installed through the Hex app. We never download from here. */
async function installedModels() {
  type CliModel = { id: string; name: string; languages: string[]; installed: boolean }
  let catalog: CliModel[]
  // The Hex CLI knows every model the app can install. The SDK's own list() rejects catalog
  // entries newer than its release, so it's only the fallback.
  const cli = Bun.spawnSync([HEX_BIN, "model", "list", "--json"])
  try {
    catalog = JSON.parse(cli.stdout.toString()).models
  } catch {
    const h = await getHost()
    catalog = (await h.client.models.list({ language: LANGUAGE })).map((m) => ({ ...m, languages: [...m.languages] }))
  }
  const supported = new Set<string>(Hex.MODEL_IDS)
  for (const m of catalog) modelNames.set(m.id, m.name)
  return catalog
    .filter((m) => m.installed)
    .map((m) => ({
      id: m.id as Hex.ModelId,
      name: m.name,
      languages: m.languages,
      // Installed in Hex, but too new for this SDK version to load.
      supported: supported.has(m.id),
      active: m.id === activeModel,
    }))
}

// MARK: History

interface HistoryEntry {
  id: string
  at: number
  text: string
  audioMs: number
  processingMs: number
  bytes: number
  error?: string
}

function readHistory(): HistoryEntry[] {
  if (!existsSync(HISTORY_FILE)) return []
  return readFileSync(HISTORY_FILE, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as HistoryEntry)
    .reverse()
}

function addHistory(entry: HistoryEntry, wav: Uint8Array) {
  writeFileSync(join(AUDIO_DIR, `${entry.id}.wav`), wav)
  appendFileSync(HISTORY_FILE, JSON.stringify(entry) + "\n")
  // Push it to the phone's history screen right away.
  const message = JSON.stringify({ type: "history", entry: phoneHistoryItem(entry) })
  for (const ws of sockets) ws.send(message)
}

// What the phone sees: text and time only, never audio.
function phoneHistoryItem(entry: HistoryEntry) {
  return { id: entry.id, at: entry.at, text: entry.text, error: entry.error ?? null }
}

function clearHistory() {
  rmSync(HISTORY_FILE, { force: true })
  rmSync(AUDIO_DIR, { recursive: true, force: true })
  mkdirSync(AUDIO_DIR, { recursive: true })
}

// MARK: Addresses and pairing

// Wi-Fi (en0) first: that's the address the iPhone can reach.
const ips = Object.entries(networkInterfaces())
  .sort(([a], [b]) => (a === "en0" ? -1 : b === "en0" ? 1 : 0))
  .flatMap(([, addrs]) => addrs ?? [])
  .filter((i) => i.family === "IPv4" && !i.internal)
  .map((i) => i.address)

const serverURL = `http://${ips[0] ?? "localhost"}:${PORT}`
const pairURL = `voicekb://pair?url=${encodeURIComponent(serverURL)}&token=${encodeURIComponent(TOKEN)}`
const qrSvg = await QRCode.toString(pairURL, { type: "svg", margin: 1 })

// MARK: HTTP

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  })
}

const LOOPBACK = new Set(["127.0.0.1", "::1", "::ffff:127.0.0.1"])
const dashboardFile = Bun.file(join(import.meta.dir, "dashboard.html"))

const server = Bun.serve<{ ip: string }>({
  port: PORT,
  hostname: "0.0.0.0",
  maxRequestBodySize: MAX_BYTES,
  async fetch(req, server) {
    const url = new URL(req.url)
    const ip = server.requestIP(req)?.address ?? ""
    const authed = req.headers.get("authorization") === `Bearer ${TOKEN}`

    // MARK: Phone API
    // Live status for the iPhone app. The pairing code comes as ?token= because iOS's
    // WebSocket API can't set headers on the upgrade request reliably.
    if (url.pathname === "/ws") {
      if (url.searchParams.get("token") !== TOKEN) return json({ error: "unauthorized" }, 401)
      if (server.upgrade(req, { data: { ip } })) return undefined
      return json({ error: "expected a WebSocket upgrade" }, 400)
    }

    // Text-only history for the phone's History screen.
    if (url.pathname === "/history" && req.method === "GET") {
      if (!authed) return json({ error: "unauthorized" }, 401)
      const limit = Math.min(Number(url.searchParams.get("limit") ?? 500), 2000)
      return json(readHistory().slice(0, limit).map(phoneHistoryItem))
    }

    if (url.pathname === "/health") {
      if (authed) phone = { lastSeen: Date.now(), ip }
      return json({ ok: true, authed, model: activeModel, modelName: modelNames.get(activeModel) ?? activeModel, ready: hexState.state === "ready" })
    }

    if (url.pathname === "/transcribe" && req.method === "POST") {
      if (!authed) return json({ error: "unauthorized" }, 401)
      phone = { lastSeen: Date.now(), ip }
      const wav = new Uint8Array(await req.arrayBuffer())
      if (wav.byteLength < 44 || new TextDecoder().decode(wav.subarray(0, 4)) !== "RIFF") {
        return json({ error: "expected a PCM WAV body" }, 400)
      }
      const id = randomUUID()
      const started = performance.now()
      try {
        const result = await transcribe(wav)
        const processingMs = Math.round(performance.now() - started)
        const text = result.transcript.trim()
        addHistory({ id, at: Date.now(), text, audioMs: result.durationMs, processingMs, bytes: wav.byteLength }, wav)
        console.log(`[transcribe] audio=${result.durationMs}ms took=${processingMs}ms → ${JSON.stringify(text)}`)
        return json({ text, durationMs: result.durationMs, processingMs })
      } catch (err) {
        const message = String((err as Error)?.message ?? err)
        const audioMs = Math.round(((wav.byteLength - 44) / 32000) * 1000)
        addHistory({ id, at: Date.now(), text: "", audioMs, processingMs: Math.round(performance.now() - started), bytes: wav.byteLength, error: message }, wav)
        console.error("[transcribe] failed:", err)
        return json({ error: message }, 500)
      }
    }

    // MARK: Dashboard (this Mac only — it shows the pairing code and your history)
    const local = LOOPBACK.has(ip)
    if (url.pathname === "/" || url.pathname.startsWith("/api/")) {
      if (!local) return json({ error: "open the dashboard on the Mac" }, 403)
    }

    if (url.pathname === "/") {
      return new Response(dashboardFile, { headers: { "content-type": "text/html; charset=utf-8" } })
    }

    if (url.pathname === "/api/status") {
      return json({
        appName: APP_NAME,
        serverURL,
        token: TOKEN,
        qrSvg,
        model: activeModel,
        hex: hexState,
        phone,
        phoneLive: sockets.size > 0,
        phoneConnectedAt,
        historyCount: readHistory().length,
      })
    }

    if (url.pathname === "/api/models" && req.method === "GET") {
      try {
        return json(await installedModels())
      } catch (err) {
        return json({ error: String((err as Error)?.message ?? err) }, 500)
      }
    }

    if (url.pathname === "/api/model" && req.method === "POST") {
      const { id } = (await req.json().catch(() => ({}))) as { id?: string }
      const models = await installedModels().catch(() => [])
      const model = models.find((m) => m.id === id)
      if (!model) return json({ error: "That model isn't installed. Install it from the Hex app first." }, 400)
      if (!model.supported) return json({ error: `${model.name} is too new for this version of the Hex SDK. Update @kitlangton/hex to use it.` }, 400)
      if (model.id !== activeModel || hexState.state === "error") {
        console.log(`[hex] switching to ${model.id}`)
        switchModel(model.id).catch((err) => console.error("[hex] switch failed:", err))
      }
      return json({ ok: true, model: model.id })
    }

    if (url.pathname === "/api/history" && req.method === "GET") {
      return json(readHistory())
    }

    if (url.pathname === "/api/history" && req.method === "DELETE") {
      clearHistory()
      return json({ ok: true })
    }

    // Show a clip (or the whole history folder) in Finder.
    if (url.pathname === "/api/reveal" && req.method === "POST") {
      const id = url.searchParams.get("id")
      const target = id && /^[0-9a-f-]{36}$/.test(id) ? join(AUDIO_DIR, `${id}.wav`) : DATA_DIR
      if (!existsSync(target)) return json({ error: "not found" }, 404)
      Bun.spawn(target === DATA_DIR ? ["open", target] : ["open", "-R", target])
      return json({ ok: true })
    }

    const audio = url.pathname.match(/^\/api\/audio\/([0-9a-f-]{36})$/)
    if (audio) {
      const file = Bun.file(join(AUDIO_DIR, `${audio[1]}.wav`))
      return (await file.exists()) ? new Response(file, { headers: { "content-type": "audio/wav" } }) : json({ error: "not found" }, 404)
    }

    if (url.pathname === "/icon.png") {
      return new Response(Bun.file(join(import.meta.dir, "../ios/VoiceKeyboard/Assets.xcassets/AppIcon.appiconset/AppIcon.png")))
    }

    // Older builds linked here.
    if (url.pathname === "/pair") return Response.redirect("/", 302)

    return json({ error: "not found" }, 404)
  },
  websocket: {
    open(ws) {
      sockets.add(ws)
      phone = { lastSeen: Date.now(), ip: ws.data.ip }
      phoneConnectedAt = Date.now()
      ws.send(statusMessage())
      console.log(`[phone] connected from ${ws.data.ip.replace("::ffff:", "")}`)
    },
    message(ws, message) {
      phone = { lastSeen: Date.now(), ip: ws.data.ip }
      if (message === "ping") ws.send("pong")
    },
    close(ws) {
      sockets.delete(ws)
      phone = { lastSeen: Date.now(), ip: ws.data.ip }
      console.log("[phone] disconnected")
    },
    // iOS pings every few seconds; drop connections that go quiet (phone left the Wi-Fi).
    idleTimeout: 30,
  },
})

const bonjour = new Bonjour()
bonjour.publish({ name: `${APP_NAME} on ${hostname().replace(/\.local$/, "")}`, type: "voicekb", port: PORT, txt: { v: "1" } })

const dashboardURL = `http://localhost:${server.port}`
console.log(`\n${APP_NAME} server running at ${serverURL}`)
console.log(`Dashboard (setup, status, history): ${dashboardURL}\n`)
if (!process.env.NO_OPEN) Bun.spawn(["open", dashboardURL])

// Load the model up front so the first dictation is fast.
enqueue(() => prepareModel(activeModel)).catch((err) => console.error("[hex] failed to start:", err))

async function shutdown() {
  // Close phone connections first so the app shows "server stopped" immediately.
  server.stop(true)
  bonjour.unpublishAll(() => bonjour.destroy())
  await resetHost()
  process.exit(0)
}
process.on("SIGINT", shutdown)
process.on("SIGTERM", shutdown)
