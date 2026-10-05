# VoiceMac

A native macOS menu-bar voice assistant that starts executing your command
**before you finish the sentence**.

```
"Open Chrome and search for the best Bengali restaurants in Kolkata."
 └──────────┬──────────┘ └──────────────────┬───────────────────────┘
      Chrome launches here        search runs when the query stops growing
```

Swift 6 / SwiftUI / AppKit. No Electron, no backend, no database, no accounts.
Everything runs locally except the speech, decision, and text APIs.

---

## Quick start

```bash
./build.sh              # builds and ad-hoc signs build/VoiceMac.app
open build/VoiceMac.app
```

On first launch it will ask for Microphone access and open Settings. Paste your
**Sarvam API key** (required) and optionally your **Jev API key**, then press
**⌘⇧Space** and speak.

To verify the core logic without a microphone or network:

```bash
swift build && .build/debug/VoiceMac --self-test
```

That replays scripted partial transcripts through the real transcript manager,
router, and dependency graph, and asserts — among other things — that `openApp`
fires from a partial while `searchWeb` does not. 47 checks, all passing.

---

## What the APIs actually support

Three findings shaped the architecture. Each was verified against the live APIs,
not assumed from documentation.

### 1. Groq cannot do this job; Sarvam can

Groq exposes only a batch endpoint, `POST /openai/v1/audio/transcriptions`.
There is no WebSocket and therefore **no interim transcripts** — the whole
mid-sentence premise is impossible on it without faking streaming by
re-uploading a growing audio window every few hundred milliseconds (slow,
and billed at a 10-second minimum per request).

Sarvam has a real streaming socket, confirmed by handshake:

```
wss://api.sarvam.ai/speech-to-text-realtime/ws   ->  HANDSHAKE OK
```

It emits `transcript.partial` / `transcript.final` plus `vad.speech_start` /
`vad.speech_end`, which is exactly what this design needs. It is also strong on
Indian languages and place names, which suits the example commands.

Config used: `model=saaras:v3-realtime`, `stream_type=fast`,
`encoding=linear16`, `sample_rate=16000`, `endpointing=vad`.

### 2. Jev returns types, never strings

Jev is a System One model: you send state plus typed questions and get back
`choice` / `noul` / `score` answers with calibrated confidence. It has no string
generation at all. So Jev **cannot** produce `"best bengali restaurants in
kolkata"`.

That splits the intelligence layer cleanly in two:

| | Does | Question types |
|---|---|---|
| **Jev** (`api.typesafe.ai/v1/systemone`) | picks *which* action, judges risk, decides if more speech is needed | `choice`, `noul`, `noul`, `score` |
| **Sarvam chat** (`api.sarvam.ai/v1/chat/completions`, `sarvam-30b`) | fills in string parameters for the action Jev already chose | — |

The extractor is whitelisted per action type: for `searchWeb` it may only return
a `query` key, and any other key it emits is discarded. It never selects the
action.

### 3. A bad key does not fail the handshake

The socket opens successfully with an invalid key, then sends:

```json
{"event":"error","code":"invalid_subscription_key","is_fatal":true,"status_code":401,...}
```

This is handled explicitly: the fatal error is surfaced to the user, and the
socket close that follows it is *not* reported as a second "could not connect"
error on top — which would have masked the real cause.

---

## How mid-sentence execution works

Partial transcripts get revised constantly:

```
"open"  ->  "open chrome"  ->  "open chrome and"  ->  "open chrome and search for openai"
```

Acting on raw partials would launch the wrong app the moment STT hears
`"open chrom"`. Two independent guards in `TranscriptManager` decide what is
safe to act on:

1. **Agreement** — a word must appear identically in the last N partials
   (default 2, configurable).
2. **Trailing-word exclusion** — the final word of the newest partial is never
   considered stable. It is the word most likely to still be growing.

Everything before that point is the **stable prefix**, and only the stable
prefix can trigger anything. In the overlay the stable prefix is drawn solid and
the unstable tail dimmed, so you can see exactly what has been committed.

Then `LocalCommandRouter` re-parses the stable prefix on every update. It is a
pure function — no network, no model — so running it dozens of times per
sentence costs nothing. `"open chrome"` never reaches Jev.

### Clause segmentation

Commands are split at command verbs, not at `"and"`. Splitting on `"and"` would
break `"search for restaurants and cafes in kolkata"`. Splitting at every verb
would break `"search for how to open a jar file"` — it would launch an app
called "a jar file".

The rule: inside a free-text object (a query, a message body) a later verb only
starts a new clause if a connector precedes it. Both cases above are covered by
tests.

---

## Safety

Risk is a property of the action *type*, and the type sets a floor that no model
can lower. `ActionRequest.init` takes `max(provided, type.defaultRisk)`, so a
provider claiming `sendMessage` is safe still gets `destructive`.

| Risk | Examples | When it runs |
|---|---|---|
| `safe` | open/focus app, open URL, search, scroll, screenshot, volume | immediately, mid-sentence |
| `caution` | quit app, click, type, focus, menu command, clear field, press key, copy/paste | only once you stop speaking |
| `destructive` | send message, and any command whose text reads as destructive | **never** without explicit confirmation |

Risk also depends on *parameters*, not only type. `menuCommand("New Tab")` and
`menuCommand("Move to Trash")` are the same action type, so `RiskPolicy`
escalates the second to `destructive`. Matching is on whole words and phrases,
so "Clear Formatting" is not mistaken for a destructive clear.

Actions carrying free text wait until their text stops growing, so a truncated
query is never searched and a half-finished message is never sent.

Jev proposes typed actions only. It cannot run a shell command, cannot emit
code, and cannot introduce a capability outside the `ActionType` enum. Every
case in that enum maps to hand-written Swift.

`Esc` cancels instantly: it stops the stream, drops queued actions, and clears
the transcript. Already-completed actions are left alone — nothing is ever
auto-rolled-back. `Esc` is only captured globally while a session is live.

---

## Architecture

```
Microphone ─ AVAudioEngine ─ 16 kHz mono int16 ─┐
                                                │  (realtime tap, ~40 ms chunks)
                        Sarvam WebSocket ◄──────┘
                                │
                   transcript.partial / .final
                                │
                        TranscriptManager  ── stable prefix
                                │
                        LocalCommandRouter  ── deterministic, no network
                                │
                   ┌────────────┴────────────┐
             matched                     unmatched
                   │                          │
                   │                     Jev (typed decision)
                   │                          │
                   │                     Sarvam LLM (parameters only)
                   └────────────┬────────────┘
                                │
                         ActionScheduler  ── dependency graph + risk gate
                                │
                       MacOSActionExecutor
                                │
      NSWorkspace ▸ Accessibility ▸ Apple Events ▸ synthetic input
```

These run as independent concurrent tasks, not a sequential pipeline. Audio
forwarding, transcript handling, and action execution all proceed at once —
which is the only way an action can run while you are still speaking.
**Executing never stops the microphone.**

```
Sources/VoiceMac/
├── App/          main, AppDelegate, AppState, SessionManager, SelfTest
├── Audio/        AudioCapture, VoiceActivityDetector
├── STT/          StreamingSTT (protocol), SarvamStreamingSTT, TranscriptManager
├── Intelligence/ LocalCommandRouter, Decision, JevDecisionProvider,
│                 SarvamParameterExtractor, ActionPlanner
├── Automation/   Action, ActionScheduler, MacOSActionExecutor,
│                 AccessibilityManager, ApplicationRegistry, AppleEvents
├── Security/     KeychainManager, Settings
├── UI/           ListeningOverlay, SettingsView, DebugView
└── Utilities/    Logger, LatencyTracker, HotKeyManager, Fuzzy
```

Providers sit behind `StreamingSTT`, `DecisionProvider`, `ParameterExtractor`,
and `ActionExecutorProtocol`, so another vendor is a new conforming type rather
than a change to the pipeline.

---

## Latency instrumentation

`LatencyTracker` records `mic_start`, `first_audio_sent`, `stt_connected`,
`first_stt_interim`, `stable_prefix_detected`, `local_intent_detected`,
`jev_request_start`, `jev_response_received`, `action_start`,
`action_completed`, `final_transcript`.

Marks are first-wins, so the second action in a sentence cannot overwrite the
number that matters: **voice start → first useful action**. It is shown live in
the overlay and broken down in the debug panel (⌘D from the menu).

Deliberate latency choices:

- The STT socket opens before the audio engine starts, so the handshake overlaps
  with device setup.
- The app registry is indexed at launch (225 apps in 37 ms on this machine), so
  the first `open <app>` pays no filesystem cost.
- Installed app names are sent as the STT terminology prompt, biasing
  recognition toward real app names.
- Jev is debounced: minimum 250 ms between calls, one in flight, and never
  called twice for the same text.
- An accessibility snapshot is only taken when the command plausibly touches
  the UI, since a large window's AX tree is slow to walk.

---

## Permissions

| Permission | Needed for | Without it |
|---|---|---|
| Microphone | everything | app cannot listen |
| Accessibility | click, type, scroll, searching inside an app | open/focus/URL/search still work |
| Screen Recording | screenshots | prompted on first screenshot |

**Rebuilds reset permissions.** macOS ties a grant to the code signature, and
ad-hoc signing produces a new one each build. To keep grants across rebuilds,
make a self-signed code-signing certificate in Keychain Access and build with
`SIGN_ID="Your Cert Name" ./build.sh`.

---

## Secrets

Keys live in the macOS Keychain (`ai.macsurfer.voicemac`). `KeychainManager` has
no logging path of any kind, so there is no code route that can put a key into
the log buffer. Settings only ever shows a masked preview.

For development, `SARVAM_API_KEY` and `JEV_API_KEY` are read from the
environment as a fallback. `.env` and `config.json` are gitignored.

Spoken content is logged only when **Debug Mode** is on, and redacted otherwise.

---

## Status against the original scope

Working and verified:

- Menu-bar app, global hotkey (⌘⇧Space), Esc cancel, overlay, settings, debug panel
- Continuous streaming capture — no record-then-upload anywhere
- Sarvam streaming STT with interim transcripts, endpoint verified live
- Transcript stability detection with agreement + trailing-word guards
- Deterministic local router for open/close/focus/URL/search/screenshot/volume/scroll/copy/paste
- Mid-sentence execution: `openApp` fires from a partial, `searchWeb` waits
- Action dependency graph with per-action risk gating and confirmation
- Jev typed decisions + Sarvam parameter extraction, both behind protocols
- Accessibility inspection with relevance filtering (never the whole tree)
- Keychain storage, structured redacting logs, latency instrumentation

Honest gaps:

- **`sendMessage` has no executor.** It is parsed, classified `destructive`, and
  gated behind confirmation, but there is no generic "send" primitive on macOS —
  it needs per-app support (Slack, Messages, Mail). Confirming it currently
  returns "not supported yet" rather than sending anything. This is the safety
  layer demonstrated end to end; the per-app send is not built.
- **Flows 1–3 are verified by replay, not by voice.** The transcript → router →
  graph → executor path is covered by `--self-test` against the real components
  with a recording executor. I cannot speak into your microphone, so the live
  audio leg is untested — run the self-test, then try it for real.
- **Vision fallback is architectural only**, as scoped. Poor-AX apps return a
  clear unsupported error rather than falling back to screenshots.
- Jev's `session_id` is not threaded through, so multi-turn Jev context is unused.

---

## Try these

```
"Open Chrome."                                      local router only, no Jev
"Open Chrome and search for OpenAI."                Chrome launches mid-sentence
"Open Slack and find Rahul."                        AX-driven search in Slack
"Search for how to open a jar file."                one clause — does not launch an app
"Take a screenshot."
"Set volume to 30."
"Send Rahul a message saying I'll call him tomorrow."   confirmation required
```

In-app control (all require Accessibility permission):

```
"Click the Send button."                     role-biased element match
"Click the second tab."                      ordinal match
"Double click the report."
"Right click the file."
"Click at 500 300."                          explicit coordinates
"Click into the message box."                focus without clicking anything else
"Type hello into the message box."           named target field
"Type meet me in the park."                  "in" here is text, not a target
"Clear the field."
"Select all."                                mapped to ⌘A, not a new primitive
"Choose New Window from the File menu."      menu-bar command
"Open Slack and click into the message box and type hello."
```

### Why the menu bar matters

Most of an app's functionality lives in its menus, and menu titles are stable,
localised, and self-describing — far more reliable than hunting for a toolbar
button. `menuCommand` walks the frontmost app's whole menu bar and matches by
name, optionally scoped to one menu. `click` also falls back to the menu bar, so
"click save as" works even when there is no on-screen button for it.

### Two grammar rules that stop verbs being read as nouns

`Send` and `Search` are command verbs *and* two of the most common UI labels, so
"click the Send button" naively split into `click("the")` + `sendMessage("button")`.
Two structural rules in the router prevent it:

1. **A clause needs an object before the next clause can start** — otherwise
   "click Send" splits into an empty click plus a send.
2. **A determiner or preposition before a verb means it is a noun** — "click
   **the** Send button", "click into **the** search field".

Combined with the existing free-text connector rule, all three cases parse
correctly, and each is covered by a test.

### Clicking things that do not implement AXPress

Web content and canvas-drawn interfaces often expose no `AXPress` action. When
it fails, the executor reads the element's frame and synthesises a real mouse
click at its centre — including a preceding mouse-move, because many apps ignore
a click that arrives without one.
