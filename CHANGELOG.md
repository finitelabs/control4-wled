# <span style="color:#0094FF">Changelog</span>

<!--
Template for a new release entry (copy below the heading, fill in, uncomment):

## v[Version] - YYYY-MM-DD

### Added
- Added

### Fixed
- Fixed

### Changed
- Changed

### Removed
- Removed
-->

## v20261113 - 2026-11-13

### Added

- Added the WLED driver, which connects to a WLED controller on the local
  network and shows its name, firmware, LED count and segments in Composer
- Added finding WLED controllers on the network, and following a controller by
  its MAC address when its address changes
- Added a check that the controller at the address is the one the driver was set
  up with, and Reset Driver to take a replacement
- Added the controller's light with on, off, level, color and color temperature
  as its LEDs allow, fades, Advanced Lighting Scenes, Color On Mode, Dim-To-Warm
  and On, Off and Toggle button links
- Added Warm White and Cool White properties that set the ends of the light's
  color temperature range
- Added the WLED Segment driver, a Control4 light for one segment that follows
  it when WLED renumbers or resizes it
- Added segment-aware power, so the WLED light reads on while a segment is lit
  and turns every segment on when none is
- Added WLED effects, palettes, presets and playlists to programming, with
  commands, variables, events and a playlist conditional
- Added the controller's effects with their sliders and options, palettes,
  presets and playlists to the light's Extras menu
- Added preset cycling with Next Preset and Previous Preset, a Cycle Presets
  property, a button link for each cycled preset and a Preset Is conditional
- Added a Connected variable, Connected and Disconnected events, and a
  connection status conditional
- Added a status line while another system sends the controller live data, and a
  check every 15 seconds for preset and playlist changes WLED does not announce
  <!-- #ifdef DRIVERCENTRAL -->
- Added a Support Code property, Cloud Monitoring and a Diagnostics Snapshot
  action
  <!-- #endif -->
