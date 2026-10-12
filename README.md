# Domino Line

**A free dynamic racing line for Assetto Corsa that reacts to your speed and learns how you drive.**

Blocks ahead of you go green → yellow → orange → red as a braking zone approaches. Red blocks stand up; when you brake they turn green and fall like dominoes. Corner by corner, it learns how hard your car can really push and moves the brake points accordingly.

> Requires [Content Manager](https://acstuff.club/app/) + Custom Shaders Patch 0.2.0 or newer.

## Features

- **Dynamic line**: coloured by your current speed, up to 3000 m ahead. No distance limit.
- **3D domino effect**: red blocks stand up and fall as you brake.
- **3 styles**: blocks, arrows or a solid line.
- **Per-corner learning**: clean, faster passes move the brake point later; going off or spinning moves it earlier. Conservative by default, aggressive mode optional.
- **Corner timing**: best time per corner and how much you gained since you started.
- **Your own line**: if you find a faster line through a corner, it replaces the AI line, but only after beating the AI line's virtual time at the limit *and* your own best time on the AI line.
- **AI expected lap time**: what a car on the AI line at the limit would do, vs. your best lap.
- **Track map** with every corner labelled and coloured by what was learned.
- **Compact HUD** window and **Ctrl+Shift+D** to toggle the line.
- Everything is saved per car + track + layout.

## Install

1. Download the latest zip from [Releases](../../releases).
2. Drag it into Content Manager and click **Install** (or copy `apps/lua/DominoLine` into `assettocorsa/apps/lua/`).
3. In game, open the apps bar on the right and enable **Domino Line** (and optionally **Domino Line HUD**).
4. Turn off the game's own ideal line (Ctrl+I).

## How it works

- Reads the track's AI line (`fast_lane.ai`) every 2 m and computes its curvature.
- From curvature, grip and downforce it gets the max speed at every point, then a braking ramp backwards from each corner.
- Each block is coloured by your speed vs. the allowed speed at that point. Where they cross is your brake point.
- Learning adjusts grip per corner from your clean passes. The car's real acceleration is learned at full throttle for the virtual lap time.

See `apps/lua/DominoLine/README.txt` for tuning tips.

## License

MIT, free to use, modify and share. Credit appreciated.
