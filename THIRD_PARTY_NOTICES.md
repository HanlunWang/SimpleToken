# Third-party notices

SimpleToken bundles the following third-party software.

## tokscale 4.18.0

- Source: https://github.com/junhoyeo/tokscale (npm package `tokscale`)
- Files: `Resources/tokscale/tokscale`, `Resources/tokscale/libFoundationModels.dylib`
- License: MIT

```
MIT License

Copyright (c) 2025 Junho Yeo

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

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

## AI Logo (brand logo collection)

- Source: https://github.com/yldm-tech/ai-logo (a fork of LobeHub's lobe-icons)
- Files: `SimpleTokenKit/Sources/DesignSystem/Resources/logos/*.svg` and their copies in `gui/logos/` (monochrome variants; path data normalised, otherwise unmodified)
- License: MIT, Copyright (c) 2023 LobeHub

The brand logos are trademarks of their respective owners. They are included for identification only; inclusion does not imply any affiliation or endorsement.


## Components of the v2 app (Go)

- **Geist, Geist Mono, Geist Pixel** fonts (Vercel, in collaboration with basement.studio), `gui/fonts/*.ttf`: SIL Open Font License 1.1, full text in `gui/fonts/OFL.txt`. The pixel face is subset to basic Latin.
- **Lucide** icons 0.469.0 (lucide-static), `gui/icons/lucide.json.gz`: ISC License, full text in `gui/icons/LUCIDE_LICENSE`.
- **mygo** (github.com/egoist/mygo): MIT License, Copyright (c) 2026 MyGo contributors.
- **purego** (github.com/ebitengine/purego): Apache License 2.0.
- **golang.org/x/image**, **golang.org/x/text**: BSD 3-Clause, Copyright The Go Authors.

These are compiled into the app binary; their license texts ship with their Go modules.
