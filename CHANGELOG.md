# <span style="color:#109EFF">Changelog</span>

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
  over WLED's WebSocket, with HTTP while it reconnects, and shows the
  controller's name, brand, product, firmware version, MAC address, LED count
  and segments in Composer
- Added a `Connected` variable and Connected and Disconnected events
- Added a check that the controller at the address is the one the driver was set
  up with; Reset Driver takes a replacement
  <!-- #ifdef DRIVERCENTRAL -->
- Added a `Support Code` property, a `Cloud Monitoring` property, Enabled by
  default, and a `Diagnostics Snapshot` action
  <!-- #endif -->
