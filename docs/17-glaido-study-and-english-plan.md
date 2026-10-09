# Glaido Study, Cold Review & English Improvement Plan (2026-10-06)

> **What this is.** A study of Glaido ("the world's fastest dictation"), a cold review of
> Vocal as it stands on `main` (`43059de`), and a phased plan to make Vocal's **English**
> dictation the best it can be. Chinese and Burmese are out of scope on purpose. Every finding
> below was verified by reading or reproducing it on `main`, unless it is marked *plausible*.
>
> **Status (same day):** the owner answered §8 and asked for G1 + G0 + G3 + G4 in one PR to
> save CI minutes. They are built on this branch. **§9** lists what shipped, what did not,
> and the hardware checklist, because CI compiles the app but never runs it.
>
> **Read with:** [docs/15](15-deep-review-and-improvement-plan.md) (the Wispr Flow plan,
> phases 0–7, mostly built) and [docs/16](16-mvp-cold-review.md) (the English MVP review).
> Nothing here re-reports what those two pages already found or fixed.

---

## 0. TL;DR

1. **Glaido's speed is a cloud trick, not a product insight.** It is cloud Whisper (Groq,
   Baseten) plus a fast LLM pass, so text arrives once, after you let go. Its own docs say
   "about one to three seconds" from release to paste; its blog says 458 ms. Neither number
   comes with a method. Vocal can beat that, and stay offline, with what is already in the
   repo: Parakeet on the Neural Engine. What it lacks is the measurement that lets
   Parakeet ship on by default.
2. **What is worth copying is the assistant layer:** voice Commands on selected text with a
   preview-then-Enter window, context from the text around the cursor, one-click styles,
   snippets that fire only when they are the whole dictation, auto-suggested dictionary
   words, and a separate hands-free chord.
3. **The cold review found two new English bugs that corrupt text on every default take**
   (cleanup on or off):
   - the loop guard turns `100000000` into `100` and the PIN `1212121212` into `12`;
   - the stutter repair turns "check in **in** five minutes" into "check in five minutes"
     and "what it was **was** amazing" into "what it was amazing".
   Both fixes are small, and failing tests are given.
4. **Vocal's biggest problem is missing evidence, not missing code.** There are still no
   latency or WER numbers from real hardware (`docs/benchmarks/` has no `M0-results.md`).
   So Parakeet ships OFF, live partial text is off by default (it rides on Parakeet), and
   every speed claim is still a guess. The plan's first step is a built-in **Speed Check**
   that produces those numbers on your Mac in about five minutes.

---

## 1. Method and its limits

- **glaido.com, docs.glaido.com and nearly every review site were blocked** by this
  environment's network egress policy (HTTP 403 / `EGRESS_BLOCKED`). That covered
  Product Hunt, Reddit, Hacker News, YouTube, the App Store, Spokenly and Voibe. The Glaido
  facts below come from:
  - search-engine excerpts of Glaido's own pages (tagged **[G]**) and of third-party
    reviews (tagged **[T]**);
  - one primary source read in full: the co-founder's public
    [`daveebbelaar/glaido-skills`](https://github.com/daveebbelaar/glaido-skills) repo
    (tagged **[P]**).
  My own inferences are tagged **[I]**. Most detailed reviews come from competitors, so read
  their verdicts with that bias in mind.
- **No Swift toolchain was available** (download.swift.org is blocked too), so nothing was
  compiled or run. Text-pipeline findings were reproduced by running the exact regexes from
  the Swift source under Python's `re`, which behaves like ICU for these patterns. Each
  carries a ready-to-paste Swift test, so CI on macOS confirms it on the first push.
- Repo state: `main` at `43059de` (2026-09-29, after #31). An earlier draft of this review
  was accidentally started on the stale v0.1.1 tree. Everything here was re-checked against
  `main`.

---

## 2. Glaido: what it is and what it does best

**Product.** A cloud push-to-talk dictation app for macOS 13+ and Windows 11. Hold a key,
speak, release, and formatted text is pasted into the focused field. On top of that sits a
"Commands / Agent Mode" layer **[G]**.
- **Makers:** GLAIDOVOICE AI SOLUTIONS FZCO (Dubai), fronted by creators Jack Roberts and
  Nate Herk **[G][T]**.
- **Timeline:** launched April–May 2026; Windows on 2026-06-29; "Tools beta" on
  2026-07-18 **[G]**.
- **Pricing:** free tier of 2,000 words a week (including Agent Mode); Pro at $20/month or
  $17/month billed annually; Enterprise with SSO **[G][T]**.

| # | Feature | What Glaido does | Source |
|---|---|---|---|
| 1 | **Speed** | Calls itself "world's fastest"; claims 150 WPM. Release→paste is "1–3 s" in its docs and "458 ms, 0.3% WER" in a blog post, with no method given. Text lands **once, after you stop**, not streamed | [G][T] |
| 2 | **How it is fast** | Cloud Whisper plus an AI formatting pass. Subprocessors: AWS, Baseten, **Groq**, Hetzner. Internet required | [T] [I: Groq-hosted Whisper] |
| 3 | **Context-aware formatting** | "Looks at the app you're in, the text around your cursor, and the type of content." Email gets paragraphs and polish, Slack stays casual, code comments keep inline code intact | [G] |
| 4 | **Styles + per-app rules** | Four global styles (Standard / Casual / Lowercase / Raw), a custom prompt of up to 500 characters, and rules per app or website. A built-in Email rule covers Gmail and Outlook web | [G][T] |
| 5 | **Commands / Agent Mode** | Select text, hold the command key, speak ("make this shorter", "translate", or a question). The result appears in a **floating window; Enter pastes it**. Starting a dictation with "Glaido…" or saying "Hey Glaido" mid-sentence turns the rest into a command | [G][T] |
| 6 | **Built-in tools** | Eight: web search, read a page, YouTube summary, deep research, math and dates, files and apps, **history search**, docs search | [T] |
| 7 | **Custom tools (MCP)** | Import a folder with `mcp.json` (local stdio servers only), with a per-tool approval policy (`auto` / `ask` / `deny`) driven by MCP `readOnlyHint` / `destructiveHint`. Onboarding is agent-first: paste a prompt into Claude Code and it builds the server | [P] |
| 8 | **Dictionary** | Custom words. On Mac it **suggests words you keep correcting**. Onboarding **imports your Wispr Flow dictionary** | [G] |
| 9 | **Snippets** | A trigger phrase expands to text, with `{clipboard}` and `{date}` tags. A snippet fires **only when the whole dictation is the trigger** | [G][T] |
| 10 | **Hotkeys** | Hold Fn; hands-free on **Fn+Space**; a separate command key; double-tap (added Jul 18); Esc cancels; optional **"Enter to stop and paste"**; left/right-distinct modifiers; warns when a shortcut collides with a system one | [G][T] |
| 11 | **History** | Last 100 takes, encrypted on the device; audio playback; **retry** (re-transcribe); ⌘K search; no per-item delete | [T][G] |
| 12 | **"Built to never lose a word"** | If the network drops, audio is saved for retry. Also "faster first-press dictations" | [G] |
| 13 | **Onboarding** | Mic → Accessibility → setup wizard → "transcribe your first sentence in under a minute" | [G] |

**What reviewers dislike [T]:**
- price (the most expensive in its class);
- cloud only;
- no mobile app;
- English sometimes comes back **translated into another language**;
- paste fails inside the **Claude Code VS Code extension**;
- latency claims that contradict each other;
- privacy wording that contradicts itself.

**What is genuinely distinctive [P][T]:**
- user-extensible tools through local MCP;
- voice commands on the free tier;
- the inline "Hey Glaido" trigger;
- importing a competitor's dictionary.

Its transcription is plain cloud Whisper. One reviewer's summary: "the $20 buys formatting
rules, command mode, and the app experience rather than more accurate transcription."

---

## 3. Where Vocal already matches or beats Glaido

Vocal is not starting behind. On `main` today it already has:

| Area | Vocal on `main` | vs Glaido |
|---|---|---|
| Privacy | Fully offline. Concealed and transient pasteboard. Secure-field block persists nothing | **Far ahead.** Glaido is cloud-only and its privacy wording contradicts itself |
| Wrong-language output | Pinned-EN is enforced in Whisper (#30 R1). Third-language detections are re-decoded (R2). A `language-mismatch` validator | **Ahead.** Glaido users report English coming back translated |
| Hotkeys | Presets plus a custom recorder (`HotkeySpec`), hold / double-tap-lock / Esc, live key tester | At par. Missing a dedicated hands-free chord and Enter-to-paste (§5) |
| Never lose a word | Failed or cancelled takes recoverable for 24 h; audio retention; device-change-safe capture | At par or ahead |
| Per-app styles | Full profiles: per-app and per-website routes, prompt, formatting gates, language pin, provider override, CRUD editor | **Ahead in power**, behind in one-click simplicity (§5) |
| Dictionary | Word or phrase entries, terminal written forms, protected-term verify and repair, Whisper prompt biasing (first 24 terms), CSV import/export, propose-only learning | At par. Missing correction-watching suggestions |
| History | FTS search, audio playback, raw vs delivered, replace-with-raw / paste-again / undo-last | At par. Missing a ⌘K palette and retry-with-another-engine |
| Cleanup safety | Validator stack: ratio floor, answered-question, rewrite, meta-text, protected terms | **Ahead.** Glaido's "answers" are a feature; Vocal guards against answering the user |
| Deterministic English | Fillers and stutters, layout commands, spoken numbers (times, years, percents), code mode | Not documented for Glaido |
| Usage stats | Takes, words, WPM, streak, median felt latency | At par |
| Insertion | AX-first with verification, paste fallback, per-app table | Probably ahead (Glaido fails in Claude Code VS Code) *(plausible: not tested)* |
| iPhone | Main app, keyboard extension, share extension, Dynamic Island (code complete, not yet run on a device) | Glaido has no mobile app |

---

## 4. Cold review of `main`: new findings (English path)

Severity: **H** = corrupts delivered text or loses work; **M** = noticeable quality or
latency cost; **L** = edge case.

### 4.1 Text pipeline (reproduced)

**F1 [H]: the loop guard destroys digit and symbol runs.**
`Stage1Normalizer.collapseUnspacedRepetitionLoops` uses `(\S{2,20}?)\1{3,}`. It was meant
for Whisper's unspaced Chinese loops, but it matches any non-space unit, and it runs
**always**, even on verbatim profiles (artifact stripping is ungated). Reproduced:

| Input | Delivered |
|---|---|
| `The code is 100000000.` | `The code is 100.` |
| `PIN 1212121212` | `PIN 12` |
| `-------- divider` (Terminal profile) | `-- divider` |
| `a ======== b` | `a == b` |
| `hahahahaha nice` | `ha nice` |

No test covers digits or symbols. Fix: require the repeated unit to contain a letter, and in
practice a Han or other non-Latin letter, because English decoding loops are spaced and
already caught by the token pass. For example `((?=\S*[\p{Han}\p{Myanmar}])\S{2,20}?)\1{3,}`,
or skip any match whose unit is all digits or punctuation. Tests to add:

```swift
@Test func digitRunsSurviveLoopGuard() {
    #expect(Stage1Normalizer.normalize("The code is 100000000.", language: .english, formatting: .init()) == "The code is 100000000.")
    #expect(Stage1Normalizer.normalize("PIN 1212121212", language: .english, formatting: .verbatim) == "PIN 1212121212")
    #expect(Stage1Normalizer.normalize("a ======== b", language: .english, formatting: .verbatim) == "a ======== b")
}
```

**F2 [H]: stutter repair deletes grammatical doubles.**
`EnglishCleanup.collapseStutters` collapses any doubled word in its list, optionally across
a comma. The list deliberately excludes "is is" and "had had" because they can be
grammatical. But "was was" and "are are" are the same construction, and the prepositions
double whenever a phrasal verb meets a prepositional phrase. Reproduced:

| Input | Delivered | Meaning |
|---|---|---|
| Check in in five minutes. | Check in five minutes. | changed |
| Please log in in the morning. | Please log in the morning. | changed |
| Turn it on on Monday. | Turn it on Monday. | changed |
| What it was was amazing. | What it was amazing. | ungrammatical |
| What they are are excuses. | What they are excuses. | ungrammatical |
| Vitamin A a day | Vitamin A day | changed |

This runs on every non-verbatim take, with cleanup on or off, and before the LLM sees the
text, so the LLM cannot undo it. Fix:
- remove `was`, `are`, `in`, `on`, `at`, `a` from `stutterWords`; or
- keep them only when the double is *not* preceded by a phrasal-verb particle context:
  collapse "in in" only when the first "in" follows a non-verb (hard to do
  deterministically, so prefer removal and leave those cases to the LLM);
- and do not collapse across a comma for prepositions ("check in, in five minutes" is
  deliberate).

Tests to add:

```swift
@Test func grammaticalDoublesSurvive() {
    for s in ["Check in in five minutes.", "Turn it on on Monday.", "What it was was amazing.", "What they are are excuses."] {
        #expect(EnglishCleanup.clean(s) == s)
    }
}
```

**F3 [M]: the ellipsis becomes a period.**
Stage 4 turns `([.!?])[.!?]+` into the first mark, so "Wait... what?" becomes "Wait. what?"
(a lowercase letter after a full stop). `Seriously?!` becomes `Seriously?`. A test pins
this (`asciiEllipsisCollapsesToPeriod`), so it was a choice. But it is the wrong one for
Email, Notes and chat, where a trailing "..." is intentional tone. Proposal: keep `...` (or
normalise it to `…`) and collapse only true duplicates (`..` → `.`, `!!` → `!`, `?.` → `?`).
This is an owner decision (Q7).

**F4 [L]: years are read into compound adjectives.**
`SpokenNumberFormatter`'s year rule fires inside them: "twenty fifteen-minute slots" →
"2015-minute slots", and "nineteen fifty-dollar tickets" → "1950-dollar tickets". Rare.
Fix: a negative lookahead for `-(minute|hour|day|dollar|year|page|…)`.

**F5 [M]: snippets fire mid-sentence.**
Snippets are ordinary dictionary entries with a multi-line or long written form (docs/15
step 26), matched on word boundaries anywhere in the text. A snippet "my address" therefore
expands inside "I changed my address last week". Glaido's rule is the right one: a snippet
fires only when the whole dictation (after filler stripping) is the trigger. Add an
`isSnippet` flag, or derive it from DictionaryCSV's snippet definition, and match those
entries against the whole utterance only.

### 4.2 Speed and feedback (verified by reading)

**F6 [M]: there is no live text by default.**
`previewTranscribe` returns nil unless Parakeet-English is enabled and the language is
pinned to EN, and both ship OFF. A default install shows a waveform and no words. Words
appearing while you speak is the single strongest "feels fast" cue (docs/15 step 22).

**F7 [M]: the preview re-decodes the whole take every tick.**
`startPreview` snapshots the full buffer and decodes all of it once there is ≥1 s of new
audio. A five-minute hands-free take re-decodes five minutes of audio about every second.
That costs ANE time and heat, and competes with the final decode at release. Decode a
trailing window (for example the last 15–20 s plus the committed-prefix offset) instead.

**F8 [M]: the final pass is still a full batch decode.**
The docs/15 Part 2b upgrade ("commit the stable prefix, decode only the tail at release")
was not built. Only the display-only preview was. On Whisper turbo this is the dominant cost
for long takes. With Parakeet it hardly matters (about 0.5 s per minute of audio), which is
one more reason to settle the Parakeet question first.

**F9 [M]: Parakeet ignores the dictionary.**
`ParakeetEngine.transcribe` accepts `dictionaryTerms` and never uses them, so turning on the
fast English path silently drops ASR-level vocabulary biasing that Whisper has. FluidAudio
0.15 (already pinned) offers CTC-based custom-vocabulary boosting for batch Parakeet TDT
*(per its docs; API to verify)*. Wire it before Parakeet becomes the default.

**F10 [L]: the Whisper bias terms are an arbitrary 24.**
`biasPromptTokens` takes `.prefix(24)` in database order. With more than 24 entries, which
terms bias the decoder is accidental. Rank them by `applyCount` and `lastAppliedAt` (the
fields exist), optionally boosted for the current profile.

**F11 [M]: there is still no hardware evidence.** The `vocal-bench` harness and
`make bench-latency` exist, but no results were ever committed (no
`docs/benchmarks/M0-results.md`). This blocks Parakeet-by-default (step 14 "pending
vocal-bench numbers") and every "faster than X" claim. See plan step G0.

### 4.3 App layer (independent review of `apps/`, `PersistenceKit`, `ProfileKit`)

A separate cold review of the app layer reported 27 findings. Each one marked *fixed* was
re-verified against the code before it was changed. The rest are recorded here for later.

| # | Sev | Finding | Status |
|---|---|---|---|
| 1 | M | A chord during a hands-free take (right-⌘+Tab, Fn+arrow) cancelled the whole take | **Fixed**: shortcuts during lock are ignored (core + tests) |
| 2 | M | Double-tapping out of hands-free started a new locked take | **Fixed**: the lock-exit tap no longer seeds a double-tap (core + tests) |
| 3 | M | The HUD swallowed clicks above the Dock for the whole take, and had nothing to click | **Fixed**: always click-through |
| 4 | M | AX insertion reported success when the field already contained the same text | **Fixed**: the value must change |
| 5 | M | AX calls on the main actor had no messaging timeout (~6 s freeze on a busy target) | **Fixed**: 1 s bound, 0.25 s for read-only context |
| 6 | M | "Keep audio: Never" kept cancelled and failed takes; Delete All left recovery files | **Fixed**: discarded at once (FR-1.6); Delete All clears them |
| 7 | M | Alacritty, kitty, WezTerm and Warp were typed into as terminals but formatted as prose | **Fixed**: routed to Terminal / Code, with an upgrade for existing installs |
| 8 | M* | The browser-automation prompt first appears mid-dictation | Open: request it from onboarding |
| 9 | M* | The clipboard snapshot forces every pasteboard format to render (Excel/Keynote) | Open: snapshot known types with a size cap |
| 10 | M– | History decodes everything on the main thread and never refreshes | Open |
| 11 | L–M | Mic levels inside `hudState` redraw every AppState observer ~12×/s | Open: split into a HUD-only object |
| 12 | L–M | Sleep during a hands-free take left the silence auto-stop armed | **Fixed** |
| 13 | L–M | An earlier take's error showed after the next take delivered | **Fixed** (test fails without the fix) |
| 14 | L–M | A hotkey press during "Recover" waits for the whole recovery | Open |
| 15 | L | "Test Your Key" ends test mode on the first edge | Open |
| 16 | L | Undo last insertion edited matching text in any app, any time later | **Fixed**: same app, within 10 minutes |
| 17 | L | The short-tap commit timer can deliver before the lock gesture completes | Open (small impact) |
| 18 | L | "Run Setup Assistant Again" may reopen on the last page | Open |
| 19 | L* | Start/stop sounds are captured at the edges of the take | Open |
| 20 | L | A stuck background secure input is only discovered after speaking | Open |
| 21 | L | iOS settings are read and written across threads during overlapping takes | Open |
| 22 | L | iOS auto-copy rides Universal Clipboard to other devices | **Fixed**: local-only |
| 23 | L* | The iOS audio session is never released after in-app takes | Open |
| 24 | L | Per-app insertion overrides are read at launch only | Open |
| 25 | L | Deleting one transcript left its text readable in the database file | **Fixed** (round 2, §11): `secure_delete` alone did not cover the search indexes; delete now also optimizes them, plus FTS5 `secure-delete` where SQLite supports it |
| 26 | L* | A downgrade can duplicate the built-in profiles | Open |
| 27 | L | The delivered sound and HUD lag the paste by the 400 ms restore wait | Open (a restore race needs care) |

\* plausible: depends on runtime behaviour.

---

## 5. Gap analysis: Glaido feature → Vocal verdict

| Glaido feature | Vocal today | Verdict | Why |
|---|---|---|---|
| Cloud speed (Groq Whisper) | Offline Whisper turbo; Parakeet built but OFF | **Adapt, not copy** | Parakeet on the ANE is about 110x real time. A 10 s take decodes in well under 100 ms, with no network round trip. Ship it as the default for English once G0 has numbers |
| Text around the cursor as context | AX preceding text (64 chars) used for spacing and capitalisation only | **Adopt (local)** | Feed a bounded, read-only CONTEXT block (text before and after the caret, about 300 chars, never stored) into the cleanup prompt. It improves continuation casing (docs/16 #5), name spelling and tone, all on-device |
| One-click styles (Standard / Casual / Lowercase / Raw) | Profiles plus a free-text style prompt | **Adopt as a layer** | Keep profiles; add a 4-way style picker in the menu bar and per profile that maps to prompt and formatting presets. Simplicity is the feature |
| Commands on selected text, preview then Enter | Layout commands only ("new line") | **Adopt (local LLM)** | The flagship assistant feature. Local model, preview panel, Enter pastes, Esc dismisses. Uses the existing validator-free "edit" path with its own prompt |
| "Hey Glaido" inline trigger | — | **Adapt, opt-in** | A leading wake word ("Vocal, …") with a whole-word, start-of-take-only match; off by default to avoid false triggers |
| Built-in tools (math and dates, history search) | — | **Adopt the local ones** | Math, dates and unit conversion done deterministically; "find what I dictated about X" through the existing FTS. No web tools (offline) |
| Custom MCP tools | — | **Defer** | Real security surface (arbitrary local processes driven by voice). Revisit only with an allow-list, per-tool approval like Glaido's `ask`, and your explicit go-ahead |
| Auto-suggest corrected words | Propose-only learning from re-dictation diffs | **Extend** | Also watch the field: re-read the inserted range through AX about 10 s later; if the user edited a word, propose a dictionary entry. Local, propose-only |
| Wispr Flow dictionary import | CSV import | **Ask** | Only valuable if you have a Wispr Flow dictionary (Q10) |
| Snippets: whole-dictation-only, `{clipboard}` / `{date}` | Snippets match anywhere (F5) | **Adopt** | Fixes F5 and adds two useful tags |
| Hands-free chord (Fn+Space) and "Enter to stop and paste" | Double-tap lock; Esc cancels | **Adopt** | Discoverable hands-free, plus a natural way to end a long take |
| Separate command hotkey | — | **Adopt** with command mode | Its own `HotkeySpec` |
| History retry and ⌘K | History window with search | **Adopt** | ⌘K quick palette; "Retry with Whisper / Parakeet / profile X" per row |
| First sentence in under a minute | First run downloads about 600 MB of Whisper | **Adapt** | Ask whether a smaller first model is acceptable (§6, idea 9) |
| Windows / 100 languages / team SSO | Mac + iOS, EN/ZH/MY | **Skip** | Out of scope for a personal, English-first app |

**Glaido weaknesses to make Vocal's strengths:** privacy, no subscription, no translation
surprises, working insertion into Claude Code / VS Code, and published latency numbers with
a method (Speed Check).

---

## 6. Brainstorm: ideas beyond Glaido (offline, safe)

1. **Speed Check (built in).** A Settings pane that shows a short passage and records you
   reading it three times. It then reports **your** release→text p50/p95 for Whisper vs
   Parakeet, WER against the known passage, and suggests the faster engine. Data stays local
   and is deletable. This solves F11 with no Terminal and no fixtures, and gives you an
   honest number that is better than any marketing claim.
2. **Low-confidence quick fix.** Whisper and Parakeet expose per-token probabilities. After
   delivery, the HUD briefly underlines the one or two least-confident words with
   alternatives. One click replaces the word through AX and offers "always write it this
   way" as a dictionary entry. This turns ASR errors into a 1-second fix and a learning
   signal.
3. **Speculative cleanup while you talk.** Once the preview's committed prefix ends a
   sentence, clean that sentence in the background. At release only the last sentence still
   needs the model, so cleanup latency stops scaling with take length.
4. **Context-seeded vocabulary.** Extract capitalised tokens and identifiers from the
   bounded AX context (for example the names in the email you are replying to) and add them
   to that take's ASR bias terms. Hear "Siobhan" correctly because it is on screen; nothing
   is stored.
5. **AI-chat profile.** Claude, ChatGPT, Cursor chat and Claude Code prompts are prose, not
   code. A built-in "AI prompt" profile (routes for Claude.app, ChatGPT.app, chatgpt.com,
   claude.ai) with light cleanup and code-symbol preservation. Today Cursor
   (`com.todesktop…`) routes to the verbatim Terminal / Code profile even when you are
   talking to its chat.
6. **Deterministic "scratch that".** A standalone "scratch that" / "delete that" deletes the
   previous sentence within the take (docs/16 #7), so the most-used correction works with
   cleanup off.
7. **Pause-aware punctuation for Parakeet.** Use the VAD's pause durations as a tie-breaker
   for sentence breaks when the model emits a run-on (pending Speed Check transcripts
   showing it does).
8. **Dictation diff view.** In History, show raw → delivered as an inline diff with each
   change labelled (filler, stutter, correction, LLM). It makes the deterministic and LLM
   layers auditable, which builds trust in leaving cleanup ON.
9. **Two-stage first run.** Download Parakeet v2 (English) first, so the first dictation
   works in about a minute. Fetch Whisper turbo in the background for code-switching (ask:
   Q1/Q2).
10. **"Whisper mode" check.** Add a quiet-speech line to Speed Check to measure accuracy when
    speaking softly (open-office use). It only needs a VAD threshold and gain tweak once
    measured.

---

## 7. The plan

Effort: S ≤ 1 day, M = 2–4 days, L = 1–2 weeks (solo plus agent pace). Each phase ships
alone. Order: **measure → fix → fast → smart → assistant → learn.**

### G0: Measure (prerequisite for everything speed-related)
| Step | What | Effort | Done when |
|---|---|---|---|
| G0.1 | **Speed Check pane** (idea 1): fixed passages, three reads, per-engine p50/p95 release→text, WER, RAM | M | A result card appears on your Mac; a Markdown export is committed as `docs/benchmarks/M0-results.md` |
| G0.2 | Turn on the timings toast for a week of real use; run `make bench-latency` | S | p50/p95 per stage from real history are committed |
| G0.3 | **Decision gate:** Parakeet default for English if its WER is within about 1 pt of Whisper and it is faster | — | Recorded in docs/12 |

### G1: English correctness hot-fixes (small, high severity)
| Step | What | Effort |
|---|---|---|
| G1.1 | F1 loop guard: never collapse digit or symbol units; tests above | S |
| G1.2 | F2 stutter list: drop the grammatical doubles; no comma-spanning for prepositions; tests above | S |
| G1.3 | F5 snippets: whole-utterance match plus `{clipboard}` / `{date}` tags | S–M |
| G1.4 | F3 ellipsis, per owner decision Q7 | S |
| G1.5 | F4 year-before-hyphen lookahead | S |
| G1.6 | App-layer findings from §4.4 rated H or M | S–M |

### G2: The fastest English path (offline)
Target, measured by G0: **release → text p50 ≤ 500 ms, p95 ≤ 900 ms for a 10 s English take
with cleanup off; p50 ≤ 900 ms with cleanup on.**

| Step | What | Effort |
|---|---|---|
| G2.1 | Parakeet v2 as the default English engine (if G0.3 says so); Whisper remains for auto / code-switching | S |
| G2.2 | F9: FluidAudio custom-vocabulary boosting for Parakeet, fed by the ranked dictionary (F10) | M |
| G2.3 | F6/F7: live partials on by default with Parakeet; trailing-window preview decode | M |
| G2.4 | Insertion fast path: confirm AX-first lands without the paste sleeps for the top apps you use, measured in G0.2 | S |
| G2.5 | F8 commit-the-prefix for Whisper, **only if** you keep Whisper as your English engine | L |

### G3: Smart cleanup, fast enough to leave ON
| Step | What | Effort |
|---|---|---|
| G3.1 | Cleanup provider default per your Mac: Apple Foundation Models on macOS 26 with Apple Intelligence, else Ollama `qwen2.5:3b` (176 ms median in the eval); answers Q3 | S |
| G3.2 | **Local context block** (Glaido #3): bounded AX text before and after the caret, never persisted, behind a setting; eval cases for continuation casing and name spelling | M |
| G3.3 | **Styles layer** (Glaido #4): Standard / Casual / Lowercase / Raw picker in the menu bar and per profile | S–M |
| G3.4 | **AI-prompt profile** (idea 5) and a Cursor chat-vs-editor split | S |
| G3.5 | Speculative per-sentence cleanup while speaking (idea 3) | L |
| G3.6 | Deterministic standalone "scratch that" (idea 6) | S |

### G4: Command mode, a local assistant (Glaido #5/#6)
| Step | What | Effort |
|---|---|---|
| G4.1 | Command hotkey (`HotkeySpec`) plus selection capture through AX (clipboard fallback with restore) | M |
| G4.2 | Edit commands on the selection, run by the local model ("shorter", "more formal", "fix grammar", "bullet points", "reply politely"), with a **preview panel: Enter pastes, Esc dismisses, ⌘Z restores** | L |
| G4.3 | Local tools: arithmetic, dates and units (deterministic); "find what I said about…" through FTS. No network | M |
| G4.4 | Opt-in leading wake word ("Vocal, …") that routes the take to command mode | S |
| G4.5 | *(Deferred)* local MCP tools with an allow-list and per-tool approval, only on your explicit go-ahead (security) | L |

### G5: The learning loop and polish
| Step | What | Effort |
|---|---|---|
| G5.1 | Correction watching (AX re-read of the inserted range after about 10 s) → propose dictionary entries | M |
| G5.2 | Low-confidence quick fix (idea 2) | L |
| G5.3 | Hands-free chord plus "Enter to stop and paste" (Glaido #10) | S |
| G5.4 | ⌘K history palette; Retry with another engine or profile; diff view (idea 8) | M |
| G5.5 | Two-stage first run (idea 9) and the "first sentence in a minute" onboarding | M |
| G5.6 | Wispr Flow dictionary import, if Q10 says yes | S |

### What not to copy
- cloud ASR or cloud cleanup by default;
- a subscription or word quotas;
- an always-on wake word (Glaido's community has a thread on continuous recording);
- arbitrary tool execution driven by voice without approval;
- latency claims without a published method.

---

## 8. Decisions only you can make

**Answered 2026-10-06:**
- offline only;
- macOS 26 with Apple Intelligence;
- keep "wait, paste once";
- build G1 + G0 + G4 + G3 in one PR;
- command mode triggered by **both** a dedicated key and an opt-in wake word;
- keep the current ellipsis behaviour (F3 stays), but capitalise the word after it
  (follow-up decision: "Wait... are you serious?" → "Wait. Are you serious?");
- cleanup stays **OFF** by default;
- cursor context **opt-in**.

Still open: 1, 5, 10, 11, 12, plus which five commands you use most.

1. **Source of truth:** is `main` at `43059de` what is installed on your Mac today, and should
   all work build on it?
2. **Your Mac now:** chip, RAM and macOS version (decides Apple Foundation Models and Apple
   Speech availability for G3.1).
3. **Offline vs speed:** is fully offline still non-negotiable, or would you accept an
   **opt-in** cloud "turbo" (for example Groq) for some apps? This plan assumes offline.
4. **Speed Check:** will you spend about five minutes reading passages on your Mac (G0)? It
   is the gate for Parakeet-by-default.
5. **Your English:** US or UK spelling; native or non-native accent (tunes the
   misheard-word rules and the eval set).
6. **Cleanup default:** ON or OFF out of the box, and which local model you run today.
7. **Ellipsis:** keep "..." as you said it, or normalise it to a period as today (F3)?
8. **Command mode:** wanted? Which five commands would you use daily? Is an opt-in wake word
   OK?
9. **Insertion feel:** keep "wait, then paste the final text once", or "paste raw instantly,
   then swap in the cleaned text" (faster, but text visibly changes)?
10. **Wispr Flow:** do you have a Wispr Flow (or Glaido) dictionary to import?
11. **Correction watching:** OK for Vocal to re-read the text field it just typed into, about
    10 s later, to learn your fixes (local only)?
12. **Where you dictate now:** still email and docs, code and terminal, and notes? How much
    goes into AI chat apps (Claude, ChatGPT, Cursor chat)?
13. **Delivery:** one PR per phase (G1 first), or a single branch?

---

## 9. Implementation status (this branch)

### Built
| Plan step | What shipped | Tests |
|---|---|---|
| G1.1 F1 | The loop guard collapses only units that contain a non-ASCII letter; digits and symbols survive | Linux |
| G1.2 F2 | in/on/at/a/was/are removed from the stutter list | Linux |
| G1.3 F5 | Snippets fire only as the whole take; `{date}` `{time}` `{clipboard}` tags; a per-entry Snippet checkbox (optional field, no migration); snippets never bias the recognizer or count as protected terms; no cleanup or reformatting | Linux (engine, session) |
| G1.5 F4 | The year rules skip hyphenated compounds | Linux |
| G1.6 | §4.3 items 1–7, 12, 13, 16, 22, 25 | Linux for 1, 2, 6 (store), 13; app code for the rest |
| G3.2 | Opt-in **Use nearby text as context** (Settings → Cleanup): ~240 characters before and 80 after the caret, read only when cleanup runs, never stored, never from secure fields; fenced `<CONTEXT>` in the prompt, rejected if echoed; prompts without context are byte-identical | Linux |
| G3.3 | **Dictation style**: Standard / Casual / Lowercase / Raw (Settings → General and the menu bar). Deterministic, after stage 4; Raw runs the pipeline verbatim and skips cleanup; Terminal / Code is untouched | Linux |
| G3.4 | **AI Prompt** built-in profile (Claude, ChatGPT, claude.ai, chatgpt.com, gemini.google.com); idempotent built-in upgrades for existing installs | Linux |
| G4.1–4.4 | **Command mode**: a command key (Settings → General → Commands, off by default) plus an opt-in "Vocal, …" wake word; the selection captured at press; arithmetic and date/time answered locally; otherwise Ollama, falling back to Apple's on-device model; a key-capable non-activating preview where **Return inserts**, ⌘C copies and Escape or clicking away dismisses | Linux (parser, tools, prompt, sanitizer, session routing, request body); app code for the key, panel and insertion |
| G0.1 | **Speed Check** (Settings tab): three passages, the same audio decoded by Whisper and Parakeet after a warm-up, p50/p95, real-time factor, WER, the G0.3 recommendation, and a Markdown report to copy or save as `docs/benchmarks/M0-results.md` | Linux (scoring, report) |
| G2.1 | **Parakeet is the default English engine.** The toggle is ON unless you switched it off, and Auto still uses Whisper. A take goes to Parakeet only once its models are on disk (they download in the background), and a Parakeet failure falls back to Whisper for that take. Settings → Models offers **Use English** when the language is Auto, and Speed Check offers **Use Parakeet for English** when its verdict says so | Linux (verdict, fallback); app code for the toggle, routing and buttons |
| G2.2 F9/F10 | **Parakeet listens for Dictionary words.** FluidAudio's CTC keyword spotter (parakeet-ctc-110m) rescores each take against your Dictionary and swaps a word only when the audio supports the term (Settings → Models → "Listen for Dictionary words", ON). The model downloads and the boost is built in the background, never inside a take; a take uses the boost only once it is ready. Each delivered take now records which Dictionary entries it used (`applyCount`, `lastAppliedAt` were never written before), and terms are ranked most-used first, so Whisper's 24-term prompt and Parakeet's 256-term cap keep your most-used words | Linux (use counts, ranking, term filter); app/engine code for the boost |
| G2.3 F6/F7 | **Live text is on by default** with Parakeet (it follows the G2.1 default), and the preview decodes only a **trailing window**: past 14 s, committed words that end before the last 6 s are frozen on screen and never decoded again. A long take now costs the same per tick as a short one, and the preview buffer drops audio it no longer needs | Linux (window logic, session wiring) |

### Not built (still in the plan)
- G2.4: the insertion fast path. It needs per-app insertion timings from your Mac first.
- G2.5: commit-the-prefix for Whisper. Dropped, since Parakeet is now the English engine.
- G3.1: Ollama is still tried first, then Apple's model; cleanup is still OFF by default.
- G3.5: speculative cleanup.
- G3.6: deterministic "scratch that".
- G4.5: MCP tools.
- G5: the learning loop, quick fix, hands-free chord, ⌘K, and two-stage first run.

### Speed Check result (2026-10-07, checklist #1 done)

Run on the owner's Mac (Mac16,5, macOS 26.7.1); the full report is
[`docs/benchmarks/M0-results.md`](benchmarks/M0-results.md).

| Engine | Release→text p50 / p95 | Real-time factor | WER |
|---|---|---|---|
| Whisper large-v3 turbo | 693 / 700 ms | 19x | 7.4% |
| Parakeet (English) | 77 / 81 ms | 177x | 6.4% |

- **Speed:** Parakeet is about 9x faster. The gap is consistent across all three passages.
- **Accuracy:** the sample is about 110 words, so 1 point of WER is roughly one word.
  The two engines are as accurate as each other here; this run does not show Parakeet
  is *more* accurate.
- **Shared mishearings:** both wrote "sink" for "sync" and "rename" for "renamed".
  "sync" is a natural first vocabulary-boost term for G2.2.
- **Whisper only:** it dropped words in passage 1 ("I already did this morning" for
  "I read it this morning").
- **Parakeet only:** it joined two sentences with a comma in passage 3.

G0.3's rule says Parakeet for English, so G2.1's gate is met.

### Speed Check, second run (2026-10-07, checklist #18)

After G2, a fresh recording; full report in
[`docs/benchmarks/M0-results-run2.md`](benchmarks/M0-results-run2.md).

| Engine | Release→text p50 / p95 | Real-time factor | WER (word errors of 94) |
|---|---|---|---|
| Whisper large-v3 turbo | 689 / 707 ms | 18x | 6.4% (6) |
| Parakeet (English) | 82 / 82 ms | 163x | 7.4% (7) |

- **Speed: unchanged.** Parakeet 82 ms against 77 ms in run 1; G2's per-take work (word
  timings) costs nothing visible. #18 passes.
- **Accuracy: the same, swapped.** Run 1 was 7 against 6 errors in Parakeet's favour; run 2
  is 6 against 7 the other way. Both times the deciding word was "sync": this time Whisper
  heard it and Parakeet wrote "sink". Over both runs each engine made 13 errors in 188
  words. Passage 3 errors were identical across engines ("fix" for "find", "launch" for
  "lunch"), which points at the reading, not the engine.
- **The rule flipped on that one word.** One point of WER is one word in this check, so
  the app said "Keep Whisper: … noticeably less accurate". Fixed: Parakeet now counts as
  about as accurate when it makes at most two more word errors (or one point, for longer
  samples), and the report prints the error counts. Parakeet stayed the English engine
  throughout; the verdict only decides whether the pane offers its button.
- Speed Check runs both engines without your Dictionary, so the boost (#16) is not in
  these numbers.

### Hardware checklist (run once on your Mac after `make install`)
| # | Check | Why |
|---|---|---|
| 1 | Settings → Speed Check: read all three passages, then Save Report into `docs/benchmarks/` | Unblocks G2 |
| 2 | Set a command key. Select a sentence in Notes, hold the key, say "make this shorter". The preview shows the result, **Return** replaces the selection, and Notes keeps focus throughout | The panel becomes key without activating Vocal, which only exists at runtime |
| 3 | Same with nothing selected: "what's 15% of 240" gives **36** instantly; "write a polite reply declining the meeting" uses the model | Local tools vs model path |
| 4 | Turn on the wake word, then dictate "Vocal, turn this into bullet points" with text selected | Wake-word routing |
| 5 | Escape and clicking elsewhere both dismiss the preview; Return then goes to your app, not the preview | Key monitor and resign handling |
| 6 | A snippet "my address" (multi-line) expands when said alone and stays prose in "I changed my address" | F5 |
| 7 | Styles: Lowercase in Messages, Raw anywhere, and Terminal stays verbatim | G3.3 |
| 8 | Turn on "Use nearby text as context", continue a sentence mid-paragraph, and check it starts lowercase | G3.2 |
| 9 | Hands-free: during a locked take press Fn+arrow (or right-⌘+Tab); the take keeps recording. Double-tap out; no new locked take starts | §4.3 #1, #2 |
| 10 | The HUD never blocks clicks; dictating into kitty or WezTerm gives verbatim text | §4.3 #3, #7 |
| 11 | "Keep audio: Never", then cancel a take: there's no Recover menu item | §4.3 #6 |
| 12 | Double-tap the command key, then hold it and type ⌥+a letter mid-command: the take still ends on release | review #2 |
| 13 | "Fix the grammar" on already-correct selected text: "Already fine — nothing changed", no duplicate | review #3 |
| 14 | Cancel a Speed Check passage: no Recover item appears | review #4 |
| 15 | ✅ 2026-10-08 (words show in the HUD). With the language on English, dictate: words appear in the HUD while you speak, and the first take after relaunch is still fast | G2.1, G2.3 |
| 16 | Add "sync" to the Dictionary, wait a minute (the boost model downloads once), then say "move our weekly sync to Thursday": it comes out "sync", and "the kitchen sink is full" still says "sink" | G2.2 |
| 17 | Hold a hands-free take for 2+ minutes: the HUD keeps up, and the text appears promptly at release | G2.3 |
| 18 | ✅ 2026-10-07. Run Speed Check again: Parakeet's numbers should match the first run (the boost is not part of Speed Check) | G2 regression |
| 19 | ✅ 2026-10-09, log-confirmed (see below). With AirPods connected (as the input, or just connected), dictate a sentence: the text arrives, and no "Audio device changed — take saved" notice appears | AirPods fix below |

**AirPods did not dictate at all (reported 2026-10-08).** Cause, from reading the code, then
confirmed on the owner's Mac (2026-10-09; log line below): opening the AirPods microphone switches the headset to its
call profile, which reconfigures the audio input a moment after the take starts. Vocal
treated every such change as "the device went away" and ended the take at once, so an
AirPods take never got going. Now capture moves its tap to a fresh engine on the input as
it is, and the take carries on: up to three reopens per take, with one short settle-and-
retry if the new format is not ready. Only when that fails does the take end with what was
captured. The fraction of a second spoken while the headset switches is still lost. The
log says `input reconfigured mid-take — reopened at … Hz` each time it happens. On the
owner's Mac, an AirPods take logged exactly one reopen, and the text arrived:

    [com.vocal.app:audio] input reconfigured mid-take — reopened at 24000.000000 Hz (1/3)

24 kHz is the headset's call-profile microphone, so the configuration change the old
code ended the take on was the switch itself. One reopen was enough.

---

## 10. Stress test as a user (2026-10-06): what was proven, and what was not

This container has no macOS, display or microphone, so the real app could not be clicked
through. What was stress-tested is everything a user's actions flow through, in the Swift 6.0
CI image. Each harness was **mutation-tested**: a fixed bug was put back, and the harness
had to catch it.

| Harness | Scale | Result on this branch | Mutation check |
|---|---|---|---|
| `HotkeyFuzzTests`: seeded holds, taps, double-taps, shortcuts, Escape, key bounce and disabled taps, mapped to the app exactly as `AppDelegate` does | 6 key presets × 150 seeds × 60 gestures = 54,000 gestures | 0 violations | Shortcut-during-lock bug: 306 violations. Lock-exit double-tap bug: 784 violations (the first run missed it; an invariant was added) |
| `SessionStressTests`: a fast user (dictations, Escape, command key, snippets) overlapping a jittery engine, through the real `DictationSession` | 30 seeds × 10 takes | Every take delivered once, in press order; history matches; every mic closed; idle; no stale error | Breaking pipeline ordering: 30/30 seeds fail (the first version caught only 1/30; timing was tightened) |
| `RealLifeCorpusTests`: Whisper-shaped emails, chat, numbers/IDs/emails/URLs, code talk, disfluency, names, quotes, long-form | 47 inputs × 4 styles | Non-empty, idempotent, no stray spacing, numbers/emails/URLs exact, no content word lost, Raw unchanged | Digit-collapse bug: caught in all four styles |

**Found by the stress pass and fixed:**
- the review's command-key lock flag (a command could keep the mic open);
- identical-text replacement pasting twice;
- context or commands reaching a remote Ollama;
- cancelled command and Speed Check takes being offered back by Recover;
- the stale HUD hint after a command;
- window buttons on the preview;
- Settings order.

**Found, then fixed on the owner's call:** the ellipsis collapse produced
"Wait... are you serious?" → "Wait. are you serious?", a full stop followed by a
lowercase word. Stage 4 now capitalises the word after any collapsed run of marks
("Wait. Are you serious?", "Really? That worked"), while single marks ("e.g. this",
"3 p.m. today") keep the speaker's casing. Evidence:
`wordAfterACollapsedEllipsisIsCapitalized`, `singleMarksKeepTheSpeakersCasing`, and
the corpus check in `representativeTransformations`. Mutation check: removing the
capitalisation fails 4 expectations across those tests.

**Not verified here; needs the real Mac:** everything in the §9 hardware checklist,
plus:
- how the preview panel looks and how focus behaves;
- HUD animation smoothness;
- audio-device quirks;
- real Whisper/Parakeet/Ollama/Apple-model latency (Speed Check measures this on your
  machine).

## 11. Round 2: cold review and deep QA (2026-10-06)

A second pass over the whole branch, after the first PR push. Glaido was re-checked
first: glaido.com and the review sites are still blocked from this environment, and
search excerpts showed nothing round 1 missed (dictionary import, snippets, a command
key, cloud-only, a 10-minute recording cap). Then two independent methods:

- **Adversarial probes.** I wrote about 90 tricky English inputs and ran them through
  the pipeline, the wake word, local tools, styles and snippets.
- **Three independent code reviewers.** One covered core logic, one the Mac app layer,
  and one privacy, iOS and test quality. Each finding was verified against the code
  before any change.

Every fix below has a regression test, except where marked "Mac-only". For each fix, I
put the bug back and confirmed its test fails (25 mutation runs, all caught).

### Found by the probes (fixed in 82ede5c)

| Defect | Before | After |
|---|---|---|
| Brand capitals at a sentence start | "iPhone is great" → "IPhone…", "um, eBay…" → "EBay…" | Words with an inner capital keep their casing |
| The same, after a collapsed ellipsis | "Wait... iPhone too?" → "Wait. IPhone too?" | "Wait. iPhone too?" |
| Local tools answered the wrong question | "What time is it in Tokyo?" → local time | Only the plain question is answered locally; the rest goes to the model |
| Bad arithmetic | "1,2 plus 1" → 13; 2^1000 printed with 300 invented digits | Malformed numbers go to the model; huge results use scientific form |
| Wake word on ordinary sentences | "Okay vocal warmups…", "Hey vocal coach…", "OK Vocal." → command | Stay dictation |

### Found by the reviewers (fixed in this round)

**Core logic**
- The wake word still fired on a musician's dictation: "Vocal, guitar and bass are
  mixed", "Vocal fix is in the mix". A command verb is now required after "Vocal" in
  every form. After punctuation, a wider set of verbs counts.
- Command-output cleanup cut real first lines: "Here are the steps:", "Okinawa trip:".
  Preambles now match whole words only, and never a line the selection contains.
- Doubled punctuation broke paths: "../config" → "./config", "main..feature" →
  "main.feature". Runs now collapse only where a sentence can end.
- Tiny results printed as a confident "0". They now use scientific form.
- Lowercase style kept dictionary terms inside other words ("Al" kept "Also"). Terms
  now match whole words only.
- An older take's pipeline could erase a newer press's microphone error. Each error
  now belongs to the press that produced it.
- A hands-free take ended when the modifier was held more than 1 s before a shortcut
  key. The shortcut guard now applies regardless of timing.
- The session's privacy flag defaulted to "stays on device", so a caller that forgot
  it would send context off the Mac. It is now a required parameter, and the
  convenience initializer treats its pipeline as leaving the device.

**Privacy**
- *Deleting one history row left its words in the search index.* Proven: the word was
  still in the file's bytes. Delete now optimizes both FTS tables, and FTS5
  `secure-delete` is enabled where supported. Both were proven with SQLite 3.45.
  Mac/iOS-only code.
- The `{clipboard}` snippet saved the clipboard (often a password) to History. History
  now stores "[clipboard]". The Mac also refuses concealed or transient pasteboard
  items.
- Opt-in context was a prompt-injection path:
  - Document text could close its own fence. Fence tags inside the context are now
    defused.
  - Output that copies an address, link or number from the document, or more than two
  of its words, is rejected (`context-copy`).
- Context was read from whatever app was frontmost when cleanup ran, not where the
  take was spoken. The reader is now given the press-time app. Mac-only check.
- Cancelled commands and Speed Check passages could be offered back by "Recover":
  - A cancelled command now deletes its own recording, whatever cancelled it.
  - Speed Check recordings use their own file prefix, which is swept but never
    recovered.
- iOS: `{clipboard}` pasted the last dictation, because auto-copy writes every
  dictation to the clipboard. Vocal's own copy is now ignored. iOS-only.
- The command key was not validated on load (Escape or Caps Lock could be bound).
  Mac-only.

**Upgrades**
- The built-in profile upgrade:
  - recorded version 2 even when a seed write failed;
  - treated a database that failed to open as a fresh install.

  Both now leave the version unrecorded, so the next launch retries.
- Adding claude.ai / chatgpt.com to AI Prompt quietly outranked a user's own browser
  profile, because website routes beat app routes. Those sites are now added only when
  the user has no app-routed profile of their own.
- Dictionary entries from before snippets existed (long or multi-line) silently became
  whole-take snippets. A one-time migration pins them to their old inline behaviour.

**Mac app layer** (Mac-only; compiled by CI, not run on hardware)
- Re-recording the dictation key could revive the replaced command-key monitor as an
  orphan event tap. A stopped monitor now never resumes.
- Closing Settings mid-recording left the Speed Check microphone on. Also:
  - A Start Over during decoding mixed two runs.
  - A cancel while the microphone was opening was lost.

  All three are fixed (window-close observer, run token, start-time cancel).
- The dictation key could end a command take early, and a command press right after a
  dictation press could end that dictation. Each key is now ignored while the other
  holds the microphone, and gating no longer depends on the lagging HUD state.
- A late phase event from the previous take could clear a new press's flag and leave
  the mic open. Only the current take's events clear it now.
- The command tap was not retried after wake. Both taps now retry until both are
  armed.
- Undo after a command acted on the previous dictation. It now says to use ⌘Z in that
  app.
- The preview took keyboard focus while "thinking", which lost typing and made a
  follow-up command read Vocal's own panel:
  - It now takes focus only when the answer is ready.
  - While thinking it shows a Cancel button.
  - A new command or dictation closes a waiting preview first.
- The 30 s deadline was not a hard limit, and Esc never stopped the model. There is
  now a real deadline (`Deadline.run`, tested with work that ignores cancellation),
  and dismissing cancels the call.
- Command polish:
  - A command that heard nothing now says so.
  - Insertion waits a beat for focus to return.
  - A remote-Ollama setup gets an accurate message.
  - An Ollama failure falls back to Apple's model.
  - No stale cloud badge.

### Not changed

- **HotkeyFuzzTests models only the dictation key.** The command key's wiring is
  covered by targeted tests, not by the fuzzer.
- **RealLifeCorpusTests compares content words as a set.** Losing one copy of a
  doubled word would pass it. The doubles themselves ("check in in", "on on") are
  covered by `EnglishCleanupTests`.

### Evidence

- **Linux:** `swift build --build-tests && swift test` in `swift:6.0-noble`: 807 tests
  pass, up from 785 at the start of round 2.
- **SwiftLint:** exits 0. Its warnings are on lines outside this round's changes.
- **Mutation checks:** 25 runs: 7 for the probe fixes and 18 for the review fixes.
  Each re-introduced bug fails its test.
- **Mac and iOS app targets:** compiled by CI only. The Mac items above are verified
  by reading the code, not by running them.


## 12. G2: the fastest English path (2026-10-07)

Built on the owner's go-ahead, after the Speed Check met the G2.1 gate (§9). What shipped
is in the §9 table (G2.1, G2.2, G2.3); checklist items 15–18 cover it on hardware.

**Choices worth knowing**
- Auto still uses Whisper, so mixed-language speech keeps working. Parakeet needs the
  language set to English; Settings → Models and Speed Check each offer one click for it.
- An existing install that had the language pinned to English but never touched the
  Parakeet toggle now uses Parakeet once its model is downloaded. The download runs once
  in the background at the next launch (the usual preload, gated on a previous successful
  model load); until it finishes, and offline, English keeps using Whisper.
- The vocabulary boost only swaps a word when FluidAudio's CTC spotter finds acoustic
  evidence for a Dictionary term. When it changes the text, the take's word timings are
  dropped rather than left contradicting it. The preview never runs the boost.
- Dictionary terms are ranked most-used first everywhere they are used (Whisper's prompt,
  Parakeet's boost, cleanup's protected terms). An exact duplicate is listed once;
  another casing stays, since cleanup protects each exact spelling.
- The preview compares words without case or edge punctuation (Parakeet capitalizes a
  window that starts mid-sentence), restarts the window at a pause when it can, and
  lines up the first hypothesis after a slide so a word at the cut is shown once.

**Not built:** G2.4 (needs insertion timings from your Mac), G2.5 (dropped: Parakeet is
the English engine).

### Independent review (before the push)
A cold reviewer checked every FluidAudio call against the pinned 0.15.6 source (no compile
problems found) and reported four behaviour bugs, each verified and fixed:
1. **The preview matched words exactly.** A window restarting mid-sentence comes back
   capitalized ("Seven," for "seven"), so nothing froze and words got rewritten; a word at
   the cut could show twice or vanish. Fixed: matching ignores case and edge punctuation,
   cuts prefer pauses, and the first hypothesis after a slide is lined up with the carried
   words (by text and by timing). Silence now freezes the words already shown.
2. **Default ON had no fallback.** With English pinned and Parakeet not yet downloaded, an
   offline take would fail where it used Whisper before. Fixed: Parakeet takes a take only
   once its models are on disk, the download runs in the background, and a Parakeet
   failure falls back to Whisper.
3. **The ranking had nothing to rank.** `applyCount`/`lastAppliedAt` were never written.
   Fixed: delivered takes record the entries they used (in place, so the Dictionary keeps
   its order), on Mac and iOS.
4. **The boost was built inside a take.** Fixed: models load and the session builds in the
   background (one shared download), keyed by the term set so a re-ranking does not
   rebuild it; a take uses the boost only when it is ready.
Also: cleanup's protected terms keep each casing again, and `unload` drops a boost build
that finishes afterwards.

### Evidence
- **Linux:** `swift build --build-tests && swift test` in `swift:6.0-noble`: 834 tests pass,
  up from 807. The preview tests passed 8 runs in a row limited to 2 CPUs.
- **SwiftLint:** exits 0; no warnings on the changed lines.
- **Mutation checks:** 25 runs over both passes. Every re-introduced bug that Linux can
  test was caught. One mutant was equivalent and was replaced. One runs on macOS only (the
  use-count write in PersistenceKit): its GRDB code and test are not compiled on Linux.
- **Not verified here:** everything in `ParakeetEngine`, the Mac app, and
  `DatabaseStore.recordDictionaryUse` with its test. They first compile and run in CI's
  macOS jobs. FluidAudio's API use was checked against its pinned source. The boost's
  accuracy and its added latency per take are unmeasured; Speed Check does not include
  the boost.
