<!-- Copyright 2026 Finite Labs, LLC. All rights reserved. -->

<img alt="WLED" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#0094FF">Overview</span>

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or WLED.

Integrate [WLED](https://kno.wled.ge) LED controllers into Control4. The driver
connects to a WLED controller on the local network, keeps a live connection to
it, and gives the controller a Control4 light: on and off, level, color and
white with fades, Advanced Lighting Scenes and keypad buttons. It also shows
what the controller reports: its name, firmware, MAC address, LED count and
segments.

The light controls the whole controller: its power and level, the color of every
segment, and the controller's own WLED effects, palettes, presets and playlists,
from the light's Extras menu and from programming. For a strip split into parts,
the **WLED Segment** driver adds a light for each segment, through this driver.

# <span style="color:#0094FF">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)

- [Features](#features)

- [Compatibility](#compatibility)

- [Using the light](#using-the-light)

  - [On, off, level and scenes](#on-off-level-and-scenes)
  - [Colors and WLED effects](#colors-and-wled-effects)
  - [The Extras menu](#the-extras-menu)
  - [Segment lights](#segment-lights)

- [Installer Setup](#installer-setup)

  - [Driver Installation](#driver-installation)
  - [Driver Setup](#driver-setup)
    - [Driver Properties](#driver-properties)
      - [Cloud Settings](#cloud-settings)
      - [Driver Settings](#driver-settings)
      - [Controller Settings](#controller-settings)
      - [Light Settings](#light-settings)
      - [Preset Cycle](#preset-cycle)
      - [Device Info](#device-info)
    - [Driver Actions](#driver-actions)
  - [Programming Reference](#programming-reference)
  - [Connections](#connections)

- [Support](#support)

- [Changelog](#changelog)

</div>

# <span style="color:#0094FF">System Requirements</span>

- Control4 OS 3.3.2 or later
- A WLED controller running WLED 0.15 or later, on a network the Control4
  controller can reach

# <span style="color:#0094FF">Features</span>

- A Control4 light with color and white, fades, Color On Mode and Dim-To-Warm
- Advanced Lighting Scenes and keypad button links with LEDs
- WLED's effects, palettes, presets and playlists in programming and the Extras
  menu, with preset cycling from keypads
- A light for each segment, with the **WLED Segment** driver
- Controllers found on the network, and followed when their address changes
- Live updates when the WLED app, a button or another system changes the
  controller

# <span style="color:#0094FF">Compatibility</span>

Any controller running WLED 0.15 or later: ESP32, ESP32-S3, ESP32-C3 and ESP8266
boards, whether WLED came installed or was installed by hand.

Each segment reports what its LEDs can light, and the
[`Segments`](#segments-read-only) property shows it:

<div style="font-size: small">

| Shown              | LEDs                                                  |
| ------------------ | ----------------------------------------------------- |
| RGB                | Color, for example WS2812B strips                     |
| RGBW               | Color and a white channel, for example SK6812 strips  |
| RGB, tunable white | Color and two whites, for example RGB+CCT strips      |
| RGB, CCT           | Color, with WLED's white balance correction turned on |
| Tunable white      | Two whites (CCT)                                      |
| CCT                | Color temperature, with no white channel reported     |
| White              | One white channel                                     |
| On/off             | A relay                                               |

</div>

> **Note:** WLED's own settings change what a segment reports. An RGBW strip
> with WLED's white mode set to calculate the white from the color reports RGB.
> The light follows such a change while it runs.

If you have a board or controller that does not work, please
[open an issue](https://github.com/finitelabs/control4-wled/issues/new).

# <span style="color:#0094FF">Using the light</span>

## On, off, level and scenes

The light works as any Control4 light does: on, off, level and toggle, with the
Default On level, Previous Level and Min and Max On Level set on the light in
Composer. Fades of any length run on the WLED controller itself, with the
light's click and hold rates. Advanced Lighting Scenes run level and color
steps, ramps, stops and flash. The light offers color and white as the
controller's LEDs allow (see [Compatibility](#compatibility)), with color
temperature between `Warm White (K)` and `Cool White (K)`, or level only, and
follows the Color On Mode and Dim-To-Warm set on the light in Composer. A color
set while the light is off is the color it next turns on in, in place of the
Color On Mode's.

## Colors and WLED effects

Any color Control4 sends, from a color pick, a scene step, the Color On Mode or
Dim-To-Warm, shows as that solid color on every segment and ends a running WLED
effect. A level change alone dims an effect and leaves it running.

The effect and palette commands in programming (see
[Programming Reference](#programming-reference)) run on every segment and leave
the light's power and level as they are: an effect set while the light is off
shows when it next turns on. A preset or playlist sets whatever it was saved
with in WLED, power and level included.

## The Extras menu

Press and hold the light in the Control4 app or on a touchscreen to open its
Extras menu. It shows what the controller's main segment shows:

- **Effect**: the controller's effects, with the running one picked. Below it
  are the sliders and checkboxes that effect uses, under the names WLED gives
  them for it, for example `Trail` and `Delay` for Scanner. The ones the effect
  does not use are hidden.
- **Color palette**: the controller's palettes, shown only while the effect uses
  a palette and the LEDs have color.
- **Preset** and **Playlist**, when the controller has any. Picking a preset
  applies it, picking a playlist starts it, and `None` stops the running
  playlist.

Entries in a list that share a name show their WLED id after it.

An effect, palette, slider or checkbox runs on every segment and leaves the
light's power and level as they are, as the programming commands do. A new
effect starts from its own speed, intensity and options, as in the WLED app. A
preset or playlist sets whatever it was saved with, power and level included.
The menu follows the controller, so a change made in the WLED app, by a preset
or by a playlist step shows there too.

## Segment lights

For a strip split into parts in WLED, for example left and right cabinets, add a
**WLED Segment** driver for each part and bind it to that segment's connection
on this driver (see [Connections](#connections)). The segment light controls its
segment only; this driver's light still controls the whole strip. The **WLED
Segment** driver includes its own documentation, accessible from within Composer
Pro.

- A segment light's level is its segment's own level, and this light's level is
  the controller's master level, which WLED applies on top of every segment.
- A segment light is on while its segment is on and the controller is on. This
  light is on while the controller is on and at least one segment is lit.
- Turning a segment light on while the controller is off turns the controller on
  with only that segment lit. With a fade, the segment and the controller fade
  up together, so it starts a little slower than on a lit controller.
- Turning off the last lit segment turns the controller off alone. The segment
  stays set to come back when this light turns on.
- Turning this light on when no segment is lit turns every segment on, as it
  lights the whole strip. With a segment lit, it turns on the controller only.
- This light's colors, effects and presets still cover every segment.

WLED can renumber segments, for example when a segment is deleted or a preset
with another layout is applied. Each connection follows its segment by its LEDs,
so a segment light stays on the same part of the strip, and a renamed segment's
connection is renamed with it. A new segment gets a new connection. When a
segment is gone, its connection goes too, unless a segment light is still bound
to it: then the light shows `Segment not found` and drives nothing until a
segment is back on the same LEDs, and unbinding the light removes the
connection.

# <span style="color:#0094FF">Installer Setup</span>

> ⚠️ Add one **WLED** driver per WLED controller, and give each controller a
> DHCP reservation in the router so its address does not change.

## Driver Installation

1. Download the latest `control4-wled.zip` from
   [GitHub](https://github.com/finitelabs/control4-wled/releases/latest).

1. Extract and
   [install](https://www.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/adding_drivers_manually.htm)
   the `.c4z` file.

1. Use the "Search" tab to find the "WLED" driver and add it to the room the
   LEDs light.

1. Pick the WLED controller in
   [`Found Controllers`](#found-controllers--select--found-controllers-), or set
   [`IP Address`](#ip-address) to its address.

1. After a few moments [`Driver Status`](#driver-status-read-only) shows
   `Connected` and the [Device Info](#device-info) properties fill in.

If it does not connect, check the address opens WLED's own page in a browser on
the same network, then set
[`Log Mode`](#log-mode--off--print--log--print-and-log-) to `Print` and check
the Lua output window.

## Driver Setup

### Driver Properties

#### Cloud Settings

##### Automatic Updates \[ Off | **_On_** \]

Turns automatic driver updates on or off. Changing it on one WLED driver changes
it on all of them.

##### Update Channel \[ **_Production_** | Prerelease \]

Selects which releases the driver installs: `Production` installs releases only,
and `Prerelease` also installs test builds.

#### Driver Settings

##### Driver Status (read-only)

Displays the state of the connection:

- `Connected`: the driver has a live connection to the controller.
- `Connected over HTTP; reconnecting live updates`: the live connection dropped
  and the driver reaches the controller over HTTP while it reconnects.
- `Connecting`: the driver is reaching the controller.
- `Not connected: ...`: the controller cannot be reached, and why.
- `Set the IP Address ...`: no address is set.
- `A different WLED controller ... answers at this address`: see
  [Reset Driver](#reset-driver).

##### Driver Version (read-only)

Displays the current version of the driver.

##### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

Sets the logging level. Default is `3 - Info`.

##### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`. It turns itself off after three hours.

#### Controller Settings

##### IP Address

Sets the WLED controller's address on the network. Changing it connects to the
new address at once. When the controller stops answering, or another controller
answers at its address, the driver looks for it on the network by its MAC
address every 30 seconds and changes `IP Address` and `Port` to where it
answers. It never moves away from an address you set before the controller has
answered there, and it keeps a host name you typed.

##### Port \[ 1 - 65535, default: **_80_** \]

Sets WLED's web port. Leave it at `80` unless it was changed in WLED.

##### Found Controllers \[ **_(Select)_** | _found controllers..._ \]

Shown only while the last search found a controller. Lists the WLED controllers
the driver finds on the network as `name (address)`, with the port after the
address when it is not 80. Picking one sets `IP Address` and `Port` to it. The
driver searches when it loads, when [Find Controllers](#find-controllers) runs,
and while its controller cannot be reached. It finds controllers on the same
network as the Control4 controller that have an mDNS address set in WLED's WiFi
settings, as they do by default.

#### Light Settings

##### Warm White (K) \[ 1900 - 10091, default: **_2700_** \]

Sets the color temperature of the strip's warmest white. WLED does not know its
strip's white points, so the light's color temperature range runs between this
and `Cool White (K)`.

##### Cool White (K) \[ 1900 - 10091, default: **_6500_** \]

Sets the color temperature of the strip's coolest white.

#### Preset Cycle

##### Cycle Presets

Sets the presets the Next and Previous Preset buttons and commands step through,
in order: WLED preset ids or names, separated by commas, for example `4, 1, 7`
or `Movie Night, Warm Glow`. Empty, the default, cycles every preset on the
controller in id order. Playlists do not cycle. A number is read as a preset id;
use the id for a preset whose name is a number or has a comma in it. A preset
named here keeps its place when it is renamed in WLED. An entry the controller
has no preset for is left out and written to the log.

##### Presets in Cycle (read-only)

Displays the presets that cycle, in order, as `Name (id)`, or `None`.

#### Device Info

Details the controller reports, updated whenever they change.

##### Name (read-only)

Displays the controller's name, as set in WLED.

##### Brand (read-only)

Displays the brand the controller's firmware reports.

##### Product (read-only)

Displays the product name the controller's firmware reports.

##### Firmware Version (read-only)

Displays the controller's WLED version.

##### MAC Address (read-only)

Displays the controller's MAC address, which the driver uses to tell its
controller from another one (see [Reset Driver](#reset-driver)).

##### LED Count (read-only)

Displays the number of LEDs the controller drives.

##### Segments (read-only)

Displays each segment's id, name, LED range and what its LEDs light, for example
`0: Left cabinet 0-59 RGBW; 1: Right cabinet 60-119 RGB`, or `None`.
[Compatibility](#compatibility) lists what each LED type means.

### Driver Actions

#### Update Drivers

Installs the latest release on the Update Channel from GitHub for every WLED
driver, regardless of the current version.

#### Find Controllers

Looks for WLED controllers on the network again and lists them in
[`Found Controllers`](#found-controllers--select--found-controllers-).

#### Reset Driver

> ⚠️ This unbinds every **WLED Segment** light from its segment connection, and
> every keypad button from this driver's button links.

The driver remembers the MAC address of the first controller it reaches. If a
different controller answers at the address later, for example after the router
gives the address to another device, the driver does not drive it. It looks for
its own controller on the network and follows it (see
[IP Address](#ip-address)), and until then `Driver Status` names the other one.
Run Reset Driver with `Yes` when the controller was replaced on purpose: the
driver forgets the old one and takes the controller at the address.

Reset Driver returns the driver to a fresh install. It keeps the `IP Address`
and `Port`, and the programming that uses the driver. It unwires every keypad
button from the On, Toggle, Off, Next Preset and Previous Preset button links,
removes every segment connection and preset link (making them again for the
controller that answers), and returns the other properties to their defaults.
The update settings stay as they are, since every WLED driver in the project
shares them. Bind each **WLED Segment** light and each keypad button again
afterwards. The light keeps the level it shows, so a reset fires no Light Off or
Light On.

**Parameters:**

- **Are You Sure?** \[ **_No_** | Yes \] - Confirmation to reset the driver.

## Programming Reference

### Commands

| Command                 | Parameters                                                  | Description                                                                    |
| ----------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Set Effect              | Effect                                                      | Runs a WLED effect on every segment, from its own speed, intensity and options |
| Set Effect Speed        | Speed (0 - 255)                                             | Sets the effect speed on every segment                                         |
| Set Effect Intensity    | Intensity (0 - 255)                                         | Sets the effect intensity on every segment                                     |
| Set Effect Custom Value | Control (Custom 1, 2, 3), Value (0 - 255; Custom 3: 0 - 31) | Sets one of the effect's Custom values on every segment                        |
| Set Effect Option       | Option (Check 1, 2, 3), State (On, Off)                     | Turns one of the effect's options on or off on every segment                   |
| Set Palette             | Palette                                                     | Uses a WLED palette on every segment                                           |
| Apply Preset            | Preset                                                      | Applies a WLED preset                                                          |
| Start Playlist          | Playlist                                                    | Starts a WLED playlist                                                         |
| Stop Playlist           | (none)                                                      | Stops the running playlist; the light keeps the look the playlist last showed  |
| Next Preset             | (none)                                                      | Applies the next preset in the cycle                                           |
| Previous Preset         | (none)                                                      | Applies the previous preset in the cycle                                       |

The choices are the controller's own, read when the driver connects and again
when the controller reports a change: a preset or playlist saved or deleted, an
effect or palette added, or new firmware. Effects that need a 2D matrix are
offered only on a controller set up with one. Custom palettes show as
`Custom Palette 1`, `Custom Palette 2` and so on.

Presets and playlists show as their name and WLED id, for example
`Movie Night (4)`. The command finds the preset by its id, so programming keeps
working after the preset is renamed in WLED. Effects and palettes are found by
name.

The controller applies a preset or starts a playlist on its next loop; the
variables and events below follow once it reports the result.

### Variables

| Variable  | Type   | Description                                                                      |
| --------- | ------ | -------------------------------------------------------------------------------- |
| Connected | BOOL   | True while the driver is connected to the controller                             |
| Effect    | STRING | The effect the controller runs, as its main segment shows it                     |
| Palette   | STRING | The palette the controller uses, as its main segment shows it                    |
| Preset    | STRING | The preset the controller last applied, or empty once its look has been changed  |
| Playlist  | STRING | The playlist the controller runs, or empty when none runs or it was sent unnamed |

### Events

| Event            | Description                                                                          |
| ---------------- | ------------------------------------------------------------------------------------ |
| Connected        | Fires when the driver connects to the controller, at start and after every reconnect |
| Disconnected     | Fires when the driver loses the controller                                           |
| Effect Changed   | Fires when the main segment's effect changes                                         |
| Preset Changed   | Fires when the controller applies a different preset, including each playlist step   |
| Playlist Started | Fires when a playlist starts, or another one replaces it                             |
| Playlist Ended   | Fires when the running playlist stops or ends                                        |

A live connection that drops while the controller still answers over HTTP fires
neither connection event. The effect, preset and playlist events fire only for a
change: a driver start, a reload or a reconnect that finds the controller as it
was fires none of them, and applying the preset already shown fires nothing.
Each variable is set before its event fires.

### Conditionals

| Conditional                       | Tests                                                                          |
| --------------------------------- | ------------------------------------------------------------------------------ |
| WLED controller connection status | Whether the driver is Connected or Disconnected, as the events follow it       |
| WLED playlist status              | Whether a playlist is Running or Not Running, as the Playlist events follow it |
| Preset Is                         | Whether the preset showing is, or is not, the one picked                       |

Preset Is lists the controller's presets as programming shows them, for example
`Movie Night (4)`, and follows the controller as presets are saved, renamed and
deleted. It tests by the preset's id, so programming keeps working after a
rename in WLED.

## Connections

### Light (provider)

The Control4 Light proxy connection. The light is online while the driver is
connected and offline while it is not.

### `{segment name}` (provider, dynamic)

One `WLED_SEGMENT` connection for each segment the controller reports. Bind a
**WLED Segment** driver's **WLED Controller** connection to one (see
[Segment lights](#segment-lights)).

> **Note:** `{segment name}` is the segment's name in WLED, or `Segment` and its
> id when it has no name, for example `Segment 1`.

### Button Links

| Connection         | Description                        |
| ------------------ | ---------------------------------- |
| On Button Link     | Turns the light on when triggered  |
| Toggle Button Link | Toggles the light when triggered   |
| Off Button Link    | Turns the light off when triggered |

A keypad button bound to a button link shows whether the light is on: lit while
it is on, or for the Off Button Link while it is off. It shows that button's
colors, set in Composer under the light's **Button and Button Connection Status
LED Colors** (Top for On, Bottom for Off, Toggle for Toggle).

| Connection                         | Description                                                 |
| ---------------------------------- | ----------------------------------------------------------- |
| Next Preset Button Link            | Applies the next preset in the cycle when triggered         |
| Previous Preset Button Link        | Applies the previous preset in the cycle when triggered     |
| `{preset name} ({id})` Button Link | One for each preset in the cycle: applies it when triggered |

> **Note:** `{preset name}` and `{id}` come from the controller's preset, for
> example `Movie Night (4) Button Link`, and the link is renamed with the
> preset.

Next steps from the preset showing, or, once its look has been changed, from the
preset the cycle last applied; with neither, Next starts at the first preset and
Previous at the last. The cycle wraps at both ends. A preset applies whatever it
was saved with in WLED, power and level included.

A keypad button bound to a preset's own button link is lit while that preset is
showing. A preset taken out of `Cycle Presets` loses its link. A preset deleted
on the controller loses its link too, unless a keypad is still connected to it:
then the link stays, and does nothing until a preset is saved again under that
id.

# <span style="color:#0094FF">Support</span>

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-wled/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

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
