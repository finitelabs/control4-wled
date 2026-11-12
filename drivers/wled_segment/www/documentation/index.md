<!-- Copyright 2026 Finite Labs, LLC. All rights reserved. -->

<style>
@media print {
   .noprint {
      visibility: hidden;
      display: none;
   }
   * {
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
    }
}
</style>

<img alt="WLED Segment" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#0094FF">Overview</span>

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or WLED.

One segment of a [WLED](https://kno.wled.ge) controller as its own Control4
light: on and off, level, color and white with fades, Advanced Lighting Scenes
and keypad buttons, for that part of the strip only. It binds to the **WLED**
driver, which keeps the one connection to the controller.

# <span style="color:#0094FF">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Compatibility](#compatibility)
- [How segment lights and the controller light work together](#how-segment-lights-and-the-controller-light-work-together)
- [Installer Setup](#installer-setup)
  <!-- #ifdef DRIVERCENTRAL -->
  - [DriverCentral Cloud Setup](#drivercentral-cloud-setup)
  <!-- #endif -->
  - [Driver Installation](#driver-installation)
  - [Driver Properties](#driver-properties)
  <!-- #ifdef DRIVERCENTRAL -->
  - [Driver Actions](#driver-actions)
  <!-- #endif -->
  - [Programming Variables](#programming-variables)
  - [Connections](#connections)
  <!-- #ifdef DRIVERCENTRAL -->
- [Developer Information](#developer-information)

<!-- #endif -->

- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#0094FF">System Requirements</span>

- Control4 OS 3.3.2 or later
- The **WLED** driver, connected to the WLED controller the segment is on

# <span style="color:#0094FF">Features</span>

- A Control4 light for one segment: on, off, level and toggle, with the Default
  On level, Previous Level and Min and Max On Level
- Color and white as the segment's LEDs allow, so two strip types on one
  controller each get the light they need
- Fades of any length, Advanced Lighting Scenes, Color On Mode and Dim-To-Warm
- On, Off and Toggle button links, with keypad LEDs that show the light's state
- A `Connected` variable for programming
- A segment that WLED renumbers or resizes keeps its light

# <span style="color:#0094FF">Compatibility</span>

The light offers what its segment's LEDs can light, as the
[`Segment`](#segment-read-only) property shows it:

<div style="font-size: small">

| Shown              | The light offers                        |
| ------------------ | --------------------------------------- |
| RGB                | Color                                   |
| RGBW               | Color, with whites on the white channel |
| RGB, tunable white | Color and color temperature             |
| RGB, CCT           | Color and color temperature             |
| Tunable white      | Color temperature                       |
| CCT                | Color temperature                       |
| White              | Level only                              |
| On/off             | On and off only                         |

</div>

Color temperature runs between the light's `Warm White (K)` and
`Cool White (K)`.

> **Note:** WLED's own settings change what a segment reports. An RGBW strip
> with WLED's white mode set to calculate the white from the color reports RGB.
> The light follows such a change while it runs.

# <span style="color:#0094FF">How segment lights and the controller light work together</span>

- A segment light's level is its segment's own level. The **WLED** driver's
  light sets the controller's master level, which WLED applies on top of every
  segment, as in WLED's own app.
- A segment light is on while its segment is on and the controller is on.
- Turning a segment light on while the controller is off turns the controller on
  with only that segment lit; the other segments stay dark. With a fade, the
  segment and the controller fade up together, so it starts a little slower than
  on a lit controller.
- Turning off the last lit segment turns the controller off alone, so the
  controller light reads off.
- Segment lights in one scene, or in a room turned on or off at once, act
  together: each sees what the others just did.
- A color or a scene step on a segment light changes its segment only, and ends
  a WLED effect running on it.
- The controller light's commands still cover every segment. Turning the
  controller light on turns every segment on; this light's On turns on its
  segment only.

# <span style="color:#0094FF">Installer Setup</span>

> ⚠️ Add the **WLED** driver for the controller first, and give the controller a
> DHCP reservation in the router.

<!-- #ifdef DRIVERCENTRAL -->

## DriverCentral Cloud Setup

> If you already have the
> [DriverCentral Cloud driver](https://drivercentral.io/platforms/control4-drivers/utility/drivercentral-cloud-driver/)
> installed in your project you can continue to
> [Driver Installation](#driver-installation).

This driver relies on the DriverCentral Cloud driver to manage licensing and
automatic updates. If you are new to using DriverCentral you can refer to their
[Cloud Driver](https://help.drivercentral.io/407519-Cloud-Driver) documentation
for setting it up.

<!-- #endif -->

## Driver Installation

1. Install the `.c4z` file from the same download as the **WLED** driver.

1. Use the "Search" tab to find the "WLED Segment" driver and add one to the
   room each part of the strip lights.

1. On the "Connections" tab, bind its **WLED Controller** connection to the
   segment's connection on the **WLED** driver. The **WLED** driver has one for
   each segment, named as the segment is named in WLED.

1. After a moment [`Driver Status`](#driver-status-read-only) shows `Connected`
   and [`Segment`](#segment-read-only) shows the segment's LEDs.

## Driver Properties

<!-- #ifdef DRIVERCENTRAL -->

### Cloud Settings

#### Cloud Status (read-only)

Displays the DriverCentral cloud license status.

#### Automatic Updates \[ Off | **_On_** \]

Turns automatic driver updates on or off. Changing it on one WLED driver changes
it on all of them.

<!-- #endif -->

### Driver Settings

#### Driver Status (read-only)

Displays the state of the segment:

- `Connected`: the **WLED** driver tells this light its segment.
- `Connecting`: the light is waiting to hear from the **WLED** driver, or the
  **WLED** driver is still reaching the controller.
- `Not connected to the WLED controller`: the **WLED** driver cannot reach the
  controller.
- `Segment not found`: the controller no longer has the segment. The light
  drives nothing until a segment is back on the same LEDs, for example after a
  preset that removed it is replaced by one that has it.
- `Bind this light to a WLED driver's segment connection`: the **WLED
  Controller** connection is not bound.
  <!-- #ifdef DRIVERCENTRAL -->
- `No active license`: the **WLED** driver has no active DriverCentral license,
  so the light drives nothing and stays at the level it had until a license is
  active.
  <!-- #endif -->

#### Driver Version (read-only)

Displays the current version of the driver.

<!-- #ifdef DRIVERCENTRAL -->

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug \]

Sets the logging level. Default is `3 - Info`. While a Support Code has
Composer's Lua tab open, it also offers `5 - Trace` and `6 - Ultra`.

<!-- #else -->

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

Sets the logging level. Default is `3 - Info`.

<!-- #endif -->

#### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`. It turns itself off after three hours.

<!-- #ifdef DRIVERCENTRAL -->

#### Support Code

Leave it blank unless Finite Labs support gives you a code: for an hour, it
opens Composer's Lua tab to this driver and adds `5 - Trace` and `6 - Ultra` to
Log Level.

#### Cloud Monitoring \[ Disabled | **_Enabled_** \]

When Enabled, the driver sends Finite Labs a short report once an hour, and a
report of each error it hits, at most 10 a minute. We use them to find and fix
problems in the driver. Set it to Disabled to send nothing.

A report holds the controller's MAC address and OS version, the driver's name,
version, device ID and DriverCentral license status, how much memory the driver
uses, and the sizes of its largest internal tables. An error report also holds
the error message and where in the driver it happened. Before a message is sent,
anything in it that looks like a password, token, key, network address or email
address is removed.

<!-- #endif -->

### Light Settings

#### Warm White (K) \[ 1900 - 10091, default: **_2700_** \]

Sets the color temperature of the segment's warmest white. WLED does not know
its strip's white points, so the light's color temperature range runs between
this and `Cool White (K)`.

#### Cool White (K) \[ 1900 - 10091, default: **_6500_** \]

Sets the color temperature of the segment's coolest white.

### Segment Info

#### Segment (read-only)

Displays the segment this light controls: its name, its LEDs and what they
light, for example `Left cabinet: LEDs 0-59, RGBW`.

<!-- #ifdef DRIVERCENTRAL -->

## Driver Actions

### Diagnostics Snapshot

Prints a report in the Lua output, and sends it to Finite Labs only while Cloud
Monitoring is Enabled.

<!-- #endif -->

## Programming Variables

| Variable  | Type | Description                                                                            |
| --------- | ---- | -------------------------------------------------------------------------------------- |
| Connected | BOOL | True while the segment is there and the **WLED** driver is connected to the controller |

## Connections

### Light (provider)

The Control4 Light proxy connection. The light is online while its segment is
there and the **WLED** driver is connected to the controller.

### WLED Controller (consumer)

Binds to one of the **WLED** driver's segment connections.

### Button Links

| Connection         | Description                        |
| ------------------ | ---------------------------------- |
| On Button Link     | Turns the light on when triggered  |
| Toggle Button Link | Toggles the light when triggered   |
| Off Button Link    | Turns the light off when triggered |

A keypad button bound to a button link shows whether the light is on, in that
button's on and off colors. They are set in Composer under the light's **Button
and Button Connection Status LED Colors** (Top for On, Bottom for Off, Toggle
for Toggle). With the project's default colors, the Off button is lit while the
light is off.

<!-- #ifdef DRIVERCENTRAL -->

# <span style="color:#0094FF">Developer Information</span>

<p align="center">
<img alt="Finite Labs" src="./images/finite-labs-logo.png" width="400"/>
</p>

Copyright © 2026 Finite Labs LLC

All information contained herein is, and remains the property of Finite Labs LLC
and its suppliers, if any. The intellectual and technical concepts contained
herein are proprietary to Finite Labs LLC and its suppliers and may be covered
by U.S. and Foreign Patents, patents in process, and are protected by trade
secret or copyright law. Dissemination of this information or reproduction of
this material is strictly forbidden unless prior written permission is obtained
from Finite Labs LLC. For the latest information, please visit
https://drivercentral.io/platforms/control4-drivers/lighting/wled-lights

<!-- #endif -->

# <span style="color:#0094FF">Support</span>

<!-- #ifdef DRIVERCENTRAL -->

If you have any questions or issues integrating this driver with Control4 or
WLED, you can contact us at
[driver-support@finitelabs.com](mailto:driver-support@finitelabs.com).

<!-- #else -->

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-wled/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

<!-- #endif -->

<!-- #embed-changelog -->
