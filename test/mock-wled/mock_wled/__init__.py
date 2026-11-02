"""Mock WLED controllers for driver tests.

Each instance serves WLED's HTTP JSON API and WebSocket on its own port and behaves as WLED
16.0.1 or 0.15.4, as its profile says. The driver's Lua fake reads the same profiles.

Profile schema (profiles/*.json, one controller each; keys not listed are ignored):

  name              info.name, the user's name for the controller.
  firmware          "16.0.1" or "0.15.4".
  chip              "esp8266", "esp32", "esp32s2", "esp32s3" or "esp32c3".
  psram             true for a board with PSRAM (64 segments on an ESP32 or S3 running 16.0.1).
  mac               12 hex digits, locally administered (second digit 2, 6, A or E).
  ip                info.ip; defaults to the address the client reached.
  release, brand, product, opt
                    override what a vendor build reports in info.
  buses             LED outputs, in order: {"type": <WLED LED type id>, "start": 0, "len": 60,
                    "rgbwm": <auto-white mode 0-4>, "order": <color order>}. Types: 22 WS2812
                    RGB, 30 SK6812 RGBW, 32 WS2805 RGB+CCT, 40 on/off, 41-45 PWM with 1 to 5
                    channels (41 white, 42 CCT, 43 RGB, 44 RGBW, 45 RGB+CCT).
  white             {"rgbwm": <global auto-white override, 255 = per bus>, "correct_wb": bool,
                    "cct_from_rgb": bool, "cct_blend": int}.
  matrix            {"w": 8, "h": 8} for a 2D layout.
  segments          segments at power-up: {"start", "stop", "n", "col": [[r, g, b, w], ...],
                    "fx"}; default one segment over every LED.
  auto_segments     what "rSeg" rebuilds: one segment per bus when true.
  presets           presets.json entries by id (1-250), stored as WLED stores them.
  boot              {"on": true, "bri": 128, "transition": 7, "preset": 0}: power-up state,
                    transition in tenths of a second.
  crossfade         0.15.4 only: false is the LED settings "Crossfade" switch turned off.
  ntp               true gives the clock unix time; false starts it at 0 at boot.
  custom_palettes   how many custom palettes the controller holds.
  ws_clients        overrides the chip's WebSocket client limit.
"""
