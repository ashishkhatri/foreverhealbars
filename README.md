# Forever Heal Bars

Minimalist grid raid frames for healers on WoW Forever.

- **Grid layout.** Compact squares, five per column, one column per group. Works solo, in a party and in raids up to 40.
- **Click-casting.** Bind spells to left, right and middle click, with or without Shift, Ctrl or Alt, then click a frame to cast on that player.
- **Your HoTs.** Small icons in the top-right corner of each frame.
- **Dispellable debuffs.** The whole frame turns the debuff type's color (blue magic, purple curse, brown disease, green poison) when someone has a debuff you can remove.
- **Incoming heals.** A light green extension on the health bar for heals about to land.
- **Range and aggro.** Out-of-range players fade, and players with aggro get a red outline (faint for high threat).
- **Lock button.** A small padlock above the top-left corner unlocks the frames. While unlocked, drag anywhere on them to move them, and drag the bottom-right corner to resize: right for wider frames, down for taller ones. Click the padlock again to lock.

Each frame shows the player's name in their class color and how much health they're missing.

## Install

1. Download the latest `ForeverHealBars-*.zip` from [Releases](https://github.com/ashishkhatri/foreverhealbars/releases).
2. Unzip it into `World of Warcraft\_forever_\Interface\AddOns\`, so you end up with `AddOns\ForeverHealBars\ForeverHealBars.toc`.
3. Log in. Healers start with click-casting already set up (see below); type `/fhb` to change it.

## Click-casting

`/fhb` opens a small window with a box for each click: left, right and middle, plain or with Shift, Ctrl or Alt. Type a spell name as it appears in your spellbook and press Enter. The spell's icon appears next to the box, and the text turns red if the spell isn't in your spellbook.

- Any plain left or right click with nothing bound targets the player or opens their menu.
- **Reset to class defaults** restores the bindings below.
- You can also type `target` or `menu` in any box.
- Bindings are saved per character.
- Changes made during combat apply when combat ends.

### Class defaults

| | Priest | Druid | Paladin | Shaman | Mage |
| --- | --- | --- | --- | --- | --- |
| Left | Flash Heal | Healing Touch | Flash of Light | Healing Wave | target |
| Right | Renew | Rejuvenation | Holy Light | Lesser Healing Wave | menu |
| Shift + left | Greater Heal | Regrowth | | Chain Heal | |
| Shift + right | Power Word: Shield | | Blessing of Protection | | |
| Ctrl + left | Dispel Magic | Remove Curse | Cleanse | Cure Poison | Remove Lesser Curse |
| Ctrl + right | Cure Disease | Cure Poison | | Cure Disease | |
| Alt + left | target | target | target | target | |
| Alt + right | menu | menu | menu | menu | |

Each binding casts the highest rank you know. Spells you haven't learned yet show in red in `/fhb` and start working once you learn them. Other classes keep plain left click to target and right click for the menu.

## Commands

Use `/fhb` or `/healbars`.

| Command | What it does |
| --- | --- |
| `/fhb` | Open the click-casting window |
| `/fhb unlock` | Unlock the frames to drag them (same as the padlock) |
| `/fhb lock` | Lock them again |
| `/fhb scale 1.2` | Scale everything, text included (0.5 to 2) |
| `/fhb reset` | Put the frames back in the default spot, size and scale |

## Releasing

Change the `## Version:` line in `ForeverHealBars.toc` and push to `main`. The Release workflow tags that version, builds `ForeverHealBars-v<version>.zip` and publishes it as a GitHub Release. If a `CF_API_KEY` secret and a `## X-Curse-Project-ID:` line are both present, it also uploads to CurseForge.

## License

MIT
