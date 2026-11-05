---
status: accepted
---

# No in-app health data visualization; Liquid Glass for chrome, Apple Health is the sole data surface

The app's UI previously aimed at showing sleep/activity data in-app (a "Dashboard" with sleep front and center, a planned `SleepDetail` hypnogram screen) — CLAUDE.md's design system explicitly called this out as the product's purpose. We decided to cut that entirely: the app becomes purely a sync engine + setup/status utility, and Apple Health is the only place health data is ever viewed. This is a deliberate extension of the app's own stated ethos ("a background gateway, not for screen time"), taken to its logical end rather than a reversal of it — but it does reverse the "the number is the hero" framing and the planned hypnogram screen, which is why it's recorded here.

Consequence: the Dashboard keeps only connection state, sync freshness, battery, and a sync-now action — no metric tiles, no per-datum health colors used for actual data display (they remain, incidentally, as icon tints on status elements). "How did I sleep?"/"am I sleeping?" moves entirely to Shortcuts/Siri (see `GetSleepStateIntent`) and to the Health app itself, not to an in-app screen.

Alongside this, the visual language moves toward Apple's Liquid Glass (iOS 26, already the project's actual deployment target — see the drift this corrected in CLAUDE.md's overview table) for chrome/status elements (`MBStatusPill` first), while data-adjacent surfaces keep the existing dark OLED + Aurora indigo palette. This mirrors the same split as the data decision: system chrome doesn't compete with content, and there's no content left to protect from glass except the setup/status flows themselves.
