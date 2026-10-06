# Glaido Study, Cold Review & English Improvement Plan (2026-10-06)

> **What this is.** A study of Glaido ("the world's fastest dictation"), a cold review of
> Vocal as it stands on `main` (`43059de`), and a phased plan to make Vocal's **English**
> dictation the best it can be. Chinese and Burmese are out of scope on purpose. This page
> recommends; the only code it touches is none. Every finding below was verified by reading
> or reproducing it on `main`, unless it is marked *plausible*.
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

### 4.3 App layer

*(The parallel app-layer review results are merged in §4.4 once complete.)*

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

These are also asked directly in the session. Nothing in G1 depends on them; G2–G5 do.

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
