# AI Cleanup, Profiles, Dictionary & Style Prompts — Detailed Spec

This document specifies the entire post-ASR text transformation layer. It is deliberately
precise: these behaviors are what make the app feel like Wispr Flow rather than a raw Whisper
wrapper, and they are the most testable part of the system (pure text-in/text-out).

## 0. Pipeline position

```
ASR raw transcript
      │
[1] Deterministic normalizer        (always on, rule-based, <1 ms)
      │
[2] Custom dictionary overrides     (always on, rule-based, <1 ms)
      │
[3] AI cleanup                      (OFF by default; per-profile opt-in; local/remote LLM)
      │
[4] Post-formatter                  (always on; language-aware punctuation/spacing rules)
      │
delivered text  ──▶ inserted into focused app + saved to history
```

Stages 1, 2, 4 are pure Swift functions — deterministic, unit-tested against golden fixtures.
Stage 3 is the only model-dependent stage and the only one allowed to fail; on any failure
(timeout, provider down, malformed output) the pipeline delivers the stage-2 output.

**History stores**: raw ASR text, delivered text, profile used, cleanup on/off, provider+model,
and per-stage timings. The raw transcript is never lost (product principle #2).

## 1. Deterministic normalizer (stage 1)

Language-aware rule pass over the raw transcript:

- Trim leading/trailing whitespace; collapse internal double spaces (EN).
- Strip Whisper artifacts: repeated-token loops, known hallucination strings on silence
  (e.g. subtitle-credit phrases), leading punctuation orphans.
- EN: capitalize first letter if the ASR didn't; ensure terminal punctuation only if the
  utterance is sentence-like (heuristic: ≥3 words).
- ZH: convert stray half-width punctuation to full-width（，。！？；：）when surrounded by Han
  characters; remove spurious spaces between consecutive Han characters (Whisper sometimes
  inserts them).
- Never touches numbers, casing of mid-sentence words, or content tokens.

## 2. Custom dictionary (stage 2) — spec

User-maintained list of overrides applied to **every** transcription, cleanup on or off.

### Data model

```
DictionaryEntry {
  id: UUID
  spoken: String        // what ASR tends to produce, e.g. "cloud code", "joe seph"
  written: String       // what should appear, e.g. "Claude Code", "Joseph"
  matchMode: .word      // .word (default) | .phrase — both case-insensitive
  languages: [Lang]?    // nil = all; else restrict (e.g. a zh-only correction)
  enabled: Bool
  createdAt, lastAppliedAt, applyCount   // usage stats surface "dead" entries in UI
}
```

### Matching semantics

- **Case-insensitive** match on the *spoken* form; replacement uses the *written* form's exact
  casing (per requirement: "Overrides are case-insensitive").
- EN `.word` mode: match on word boundaries (`\b`), so `cat → Katt` never rewrites "category".
  Multi-word spoken forms allowed; internal whitespace matches any single whitespace run.
- ZH: no word boundaries exist; `.phrase` literal substring match on the spoken form. Entries
  containing Han characters default to `.phrase`.
- If the spoken form appears at sentence start in EN and written form is lowercase
  (e.g. "iphone → iPhone" is fine, but "Bob → bob" would break capitalization), apply as-is —
  the user's written form is authoritative. No magic.
- **Longest-match-first**: entries sorted by spoken-form length descending; each character span
  is consumed by at most one entry (no cascading re-replacement, no entry applied to another
  entry's output — prevents rewrite loops).
- Applied to raw ASR output **before** the LLM sees the text, and the active entries are also
  passed to the LLM as "protected terms" (see §3.4) so cleanup can't undo them. After cleanup,
  stage 2 runs **again** (idempotent) to catch LLM re-introductions of the spoken form.

### Future (post-v1) upgrade

ASR-level biasing: WhisperKit prompt-token injection / logit biasing with dictionary terms so
the recognizer itself prefers "Claude" over "cloud". Tracked in roadmap "Later"; the stage-2
text pass remains the correctness backstop.

## 3. AI cleanup (stage 3) — spec

### 3.1 What it does (in priority order)

1. **Self-corrections**: apply spoken repairs and keep only the corrected content.
   - "meet on Friday, sorry, Saturday" → "meet on Saturday"
   - "send it to Alice — no wait, to Bob" → "send it to Bob"
   - "about 30, I mean 40 people" → "about 40 people"
   - ZH equivalents: 「周五，啊不对，周六」→「周六」; 「三十个，我是说四十个」→「四十个」
2. **Filler removal**: um, uh, er, like (discourse-filler sense only), you know, sort of
   (hedge sense), I mean (when not a self-correction marker); ZH: 嗯、呃、那个（filler sense）、
   就是说（filler sense）. Conservative: when unsure whether a token is filler or content,
   keep it.
3. **Punctuation & sentence breaks**: insert/repair terminal punctuation, commas, question
   marks from interrogative form; break run-on speech into sentences; paragraph breaks on long
   topic shifts.
4. **Grammar repair**: fix disfluent repetitions ("I I think"), agreement errors, dropped
   articles — *minimal-edit* repair, not rewriting.
5. **Style shaping**: apply the active profile's prompt (tone, formatting, spelling variant,
   bullets…) — only the delta the profile asks for.

**Hard rules (encoded in every system prompt):** never answer questions in the dictation —
transform it; never add information; never translate between languages unless the profile
explicitly says so; preserve code-switched English words inside Chinese sentences verbatim;
never modify protected terms (§3.4); output ONLY the cleaned text with no preamble, quotes, or
markdown fences.

### 3.2 Provider abstraction

```swift
protocol CleanupProvider {
  var id: ProviderID { get }            // .local, .ollama, .openAICompatible(config)
  func isAvailable() async -> Bool
  func cleanup(_ req: CleanupRequest) async throws -> CleanupResponse
}
```

| Provider | Transport | Notes |
|---|---|---|
| **Local (bundled)** | in-process | macOS: MLX-served small instruct model; iOS: Apple Foundation Models / small MLX model. Exact models per `docs/04` research. Downloadable like ASR models, not baked into the binary. |
| **Ollama** | `http://localhost:11434/api/chat` | Auto-detected; user picks a pulled model; `keep_alive` tuned so cleanup doesn't cold-load per dictation. |
| **OpenAI-compatible** | user URL + key + model | Covers OpenAI, Groq, DeepSeek, LM Studio, llama.cpp server, a remote box. Explicit "this leaves your device" labeling in settings. |

Selection: per-profile provider override → global default provider → fallback chain
(local → skip). Timeout default 6 s (configurable); on timeout deliver stage-2 text and record
`cleanup: timed-out` in history.

### 3.3 Prompt architecture

One **system prompt template** with slots, versioned in-repo as a resource
(`CleanupPrompts/v1/system.txt`, golden-tested):

```
{ROLE + HARD RULES}
{LANGUAGE RULES: selected from en.txt / zh.txt by detected language}
{PROTECTED TERMS: written forms from dictionary}
{PROFILE PROMPT: active profile's instructions}
{USER STYLE PROMPT: global custom style prompt, if set}
{OUTPUT CONTRACT: plain text only}
--- user message = stage-2 transcript ---
```

- Temperature 0–0.2; max_tokens ≈ 2× input tokens; stop sequences guard against chat framing.
- **Output validation** before delivery: reject and fall back to stage-2 text if the output
  (a) is empty, (b) length ratio vs input is outside [0.4, 2.5] (catches "answered the
  question" and truncation failures), (c) contains meta-text markers ("Here is", "以下是",
  markdown fences), or (d) language of output ≠ language of input (unless profile requests
  translation). Validation failures are logged with the raw LLM output for prompt iteration.

### 3.4 Protected terms

Dictionary *written* forms + user-flagged terms are listed in the prompt as immutable tokens.
Post-cleanup, stage 2 re-runs and a verifier checks each protected term that existed in
stage-2 output still exists; if the LLM dropped one, fall back to stage-2 text.

## 4. Profiles & automatic switching — spec

A **profile** = named cleanup configuration + routing rules.

```
Profile {
  id, name, icon
  cleanupEnabled: Bool          // master switch per profile
  promptText: String            // the profile's AI instructions
  providerOverride: ProviderID?
  formatting: { language hints, spelling variant, bullets allowed, … }
  routes: [Route]               // matchers, see below
  priority: Int                 // explicit ordering for conflicts
}
Route = .app(bundleID)          // e.g. com.tinyspeck.slackmacgap
      | .website(hostname)      // e.g. mail.google.com (suffix match on registrable domain + subdomain)
      | .default                // exactly one profile owns .default
```

### Routing algorithm (macOS)

On hotkey **press** (not release — so the profile is known before cleanup starts):

1. `NSWorkspace.shared.frontmostApplication` → bundle ID.
2. If bundle ID ∈ known browsers {Safari, Chrome, Arc, Edge, Brave, Firefox}: fetch active
   tab URL via the per-browser scripting interface, reduce to **hostname only** (never path,
   query, or title — privacy requirement), match `.website` routes first.
3. Else match `.app` routes.
4. No match → `.default` profile.
5. Resolution is logged in history ("Profile: Email (matched mail.google.com)").

URL fetching is permission-gated (macOS Automation prompt per browser); if not granted,
website routing silently degrades to app-level routing. Hostname is used for routing in
memory only — **never persisted** beyond the profile-name log line.

### Built-in starter profiles

| Profile | Routes | Behavior |
|---|---|---|
| **Default** | `.default` | Light touch: fillers, self-corrections, punctuation. No restyle. |
| **Messages** | Slack, WeChat, Messages, Discord, Telegram | Casual, lowercase-friendly EN, no terminal period on short messages, emoji preserved as spoken ("smiley face" → 🙂 optional). |
| **Email** | Mail, Gmail/Outlook hostnames | Full sentences, greeting/sign-off untouched, professional tone, paragraphs. |
| **Terminal / Code** | Terminal, iTerm2, Ghostty, VS Code, Xcode, Cursor | **Cleanup OFF** (verbatim mode) except dictionary; never add punctuation to might-be-commands. |
| **Notes / Docs** | Notes, Obsidian, Google Docs hostname, Pages | Structured: paragraphs, bullets when enumerating ("first… second…" → list). |

All editable; user can add unlimited profiles (F8 requirement: "write your own profile with
any prompt you want").

### iOS routing

Keyboard extension knows the host app's bundle ID → same `.app` routing. No hostname routing
on iOS (no browser-tab access from a keyboard) → browser apps route to Default (documented
limitation).

## 5. Custom style prompt (stage 3 slot) — spec

A single global free-text prompt (Settings → Style), e.g. "Use British spelling. Keep
sentences under 20 words. Never use the word 'utilize'." Injected into **every** profile's
prompt (slot `USER STYLE PROMPT`) after the profile prompt, so profile-specific instructions
win on conflict (documented in UI). Empty by default. Per-profile "ignore global style"
toggle for e.g. the Terminal profile.

## 6. Post-formatter (stage 4)

Deterministic, language-aware, always on (even when cleanup is off):

- ZH: full-width punctuation enforcement; optional pangu spacing (thin space between Han and
  Latin/digit runs) per settings toggle; convert Simplified↔Traditional if the profile says so
  (OpenCC-style table, offline).
- EN: smart quotes optional (default off — code safety); collapse duplicate terminal
  punctuation.
- Both: apply "spacing before insertion" logic — if the insertion point follows a
  non-whitespace character, prefix a space (EN) or nothing (ZH); capitalize after sentence-
  ending punctuation in EN. (Same trick Wispr Flow uses to make consecutive dictations flow.)

## 7. Testing strategy for this layer

- **Golden fixtures**: `Tests/Fixtures/cleanup/{en,zh}/NNN_{name}.json` — each holds raw ASR
  text, dictionary state, profile, expected stage-2 and stage-4 outputs. Stages 1/2/4 assert
  exact equality (they're deterministic).
- **LLM eval set** (stage 3): ~60 curated transcripts (fillers, self-corrections incl. ZH
  「不对」patterns, questions-that-must-not-be-answered, protected terms, code-switching).
  A scoring harness (scripts/eval-cleanup) runs them against a provider and reports pass/fail
  per hard rule + edit-distance-to-reference. Run per model/prompt change; results checked in
  so prompt regressions are diffable.
- **Property tests**: dictionary idempotence (applying twice = once), no-cascade guarantee,
  length-ratio validator rejects adversarial outputs.
