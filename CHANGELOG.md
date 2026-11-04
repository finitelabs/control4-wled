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

## Unreleased

### Added

- Added the WLED driver: it connects to a WLED controller on the local network
  and shows the controller's name, brand, product, firmware version, MAC
  address, LED count and segments in Composer
- Added a `Connected` variable, Connected and Disconnected events, and a WLED
  controller connection status conditional
- Added a check that the controller at the address is the one the driver was set
  up with, and Reset Driver to take a replacement
- Added the controller's light: on, off, level, color and color temperature as
  the controller's LEDs allow (a color from Control4 shows as a solid color and
  ends a running WLED effect), fades of any length, Advanced Lighting Scenes,
  Color On Mode and Dim-To-Warm, and On, Off and Toggle button links
- Added `Warm White (K)` and `Cool White (K)` properties, the ends of the
  light's color temperature range
- Added the controller's WLED effects, palettes, presets and playlists to
  programming: Set Effect, Set Effect Speed, Set Effect Intensity, Set Effect
  Custom Value, Set Effect Option, Set Palette, Apply Preset, Start Playlist and
  Stop Playlist, with `Effect`, `Palette`, `Preset` and `Playlist` variables,
  Effect Changed, Preset Changed, Playlist Started and Playlist Ended events,
  and a WLED playlist status conditional
- Added the light's Extras menu: the controller's effects, with the sliders and
  options the running effect uses under WLED's names for them, its palettes,
  presets and playlists
- Added preset cycling: Next Preset and Previous Preset button links and
  commands, a `Cycle Presets` property for which presets cycle and in what
  order, a button link for each of those presets with its keypad LED lit while
  it shows, and a Preset Is conditional
- Added the WLED Segment driver: a Control4 light for one segment of a WLED
  controller, bound to the WLED driver's connection for that segment, which
  follows the segment when WLED renumbers or resizes it
- Added segment-aware power to the WLED light: it reads on only while a segment
  is lit, and turns every segment on when it turns on with none lit
- Added finding WLED controllers on the network: a `Found Controllers` list to
  pick a controller from, a `Find Controllers` action, and IP Address and Port
  following the driver's controller by its MAC address when its address changes
  <!-- #ifdef DRIVERCENTRAL -->
- Added a `Support Code` property, a `Cloud Monitoring` property, Enabled by
  default, and a `Diagnostics Snapshot` action
- Added a license check: after five minutes without an active DriverCentral
  license the WLED driver drops the controller, shows `No active license` in
  Driver Status, and its lights keep their level with no event; a license
  connects it again at once
  <!-- #endif -->
