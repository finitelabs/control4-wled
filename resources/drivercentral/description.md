<p><img src="https://drivercentral.io/images/companies/61/WLED/facts-strip-2400x136.png?1794355962167" alt="" width="1200" height="68" /></p>

## Overview

*This software is neither affiliated with nor endorsed by either Control4 or
WLED.*

Control WLED LED controllers from Control4 over your local network. Each
controller becomes a Control4 light with color, white and fades, and its WLED
effects, palettes, presets and playlists are at hand from the light's Extras
menu, keypads and programming. A strip split into segments can have a Control4
light for each segment.

## Features

- Local control over your network, with no cloud service
- A Control4 light with color and white, fades, Color On Mode and Dim-To-Warm
- Advanced Lighting Scenes and keypad button links with LEDs
- WLED's effects, palettes, presets and playlists in programming and the Extras
  menu, with preset cycling from keypads
- A light for each segment, with the included WLED Segment driver
- Controllers found on the network, and followed when their address changes
- Live updates when the WLED app, a button or another system changes the
  controller

## Included drivers

### WLED

Add one for each WLED controller. It finds the controller on the network, keeps
a live connection to it, and gives it a Control4 light for the whole strip, with
the controller's effects, palettes, presets and playlists.

### WLED Segment

A Control4 light for one segment of a strip split into parts in WLED. Add one
for each segment and bind it to that segment's connection on the WLED driver. It
follows the segment when WLED renumbers or resizes it.

## System requirements

- Control4 OS 3.3.2+
- A WLED controller running WLED 0.15 or later, on a network the Control4
  controller can reach

## Compatibility

Any controller running WLED 0.15 or later works, on an ESP32, ESP32-S3, ESP32-C3
or ESP8266 board, whether WLED came installed or was installed by hand. Each
light offers only what its LEDs can show, whether that is color with up to two
whites, tunable white, a single white, or on and off.
