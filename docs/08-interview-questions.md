# Interview — Open Questions for the Product Owner

Answers to these questions tune the plan. Defaults are chosen so work can proceed if a
question is unanswered — each shows the assumption currently baked into the PRDs.

Answered so far:

- ✅ **Languages**: English + Chinese for v1; **Burmese deferred** (owner decision, 2026-08-16).

## A. Hardware & OS (determines engine + API choices)

**A1. Which Mac do you have (chip + RAM)?**
Default assumption: Apple Silicon (M-series), ≥16 GB RAM.
Why it matters: model size selection (large-v3-turbo vs distil/small), whether local MLX LLM
cleanup is comfortable alongside your other work.

**A2. Which macOS version are you on, and are you willing to run the current major release?**
Default assumption: macOS 26 (Tahoe) or newer.
Why it matters: Apple's `SpeechAnalyzer`/`SpeechTranscriber` and Foundation Models framework
require macOS 26+; targeting it removes whole subsystems we'd otherwise build.

**A3. Which iPhone (model + iOS version)?**
Default assumption: iPhone 15 Pro or newer, iOS 26.
Why it matters: on-device model sizes that run acceptably; Action Button availability changes
the iOS push-to-talk story.

**A4. Do you have a paid Apple Developer account ($99/yr), or free Apple ID only?**
Default assumption: **paid** (needed for painless personal iPhone installs; free-ID apps
expire every 7 days and some entitlements are unavailable).
Why it matters: iOS sideload lifetime, iCloud sync entitlement, keyboard extension signing.

## B. Chinese specifics

**B5. Simplified or Traditional Chinese output (or both, switchable)?**
Default assumption: Simplified primary, conversion toggle later.

**B6. Do you code-switch mid-sentence (mixing English words inside Chinese sentences)?**
Default assumption: yes — engine choice favors models with strong zh↔en code-switching.

**B7. Should Chinese output use full-width punctuation（。，！？）with no spaces between**
**Latin and Han characters, or "pangu" spacing around Latin words?**
Default assumption: full-width punctuation; thin spacing around Latin/digits (typographic
convention), applied by a deterministic formatter, not the LLM.

## C. Interaction design

**C8. Preferred push-to-talk key on Mac?** Options: Fn/Globe hold (Wispr Flow default; needs
key interception), Right-⌘ hold, Right-⌥ hold, or a chord like ⌥Space.
Default assumption: **Right-⌥ (right Option) hold** to start; Fn support investigated as an
upgrade. Also: hold-to-talk AND a double-tap-to-lock ("hands-free") mode — want both?

**C9. While you speak, do you want live partial text on screen (streaming preview in the HUD),**
**or is a simple "listening" indicator enough?**
Default assumption: waveform + streaming partial text in a small floating HUD near the cursor
or screen-bottom, Wispr-Flow-style.

**C10. After release, should text be typed instantly as-is and then *replaced* when AI cleanup**
**finishes (fast but visibly swaps), or wait and insert only the cleaned text (one clean paste,**
**slightly slower)?**
Default assumption: wait-and-insert-final (cleanup is fast enough locally; swapping text in
arbitrary apps is fragile).

**C11. On iPhone, what matters more: a custom keyboard with a mic button inside other apps,**
**or a fast open-app→dictate→auto-copy flow (Action Button → dictate → paste anywhere)?**
Default assumption: both, phased — main-app flow first (M6), keyboard extension second (M7),
because keyboard extensions carry real constraints (see iOS PRD).

## D. AI cleanup

**D12. For Mac cleanup, do you already run Ollama (or LM Studio)? Which models are pulled?**
Default assumption: we bundle in-process MLX cleanup (no external dependency) and also support
Ollama if present.

**D13. Any cloud provider you'd want as optional fallback (OpenAI, Groq, DeepSeek, none)?**
Default assumption: none configured; the provider abstraction supports any OpenAI-compatible
URL + key if you add one later.

**D14. Default cleanup aggressiveness:** light touch (fillers + punctuation only) vs full
rewrite-to-style?
Default assumption: light touch as the global default profile; heavier styles opt-in per app
profile.

## E. Data & sync

**E15. Should transcript history sync between Mac and iPhone?**
Default assumption: v1 local-only per device; optional iCloud (CloudKit private DB) sync as a
later milestone — offline-first, sync is only a convenience layer.

**E16. Keep audio recordings in history, or text only?**
Default assumption: keep audio (Opus, ~30 MB per recorded hour) with a retention setting
(e.g. auto-delete audio after 30 days, keep text forever).

**E17. Any encryption requirement beyond FileVault/iOS data protection?**
Default assumption: rely on OS-level encryption; no app-layer crypto.

## F. Product

**F18. App name?** Repo is `vocal2text`; docs use codename **Vocal**.

**F19. Menu-bar icon / HUD aesthetic preferences?** (minimal monochrome vs colorful waveform)
Default assumption: minimal monochrome menu-bar icon; subtle dark HUD with waveform.

**F20. Anything you dictate a LOT that we should optimize for early?** (emails? code comments?
chat? Chinese social apps like WeChat?) This drives the built-in profile set and test fixtures.
