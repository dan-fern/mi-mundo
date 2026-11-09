# Third-party data and notices

Mi Mundo's own code is MIT-licensed (see LICENSE). The app also ships data
from these projects. This file is bundled into the app and shown under
Parent home → Credits.

Made with Natural Earth. Free vector and raster map data @ naturalearthdata.com.

| Data | Used for | License |
|---|---|---|
| [Natural Earth](https://www.naturalearthdata.com) admin-0 countries, 1:110m and 1:50m (v5.1.2) | Country outlines (`apple/MiMundo/Resources/World.bin`) | Public domain |
| Natural Earth 1:50m rivers, lakes, geography regions and elevation points (v5.1.2) | Rivers, lakes, deserts, mountain ranges and peaks (`Features.bin`) | Public domain |
| [Wikidata](https://www.wikidata.org) | Capitals and where they are, population, languages and landmarks (`Countries.json`; snapshots in `tools/wikidata-facts.json`, `tools/wikidata-capitals.json` and `tools/wikidata-landmarks.json`, hand fixes in `tools/facts-overrides.json`) | CC0 1.0 |
| [flag-icons](https://github.com/lipis/flag-icons) 7.2.3 | Flags (`Flags.xcassets`) | MIT, notice below |

Rebuild instructions: `tools/fetch-data.sh`, then `tools/build-data.sh`
(`tools/fetch-facts.py`, `tools/fetch-capitals.py` and `tools/fetch-landmarks.py` refresh the Wikidata
snapshots).

## flag-icons

```
The MIT License (MIT)

Copyright (c) 2013 Panayiotis Lipiridis

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
