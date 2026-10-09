# Speed Check — Mac16,5, Version 26.7.1 (Build 25G241)

Recorded 2026-10-07T21:44:25Z with Vocal's built-in Speed Check (docs/17 G0): each passage read once, the same audio decoded by every engine after a warm-up. Release→text = engine decode + text pipeline; insertion is identical across engines and not included.

| Engine | Takes | Release→text p50 | p95 | Real-time factor | WER |
|---|---|---|---|---|---|
| Whisper (openai_whisper-large-v3-v20240930_turbo) | 3 | 689 ms | 707 ms | 18x | 6.4% |
| Parakeet (English) | 3 | 82 ms | 82 ms | 163x | 7.4% |

**Recommendation:** Keep Whisper: Parakeet was faster but noticeably less accurate on your voice.

## Transcripts

- **Whisper (openai_whisper-large-v3-v20240930_turbo)**, passage 1 (11.9 s audio, 689 ms, WER 2.9%): Thanks for sending the draft over. I read it this morning and the structure works well. But the second section repeats the introduction, so let's cut it before we share with the team.
- **Parakeet (English)**, passage 1 (11.9 s audio, 70 ms, WER 2.9%): Thanks for sending the draft over, I read it this morning and the structure works well, but the second section repeats the introduction, so let's cut it before we share with the team.
- **Whisper (openai_whisper-large-v3-v20240930_turbo)**, passage 2 (13.4 s audio, 707 ms, WER 3.4%): Could you move our weekly sync to Thursday afternoon? I have a dentist appointment on Wednesday. I would rather not rush the conversation about the new onboarding flow.
- **Parakeet (English)**, passage 2 (13.4 s audio, 82 ms, WER 6.9%): Could you move our weekly sink to Thursday afternoon I have a dentist appointment on Wednesday, I would rather not rush the conversation about the new onboarding flow.
- **Whisper (openai_whisper-large-v3-v20240930_turbo)**, passage 3 (11.0 s audio, 673 ms, WER 12.9%): The build failed again because the test runner could not fix the configuration file. I think the path changed when we renamed the folder so I fixed it after launch.
- **Parakeet (English)**, passage 3 (11.0 s audio, 82 ms, WER 12.9%): The build failed again because the test runner could not fix the configuration file, I think the path changed when we renamed the folder, so I fixed it after launch.
