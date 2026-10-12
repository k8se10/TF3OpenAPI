# Converting station mods: first look

Status: assessment only. Nothing is built. Read from two Transport Fever 2 station mods (a modular rail
station and the modular station it is built on) and from the game's own scripts, build 40408.

## What a Transport Fever 2 station mod is made of

| Part | In the two mods | What the converter does with it today |
|---|---|---|
| Models (`res/models/model/station/...`) | 39 each | converted like any other model |
| Meshes, materials, textures | 38 / 7 / 27 | converted |
| The construction (`res/construction/.../*.con`) | 1, about 1,100 lines of script | not converted |
| Modules (`*.module`) | 10, 80 to 210 lines of script each | not converted |
| The mod's own helper scripts (`res/scripts/modules/*.lua`) | 2, about 600 lines | not converted |
| Pictures for the build menu (`res/textures/ui/construction/...`) | a few | copied as textures, not placed |

So the models are the easy half. The station itself is a program: the `.con` builds the station from its
parameters and modules each time the player changes it, by calling the game's construction libraries.

## Do the libraries it calls still exist?

Every library function the two mods call, checked against the newer game's scripts:

| Library (as the mods `require` it) | In the newer game | Functions the mods use that are gone |
|---|---|---|
| `constructionutil` | `scripts/construction/constructionutil.lua` | none |
| `modulesutil` | `scripts/construction/modulesutil.lua` | none |
| `paramsutil` | `scripts/construction/paramsutil.lua` | `makeTrackTypeParam`, `makeTrackCatenaryParam` |
| `colliderutil` | `scripts/construction/colliderutil.lua` | `createBox` |
| `modules/trainstationutil` | `stations/rail.zip` -> `rail/trainstationutil.lua` | none |
| `vec2`, `vec3` | `scripts/vec2`, `scripts/vec3` | none |
| `transf` | `scripts/transf.lua`, marked obsolete; it hands out the newer matrix library | `mul`, `transl`, `rotZTransl`, `rotZYXTransl` are not in that small file itself, but the matrix library it returns has functions of those names |

The libraries moved (a plain `require "constructionutil"` no longer finds them) and three functions are gone,
but most of what the mods lean on is still there. That is far better than rebuilding a station from nothing,
and it is why this looks possible where the Transport Fever 1 -> 2 converter gave up.

## What is not known yet

1. **Whether the libraries behave the same.** Same names do not mean same arguments or same results. Each of
   the calls the mods make has to be compared with the newer game's version.
2. **What the newer game expects a construction to return.** A Transport Fever 2 `updateFn` returns models,
   track and street pieces, terminals, ground faces, terrain alignment and slots for modules. The newer game
   has its own station metadata (`stations/station_metadata.tl`) and its own stations to compare against.
3. **File names and places.** The newer game's constructions are `.con.lua` and modules `.module.lua`; where a
   mod's own helper scripts have to live to be found is to be read off a working mod.
4. **The models' own station data**: lanes for passengers, terminals, the things the game's own station models
   carry (`transportNetworkProvider`). Whether the old form is upgraded on load like vehicle data is.
5. **Modules that plug into the game's own station.** One of the two mods adds modules to the stock modular
   station; those depend on the stock station's slot layout, which will have changed.

## How to go about it

1. Read one of the newer game's own modular rail stations (`.con.lua`, a platform module, a track module) and
   lay it beside the Transport Fever 2 mod's: file by file, result by result.
2. Convert the simpler of the two mods by hand-written rules: carry the scripts over with their `require`s
   pointed at the new places, supply the three missing functions, convert the models.
3. Load it. Fix what the game says. Only then decide how much of this can be a general rule and how much is
   particular to this family of stations.

It will take several rounds in the game. Vehicles took four before the first one ran.
