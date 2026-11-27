# <span style="color:#FF6B00">Changelog</span>

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

## v20261127 - 2026-11-27

### Added

- Added Control4 load groups to the WLED and WLED Segment lights. Each joins a
  load group and follows the group's level, ramps and sync.

### Fixed

- Fixed a WLED or WLED Segment light coming on at a removed brightness preset's
  level when that preset was its on mode.
- Fixed a color preset from the Color Agent lighting a WLED or WLED Segment
  light in the light's own color preset with the same number.

## v20261117 - 2026-11-17

### Added

- Added the WLED and WLED Segment drivers
- Added a Control4 light with color and white, fades, Color On Mode and
  Dim-To-Warm
- Added Advanced Lighting Scenes and keypad button links with LEDs
- Added WLED's effects, palettes, presets and playlists to programming and the
  Extras menu, with preset cycling from keypads
- Added a light for each segment, with the WLED Segment driver
- Added finding controllers on the network, and following a controller when its
  address changes
- Added live updates when the WLED app, a button or another system changes the
  controller
  <!-- #ifdef DRIVERCENTRAL -->
- Added a Support Code property, Cloud Monitoring and a Diagnostics Snapshot
  action
  <!-- #endif -->
