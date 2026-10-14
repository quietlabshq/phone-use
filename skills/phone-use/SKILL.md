---
name: phone-use
description: Operate iPhone simulators and configured physical iPhones through the phone-use MCP tools. Use for phone UI tasks, not unrelated desktop control.
---

# Phone use

Start with `list_phones`, select the intended phone, then call `screenshot`. Pass its `phone_id` consistently; it is required when multiple phones are available. Discovery or capture alone does not establish that hardware input works. For physical setup or pairing failures, read [the test-day guide](../../docs/test-day.md).

Use a screenshot-decide-one-action-screenshot loop. Inspect the new screenshot to verify the action before continuing. Prefer `open_app` for launching apps and `press_home` for recovery. Tap the center of a visible target. If a tap fails, take a fresh screenshot and retry once with fresh coordinates; if it fails again, stop and report what happened.

Coordinates are pixels in the returned image, not iOS points or unscaled native-display pixels. Screenshots preserve aspect ratio with the longest edge capped at 1344 pixels. Use the latest image dimensions, especially after rotation. To scroll down, swipe near the horizontal center from about 70% to 30% of image height, avoiding controls and screen edges; verify the result before another swipe.

Dismiss the keyboard with `press_key` using `escape`, or tap a safe area outside the field. To replace field contents, focus the field, use `press_key` with `key: "a", modifiers: ["command"]`, then type. If select-all is unsupported, use `backspace` with a bounded `repeat` (1-100) and verify before repeating. `type_text` and app names accept US-ASCII only, at most 100 characters per call. Report unsupported input rather than silently transliterating it or changing the requested content.

Stay within the user's existing explicit authorization. Never send, post, pay, or delete without it, and do not ask again when it was already granted for the action. Never enter a password the user has not provided. Stop at Face ID or a passcode challenge and report the need for the user's intervention. Avoid blindly retrying actions that could have taken effect despite an error.
