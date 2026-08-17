# Running Vocal on your iPhone (Phase B — B1 and the on-device gates)

Companion to `docs/10-running-on-your-mac.md`. Everything below needs a
physical iPhone, a Mac with Xcode, and your Apple ID — none of it can be done
in CI, which is why it is a checklist rather than a claim.

Sections 2–4 (keyboard, share sheet) assume a paid Developer Program build.
On a free Apple ID they are unreachable by construction, not by oversight —
see §1.

## 0. What CI already proves, and what it does not

Green CI means the package tests pass on Linux and macOS, and that
`VocalIOS` plus its three embedded extensions **compile** for the iOS
simulator, unsigned. It proves nothing about signing, App Groups, Full Access,
microphone behaviour, background residency, battery, or whether text actually
lands in WeChat. Those are the acceptance criteria AC-i1 … AC-i9 in
`docs/02-prd-ios.md`, and this document is how you close them.

## 1. First build to the device

Which of the two builds you want is decided by your Apple account, so start
there.

**A free (personal) Apple ID cannot provision App Groups.** This is not a
degradation you can shrug off: all four iOS targets declare that entitlement,
so Xcode fails signing outright — *"Personal development teams do not support
the App Groups capability"* — and nothing installs. Free provisioning profiles
also expire after 7 days, so the app stops launching until you re-run it from
Xcode.

| | Free Apple ID (`make generate-free`) | Paid Developer Program (`make generate`) |
|---|---|---|
| Main-app dictation, Action Button, history, dictionary | ✅ | ✅ |
| Dynamic Island / Lock Screen indicator | ✅ | ✅ |
| Keyboard (mode D2b) | ❌ | ✅ |
| Share-sheet voice-note import | ❌ | ✅ |
| Re-install every | 7 days | 1 year |

### 1a. Free Apple ID

```sh
brew install xcodegen        # once
make generate-free           # writes VocalFree.xcodeproj
open VocalFree.xcodeproj
```

`scripts/free-account-spec.py` derives the spec from `project.yml`, dropping
every App Group entitlement and the two extensions that exist only to cross
that boundary. The widget stays: the Dynamic Island reads its state from
ActivityKit, never from the shared container, so it needs no entitlement.

No source changes are involved — the app already treats an unreachable
container as "no bridge" (`BridgeStore.appGroup()` returns nil,
`isBridgeAvailable` goes false), and the Keyboard settings screen says so
rather than failing silently.

Set **Team** on `VocalIOS` and `VocalWidgets`, pick your iPhone, Run. Then skip
to §1c; §2 and §3 do not apply.

What you lose is one paste: dictate in the app, the transcript auto-copies, and
you paste it into WeChat with the system keyboard. That is mode D1 in docs/02,
and it is the flow that shipped in v0.1 and has the most road behind it.

### 1b. Paid Developer Program

```sh
brew install xcodegen        # once
make generate                # writes Vocal.xcodeproj
open Vocal.xcodeproj
```

`make generate` **resets the signing Team on every target**. In Xcode, for each
of the four iOS targets — `VocalIOS`, `VocalKeyboard`, `VocalShareExt`,
`VocalWidgets` — open Signing & Capabilities and:

1. Set **Team** to your team.
2. Confirm **App Groups** is present and `group.com.vocal.shared` is ticked.
   Xcode registers the group on first use; if the checkbox is empty, press `+`
   and type it exactly. All four targets must agree — the identifier lives in
   one place in `project.yml` (`VOCAL_APP_GROUP`) and is written into both the
   entitlement and an Info.plist key that `BridgeKit.AppGroup` reads at runtime.

Then pick your iPhone as the run destination and run the `VocalIOS` scheme.

### 1c. Trusting the build

The phone refuses to launch a sideloaded app until you allow it: **Settings →
General → VPN & Device Management → Developer App → Trust**. First install
only.

### First run on device

- Grant the microphone prompt.
- Settings → Speech model → **Warm Up Model**. This downloads ~600 MB once.
  Do it on Wi-Fi, with the app in the foreground.
- Try the Action Button path: Shortcuts → find "Start Dictation" → assign to the
  Action Button, then press it.

**Record for AC-i1:** cold-launch-to-listening and release-to-clipboard for a
5-second utterance, from a screen recording. The budget is ≤ 1.5 s and ≤ 2.5 s.

## 2. Installing the keyboard

1. Settings → General → Keyboard → Keyboards → **Add New Keyboard…** → Vocal.
2. Tap **Vocal** in that list → switch on **Allow Full Access**.

Full Access is not optional and not cosmetic: on current iOS a keyboard cannot
open its container app or read a shared App Group container without it
(`docs/02` §6). The system prompt is alarming by design. The check that the
prompt is not warranted here is in the build itself — the `VocalKeyboard`
target links `CoreModels` and `BridgeKit` and nothing else (`project.yml`), and
CI's `keyboard-offline-guard` job fails the build if any networking symbol
appears in that target or in `BridgeKit`.

## 3. The keyboard round trip (AC-i3)

The design is D2b: the keyboard never records. It asks the app to.

1. In Vocal: Settings → Keyboard → **Arm for 5 minutes**.
   The orange recording indicator appears and stays lit. That is expected and
   is the whole reason the default window is short — an armed session holds a
   live audio session so iOS keeps the app resident.
2. Switch to Messages (then WeChat, Safari, Mail). Globe → Vocal keyboard.
3. Tap **Dictate**, speak, tap **Stop**.
4. The transcript appears in the review row; tap ✓ to insert.
   (Settings → Keyboard → "Insert without asking" skips the review.)

With no session armed, the mic key reads **Open Vocal** and deep-links once.
There is no API to send you back — that bounce is real and documented.

**Record for AC-i3:** a screen recording per app (Messages, WeChat, Safari form
field, Mail), and the matching history rows showing which profile ran.

**Spike measurement still open (`docs/02` §3.1):** time from the mic-key tap to
the app actually starting to record, with the app backgrounded and
audio-active. That is the Darwin-notification delivery latency the PRD flags as
`[verify]`. Measure it with a stopwatch on a screen recording across ~10 presses
and write the p50/p95 into `docs/benchmarks/`.

## 4. Share-sheet import (AC-i5)

From WhatsApp or Voice Memos, share a voice note → **Save to Vocal**. Vocal only
appears in share sheets that carry `public.audio` items.

Then in Vocal: Settings → Voice notes → **Transcribe all**. Progress and Cancel
are live; a file that fails three times is retired and shown with its reason
rather than retried forever.

**Record for AC-i5:** the resulting history row, and confirm a dictionary entry
corrected the import (that is half of AC-i8).

## 5. Lock-screen capture and the Dynamic Island (AC-i6)

Start a dictation in the app, lock the phone, keep talking for three minutes,
unlock, stop.

- The Dynamic Island should show the take throughout — compact while you use
  other apps, expanded on long-press, and on the Lock Screen as a banner.
- The elapsed timer is rendered by the system (`Text(timerInterval:)`), so it
  ticks whether or not the app is scheduled.

**Record for AC-i6:** a screen recording covering the whole three minutes, and
the completed history row.

## 6. Airplane mode (AC-i4)

Turn on Airplane Mode after the model has been downloaded, then repeat §1, §3
and §4. Everything must behave identically. Screen-record it.

## 7. Battery (NFR-i3)

Xcode → Debug Navigator → Energy Impact, or Settings → Battery after a normal
day. Note separately: a day with ~30 dictations and **no** armed sessions, and a
day where you armed sessions as you would in practice. The second number is the
one the 5-minute default is protecting.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Keyboard says "Needs Full Access" | Full Access off | §2 step 2 |
| Keyboard settings say "Unavailable" | App Group entitlement missing or unprovisioned | Expected on a free-account build (§1a). On a paid build, §1b step 2 |
| Mic key always says "Open Vocal" | No armed session, or the app was killed so its status went stale (90 s) | Arm again; leave Vocal running |
| Nothing inserts after a take | Reply arrived for a different request, or older than 2 min | Both are deliberate guards — retry; the transcript is still in History |
| Share sheet has no "Save to Vocal" | The item is not `public.audio` (e.g. a video container) | Out of scope this pass |
| Orange dot stays on | An armed capture session is running | Settings → Keyboard → Disarm now |
