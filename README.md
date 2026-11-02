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

  - [Colors and WLED effects](#colors-and-wled-effects)
  - [The Extras menu](#the-extras-menu)
  - [Segment lights](#segment-lights)

- [Installer Setup](#installer-setup)

  - [Driver Installation](#driver-installation)
  - [Driver Properties](#driver-properties)
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

- A Control4 light for the controller: on, off, level and toggle, with the
  Default On level, Previous Level and Min and Max On Level
- Color and white as the controller's LEDs allow: color, color temperature
  between the installer's white points, or level only
- Fades of any length, run by the controller itself, with click and hold rates
- Advanced Lighting Scenes: level and color steps, ramps, stops and flash
- Color On Mode and Dim-To-Warm, as set on the light in Composer
- On, Off and Toggle button links, with keypad LEDs that show the light's state
- A live connection to the controller over WLED's WebSocket, so changes made in
  the WLED app, with a button or by another system show at once
- HTTP while the live connection reconnects, so the controller stays reachable
- The controller's name, brand, product, firmware version, MAC address, LED
  count and segments in Composer
- A `Connected` variable and Connected and Disconnected events for programming
- The controller's own WLED effects, palettes, presets and playlists in
  programming: set an effect, its speed and intensity, or a palette, apply a
  preset, and start or stop a playlist
- `Effect`, `Palette`, `Preset` and `Playlist` variables, and events when the
  effect or preset changes and when a playlist starts or ends
- The same effects, palettes, presets and playlists in the light's Extras menu,
  with the sliders and options each effect uses, under WLED's names for them
- Preset cycling from keypads and programming: Next and Previous Preset button
  links and commands over the presets the installer picks, a button link for
  each of those presets with its keypad LED lit while it shows, and a Preset Is
  conditional
- A connection for each segment, for **WLED Segment** lights that control one
  part of the strip each, through this driver's one connection
- A check that the controller at the address is the one the driver was set up
  with, so it never drives another controller after an address change

# <span style="color:#0094FF">Compatibility</span>

Any controller running WLED 0.15 or later: ESP32, ESP32-S3, ESP32-C3 and ESP8266
boards, whether WLED came installed or was installed by hand.

Each segment reports what its LEDs can light, and the **Segments** property
shows it:

<div style="font-size: small">

| Shown              | LEDs                                                  |
| ------------------ | ----------------------------------------------------- |
| RGB                | Color, for example WS2812B strips                     |
| RGBW               | Color and a white channel, for example SK6812 strips  |
| RGB, tunable white | Color and two whites, for example RGB+CCT strips      |
| RGB, CCT           | Color, with WLED's white balance correction turned on |
| Tunable white      | Two whites (CCT)                                      |
| White              | One white channel                                     |
| On/off             | A relay                                               |

</div>

> **Note:** WLED's own settings change what a segment reports. An RGBW strip
> with WLED's white mode set to calculate the white from the color reports RGB.
> The light follows such a change while it runs.

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
segment only; this driver's light still controls the whole strip.

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

1. Set [`IP Address`](#ip-address) to the WLED controller's address.

1. After a few moments [`Driver Status`](#driver-status-read-only) shows
   `Connected` and the [Device Info](#device-info) properties fill in.

If it does not connect, check the address opens WLED's own page in a browser on
the same network, then set
[`Log Mode`](#log-mode--off--print--log--print-and-log-) to `Print` and check
the Lua output window.

## Driver Properties

### Cloud Settings

#### Automatic Updates \[ Off | **_On_** \]

Turns automatic driver updates on or off. Changing it on one WLED driver changes
it on all of them.

#### Update Channel \[ **_Production_** | Prerelease \]

Production installs releases only; Prerelease also installs test builds.

### Driver Settings

#### Driver Status (read-only)

Displays the state of the connection:

- `Connected`: the driver has a live connection to the controller.
- `Connected over HTTP; reconnecting live updates`: the live connection dropped
  and the driver reaches the controller over HTTP while it reconnects.
- `Connecting`: the driver is reaching the controller.
- `Not connected: ...`: the controller cannot be reached, and why.
- `Set the IP Address ...`: no address is set.
- `A different WLED controller ... answers at this address`: see
  [Reset Driver](#reset-driver).

#### Driver Version (read-only)

Displays the current version of the driver.

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

Sets the logging level. Default is `3 - Info`.

#### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`. It turns itself off after three hours.

### Controller Settings

#### IP Address

The WLED controller's address on the network. Changing it connects to the new
address at once.

#### Port

WLED's web port. Leave it at `80` unless it was changed in WLED.

### Light Settings

#### Warm White (K)

The color temperature of the strip's warmest white, 2700 K by default. WLED does
not know its strip's white points, so the light's color temperature range runs
between this and Cool White.

#### Cool White (K)

The color temperature of the strip's coolest white, 6500 K by default.

### Preset Cycle

#### Cycle Presets

The presets the Next and Previous Preset buttons and commands step through, in
order: WLED preset ids or names, separated by commas, for example `4, 1, 7` or
`Movie Night, Warm Glow`. Empty, the default, cycles every preset on the
controller in id order. Playlists do not cycle. A number is read as a preset id;
use the id for a preset whose name is a number or has a comma in it. A preset
named here keeps its place when it is renamed in WLED. An entry the controller
has no preset for is left out and written to the log.

#### Presets in Cycle (read-only)

The presets that cycle, in order, as `Name (id)`, or `None`.

### Device Info

Read-only details the controller reports, updated whenever they change:
**Name**, **Brand**, **Product**, **Firmware Version**, **MAC Address**, **LED
Count** and **Segments**. **Segments** lists each segment's id, name, LED range
and what its LEDs light (see [Compatibility](#compatibility)).

## Driver Actions

### Update Drivers

Checks GitHub for a newer release and installs it.

### Reset Driver

The driver remembers the MAC address of the first controller it reaches. If a
different controller answers at the address later, for example after the router
gives the address to another device, the driver does not drive it and
`Driver Status` names it. Run Reset Driver with `Yes` when the controller was
replaced on purpose: the driver forgets the old one and takes the controller at
the address.

Reset Driver returns the driver to a fresh install. It keeps the IP Address and
Port, and the programming that uses the driver. It unwires every keypad button
from the On, Toggle, Off, Next Preset and Previous Preset button links, removes
every segment connection and preset link (making them again for the controller
that answers), and returns the other properties to their defaults. Bind each
**WLED Segment** light and each keypad button again afterwards.

## Programming Reference

### Commands

| Command              | Does                                                                           |
| -------------------- | ------------------------------------------------------------------------------ |
| Set Effect           | Runs a WLED effect on every segment, from its own speed, intensity and options |
| Set Effect Speed     | Sets the effect speed on every segment, 0 to 255                               |
| Set Effect Intensity | Sets the effect intensity on every segment, 0 to 255                           |
| Set Palette          | Uses a WLED palette on every segment                                           |
| Apply Preset         | Applies a WLED preset                                                          |
| Start Playlist       | Starts a WLED playlist                                                         |
| Stop Playlist        | Stops the running playlist; the light keeps the look the playlist last showed  |
| Next Preset          | Applies the next preset in the cycle                                           |
| Previous Preset      | Applies the previous preset in the cycle                                       |

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

| Event            | When                                                                      |
| ---------------- | ------------------------------------------------------------------------- |
| Connected        | The driver connects to the controller, at start and after every reconnect |
| Disconnected     | The driver loses the controller                                           |
| Effect Changed   | The main segment's effect changes                                         |
| Preset Changed   | The controller applies a different preset, including each playlist step   |
| Playlist Started | A playlist starts, or another one replaces it                             |
| Playlist Ended   | The running playlist stops or ends                                        |

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

### Segments (provider)

One connection for each segment the controller reports, named as the segment is
named in WLED, or `Segment` and its id when it has no name. Bind a **WLED
Segment** driver's **WLED Controller** connection to one (see
[Segment lights](#segment-lights)).

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

| Connection                  | Description                                                 |
| --------------------------- | ----------------------------------------------------------- |
| Next Preset Button Link     | Applies the next preset in the cycle when triggered         |
| Previous Preset Button Link | Applies the previous preset in the cycle when triggered     |
| _Name (id)_ Button Link     | One for each preset in the cycle: applies it when triggered |

Next steps from the preset showing, or, once its look has been changed, from the
preset the cycle last applied; with neither, Next starts at the first preset and
Previous at the last. The cycle wraps at both ends. A preset applies whatever it
was saved with in WLED, power and level included.

A preset's own button link is named from the controller and renamed with the
preset. A keypad button bound to it is lit while that preset is showing. A
preset taken out of **Cycle Presets** loses its link. A preset deleted on the
controller loses its link too, unless a keypad is still connected to it: then
the link stays, and does nothing until a preset is saved again under that id.

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

- Added the WLED driver: it connects to a WLED controller on the local network
  over WLED's WebSocket, with HTTP while it reconnects, and shows the
  controller's name, brand, product, firmware version, MAC address, LED count
  and segments in Composer
- Added a `Connected` variable and Connected and Disconnected events
- Added a check that the controller at the address is the one the driver was set
  up with; Reset Driver takes a replacement
- Added the controller's light: on, off, level, color and color temperature as
  the controller's LEDs allow, fades of any length, Advanced Lighting Scenes,
  Color On Mode and Dim-To-Warm, and On, Off and Toggle button links. A color
  from Control4 shows as a solid color and ends a running WLED effect
- Added `Warm White (K)` and `Cool White (K)` properties, the ends of the
  light's color temperature range
- Added the controller's WLED effects, palettes, presets and playlists to
  programming: Set Effect, Set Effect Speed, Set Effect Intensity, Set Palette,
  Apply Preset, Start Playlist and Stop Playlist, with `Effect`, `Palette`,
  `Preset` and `Playlist` variables, Effect Changed, Preset Changed, Playlist
  Started and Playlist Ended events, and a WLED playlist status conditional
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
- Changed the WLED light to read on only while a segment is lit, and to turn
  every segment on when it turns on with none lit
