# The engine's source tree, as the executable names it

Read 2026-10-13 from build 40420. The executable carries the path of a source file wherever that file
has an assertion or a log line, so the list below is every source file with at least one of those - not
every file of the engine. 893 files. It is the map used to decide what to reverse-engineer next and to
tell which system a function belongs to (a function that refers to one of these paths is from that file).
The build path in front of each name is left out.

| Part | Files | What it is |
| --- | --- | --- |
| `train_fever` | 753 | the game itself (the name is that of the series' first game) |
| `framework` | 107 | shared base: core types, file system, Lua binding, mods, platform, renderer base, resources, interface toolkit |
| `gamelib` | 22 | mod hub, publisher SDK, player profile |
| `third_party` | 11 | boost, fmt |

## `framework/src/framework/cooking/handlers` (1)

`MipMapHandler.cpp`

## `framework/src/framework/core` (24)

`Cast.h`, `Clock.h`, `Config.cpp`, `CowVector.h`, `EnumBitset.h`, `FreeIdsCache.h`, `LoopResults.h`, `PimplPtr.h`, `PmrFixedPoolResource.h`, `RefCell.h`, `StringRep.h`, `ThreadDataProvider.h`, `ThreadPool.cpp`, `ThreadPool.h`, `ValuePtr.h`, `Vector.h`, `build_config.cpp`, `format.h`, `lang_util.cpp`, `lang_util.h`, `log_genericConverter.h`, `map_util.h`, `string_util.cpp`, `utf8_util.cpp`

## `framework/src/framework/core/error` (3)

`Exception.cpp`, `checked_exception.h`, `exc_util.h`

## `framework/src/framework/core/image` (7)

`LTGA.cpp`, `Rgbe.cpp`, `RgbeIO.cpp`, `image_util.cpp`, `png_util.cpp`, `screenshot_util.cpp`, `texture_conversion_util.h`

## `framework/src/framework/core/math` (5)

`hermite.cpp`, `hermite.h`, `hermite_multiple.cpp`, `interpolation_util.h`, `random_util.cpp`

## `framework/src/framework/core/third_party/vma` (1)

`vk_mem_alloc.h`

## `framework/src/framework/filesystem` (7)

`CachedBaseFileSystem.cpp`, `DefaultBaseFileSystem.cpp`, `DirectBaseFileSystem.cpp`, `FileChangeTracker.cpp`, `ModFilterBaseFileSystem.cpp`, `filesystem_legacy_util.cpp`, `filesystem_util.cpp`

## `framework/src/framework/io` (7)

`FileIO.cpp`, `JsonConverterContext.h`, `Path.cpp`, `ZIP.cpp`, `filesystem_util.cpp`, `fstream.cpp`, `serial_std.h`

## `framework/src/framework/localization` (1)

`LanguageRep.cpp`

## `framework/src/framework/lua` (13)

`Converter.h`, `Loader.cpp`, `StackConverter.h`, `State.cpp`, `StateProvider.cpp`, `Value.cpp`, `Value.h`, `Value_genericConverter.h`, `lua_call.cpp`, `lua_debug_util.cpp`, `luabridge.h`, `stack_conv_common.h`, `state_util.cpp`

## `framework/src/framework/mod` (6)

`ModDesc_genericConverter.h`, `ModRep.cpp`, `ScriptParam_converter.h`, `ScriptParam_genericConverter.h`, `ValueParam_converter.h`, `mod_util.cpp`

## `framework/src/framework/model` (1)

`MetadataMap.h`

## `framework/src/framework/platform` (5)

`BasicGamepad.cpp`, `StandardSaveGameBackend.cpp`, `backend_factory.cpp`, `gamepad_util.cpp`, `platform_types.h`

## `framework/src/framework/platform/sdl` (5)

`SdlBackend.cpp`, `SdlGamepad.cpp`, `SdlMouseCursor.cpp`, `SdlWindow.cpp`, `sdl_surface_util.cpp`

## `framework/src/framework/renderer` (7)

`DescriptorSetRep.cpp`, `IRenderContext.h`, `ValidationRenderContext.cpp`, `converter.h`, `memory_util.cpp`, `pipeline_util.h`, `tex_load_util.cpp`

## `framework/src/framework/res` (4)

`ResTypeRep.h`, `res_util.cpp`, `res_util_rep.h`, `serial_res.h`

## `framework/src/framework/ui/react` (9)

`IncrementalStorage.cpp`, `NodeStorage.cpp`, `PropsStorage.cpp`, `StateStorage.cpp`, `const_tree.cpp`, `react_framework.cpp`, `scripting_interface.cpp`, `transform.cpp`, `translate.cpp`

## `framework/src/framework/voronoi` (1)

`Voronoi.cpp`

## `gamelib/src/gamelib/modhub` (4)

`ModHubBackendProvider.cpp`, `ModTagLocalization.cpp`, `modhub_types_genericConverter.h`, `modhub_util.cpp`

## `gamelib/src/gamelib/modhub/internal` (3)

`RequestHandler.cpp`, `RequestHandler.h`, `RequestProcessor.cpp`

## `gamelib/src/gamelib/modhub/local` (1)

`LocalModHubBackend.cpp`

## `gamelib/src/gamelib/modhub/modio` (3)

`ModioModHubBackend.cpp`, `PlatformSpecificNone.hpp`, `PlatformSpecificSteam.hpp`

## `gamelib/src/gamelib/modhub/ui` (2)

`ModBackendDataFetcher.cpp`, `ModBrowserDataProvider.cpp`

## `gamelib/src/gamelib/pdxsdk` (2)

`PdxHelper.cpp`, `PlatformSpecificSteam.hpp`

## `gamelib/src/gamelib/profile` (6)

`AchievementRep.cpp`, `PlayerStat.cpp`, `PlayerStatRep.cpp`, `ProfileDataCommon.h`, `backend_factory.cpp`, `profile_util.cpp`

## `gamelib/src/gamelib/profile/steam` (1)

`SteamUserProfileBackend.cpp`

## `third_party/boost/libs/asio/include/boost/asio/detail` (2)

`resolver_service.hpp`, `win_iocp_socket_service.hpp`

## `third_party/boost/libs/asio/include/boost/asio/impl` (3)

`connect.hpp`, `read_until.hpp`, `write.hpp`

## `third_party/boost/libs/asio/include/boost/asio/ip` (1)

`basic_resolver.hpp`

## `third_party/boost/libs/exception/include/boost/exception/detail` (1)

`exception_ptr.hpp`

## `third_party/boost/libs/graph/include/boost/graph` (1)

`topological_sort.hpp`

## `third_party/fmt/include/fmt` (3)

`base.h`, `chrono.h`, `format.h`

## `train_fever/include/vulkan` (3)

`vulkan.hpp`, `vulkan_format_traits.hpp`, `vulkan_funcs.hpp`

## `train_fever/src/Game` (36)

`Application.cpp`, `CostRep.cpp`, `DataLogger.cpp`, `EnvironmentalMap.cpp`, `Game.cpp`, `GameRes.cpp`, `GameSim.cpp`, `GameState.cpp`, `GameStateLegacyHandler.cpp`, `GameTime.cpp`, `GlobalSettings.cpp`, `GlobalUtil.cpp`, `MarkerManager.cpp`, `NameRep.cpp`, `PlayerStats.cpp`, `Renderer.cpp`, `Serializer.cpp`, `achievements.cpp`, `cargo_util.cpp`, `collision_shape_lib.cpp`, `construction_rep_util.cpp`, `crashdb_helper.cpp`, `game_io.h`, `game_legacy_util.cpp`, `game_metadata_util.cpp`, `game_mission_util.cpp`, `game_res_util.cpp`, `game_util.cpp`, `game_verify.cpp`, `init_game_util.cpp`, `journal_util.h`, `keybinding_conflicts.cpp`, `lua_loader_factory.cpp`, `maintenance_util.cpp`, `player_util.cpp`, `register_metadata.cpp`

## `train_fever/src/Game/Engine` (14)

`ColorMap.cpp`, `ColorMap.h`, `FramebufferHelper.cpp`, `GLContext.cpp`, `HdrHelper.cpp`, `LightingHelper.cpp`, `ParticleRenderer.cpp`, `ProgramManager.cpp`, `RenderHelper.cpp`, `ShadowMap.cpp`, `ShipFoamRenderer.cpp`, `SsaoHelper.cpp`, `WaterWaveRenderer.cpp`, `shadow_map_util.cpp`

## `train_fever/src/Game/Terrain` (25)

`AutoGroundTexRep.cpp`, `EngineTerrain.cpp`, `GrassRenderer.cpp`, `GroundTextureData.cpp`, `GroundTexture_converter.h`, `MaterialIndexManager.cpp`, `MeshConstructor.h`, `PatchRenderDataProvider.cpp`, `RenderDataManager.cpp`, `Terrain.cpp`, `TerrainRenderer.cpp`, `TextureGrid.cpp`, `TextureGrid.h`, `ViewTerrain.cpp`, `auto_ground_texture_util.cpp`, `ground_tex_util.cpp`, `heightmap_util.cpp`, `map_util.cpp`, `sub_terrain_util.cpp`, `terrain_alignment_list_util.cpp`, `terrain_alignment_list_util.h`, `terrain_gen_util.cpp`, `terrain_modification_util.cpp`, `terrain_util.cpp`, `vegetation_util.cpp`

## `train_fever/src/Game/Terrain/nodes` (70)

`AbsMapLayerGeneratorNode.cpp`, `AddFloatLayerGeneratorNode.cpp`, `AddMapLayerGeneratorNode.cpp`, `AmboccMapLayerGeneratorNode.cpp`, `AssetOutputNode.cpp`, `AxpbyPointLayerGeneratorNode.cpp`, `BiomesInputNode.cpp`, `BiomesOutputNode.cpp`, `CliffMapLayerGeneratorNode.cpp`, `CombineMapLayerGeneratorNode.cpp`, `CompareMapLayerGeneratorNode.cpp`, `CompareMapLayerGeneratorNode.h`, `ConstantFloatLayerGeneratorNode.cpp`, `ConstantMapLayerGeneratorNode.cpp`, `ConstantPointCloudLayerGeneratorNode.cpp`, `ConstantPointLayerGeneratorNode.cpp`, `DataInputNode.cpp`, `DataMapLayerGeneratorNode.cpp`, `DataOutputNode.cpp`, `DisplaceMapLayerGeneratorNode.cpp`, `DistanceMapLayerGeneratorNode.cpp`, `DitheringNoiseMapLayerGeneratorNode.cpp`, `DotPointLayerGeneratorNode.cpp`, `Erosion2MapLayerGeneratorNode.cpp`, `ErosionMapLayerGeneratorNode.cpp`, `FractalNoiseMapLayerGeneratorNode.cpp`, `GaussMapLayerGeneratorNode.cpp`, `GradientMapLayerGeneratorNode.cpp`, `GradientNoiseMapLayerGeneratorNode.cpp`, `HeightmapInputNode.cpp`, `HeightmapOutputNode.cpp`, `HerpMapLayerGeneratorNode.cpp`, `InputDataMapLayerGeneratorNode.cpp`, `InputParamLayerGeneratorNode.cpp`, `LaplaceMapLayerGeneratorNode.cpp`, `LerpMapLayerGeneratorNode.cpp`, `LinearGradientMapLayerGeneratorNode.cpp`, `MapClampMapLayerGeneratorNode.cpp`, `MappedWhiteNoiseMapLayerGeneratorNode.cpp`, `MaskCombineMapLayerGeneratorNode.cpp`, `MaskMapLayerGeneratorNode.cpp`, `MaterialBackgroundOutputNode.cpp`, `MaterialOutputNode.cpp`, `MesaMapLayerGeneratorNode.cpp`, `MinMaxMapLayerGeneratorNode.cpp`, `MixMapLayerGeneratorNode.cpp`, `ModuloMapLayerGeneratorNode.cpp`, `MulFloatLayerGeneratorNode.cpp`, `MulMapLayerGeneratorNode.cpp`, `NormalDistributionMapLayerGeneratorNode.cpp`, `NormalizeMapLayerGeneratorNode.cpp`, `PWConstMapLayerGeneratorNode.cpp`, `PWLerpMapLayerGeneratorNode.cpp`, `PercolationMapLayerGeneratorNode.cpp`, `PointsMapLayerGeneratorNode.cpp`, `PowFloatLayerGeneratorNode.cpp`, `RadialGradientMapLayerGeneratorNode.cpp`, `RandomPointCloudLayerGeneratorNode.cpp`, `RasterizerMapLayerGeneratorNode.cpp`, `RidgeMapLayerGeneratorNode.cpp`, `RidgedNoiseMapLayerGeneratorNode.cpp`, `RiverMapLayerGeneratorNode.cpp`, `ScaleAddMapLayerGeneratorNode.cpp`, `ScalePointCloudLayerGeneratorNode.cpp`, `ScriptableLayerGeneratorNode.cpp`, `SimplexNoiseMapLayerGeneratorNode.cpp`, `TextureMapLayerGeneratorNode.cpp`, `TransformMapLayerGeneratorNode.cpp`, `VoronoiNoiseMapLayerGeneratorNode.cpp`, `WhiteNoiseMapLayerGeneratorNode.cpp`

## `train_fever/src/Game/Terrain/procedural` (6)

`ClimateRep.cpp`, `LayerGeneratorNodeRep.cpp`, `TerrainGeneratorRep.cpp`, `converter_terrain.h`, `layer_generator_util.cpp`, `layer_nodes.cpp`

## `train_fever/src/Game/Terrain/procedural/Generators` (4)

`Layers.cpp`, `RidgeGenerator.cpp`, `RiverGenerator.cpp`, `TextureLoadGenerator.cpp`

## `train_fever/src/Game/Terrain/procedural/utils` (3)

`Percolation.cpp`, `heightmap_util.cpp`, `kernel_util.h`

## `train_fever/src/Game/Terrain/render_data` (2)

`GrassData.cpp`, `MaterialData.cpp`

## `train_fever/src/Game/Terrain/rep` (1)

`GrassTypeRep.cpp`

## `train_fever/src/Game/UI/Actions` (27)

`AreasRenderable.cpp`, `BasicAction.cpp`, `BuilderMovement.cpp`, `Bulldozer.cpp`, `CachedProposalEngine.cpp`, `CameraAction.cpp`, `CircleRenderable.cpp`, `ConstructionBuilder.cpp`, `CrosswalkModifier.cpp`, `FollowAction.cpp`, `LaneModifier.cpp`, `ModuleBuilder.cpp`, `ProposalAction.cpp`, `ProposalEngine.cpp`, `Selector.cpp`, `StreetBuilder.cpp`, `StreetTerminalBuilder.cpp`, `TerrainModifier.cpp`, `TerrainPainter.cpp`, `TrackModifier.cpp`, `WrappedEngine.cpp`, `brush_util.cpp`, `builder_renderer_util.cpp`, `builder_util_zone.cpp`, `bulldozer_util.cpp`, `selection_renderer_util.cpp`, `street_builder_util.cpp`

## `train_fever/src/Game/UI/Actions/bulldozer` (3)

`AssetBulldozerAction.cpp`, `ModuleBulldozerAction.cpp`, `town_bulldozer_util.cpp`

## `train_fever/src/Game/UI/Components` (23)

`BasicFilter.cpp`, `BuildControlComp.cpp`, `CameraManager.cpp`, `ConstructionTable.cpp`, `FileListDataProvider.cpp`, `GameUI.cpp`, `HudIconManager.cpp`, `MapPreviewComp.cpp`, `MenuUI.cpp`, `RendererComponent.cpp`, `SavegameDialog.cpp`, `SavegameList.cpp`, `SectionTypeComp.cpp`, `TerrainEditor.cpp`, `debug_show_entities_panel.cpp`, `debug_util.cpp`, `game_ui_util.cpp`, `line_ui_util.cpp`, `map_mod_util.cpp`, `map_preview_util.cpp`, `menu_ui_util.cpp`, `render_component_debug_util.cpp`, `settings_menu_util.h`

## `train_fever/src/Game/UI/Components/debug` (11)

`DebugHudFilterComp.cpp`, `DebugViewComp.cpp`, `DrawCallDataProvider.cpp`, `ModelLodDataProvider.cpp`, `debug_data_util.cpp`, `debug_environment_util.cpp`, `debug_main_util.cpp`, `debug_rendering_util.cpp`, `debug_settings_util.cpp`, `debug_view_util.cpp`, `recursive_table_util.cpp`

## `train_fever/src/Game/UI/Hud` (2)

`Buffer.cpp`, `ItemCreator.cpp`

## `train_fever/src/Game/UI/Util` (39)

`AnimatedVariable.cpp`, `AssetGroupRecycler.cpp`, `BuilderRenderer.cpp`, `CameraController.cpp`, `CargoFlowRenderable.cpp`, `CatchmentAreaRenderable.cpp`, `ConstructionDustManager.cpp`, `DustAutomaton.cpp`, `LineBuffer.cpp`, `LineViewer.cpp`, `MarkerRenderable.cpp`, `MissionArrowRenderable.cpp`, `ModelManager.cpp`, `ModelMeshManager.cpp`, `ModelTextureManager.cpp`, `NodeViewer.cpp`, `OctreeSkipManager.cpp`, `OctreeSkipManager.h`, `ParticleManager.cpp`, `PlotsRenderable.cpp`, `ProceduralRenderer.cpp`, `ScriptGuiManager.cpp`, `SelectionRenderer.cpp`, `StationViewer.cpp`, `TextureTriangleBuffer.cpp`, `TriangleBuffer.cpp`, `VoronoiRenderable.cpp`, `WindRenderable.cpp`, `buffer_util.cpp`, `catchment_area_ui_util.cpp`, `chart_util.cpp`, `converter.h`, `entity_visitor_util.cpp`, `finance_util.cpp`, `logbook_util.cpp`, `particle_manager_util.cpp`, `particle_params.h`, `render_util.cpp`, `util.cpp`

## `train_fever/src/Game/UI/layers` (3)

`color_functions.cpp`, `renderables_cargo.cpp`, `renderables_speed.cpp`

## `train_fever/src/Game/UI/modhub` (1)

`ModPublishHelper.cpp`

## `train_fever/src/Game/UI/track_builder` (5)

`TrackRenderable.cpp`, `builder_util_2.cpp`, `edge_util.cpp`, `shape_util_2.cpp`, `track_render_util.cpp`

## `train_fever/src/Game/UrbanSim` (22)

`LogBookUpdateHelper.cpp`, `Obstacle.cpp`, `PathFactory.cpp`, `RandomLocationFactory.cpp`, `StockListUpdateHelper.cpp`, `StreetLoopFactory.cpp`, `TownDeveloper.cpp`, `building_distribution.cpp`, `destination_util.cpp`, `industry_util.cpp`, `init_streets_util.cpp`, `init_town_util.cpp`, `logbook_util.cpp`, `parcel_upgrade_util.cpp`, `parcel_util.cpp`, `pathfinder_util.cpp`, `sim_entity_util.cpp`, `simulation_util.cpp`, `stock_list_util.cpp`, `street_developer_util.cpp`, `town_connection_util.cpp`, `town_util.cpp`

## `train_fever/src/Game/audio` (12)

`AircraftAudioEmitter.cpp`, `AudioEmitterBackend.cpp`, `BuilderAudio.cpp`, `ConstructionAudioEmitter.cpp`, `CustomStateAudioEmitter.cpp`, `EnvironmentAudioEmitter.cpp`, `MusicPlayer.cpp`, `RailVehicleAudioEmitter.cpp`, `RoadVehicleAudioEmitter.cpp`, `ShipAudioEmitter.cpp`, `SoundSetRep.cpp`, `VoiceOverManager.cpp`

## `train_fever/src/Game/campaign` (2)

`converter.h`, `file_util.cpp`

## `train_fever/src/Game/command` (3)

`CommandList.cpp`, `apply_command.cpp`, `make_command.cpp`

## `train_fever/src/Game/construction` (9)

`BaseProposalTerrain.h`, `apply_proposal.cpp`, `con_builder_util_network.cpp`, `con_util_costs.cpp`, `con_util_entity_index.h`, `create_proposal_data.cpp`, `make_proposal.cpp`, `preprocess_proposal.cpp`, `proposal_util.cpp`

## `train_fever/src/Game/construction/street` (5)

`CachedStreetGraph.cpp`, `EngineStreetGraph.cpp`, `ProposalStreetGraph.cpp`, `StreetProposal.cpp`, `street_proposal_util.cpp`

## `train_fever/src/Game/ecs` (62)

`AccountSystem.cpp`, `AircraftMoveSystem.cpp`, `AnimalMoveSystem.cpp`, `AutoGroundTexSystem.cpp`, `BaseParallelStripSystem.cpp`, `CarriageListSystem.cpp`, `CatchmentAreaSystem.cpp`, `CollisionSystem.cpp`, `EcsOctree.h`, `EmissionEmitterSystem.cpp`, `EmissionGridSystem.cpp`, `GameScriptSystem.cpp`, `LandVehicleMoveSystem.cpp`, `LandmarkSystem.cpp`, `LineSystem.cpp`, `LogBookSystem.cpp`, `LotSystem.cpp`, `ModelInstanceListSystem.cpp`, `NameSystem.cpp`, `NotificationAdapter.cpp`, `NotificationSystem.cpp`, `OctreeSystem.cpp`, `ParcelSystem.cpp`, `PersonMoveSystem.cpp`, `RailroadCrossingSystem.cpp`, `RiverSystem.cpp`, `RunwaySystem.cpp`, `ShapeListSystem.cpp`, `ShipMoveSystem.cpp`, `SignalSystem.cpp`, `SimCargoSystem.cpp`, `SimEntityAtStockSystem.cpp`, `SimEntityAtTerminalSystem.cpp`, `SimEntityAtVehicleSystem.cpp`, `SimEntityNeedsPathSystem.cpp`, `SimPersonAtTerminalSystem.cpp`, `SimPersonAtVehicleSystem.cpp`, `SimPersonCacheSystem.cpp`, `SimPersonSystem.cpp`, `StationGroupSystem.cpp`, `StationSystem.cpp`, `StockListSystem.cpp`, `StreetConnectorSystem.cpp`, `StreetMaintenanceSystem.cpp`, `StreetSystem.cpp`, `TerrainAlignmentSystem.cpp`, `TownBuildingSystem.cpp`, `TownLandmarkSystem.cpp`, `TownSystem.cpp`, `TpNetLinkSystem.cpp`, `TrafficLightSystem.cpp`, `TransportNetworkSystem.cpp`, `TransportVehicleSystem.cpp`, `VehicleDepotSystem.cpp`, `VehicleOrderSystem.cpp`, `animal_util.cpp`, `emission_util.cpp`, `name_util.cpp`, `rasterize_util.cpp`, `terrain_ecs_util.cpp`, `time_util.cpp`, `train_move_util.cpp`

## `train_fever/src/Game/ecs/component` (1)

`EmissionGrid.cpp`

## `train_fever/src/Game/ecs/grid_collision` (4)

`GridCollision.cpp`, `GridCollisionSystem.cpp`, `PassableTilesSystem.cpp`, `WaterCollisionSystem.cpp`

## `train_fever/src/Game/mod_validator` (2)

`ModValidator.cpp`, `cooking_util.cpp`

## `train_fever/src/Game/model` (12)

`AircraftTransformator.cpp`, `BridgeTransformator.cpp`, `RailVehicleTransformator.cpp`, `RoadVehicleTransformator.cpp`, `ShipTransformator.cpp`, `TownBuildingTransformator.cpp`, `TramTransformator.cpp`, `TransformatorRep.cpp`, `bridge_transformator_util.cpp`, `game_model_util.cpp`, `transformator_util.cpp`, `transformator_util_engine.cpp`

## `train_fever/src/Game/model/metadata` (1)

`converter.h`

## `train_fever/src/Game/procedural` (10)

`BuildingTypeRep.cpp`, `GeneratorCache.cpp`, `RailroadCrossingGenerator.cpp`, `StreetGenerator.cpp`, `TrackGenerator.cpp`, `catenary_util.cpp`, `edge_decoration_util.cpp`, `track_gen_util.cpp`, `util.cpp`, `util.h`

## `train_fever/src/Game/profile` (1)

`UserProfile.cpp`

## `train_fever/src/Game/scripting` (18)

`GameScriptNotificationHelper.cpp`, `GameScriptNotificationHelper.h`, `app_interface.cpp`, `app_script_util.cpp`, `core_interface.cpp`, `engine_interface.cpp`, `engine_util.cpp`, `game_script_util.cpp`, `gamescript_util.cpp`, `gui_interface.cpp`, `luabridge_util.cpp`, `modhub_interface.cpp`, `native_containers.h`, `proposal_util.cpp`, `react_interface.cpp`, `res_interface.cpp`, `sol_util.cpp`, `util_interface.cpp`

## `train_fever/src/Game/scripting/transformators` (2)

`transformator_data_state.cpp`, `transformator_util_scripting.cpp`

## `train_fever/src/Game/scripting/usertypes` (3)

`helper_templates.h`, `usertypes_base.cpp`, `usertypes_res.cpp`

## `train_fever/src/Game/transport` (59)

`AStar.h`, `CargoTypeRep.cpp`, `CarriageListPathTracer.h`, `DriveExpanderCache.h`, `EdgeDecoration_converter.h`, `EdgeReservationManager.cpp`, `EdgeUseManager.cpp`, `EngineTpNetGraph.cpp`, `EngineTpNetLinkGraph.cpp`, `ExtPath.h`, `ITpNetLinkGraph.h`, `LinkGraphPathExpander.h`, `LinkPathExpander.h`, `LinkPathSeg.h`, `MultipleUnit_converter.h`, `PathFinder.h`, `PathTracer.h`, `ProposalTpNetGraph.cpp`, `ProposalTpNetLinkGraph.cpp`, `SimEntityUpdateHelper.cpp`, `TpNetData.h`, `TrafficLightTypeRep.cpp`, `TransportNetworkConstructor.cpp`, `VehicleReplaceHelper.cpp`, `VehicleUpdateHelper.cpp`, `WaterCollisionGridWrapper.cpp`, `air_vehicle_util_1.h`, `air_vehicle_util_1_engine.cpp`, `bridge_util.cpp`, `catchment_area_util.cpp`, `construction_util.cpp`, `converter.h`, `edge_geometry_speed_util.cpp`, `ext_path_edge_util.cpp`, `ext_path_util.cpp`, `lane_util.cpp`, `line_util.cpp`, `link_util.cpp`, `move_path_util.cpp`, `path_parts_util.cpp`, `path_util.cpp`, `pathfinder_util.h`, `pathfinder_util_air.cpp`, `pathfinder_util_water.cpp`, `station_util.cpp`, `transport_vehicle_util_path.cpp`, `transport_vehicle_util_path_air.cpp`, `transport_vehicle_util_path_common.cpp`, `transport_vehicle_util_path_default.cpp`, `update_util.cpp`, `util.cpp`, `util.h`, `vehicle_cargo_util.cpp`, `vehicle_load_config_util.cpp`, `vehicle_util.cpp`, `vehicle_util_2.cpp`, `vehicle_util_3.cpp`, `vehicle_util_4.cpp`, `vehicle_util_engine.cpp`

## `train_fever/src/Game/transport/street` (19)

`SnapPoint.h`, `StreetShapeFactory.cpp`, `StreetStyleRep.cpp`, `StreetTemplateRep.cpp`, `StreetToolkit.cpp`, `construction_util_bulldozer.cpp`, `construction_util_connector.cpp`, `construction_util_engine.cpp`, `construction_util_graph.cpp`, `construction_util_network.cpp`, `construction_util_parallel.cpp`, `construction_util_proposal.cpp`, `construction_util_section.cpp`, `construction_util_street.cpp`, `construction_util_street_upgrade.cpp`, `construction_util_terminal.cpp`, `construction_util_track_shape.cpp`, `converter.h`, `street_util.cpp`

## `train_fever/src/Lib/Geometry/Streets` (3)

`generation_util.cpp`, `lane_config_util.cpp`, `spline_connector.cpp`

## `train_fever/src/Lib/Geometry/Streets/Transitions` (7)

`Crossing.cpp`, `Curve.cpp`, `End.cpp`, `Link.cpp`, `lane_connection_util.cpp`, `lanes_util.cpp`, `transition_util.cpp`

## `train_fever/src/Lib/Geometry/Streets/track` (8)

`Crossing.cpp`, `End.cpp`, `Link.cpp`, `RailroadCrossing.cpp`, `Switch.cpp`, `TripleSwitch.cpp`, `spline_connector.cpp`, `util.cpp`

## `train_fever/src/Lib/UI` (63)

`AbsoluteLayout.cpp`, `AbstractLayout.cpp`, `BlurHelper.cpp`, `Button.cpp`, `ButtonPromptList.cpp`, `Chart.cpp`, `ColorChooser.cpp`, `ComboBox.cpp`, `Component.cpp`, `Component.h`, `Core.cpp`, `DataTable.cpp`, `DialogBox.cpp`, `DoubleSpinBox.cpp`, `FloatingLayout.cpp`, `FlowLayout.cpp`, `FontManager.cpp`, `GradientLegend.cpp`, `Guide.cpp`, `GuideManager.cpp`, `ImageMouseCursor.cpp`, `ImageView.cpp`, `InGameConsole.cpp`, `InputActionInvokeData.h`, `InputActionRep.cpp`, `KeyCombo.cpp`, `KeybindingHintDisplay.cpp`, `LayoutBase.cpp`, `LinearLayout.cpp`, `List.cpp`, `MaskHelper.cpp`, `MemoryManager.h`, `NodeEditor.cpp`, `NodeTreeRep.cpp`, `ParamsListComp.cpp`, `ParticleSystem2dComp.cpp`, `PopupManager.cpp`, `PreciseSlider.cpp`, `ProgressBar.cpp`, `RadialMenu.cpp`, `ScriptComponentRoot.cpp`, `ScrollCanvas.cpp`, `ScrollView.cpp`, `TabWidget.cpp`, `Table.cpp`, `TableLayout.cpp`, `TextInputField.cpp`, `TextSelection.cpp`, `TextView.cpp`, `ToggleButtonGroup.cpp`, `ToolTipManager.cpp`, `Util.cpp`, `ValueParamListComp.cpp`, `Window.cpp`, `WindowContainer.cpp`, `debug_util.cpp`, `inputAction_details.cpp`, `input_action_util.cpp`, `keybinding_hint_display_util.cpp`, `layout_wrapper.h`, `math_components_util.cpp`, `react_builtin.cpp`, `react_transform.cpp`

## `train_fever/src/Lib/UI/builtin` (26)

`BuiltinActionFn.cpp`, `BuiltinBoxLayout.cpp`, `BuiltinButton.cpp`, `BuiltinChart.cpp`, `BuiltinComboBox.cpp`, `BuiltinDataTable.cpp`, `BuiltinDropComponent.cpp`, `BuiltinEntityWindow.cpp`, `BuiltinGradientLegend.cpp`, `BuiltinImageView.cpp`, `BuiltinKeybindingDisplay.cpp`, `BuiltinList.cpp`, `BuiltinMapPreviewComp.cpp`, `BuiltinNativeFileDialogButton.cpp`, `BuiltinParticleSystem2d.cpp`, `BuiltinProgressBar.cpp`, `BuiltinRadialMenu.cpp`, `BuiltinReactAdapterGuest.cpp`, `BuiltinRendererComponent.cpp`, `BuiltinScrollArea.cpp`, `BuiltinTabWidget.cpp`, `BuiltinTableLayout.cpp`, `BuiltinToolButton.cpp`, `BuiltinWindow.cpp`, `DeferredTreeSupport.h`, `builtin_util.h`

## `train_fever/src/Lib/UI/builtin/action_descriptor` (2)

`BuiltinActionDescriptor.cpp`, `BuiltinConstructionAction.cpp`

## `train_fever/src/Lib/UI/builtin/hud_icon` (1)

`BuiltinDeferredHudIconMaster.cpp`

## `train_fever/src/Lib/UI/style` (5)

`StyleSheetRep.cpp`, `TimingFunction.cpp`, `compute.h`, `length.cpp`, `style_animation.cpp`

## `train_fever/src/Lib/Util` (18)

`AbstractKeybindingConflictsDefinition.cpp`, `Counted.h`, `IdRep.h`, `ModelIdOrGeneratorIndex.h`, `Polygon.h`, `Publisher.h`, `RichTextBuilder.cpp`, `ScriptRep.cpp`, `Spline.cpp`, `Tesselator.cpp`, `VectorMap.h`, `VisualConsole.cpp`, `bbcode.cpp`, `color_hsv_util.cpp`, `markup_util.cpp`, `message_box.cpp`, `min_span_tree.h`, `oom_util.cpp`

## `train_fever/src/Lib/Util/io` (1)

`serial_filesystem.h`

## `train_fever/src/Lib/audio` (3)

`BufferManager.cpp`, `IContext.cpp`, `IDevice.cpp`

## `train_fever/src/Lib/audio/openal` (1)

`OpenALSource.cpp`

## `train_fever/src/Lib/audio/util` (3)

`OggLink.cpp`, `OggPlayer.cpp`, `OggStream.cpp`

## `train_fever/src/Lib/ecs` (7)

`ComponentManager.cpp`, `ComponentManager.h`, `Engine.cpp`, `Engine.h`, `EntityRev.cpp`, `NodeList.h`, `Revision.h`

## `train_fever/src/Lib/engine` (4)

`AudioManager.cpp`, `CollisionShapeRep.cpp`, `collision_shape_util.cpp`, `view_util.cpp`

## `train_fever/src/Lib/model` (17)

`Material.h`, `MaterialTypeRep.cpp`, `Mesh.cpp`, `MeshConstructor.cpp`, `Model.cpp`, `Model.h`, `ModelRep.cpp`, `ModelVisitor.cpp`, `TransportMode.h`, `converter.h`, `edge_geometry_util.cpp`, `edge_geometry_util.h`, `material_type_util.cpp`, `model_instance_util.cpp`, `model_util.cpp`, `stack_converter.h`, `transport_mode_util.cpp`

## `train_fever/src/Lib/model/io` (6)

`Importer.cpp`, `converter_engine.h`, `converter_model.h`, `converter_model_metadata.h`, `serialization_util.cpp`, `serialization_util_metadata.cpp`

## `train_fever/src/Lib/model_construction` (5)

`ConstructionRep.cpp`, `MetaConstructionRep.cpp`, `converter.h`, `modules_util.cpp`, `stack_converter.h`

## `train_fever/src/Lib/potrace` (3)

`Bitmap.cpp`, `Param.cpp`, `Tracer.cpp`

## `train_fever/src/Lib/procedural` (2)

`AttributeMap.h`, `Result.cpp`

## `train_fever/src/Lib/renderer` (13)

`RenderPassProvider.cpp`, `ShaderCache.cpp`, `StreamingBuffer.cpp`, `TextureManager.cpp`, `TransportNetworkRenderer.cpp`, `UIRenderer.cpp`, `VramBudgetManager.cpp`, `WaterRenderer.cpp`, `backend_factory.cpp`, `shader_util.cpp`, `tex_load.cpp`, `tex_util.cpp`, `vertex_util.h`

## `train_fever/src/Lib/renderer/model` (10)

`DynamicModelRenderer.cpp`, `InstAttrHelper.cpp`, `MaterialUboManager.cpp`, `MeshVBOManager.cpp`, `ModelDescriptorManager.cpp`, `StackBuffer.h`, `StaticBuffer.cpp`, `TechniqueProvider.cpp`, `VaoManager.cpp`, `render_util.cpp`

## `train_fever/src/Lib/renderer/model/technique` (2)

`StandardTechnique.cpp`, `mat_bind.h`

## `train_fever/src/Lib/renderer/opengl` (5)

`OpenGLRenderContext.cpp`, `Program.cpp`, `debug_util.cpp`, `opengl_tex_util.cpp`, `tex_load.cpp`

## `train_fever/src/Lib/renderer/vulkan` (13)

`Buffer.cpp`, `Buffer.h`, `DescriptorPool.cpp`, `PipelineCache.cpp`, `QueryPool.cpp`, `SynchronisedStagingManager.cpp`, `Texture.h`, `VulkanRenderContext.cpp`, `VulkanRenderContext.h`, `command_util.cpp`, `pipeline_util.cpp`, `util.cpp`, `vulkan_tex_util.cpp`
