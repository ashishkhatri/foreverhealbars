# Forever Heal Bars

Minimalist grid raid frames for healers on WoW Forever.

- **Grid layout.** Compact squares, five per column, one column per group. Works solo, in a party and in raids up to 40.
- **Click-casting.** Bind spells to left, right and middle click, with or without Shift, Ctrl or Alt, then click a frame to cast on that player.
- **Your HoTs.** Small icons in the top-right corner of each frame.
- **Dispellable debuffs.** A colored border, by debuff type, when someone has a debuff you can remove.
- **Incoming heals.** A light green extension on the health bar for heals about to land.
- **Range and aggro.** Out-of-range players fade, and players with aggro get a red outline.

Each frame shows the player's name in their class color and how much health they're missing.

## Install

1. Download the latest `ForeverHealBars-*.zip` from [Releases](https://github.com/ashishkhatri/foreverhealbars/releases).
2. Unzip it into `World of Warcraft\_forever_\Interface\AddOns\`, so you end up with `AddOns\ForeverHealBars\ForeverHealBars.toc`.
3. Log in, type `/fhb` and set up your click-casting.

## Click-casting

`/fhb` opens a small window with a box for each click: left, right and middle, plain or with Shift, Ctrl or Alt. Type a spell name as it appears in your spellbook and press Enter. The spell's icon appears next to the box, and the text turns red if the spell isn't in your spellbook.

- Blank boxes use the defaults: left click targets the player, right click opens their menu.
- You can also type `target` or `menu` in any box.
- Bindings are saved per character.
- Changes made during combat apply when combat ends.

## Commands

Use `/fhb` or `/healbars`.

| Command | What it does |
| --- | --- |
| `/fhb` | Open the click-casting window |
| `/fhb unlock` | Show a handle to drag the frames around |
| `/fhb lock` | Hide the handle |
| `/fhb scale 1.2` | Resize the frames (0.5 to 2) |
| `/fhb reset` | Put the frames back in the default spot and size |

## Releasing

Change the `## Version:` line in `ForeverHealBars.toc` and push to `main`. The Release workflow tags that version, builds `ForeverHealBars-v<version>.zip` and publishes it as a GitHub Release. If a `CF_API_KEY` secret and a `## X-Curse-Project-ID:` line are both present, it also uploads to CurseForge.

## License

MIT
