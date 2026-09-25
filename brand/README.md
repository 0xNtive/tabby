# tabby brand

**tabby** (always lowercase) organizes Claude Code terminal tabs. The mascot is a tabby cat whose forehead stripes are three colored terminal tabs, one per session.

- Tagline: **Every Claude Code tab, at a glance.**
- One-liner: *AI tab names, calm colors and live status for every Claude Code session. Free, local and native to Claude.*
- Voice: calm, friendly and precise. Short sentences, concrete nouns, no hype. There's a little cat in the UI; the copy isn't cutesy.

## Files

| file | use |
|---|---|
| `logo.svg` | full-color mark, for dark or light backgrounds |
| `logo-mono.svg` | single-color template (menu bar, favicons on busy backgrounds) |
| `app-icon.svg` / `app-icon-1024.png` | macOS app icon (cream cat on a dark squircle) |
| `../island/AppIcon.icns` | built from `app-icon.svg` (`qlmanage` → `sips` → `iconutil`) |

## Color

| token | hex | role |
|---|---|---|
| ink | `#262b35` | cat body, dark UI surfaces |
| night | `#14161b` | page background |
| cream | `#f4ede0` | text on dark, eyes |
| stripe-blue | `#77b7f4` | session 1 |
| stripe-green | `#7fc489` | session 2 |
| stripe-orange | `#e79e6b` | session 3 (primary accent / CTA) |
| blush | `#e394c1` | nose, highlights |
| waiting | `#ffa138` | "needs you" |

These are the Tabby Dusk accents from `lib/themes.js`, so the brand and the product's default theme are the same palette.

## Type

- Display: a friendly rounded or soft grotesque. On Apple surfaces use SF Pro Rounded; on the web pick a distinctive open-source equivalent (not Inter or Roboto).
- Code: a monospace with clear quotes and slashes.

## Motion

Motion is small and springy, like a cat's ear twitch. Dots pop, bells wiggle, the island breathes. Always respect Reduce Motion.
