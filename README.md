# SuperTuxKart in the browser

A self-contained launcher page for the [SuperTuxKart WebAssembly port][port] by
[ading2210][author]. `index.html` is the whole front end: it detects whether the
browser can run the game, downloads and unpacks the asset bundle, caches it, and
hands control to the engine.

The compiled engine is **not** in this repository. It is a few hundred megabytes
of WebAssembly and packed game data, so you either build it or point the page at
a copy that is already hosted somewhere. Both routes are below.

[port]: https://github.com/ading2210/stk-code/tree/wasm
[author]: https://github.com/ading2210/

## Running it

The page cannot be opened as a `file://` URL. The engine is compiled with
threads, so it needs `SharedArrayBuffer`, which browsers only expose to pages
that are *cross-origin isolated*. That requires two response headers:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

`serve.py` sets them for local use:

```
python3 serve.py
```

Then open <http://localhost:8000>. If the headers are missing, or the build is
absent, the page says so and tells you what to fix rather than failing silently.

For static hosting, `_headers` applies the same two headers on Netlify and
Cloudflare Pages. On other hosts, configure them yourself.

## Getting the game files

The launcher expects this next to `index.html`:

```
game/
  supertuxkart.js          # Emscripten loader, patched by the port's build
  supertuxkart.wasm        # the engine
  data_low.tar.gz.00 …     # asset bundle, split into parts
  data_low.tar.gz.manifest # total size, then one part filename per line
  data_mid.tar.gz.*        # optional, medium textures
  data_high.tar.gz.*       # optional, high textures
```

### Option A: point at an existing build

If the build is hosted elsewhere, pass its URL and skip building entirely:

```
http://localhost:8000/?base=https://example.com/stk/game/
```

The host has to allow cross-origin reads, and under `require-corp` it must also
send `Cross-Origin-Resource-Policy: cross-origin` on those files. Same-origin
hosting avoids both problems.

### Option B: build it yourself

`build-game.sh` runs the whole pipeline and drops the result straight into
`game/`. Roughly an hour on four cores, plus a large download. Linux only.

```
./build-game.sh                      # low-quality textures
./build-game.sh --quality all        # all three bundles
./build-game.sh --seed-ports         # see below
```

Start with `low`. The generator's XML rewrite step scales badly with texture
count, so `mid` takes noticeably longer than `low` and `high` takes hours.

It wraps the port's own `wasm/get_emsdk.sh`, `wasm/build_deps.sh`,
`wasm/build.sh` and `wasm/pack_assets.sh`, and works around three things that
otherwise stop them:

- **embuilder port names gained hyphens.** The port's `build.sh` asks for
  `sdl2_image_jpg`, which current Emscripten rejects as an unknown target. The
  name is now `sdl2_image-jpg`, and because the engine is built with `-pthread`
  the `-mt` variants are the ones that actually get linked.
- **cmake needs `-DCHECK_ASSETS=off`** unless a `stk-assets` tree sits next to
  the source, and it needs several passes before its `find_package` cache
  settles. The port's README notes that repeated-run quirk; the script just
  retries.
- **Emscripten fetches SDL and friends as GitHub archive zips.** Where those
  are blocked but git is not, `--seed-ports` clones each port at its pinned tag
  into `<emsdk>/upstream/emscripten/cache/ports/<name>/<subdir>/` and writes the
  expected archive URL to `cache/ports/<name>/.emscripten_url`. Emscripten then
  treats the port as already downloaded. Tags are pinned per emsdk release, so
  if a port still tries to download, read `TAG` and `SUBDIR` from
  `upstream/emscripten/tools/ports/<name>.py`.

The karts and tracks live in SVN rather than git, so the script pulls the 1.4
source release tarball, which carries the same content as a plain download.

To do it by hand instead, follow the port's own README and apply the three fixes
above.

## What this launcher does differently

It is a rewrite of the port's own `web/index.html` and `web/script.js`, kept
compatible with the same build output, with these changes:

- **No external dependencies.** The upstream loader pulls `pako` and `js-untar`
  from a CDN. This one unpacks with the browser's built-in
  `DecompressionStream` and a tar reader written inline, so the page works
  offline and adds no third-party origins to a page that is meant to be
  cross-origin isolated.
- **Streaming extraction.** Archive parts are piped through gunzip and into the
  virtual filesystem as they arrive, instead of holding the compressed archive
  and the decompressed copy in memory at once. Peak memory is roughly the
  largest single file rather than the size of the bundle.
- **Compressed cache.** Cached bundles are stored compressed in IndexedDB,
  around 120 MiB instead of the several hundred the decompressed form takes.
- **Works from a subdirectory.** Every path is relative to the page, so hosting
  under a project path works. Upstream hardcodes absolute paths.
- **Diagnostics instead of a hang.** Missing isolation headers, no WebGL 2, a
  `file://` URL, or an absent build each produce an explanation and the command
  that fixes it.
- **Optional config.** `config.json` is read if present and defaulted if not,
  and `globalThis.config` is always defined because the port's websocket patch
  reads it.
- **Saved data is flushed** when the tab is hidden or closed, not only when the
  engine writes its config.

## Known limits

From the port itself, not the launcher:

- Networking and online multiplayer do not work and can hang the game.
- Rendering uses OpenGL ES 2 through the legacy renderer, so performance is well
  below native. The engine logs `OpenGL version is too old!` on startup; that is
  expected and the game still runs.
- Roughly 500 MB of memory is needed, so 32-bit browsers will struggle.

From the asset pipeline:

- The generator converts textures to JPEG and rewrites the texture names
  embedded in the `.spm` meshes to match, but it misses a few. A handful of
  powerup textures are then requested as `.png` when only a `.jpg` was written,
  and the engine logs `STKTexManager: Failed to load bubblegum.png` and similar
  for the bubblegum, swatter and nitro models, which render untextured. Build
  with `--keep-png` to skip the conversion and avoid it, at the cost of a larger
  bundle.
- The karts and tracks come from the 1.4 release while the engine is built from
  the port's branch, so a small amount of drift like this is expected.

## Layout

```
index.html     the launcher, self-contained
build-game.sh  builds the engine and asset bundles into game/
serve.py       local server with the required isolation headers
config.json    websocket proxy settings, off by default
_headers       the same headers for Netlify / Cloudflare Pages
game/          the compiled build, not in git
```

## Licensing

SuperTuxKart is GPL-3.0-or-later; its assets are CC-BY-SA. This launcher covers
the same project and carries no separate claim.
