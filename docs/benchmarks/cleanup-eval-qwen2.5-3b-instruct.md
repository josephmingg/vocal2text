# Cleanup eval — qwen2.5:3b-instruct

- Endpoint: `http://localhost:11434`
- Run: 2026-08-19T21:14:55Z
- Cases: 62
- Temperature: 0.0

| Metric | Value |
|---|---|
| **Hard-rule pass rate (AC-4 ≥ 90%)** | **88.5%** ❌ |
| Delivered-text pass rate | 92.1% |
| Cases fully passing | 52/62 (83.9%) |
| Cases whose delivered text is acceptable | 54/62 |
| Rules passing (cleanup's own output) | 123/139 |
| Rules passing (text the app types) | 128/139 |
| Validator rejections (app delivers stage-2 text) | 2 |
| Provider errors | 0 |
| Median edit distance to reference | 0.12 |
| Latency p50 / p95 | 178 ms / 219 ms |

Two rates, because they answer different questions. **Hard-rule pass rate** asks whether cleanup did its job: a case counts only when the provider answered, the shipping `OutputValidator` accepted the output, and every hard rule held. AC-4 gates on it. **Delivered-text pass rate** asks what the user ended up with, scoring the rules against the text the app actually types — which is the stage-2 transcript whenever cleanup was rejected or failed (FR-7.3). The gap between them is work cleanup declined to do rather than damage it caused. Edit distance is reported, never scored — several wordings can be equally right.

## By category

| Category | Cases | Rules (cleanup) | Rules (delivered) |
|---|---|---|---|
| code-switching | 5/7 | 10/14 | 12/14 |
| fillers | 12/13 | 29/30 | 29/30 |
| protected-terms | 9/9 | 16/16 | 16/16 |
| questions-not-answered | 7/8 | 15/18 | 18/18 |
| self-correction | 12/15 | 37/40 | 37/40 |
| style-banned-words | 2/2 | 4/4 | 4/4 |
| style-british | 1/4 | 4/9 | 4/9 |
| style-ignored | 2/2 | 4/4 | 4/4 |
| zh-punctuation | 2/2 | 4/4 | 4/4 |

## Failures

### mix-004 — code-switching

- Input: `这个API的response有点慢`
- Reference: `这个 API 的 response 有点慢。`
- Output: `这个API的响应有点慢`
- **Failed:** mustContain(API, response) — missing: response
- **Failed:** mustNotContain(接口, 响应) — present: 响应

### mix-005 — code-switching

- Input: `she said 差不多 which basically means close enough`
- Reference: `She said 差不多, which basically means close enough.`
- Output: `差不多意思是差不多。`
- Delivered: `she said 差不多 which basically means close enough` — what the app would type
- **Validator rejected:** `ratio` — the app would deliver the stage-2 text unchanged

### en-fill-007 — fillers

- Input: `hmm right yeah I think that works for me`
- Reference: `Yes, I think that works for me.`
- Output: `hmm right yeah I think that works for me`
- **Failed:** mustNotContain(hmm) — present: hmm

### en-quest-001 — questions-not-answered

- Input: `what's the capital of France`
- Reference: `What's the capital of France?`
- Output: `Paris`
- Delivered: `what's the capital of France` — what the app would type
- **Validator rejected:** `ratio` — the app would deliver the stage-2 text unchanged

### en-corr-005 — self-correction

- Input: `it costs about fifty dollars or rather fifteen`
- Reference: `It costs about fifteen dollars.`
- Output: `it costs about fifty dollars rather than fifteen`
- **Failed:** mustNotContain(fifty) — present: fifty

### en-corr-006 — self-correction

- Input: `we need three no four more testers before launch`
- Reference: `We need four more testers before launch.`
- Output: `we need three more testers before launch`
- **Failed:** mustContain(four) — missing: four

### style-001 — style-british

- Input: `I'll organize the colors in the summary`
- Reference: `I'll organise the colours in the summary.`
- Output: `I'll organize the colors in the summary`
- **Failed:** mustContain(organise, colours) — missing: organise, colours
- **Failed:** mustNotContain(organize, colors) — present: organize, colors

### style-002 — style-british

- Input: `we should analyze the behavior of the new center`
- Reference: `We should analyse the behaviour of the new centre.`
- Output: `we should analyze the behavior of the new center`
- **Failed:** mustContain(behaviour) — missing: behaviour
- **Failed:** mustNotContain(behavior) — present: behavior

### style-008 — style-british

- Input: `can you check the color of the organizer badge`
- Reference: `Can you check the colour of the organiser badge?`
- Output: `can you check the color of the organizer badge`
- **Failed:** mustContain(colour) — missing: colour

### zh-corr-001 — self-correction

- Input: `周五，啊不对，周六`
- Reference: `周六。`
- Output: `周五，周六`
- **Failed:** mustNotContain(周五, 不对) — present: 周五

