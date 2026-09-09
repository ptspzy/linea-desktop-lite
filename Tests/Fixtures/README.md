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
