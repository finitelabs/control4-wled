# DriverCentral images

Marketing images for the WLED Lights listing (DriverCentral product 978). Each
banner and photo is an HTML page rendered to PNG, and the rendered PNGs sit next
to their sources. The product card comes from `make icons`.

| Path                             | Size      | Used for                                                                                                                                                                                                               |
| -------------------------------- | --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `banners/spotlight-4096x848`     | 4096x848  | DriverCentral homepage spotlight banner (emailed to DriverCentral, not uploaded)                                                                                                                                       |
| `banners/launch-post-2400x1200`  | 2400x1200 | Launch posts (c4forums, Reddit, Discord)                                                                                                                                                                               |
| `banners/facts-strip-2400x136`   | 2400x136  | The first image in the listing's description: four facts in a row, three-quarters of the width, on a transparent background. Put it in a plain paragraph in the description, not a heading, which adds its own spacing |
| `product-card-300x300.png`       | 300x300   | The listing's product card, written by `make icons` from `resources/Driver Icons.sketch`                                                                                                                               |
| `photos/1-...` to `photos/6-...` | 2000x2000 | Listing photos, uploaded in number order                                                                                                                                                                               |

`assets/` holds what the pages share: the Finite Labs logo, `scene.js`, which
draws the banners' art, and WLED's official logo as `brand-mark.png`
(`images/wled_logo_akemi.png` in https://github.com/wled/WLED at v16.0.1), with
only its transparent margin trimmed. The banners' art is `strip`, a glowing LED
strip behind the logo, set on each banner's `<svg class="scene">`; the
template's DriverCentral README lists the styles. WLED publishes no brand kit;
its files are under the EUPL-1.2, which grants no trademark rights, so the logo
is used only to name the devices the driver controls (see the repo's `NOTICE`).

## Rendering

```bash
resources/drivercentral/render.sh
```

This needs Google Chrome, python3 and a network connection (the pages load Inter
from Google Fonts). It renders every page at 2x and overwrites the PNGs. Pass a
directory to render somewhere else instead.

Chrome sometimes hangs on a page. After 60 seconds on one page, `render.sh`
stops Chrome and fails, naming the page; run it again. `RENDER_TIMEOUT` sets the
limit in seconds.

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
