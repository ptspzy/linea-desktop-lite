# Audio fixture

`reference-004.wav` is a synthetic macOS Tingting voice sample generated for regression testing.

Reference transcript:

```text
当前模型使用 Qwen3-ASR 0.6B 4-bit MLX balanced
```

The test reads this file without playing it.

`spoken-decimal.wav` is also synthetic Tingting speech, generated at rate 155 and converted
to mono 16 kHz signed 16-bit PCM. Its spoken text is `数值是三点一四一五九二六三。`.
Expected formatted output: `数值是3.14159263`. The decimal digits are intentional, not a request
to substitute a known mathematical constant. This fixture is checked through the production
ASR and formatting pipeline, without playback, on both runtime architectures.

The following synthetic Tingting samples use rate 155, mono 16 kHz signed 16-bit PCM.
`make test-quality` checks them through the production model, default hotwords and formatter:

| File | Spoken text | Required result |
| --- | --- | --- |
| `developer-branch.wav` | 分支是 dev 斜杠一点一。 | `分支是dev/1.1` |
| `developer-spelled-branch.wav` | D.E.V.一点一。 | Exactly `dev/1.1`, without requiring a spoken slash or the word "branch" |
| `developer-list.wav` | 第一，修复登录。第二，补充测试。第三，发布版本。 | Three separate numbered lines, preserving every item |
| `developer-paragraphs.wav` | 接口已经修复。换段。接下来补测试。换段。最后发布版本。 | Three paragraphs separated by blank lines, without the commands |

These are reproducible integration fixtures, not human-speech accuracy benchmarks.
