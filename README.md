<img src="logo.png" width="128" alt="Forever Heal Bars logo">

# Forever Heal Bars

Minimalist grid raid frames for healers on WoW Forever.

- **Grid layout.** Compact squares, five per column, one column per group. Works solo, in a party and in raids up to 40.
- **Click-casting.** Bind spells to left, right, middle, mouse 4, mouse 5 and the mouse wheel (up and down), with or without Shift, Ctrl or Alt, then click (or scroll over) a frame to cast on that player. Wheel directions with nothing bound still zoom the camera.
- **Your HoTs.** Small icons in the top-right corner of each frame.
- **All debuffs.** Small icons in the bottom-left corner for every debuff on the player, whether or not you can remove it (up to four). Works in combat.
- **Dispellable debuffs.** When someone has a debuff you can remove, their whole frame pulses in the debuff's color (blue magic, magenta curse, red disease, teal poison), with a thin outline in the same color.
- **Incoming heals.** A light green extension on the health bar for heals about to land, that slides out from the health edge when a heal starts, then softly pulses until it lands. HoTs (Renew, Rejuvenation, Regrowth) from anyone add a softer, steady segment of the same green after it showing what they still have left to heal, shrinking as they tick. When the game doesn't report a HoT's amount (common for other players' HoTs), the spell rank's base healing is used.
- **Resources (optional).** Tick **Show mana / rage / energy bar** in settings for a thin bar along the bottom of each frame: mana (blue), rage (red) or energy (yellow). Off by default. While a player is casting, the mana that cast will cost shows as a lighter section at the end of their bar.
- **Shields.** A thin white bar along the top of a frame shows how much absorb a shield (like Power Word: Shield) has left. It works in combat.
- **Pets.** Each player's pet gets a narrower frame right beside its owner's, in a darker shade of the owner's class color, with the same click-casting. Untick **Show pets beside their owners** in `/fhb` (or type `/fhb pets`) to hide them.
- **Buff reminders.** Out of combat, frames flash the icon of any of your buffs that player is missing or that runs out within 5 minutes: Fortitude, Divine Spirit and Shadow Protection for priests, Arcane Intellect for mages (mana users only), Mark of the Wild for druids (and Thorns on tanks). Only buffs you know are checked, and the group versions count. They hide in combat. Untick **Flash buffs players need from you** in `/fhb` (or `/fhb buffs`) to turn them off.
- **Roles.** A small tank, healer or damage icon in the top-left corner of each frame, from the group's role assignment (or the raid's main tank mark).
- **Your target.** The frame of whoever you have targeted gets a white outline.
- **Range and aggro.** Out-of-range players are dimmed, and players with aggro get a red outline (faint for high threat).
- **Lock button.** A small padlock above the top-left corner unlocks the frames. While unlocked, drag anywhere on them to move them, and drag the bottom-right corner to resize: right for wider frames, down for taller ones. Click the padlock again to lock.
- **Settings button.** A small gear next to the padlock opens the settings window (same as `/fhb`).

Each frame shows the player's name over a health bar in their class color. When someone takes damage, the chunk they just lost shows as a striped segment in the same color, then smoothly drains down and fades out (about a second, or sooner if their health changes again).

Blizzard's own party and raid frames are hidden by default (the raid tools tab on the left edge stays). Untick **Hide Blizzard party and raid frames** in `/fhb`, or type `/fhb blizzard`, then `/reload` to bring them back.

## Install

1. Download the latest `ForeverHealBars-*.zip` from [Releases](https://github.com/ashishkhatri/foreverhealbars/releases).
2. Unzip it into `World of Warcraft\_forever_\Interface\AddOns\`, so you end up with `AddOns\ForeverHealBars\ForeverHealBars.toc`.
3. Log in. Healers start with click-casting already set up (see below); type `/fhb` to change it.

## Click-casting

`/fhb` (or the gear next to the padlock) opens a window with a box for each click: left, right, middle, mouse 4, mouse 5, wheel up and wheel down, plain or with Shift, Ctrl or Alt. Drag a spell from your spellbook (the **Spellbook** button opens it) onto one of the squares: there's one for each click, plain or with Shift, Ctrl or Alt. Drag a square onto another to move it (the two swap). Right-click a square to clear it, or right-click an empty one to set it to Target or Menu. The spell's icon appears next to the box, and the text turns red if the spell isn't in your spellbook.

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

Every command also has a control in the settings window (`/fhb`): checkboxes for lock, pets, buff reminders and Blizzard frames, a scale slider, and buttons for reset and debug.

| Command | What it does |
| --- | --- |
| `/fhb` | Open the click-casting window |
| `/fhb unlock` | Unlock the frames to drag them (same as the padlock) |
| `/fhb lock` | Lock them again |
| `/fhb scale 1.2` | Scale everything, text included (0.5 to 2) |
| `/fhb buffs` | Turn buff reminders on or off |
| `/fhb pets` | Show or hide pet frames beside their owners |
| `/fhb blizzard` | Turn hiding Blizzard's party and raid frames on or off |
| `/fhb debug` | List the debuffs and buffs on your target (or yourself) and what the game reports about them |
| `/fhb reset` | Put the frames back in the default spot, size and scale |

## Releasing

Change the `## Version:` line in `ForeverHealBars.toc` and push to `main`. The Release workflow tags that version, builds `ForeverHealBars-v<version>.zip` and publishes it as a GitHub Release. If a `CF_API_KEY` secret and a `## X-Curse-Project-ID:` line are both present, it also uploads to CurseForge.

## License

MIT
