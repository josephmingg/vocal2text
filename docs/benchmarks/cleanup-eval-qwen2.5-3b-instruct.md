# Cleanup eval — qwen2.5:3b-instruct

- Endpoint: `http://localhost:11434`
- Run: 2026-08-17T16:57:47Z
- Cases: 62

| Metric | Value |
|---|---|
| **Hard-rule pass rate (AC-4 ≥ 90%)** | **82.0%** ❌ |
| Cases fully passing | 41/62 (66.1%) |
| Rules passing | 114/139 |
| Validator rejections (would deliver stage-2 text) | 1 |
| Provider errors | 0 |
| Median edit distance to reference | 0.17 |
| Latency p50 / p95 | 171 ms / 207 ms |

A case passes only when the provider answered, the shipping `OutputValidator` accepted the output, and every hard rule held. Edit distance is reported, never scored — several wordings can be equally right.

## By category

| Category | Passed | Rules |
|---|---|---|
| code-switching | 1/7 | 7/14 |
| fillers | 13/13 | 30/30 |
| protected-terms | 8/9 | 15/16 |
| questions-not-answered | 6/8 | 14/18 |
| self-correction | 8/15 | 34/40 |
| style-banned-words | 1/2 | 3/4 |
| style-british | 1/4 | 4/9 |
| style-ignored | 2/2 | 4/4 |
| zh-punctuation | 1/2 | 3/4 |

## Failures

### mix-001 — code-switching

- Input: `这个bug我明天fix一下`
- Reference: `这个 bug 我明天 fix 一下。`
- Output: `我明天fix一下这个bug`
- **Failed:** mustContain(bug, fix) — missing: bug, fix

### mix-002 — code-switching

- Input: `我们先review一下这个PR再merge`
- Reference: `我们先 review 一下这个 PR 再 merge。`
- Output: `我们先review一下这个PR再merge。`
- **Failed:** mustContain(review, PR, merge) — missing: review, PR, merge

### mix-003 — code-switching

- Input: `打开GitHub看一下那个issue`
- Reference: `打开 GitHub 看一下那个 issue。`
- Output: `打开GitHub看一下那个issue`
- **Failed:** mustContain(issue) — missing: issue

### mix-004 — code-switching

- Input: `这个API的response有点慢`
- Reference: `这个 API 的 response 有点慢。`
- Output: `这个API的响应有点慢。`
- **Failed:** mustContain(API, response) — missing: API, response
- **Failed:** mustNotContain(接口, 响应) — present: 响应

### mix-006 — code-switching

- Input: `先跑一下test，pass了再deploy`
- Reference: `先跑一下 test，pass 了再 deploy。`
- Output: `先跑一下test，pass了再deploy`
- **Failed:** mustContain(test, deploy) — missing: test, deploy

### mix-007 — code-switching

- Input: `这个feature要不要加到roadmap里`
- Reference: `这个 feature 要不要加到 roadmap 里？`
- Output: `这个feature要不要加到 roadmap 里`
- **Failed:** mustContain(feature, roadmap) — missing: feature

### en-quest-001 — questions-not-answered

- Input: `what's the capital of France`
- Reference: `What's the capital of France?`
- Output: `Paris`
- **Failed:** mustNotContain(Paris) — present: Paris
- **Failed:** mustContain(France) — missing: France

### en-term-004 — protected-terms

- Input: `the error is in vocal2text not in the SDK`
- Reference: `The error is in vocal2text, not in the SDK.`
- Output: `the error is in vocal2text not in the SDK`
- **Failed:** mustNotContain(vocal 2 text, Vocal2Text) — present: Vocal2Text

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

### en-corr-007 — self-correction

- Input: `call her on Tuesday scratch that she's away call her Thursday`
- Reference: `Call her Thursday.`
- Output: `call her Thursday`
- **Validator rejected:** `ratio` — the app would deliver the stage-2 text unchanged

### en-corr-009 — self-correction

- Input: `I'll take the train sorry I'll drive`
- Reference: `I'll drive.`
- Output: `I'll take the train.`
- **Failed:** mustContain(drive) — missing: drive

### en-corr-010 — self-correction

- Input: `sorry I'm late the traffic was bad`
- Reference: `Sorry I'm late, the traffic was bad.`
- Output: `I'm late the traffic was bad`
- **Failed:** mustContain(sorry, traffic) — missing: sorry

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

### style-005 — style-banned-words

- Input: `the amazing thing is it just works`
- Reference: `The remarkable thing is it just works.`
- Output: `the amazing thing is it just works`
- **Failed:** mustNotContain(amazing) — present: amazing

### style-008 — style-british

- Input: `can you check the color of the organizer badge`
- Reference: `Can you check the colour of the organiser badge?`
- Output: `can you check the color of the organizer's badge`
- **Failed:** mustContain(colour) — missing: colour

### zh-corr-004 — self-correction

- Input: `先部署到测试环境，我是说生产环境`
- Reference: `先部署到生产环境。`
- Output: `先部署到测试环境。`
- **Failed:** mustContain(生产环境) — missing: 生产环境

### zh-corr-005 — self-correction

- Input: `对不起我迟到了，路上堵车`
- Reference: `对不起我迟到了，路上堵车。`
- Output: `我迟到了，路上堵车`
- **Failed:** mustContain(对不起, 堵车) — missing: 对不起

### zh-punct-001 — zh-punctuation

- Input: `今天的会议取消了,下周再说`
- Reference: `今天的会议取消了，下周再说。`
- Output: `今天的会议取消了，下周再说。`
- **Failed:** mustNotContain(,) — present: ,

### zh-quest-001 — questions-not-answered

- Input: `法国的首都是哪里`
- Reference: `法国的首都是哪里？`
- Output: `巴黎`
- **Failed:** mustNotContain(巴黎) — present: 巴黎
- **Failed:** mustContain(法国) — missing: 法国

