# Speed Check — Mac16,5, Version 26.7.1 (Build 25G241)

Recorded 2026-10-07T20:08:21Z with Vocal's built-in Speed Check (docs/17 G0): each passage read once, the same audio decoded by every engine after a warm-up. Release→text = engine decode + text pipeline; insertion is identical across engines and not included.

| Engine | Takes | Release→text p50 | p95 | Real-time factor | WER |
|---|---|---|---|---|---|
| Whisper (openai_whisper-large-v3-v20240930_turbo) | 3 | 693 ms | 700 ms | 19x | 7.4% |
| Parakeet (English) | 3 | 77 ms | 81 ms | 177x | 6.4% |

**Recommendation:** Turn on Parakeet for English: it was faster and about as accurate on your voice.

## Transcripts

- **Whisper (openai_whisper-large-v3-v20240930_turbo)**, passage 1 (13.1 s audio, 693 ms, WER 8.8%): Thanks for sending the draft over. I already did this morning and the structure works well. But the second section repeats the introduction, so let's cut it before we share with the team.
- **Parakeet (English)**, passage 1 (13.1 s audio, 71 ms, WER 5.9%): Thanks for sending the draft over. I read it this morning and the structure works well, but the second section repeats an introduction, so let's cut it before we share with the team.
- **Whisper (openai_whisper-large-v3-v20240930_turbo)**, passage 2 (13.0 s audio, 691 ms, WER 3.4%): Could you move our weekly sink to Thursday afternoon? I have a dentist appointment on Wednesday and I would rather not rush the conversation about the new onboarding flow.
- **Parakeet (English)**, passage 2 (13.0 s audio, 81 ms, WER 3.4%): Could you move our weekly sink to Thursday afternoon? I have a dentist appointment on Wednesday, and I would rather not rush the conversation about the new onboarding flow.
- **Whisper (openai_whisper-large-v3-v20240930_turbo)**, passage 3 (12.5 s audio, 700 ms, WER 9.7%): The build failed again because the test runner could not find the configuration file. I think the path changed when we rename the folder so I'll fix it after lunch.
- **Parakeet (English)**, passage 3 (12.5 s audio, 77 ms, WER 9.7%): The build failed again because the test runner could not find the configuration file, I think the path changed when we rename the folder, so I'll fix it after lunch.
