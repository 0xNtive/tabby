# tabby brand

**tabby** (always lowercase) organizes Claude Code terminal tabs. The mark is a geometric tabby cat: a rounded-square head, two ears, and three forehead stripes with rounded ends, like tabs hanging from a tab bar. It was generated as a vector with Higgsfield (Recraft V4.1) and recolored to the palette below; the geometry is used unchanged everywhere.

- Tagline: **Every Claude Code tab, at a glance.**
- One-liner: *AI tab names, calm colors and live status for every Claude Code session. Free, local and native to Claude.*
- Voice: calm, friendly and precise. Short sentences, concrete nouns, no hype. There's a little cat in the UI; the copy isn't cutesy.

## Files

| file | use |
|---|---|
| `logo.svg` | the mark, exactly as exported (transparent background, Harbor eyes) |
| `logo-2048.png` | the mark as a 2048 px transparent PNG |
| `app-icon.svg` / `app-icon-1024.png` | macOS app icon: the mark on a Harbor squircle |
| `../island/AppIcon.icns` | built from `app-icon-1024.png` (`sips` → `iconutil`) |
| `../island/Sources/Brand.swift` | the same paths in code: the menu-bar template icon (stripes and eyes cut out) and the blinking footer cat |

## Color

| token | hex | role |
|---|---|---|
| Harbor | `#0f3a3c` | ground: app icon, website, dark surfaces |
| Foam | `#eef6f2` | text on Harbor |
| Marmalade | `#f4913e` | the cat, and the one accent color |
| Tab Sky | `#7cc4f0` | session color in illustrations |
| Tab Rose | `#f59ab1` | session color in illustrations |
| Tab Moss | `#a7d98f` | session color in illustrations |

Marmalade on Harbor is 5.2:1; Foam on Harbor is 11:1. Session colors appear only where they stand for sessions (tabs, dots), never as UI accents.

## Type

- Display and text: Outfit (a friendly geometric grotesk). On Apple surfaces, SF Pro Rounded.
- Code: IBM Plex Mono.

## Motion

Motion is small and springy, like a cat's ear twitch. Dots pop, bells wiggle, the island breathes, the cat blinks. Always respect Reduce Motion.
