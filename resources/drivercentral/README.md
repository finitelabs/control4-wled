# DriverCentral images

Listing photos for the WLED Lights listing (DriverCentral product 978). Each
photo is an HTML page rendered to PNG, and the rendered PNGs sit next to their
sources.

| Path                             | Size      | Used for                                 |
| -------------------------------- | --------- | ---------------------------------------- |
| `photos/1-...` to `photos/6-...` | 2000x2000 | Listing photos, uploaded in number order |

`assets/` holds what the pages share: the Finite Labs logo and the WLED driver's
icon.

## Rendering

```bash
resources/drivercentral/render.sh
```

This needs Google Chrome and a network connection (the pages load Inter from
Google Fonts). It renders every photo at 2x and overwrites the PNGs. Pass a
directory to render somewhere else instead.

## Listing photos

Every photo is `photos/frame.html` around one screenshot from `photos/sources/`.
Each line of `photos/photos.txt` is `<output name>|<query>`, and the query sets
the fields below. `crop`, `end` and `tail` are pixels of the screenshot scaled
to the card's 880 px width.

- `t`, `s`: the title and subtitle.
- `img`: the screenshot in `photos/sources/`.
- `crop`: pixels cut from the top of the screenshot.
- `end`: the height kept fully visible below `crop`.
- `tail`: extra rows under `end` that fade out, for a list that continues; `bg`
  is the fade color and `more` the text over it.
- `fit=1`: scale the whole screenshot to fit instead.

The DriverCentral viewer hides about the bottom 15% of a square photo until the
popup is scrolled, so the frame keeps everything above that line (`SAFE` in
`frame.html`).

The screenshots come from the Control4 app and from Composer on the dev
controller running the DriverCentral build, with the WLED driver connected to
mock controllers from `test/mock-wled` running the demo profiles in
`photos/mock/`: from `test/mock-wled`,
`python -m mock_wled --config ../../resources/drivercentral/photos/mock/instances.json`.
The controller, segment and preset names, the MAC addresses and the firmware
come from those profiles. The setup photo's IP addresses and the found
controllers in it are placeholders set for the shot. Each crop leaves out the
project and every other device. Retake a screenshot when the view it shows
changes, then rerender.
