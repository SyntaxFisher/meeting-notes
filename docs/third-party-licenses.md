# Third-party components

[Back to the product overview](../README.md)

Meeting Notes bundles or downloads the following components. Their license texts ship in the app
under `Meeting Notes.app/Contents/Resources/Licenses` (**Settings > About > Licenses** shows that folder).

| Component | Version | Use | License | Bundled license file |
| --- | --- | --- | --- | --- |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (with ggml) | 1.9.5, XCFramework from release `b5454` (same commit), SHA-256 `e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b` | Speech recognition and voice activity detection, inside the transcription helper | MIT | `whisper.cpp-LICENSE.txt` |
| [OpenAI Whisper](https://github.com/openai/whisper) large-v3-turbo, ggml q5_0 conversion | `ggml-large-v3-turbo-q5_0.bin` from [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) revision `5359861c`, SHA-256 `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`, 574 MB | Speech recognition model, downloaded on first use | MIT | `Whisper-model-LICENSE.txt` |
| [Silero VAD](https://github.com/snakers4/silero-vad) v5.1.2, ggml conversion | `ggml-silero-v5.1.2.bin` from [ggml-org/whisper-vad](https://huggingface.co/ggml-org/whisper-vad) revision `9ffd54a1`, SHA-256 `29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf`, 885 KB | Voice activity detection model, downloaded on first use | MIT | `Silero-VAD-LICENSE.txt` |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.17.1 (`NativeTranscription/Package.resolved`) | Offline speaker diarization; its models download on first use | Apache 2.0 | `FluidAudio-LICENSE.txt`, `ThirdPartyLicenses/` |
| [Sparkle](https://sparkle-project.org) | 2.10.0 | Updates (release builds) | MIT | `Sparkle-LICENSE.txt` |

The pinned versions and checksums live in `NativeTranscription/Package.swift` (whisper.cpp),
`NativeTranscription/Sources/MeetingTranscriber/ModelStore.swift` (models) and
`scripts/build.py` (Sparkle). The license texts of whisper.cpp, the Whisper model and Silero VAD
are kept in `NativeTranscription/Licenses/`.
