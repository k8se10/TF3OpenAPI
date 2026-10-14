# Left-hand traffic and existing saves (build 40420, 2026-10-14)

Requirement (user, 2026-10-14): native left-hand traffic; saves made with the other left-hand-traffic mod
(`left_hand_traffic_1`) and right-hand saves made without any such mod must load with no corruption or crash;
vehicles and people must be reset where lanes change under them.

## What the engine does (read, not seen in the game)

1. **Lanes are saved as built.** `ecs::component::TransportNetwork` has its own loader
   (`ecs::ComponentManager::Load`, `0x14019b510`) and is built only when a build is applied
   (`construction_builder_util::ConstructTransportNetwork` `0x140a083c0`, from `construction_builder_util::Apply`
   `0x1409fae80`). A street type or a building script changed by a mod affects only what is built or rebuilt
   after it; everything already in a save keeps its lanes, whichever mods are active at load
   (`re_notes/engine/streets.md` point 6). Loading a save never turns a lane under a vehicle.
2. **Every build re-plans what used the rebuilt pieces.** `Apply` runs two helpers on the transport networks
   it removes or replaces:
   - `VehicleUpdateHelper` (`~VehicleUpdateHelper` `0x142585a40`, `transport/VehicleUpdateHelper.cpp`): for
     the vehicles whose paths touch them - a vehicle en route (`TransportVehicleState` 1) gets
     `vehicle_util::SetPathToStationDeferred` (`0x142663140`, a new path to its next stop); one going to a
     depot (state 3) a new path there (`0x142662d50`); parked vehicles on removed networks are unparked
     (`vehicle_util::Unpark` `0x142663910`). It asserts that no vehicle is left without a path.
   - `SimEntityUpdateHelper` (`0x14256d6e0` / `0x14256e810`, `SimEntityUpdateHelper.cpp`): people and cargo.
     `CutSimEntityPaths` (`0x142573f30`) cuts their move paths at the removed networks;
     `ApplySimPersonIdleData / MovingData / AtTerminalData / AtVehicleData / AtBuildingData` and
     `ApplySimCargoData` give each one a valid state again (`SimPersonValidState`, `SimCargoValidState`).
   This is the game's own reset, the one it uses whenever a player upgrades or replaces a road under traffic.

## Consequences

- **A save made with `left_hand_traffic_1`, loaded with ours:** everything already built keeps the lanes that
  mod gave it. Nothing to reset at load. What is built afterwards follows our rules; where ours equal that
  mod's (streets: the same rule - two-way types' road lanes turned, one-way types kept), the new pieces join
  the old ones as before. Where they differ (inside some buildings), a rebuilt building gets our lanes and the
  game re-plans its vehicles as for any rebuild.
- **A right-hand save loaded with ours:** its roads stay right-hand; new roads would be left-hand. Mixed sides
  at a joint are not a corruption (lanes are joined by position, `StreetGeometry` reads each lane's own flag)
  but would drive wrongly. So such a save must either stay right-hand (the mod leaves it alone) or be
  converted as a whole: every street and building rebuilt through the game's own build commands, a few at a
  time, so that the two helpers above re-plan every vehicle and person on the way.
- **Removing the mod from a left-hand save:** it loads (lanes are saved); new roads would be right-hand.
  Converting back needs the mod present.

## Not yet known (to read or to see on a copy of a save)

- What happens to a vehicle standing ON a piece being rebuilt (not only routed over it): the helpers re-plan
  paths, the vehicle's position on the old edge has to be mapped somewhere - read `PrepareSimPersonData`,
  `GetNewId` (`con_builder_util_network.cpp`) and the old-to-new edge maps (`new2oldEdges` in proposal
  results) before converting a save.
- Whether the game refuses a rebuild with vehicles on it (a collision / "in the way" check), and what the
  script build command returns then.
- Where `busAndTramRight` is used.
