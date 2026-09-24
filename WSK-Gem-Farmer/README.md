# WSK Gem Farmer v0.1.8 test

Install by replacing the old WSK-Gem-Farmer folder and reloading QQT scripts.
Start outside the intended dungeon entrance. Keep UR configured for automatic
combat and Batmobile loaded with independent free-roam off. No evade code and
no WSK movement holds triggered by nearby mobs.

Boss-room discovery fix:
The original stuck check treated tiny back-and-forth movement as progress. The
new check detects ten seconds without leaving an eight-unit area. Discovery
also switches to recovery if no altar is found within twenty seconds.

Recovery clears stale exploration, then requests paths to reachable points
around the ACTUAL boss-room arrival position: eight directions at radii 18,
30 and 42 units. No fixed world coordinates or assumed screen direction.
Batmobile must supply get_closeby_node and navigate_long_path. Rejected points
are skipped; each accepted target has an eight-second budget. The script scans
for the altar each update and cancels recovery immediately when it is visible.
Recovery does not interact with portals or objects. All portals remain excluded.

The altar/summon phase now has a 120-second overall limit to allow recovery.
Exhausted candidates or timeout stops the script for inspection rather than
looping at a wall indefinitely. Recovery is heuristic; it does not guarantee
coverage of every layout. Other run behavior is retained from v0.1.7.

Look for: Boss search recovery / Boss search point / Altar found during recovery.
Send those lines and Boss diagnostic lines if it still cannot find the pillar.

Validation: simulated local oscillation, reachable-point recovery, rejected
paths, altar discovery handoff, and regression checks. In-game recovery needs
testing on a layout that previously got stuck.
