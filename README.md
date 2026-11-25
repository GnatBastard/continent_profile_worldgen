# Continent Profile Worldgen — terrain test build

Create a new **singlenode** world and enable this mod.

Current terrain settings:

- summit: about **3,800 m**
- nominal coastline ellipse: **26.0 km × 24.8 km**
- ellipse rotation: **−8°**
- macro domain warp: **6 km amplitude**, about **4 km feature scale**
- micro domain warp: **5 nodes amplitude**, about **32-node feature scale**
- post-profile vertical roughness: **off**
- one dominant mainland; small offshore islands allowed
- procedural coastal spawn
- no climate or biome generation yet

The micro warp changes the X/Z sample position rather than adding vertical noise directly, so broad buildable regions remain broad while the ground gains subtle local texture.

This package also includes the safe optional-node alias resolver so missing `mapgen_dirt`, `mapgen_dirt_with_grass`, or `mapgen_sand` aliases fall back rather than crashing mapgen.
