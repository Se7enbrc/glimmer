# Credits

Glimmer's Swift streaming transport was **ported from
[moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c)**,
the core protocol library written by the
[Moonlight Game Streaming](https://github.com/moonlight-stream) team. Their work
is a genuinely impressive, hard-won implementation of the GameStream/Sunshine
wire protocol, and Glimmer would not exist without it. Thank you.

A few higher-level pieces - the pairing handshake, the nvhttp control client,
and the frame pacer - were likewise ported from the same team's
[moonlight-qt](https://github.com/moonlight-stream/moonlight-qt) (also GPLv3).

Because these are faithful ports - derivative works - Glimmer is distributed
under the **GNU General Public License v3** (see [LICENSE](LICENSE)), the same
license as the originals.

A clean-room reimplementation, written from the published GameStream/Sunshine
wire protocol rather than from moonlight-common-c's source, is planned. Once
that lands, Glimmer will become independently licensed. Until then, the GPLv3
notice on the ported files is accurate and intentional.

## MIT-licensed upstreams ported via moonlight-common-c

Two of the components ported into the Swift engine originate from separately
licensed (MIT) projects that moonlight-common-c vendors. Their copyright and
permission notices are preserved here, as the MIT license requires:

- **[enet](https://github.com/lsalzman/enet)** - Copyright (c) 2002-2024 Lee
  Salzman. MIT License. `Glimmer/Stream/Native/EnetControlChannel*.swift` and
  `EnetWire.swift` port the protocol logic of the enet sources vendored in
  moonlight-common-c (`protocol.h` / `host.c` / `protocol.c`).
- **[nanors](https://github.com/sleepybishop/nanors)** - Copyright (c) 2021
  Joseph Calderon. MIT License. `Glimmer/Stream/Native/ReedSolomon.swift` ports
  `nanors/rs.c` plus the scalar GF(256) math from nanors' vendored
  `deps/obl/oblas_lite.c` (covered by the same nanors license).

MIT permission notice (applies to both):

> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.
