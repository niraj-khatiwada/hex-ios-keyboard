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
const MODEL = (process.env.HEX_MODEL ?? "parakeet_unified_en") as Hex.ModelId
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

// MARK: Status shown on the dashboard

type HexState =
  | { state: "starting" }
  | { state: "downloading"; percent: number }
  | { state: "loading" }
  | { state: "ready"; pid: number }
  | { state: "error"; message: string }

let hexState: HexState = { state: "starting" }
let phone: { lastSeen: number; ip: string } | undefined

// MARK: Hex transcriber

// Keep one transcriber alive so the model stays loaded between clips.
let transcriber: Hex.Transcriber | undefined
let starting: Promise<Hex.Transcriber> | undefined

function getTranscriber(): Promise<Hex.Transcriber> {
  if (transcriber) return Promise.resolve(transcriber)
  hexState = { state: "starting" }
  starting ??= Hex.create({
    command: [HEX_BIN, "service", "--embedded"],
    model: MODEL,
    language: LANGUAGE,
    onProgress: (p) => {
      if (p.type === "downloading") {
        const percent = p.totalBytes ? Math.round((p.downloadedBytes / p.totalBytes) * 100) : 0
        hexState = { state: "downloading", percent }
      } else if (p.type === "loading" || p.type === "verifying") {
        hexState = { state: "loading" }
      }
    },
  })
    .then((t) => {
      transcriber = t
      hexState = { state: "ready", pid: t.pid }
      console.log(`[hex] ready: model=${t.model} pid=${t.pid}`)
      return t
    })
    .catch((err) => {
      hexState = { state: "error", message: String(err?.message ?? err) }
      throw err
    })
    .finally(() => {
      starting = undefined
    })
  return starting
}

async function resetTranscriber() {
  const t = transcriber
  transcriber = undefined
  await t?.close().catch(() => {})
}

// The native service rejects concurrent requests, so run clips one at a time.
let queue: Promise<unknown> = Promise.resolve()
function enqueue<T>(job: () => Promise<T>): Promise<T> {
  const run = queue.then(job, job)
  queue = run.catch(() => {})
  return run
}

async function transcribe(wav: Uint8Array) {
  return enqueue(async () => {
    try {
      return await (await getTranscriber()).transcribe(wav)
    } catch (err) {
      // A dead helper won't recover; start a fresh one next time.
      await resetTranscriber()
      getTranscriber().catch(() => {})
      throw err
    }
  })
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

const server = Bun.serve({
  port: PORT,
  hostname: "0.0.0.0",
  maxRequestBodySize: MAX_BYTES,
  async fetch(req, server) {
    const url = new URL(req.url)
    const ip = server.requestIP(req)?.address ?? ""
    const authed = req.headers.get("authorization") === `Bearer ${TOKEN}`

    // MARK: Phone API
    if (url.pathname === "/health") {
      if (authed) phone = { lastSeen: Date.now(), ip }
      return json({ ok: true, authed, model: MODEL, ready: hexState.state === "ready" })
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
        model: MODEL,
        hex: hexState,
        phone,
        historyCount: readHistory().length,
      })
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
})

const bonjour = new Bonjour()
bonjour.publish({ name: `${APP_NAME} on ${hostname().replace(/\.local$/, "")}`, type: "voicekb", port: PORT, txt: { v: "1" } })

const dashboardURL = `http://localhost:${server.port}`
console.log(`\n${APP_NAME} server running at ${serverURL}`)
console.log(`Dashboard (setup, status, history): ${dashboardURL}\n`)
if (!process.env.NO_OPEN) Bun.spawn(["open", dashboardURL])

// Load the model up front so the first dictation is fast.
getTranscriber().catch((err) => console.error("[hex] failed to start:", err))

async function shutdown() {
  bonjour.unpublishAll(() => bonjour.destroy())
  await resetTranscriber()
  process.exit(0)
}
process.on("SIGINT", shutdown)
process.on("SIGTERM", shutdown)
