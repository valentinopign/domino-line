DOMINO LINE v0.8 - Dynamic racing line for Assetto Corsa
========================================================

A racing line that reacts to YOUR speed. Blocks ahead turn from green to
yellow, orange and red as a braking zone approaches. Red blocks stand up;
when you brake they turn green and fall like dominoes. It also learns,
corner by corner, how hard you can push your car on each track.

REQUIREMENTS
- Content Manager + Custom Shaders Patch (CSP) 0.2.0 or newer.
- A track with an AI line (ai/fast_lane.ai). Almost all tracks have one.

INSTALL
1. Drag the .zip into Content Manager and click Install.
   (Or copy apps\lua\DominoLine into your assettocorsa\apps\lua\ folder.)
2. Turn off the game's own ideal line (Ctrl+I) so they don't overlap.
3. On track: move the mouse to the right edge -> apps bar -> "Domino Line".

READING THE LINE
- Green: you have margin.
- Yellow / orange: a braking zone is coming.
- Red: at your current speed you can't make that part of the track.
  When the red reaches your car, BRAKE.
- The window shows "Brake in X m", a bar that fills up as the brake point
  gets closer, and the target speed of the next corner.

SHORTCUT AND HUD
- Ctrl+Shift+D turns the line on/off without opening the window.
- "Domino Line HUD" (separate app in the apps bar): a small window with just
  the brake call, the bar and the next corner speed. Handy while racing.

TABS
- Drive: line on/off, style (Blocks / Arrows / Line), 3D domino, learning on/off.
- Learning: conservative or aggressive mode, track map with corner labels,
  corner table (8 per page), backup / restore / reset.
- Settings: physics and visual tuning.

LEARNING
- Clean pass faster than the target -> that corner's grip goes up and its
  brake point moves later.
- Off track (4 wheels out) or spin -> grip goes down, brake point moves earlier.
- Clean but slow pass -> no change.
- Only counts if you entered the corner from the start of its zone
  (leaving the pits or restarting mid-corner is ignored).
- Conservative by default (max +3% per pass). Aggressive adapts in 1-2 laps
  but can learn from a lucky pass.
- Changes are small on purpose: +10% grip is roughly +5% corner speed,
  which moves the brake point a few metres. Check the "Brake" column.
- Corner timing: every pass is timed over the same stretch of track
  (about 220 m before the apex to 80 m after). The table shows your best
  clean time per corner and the Gain: best vs. your first 3 clean passes.
  The total at the top is how much time per lap you have gained.
- Saved automatically per car + track + layout in this app's folder
  (learn_*.txt). Backup / Restore keeps one manual save point.

YOUR OWN LINE (new in v0.8)
- The path starts as the track's AI line. If you find a faster line through a
  corner, Domino Line can switch to YOUR line in that corner only.
- To avoid "learning" a line that's just faster than your early slow laps,
  your line only replaces the AI line if one clean pass beats BOTH:
    1. the AI line's virtual time at the limit (computed from the physics
       model with no safety margin), and
    2. your own best real time while following the AI line (within 1.5 m).
  So you need at least one clean pass on the AI line in that corner first.
- If you later drive the AI line faster than your own, it switches back.
- The Line column shows AI or YOU per corner. "Reset my lines" goes back to
  the AI line everywhere without touching the rest of the learning.

AI EXPECTED LAP TIME
- Above the map: the lap time a car following the AI line at the limit would
  do (purple), with an uncertainty range, and your best lap. When you beat
  it, the AI time turns green and your time turns purple.
- The model learns your car's real acceleration at full throttle, so the
  expected time gets more accurate after a few laps.

TUNING
- Warns you too late       -> lower Braking or Margin.
- Warns you too early      -> raise Braking or Margin.
- Fast corners look slow   -> raise Lateral grip or Downforce.
- Line hidden by asphalt   -> raise Height.

Author: legg
