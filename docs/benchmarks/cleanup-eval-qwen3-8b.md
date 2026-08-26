# Cleanup eval — qwen3:8b

- Endpoint: `http://localhost:11434`
- Run: 2026-08-17T21:16:18Z
- Cases: 62

| Metric | Value |
|---|---|
| **Hard-rule pass rate (AC-4 ≥ 90%)** | **89.6%** ❌ |
| Cases fully passing | 52/62 (83.9%) |
| Rules passing | 121/135 |
| Validator rejections (would deliver stage-2 text) | 3 |
| Provider errors | 2 |
| Median edit distance to reference | 0.10 |
| Latency p50 / p95 | 9550 ms / 28638 ms |

A case passes only when the provider answered, the shipping `OutputValidator` accepted the output, and every hard rule held. Edit distance is reported, never scored — several wordings can be equally right.

## By category

| Category | Passed | Rules |
|---|---|---|
| code-switching | 6/7 | 13/14 |
| fillers | 12/13 | 29/30 |
| protected-terms | 8/9 | 14/14 |
| questions-not-answered | 8/8 | 18/18 |
| self-correction | 13/15 | 38/40 |
| style-banned-words | 0/2 | 1/2 |
| style-british | 2/4 | 6/9 |
| style-ignored | 2/2 | 4/4 |
| zh-punctuation | 1/2 | 3/4 |

## Failures

### mix-005 — code-switching

- Input: `she said 差不多 which basically means close enough`
- Reference: `She said 差不多, which basically means close enough.`
- Output: ``
- **Validator rejected:** `empty` — the app would deliver the stage-2 text unchanged
- **Failed:** mustContain(差不多) — missing: 差不多

### en-term-001 — protected-terms

- Input: `run kubectl apply against the staging cluster`
- Reference: `Run kubectl apply against the staging cluster.`
- Output: `(none)`
- **Provider error:** timedOut

### en-corr-008 — self-correction

- Input: `the file is in downloads wait no it's on the desktop`
- Reference: `The file is on the desktop.`
- Output: ``
- **Validator rejected:** `empty` — the app would deliver the stage-2 text unchanged
- **Failed:** mustContain(desktop) — missing: desktop

### en-corr-010 — self-correction

- Input: `sorry I'm late the traffic was bad`
- Reference: `Sorry I'm late, the traffic was bad.`
- Output: `I'm late. The traffic was bad.`
- **Failed:** mustContain(sorry, traffic) — missing: sorry

### style-002 — style-british

- Input: `we should analyze the behavior of the new center`
- Reference: `We should analyse the behaviour of the new centre.`
- Output: `we should analyze the behavior of the new center`
- **Failed:** mustContain(behaviour) — missing: behaviour
- **Failed:** mustNotContain(behavior) — present: behavior

### style-004 — style-banned-words

- Input: `this is a really awesome result honestly`
- Reference: `This is a very good result.`
- Output: `(none)`
- **Provider error:** timedOut

### style-005 — style-banned-words

- Input: `the amazing thing is it just works`
- Reference: `The remarkable thing is it just works.`
- Output: `the amazing thing is it just works`
- **Failed:** mustNotContain(amazing) — present: amazing

### style-008 — style-british

- Input: `can you check the color of the organizer badge`
- Reference: `Can you check the colour of the organiser badge?`
- Output: `Can you check the color of the organizer badge?`
- **Failed:** mustContain(colour) — missing: colour

### zh-fill-002 — fillers

- Input: `嗯，就是说，我们明天再讨论`
- Reference: `我们明天再讨论。`
- Output: ``
- **Validator rejected:** `empty` — the app would deliver the stage-2 text unchanged
- **Failed:** mustContain(明天, 讨论) — missing: 明天, 讨论

### zh-punct-001 — zh-punctuation

- Input: `今天的会议取消了,下周再说`
- Reference: `今天的会议取消了，下周再说。`
- Output: `今天的会议取消了,下周再说`
- **Failed:** mustNotContain(,) — present: ,

