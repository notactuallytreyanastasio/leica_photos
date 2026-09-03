# glm_funk

Scratch project for driving the `pi` coding agent with **GLM 5.3** served by Fireworks.ai.

## Setup (already done on this machine)

| File | Purpose |
|------|---------|
| `~/.pi/agent/auth.json` | Fireworks API key under the `fireworks` provider (mode 0600) |
| `~/.pi/agent/models.json` | Adds `glm-5p3` and `glm-5p3-flash` to pi's built-in Fireworks provider |
| `~/.pi/agent/settings.json` | Makes `accounts/fireworks/models/glm-5p3` the default model, thinking `medium` |

Alternative to `auth.json`: `export FIREWORKS_API_KEY=...` in your shell.

## Usage

```bash
pi                                  # interactive, defaults to GLM 5.3
pi --thinking max                   # GLM 5.3 with max reasoning
pi --model glm-5p3-flash            # cheaper/faster variant (also accepts images)
pi -p --no-session "prompt here"    # headless one-shot
pi --list-models | grep glm         # see what's registered
```

Inside a session, `/model` switches models and `Ctrl+P` cycles the `enabledModels` list.

## Notes

- Fireworks model IDs: `accounts/fireworks/models/glm-5p3`, `accounts/fireworks/models/glm-5p3-flash`.
- Both report a 1M context window and support tool calling; only Flash accepts image input.
- The `cost` block for `glm-5p3` in `models.json` is copied from GLM 5.2 as a placeholder.
  Update it from https://fireworks.ai/pricing so pi's cost tracking is accurate.
- Thinking levels map to Fireworks `reasoning_effort`: `off` -> none, `low/medium/high` -> high, `max` -> max.
