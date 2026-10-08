# Native GUI third-party notices

These components are vendored for the **native (non-WebView2) GUI**. They are source/libs only —
no build step of their own, no package manager, matching the existing `third_party/webview2`
convention.

| Component | Version / pin | Licence | Upstream |
|---|---|---|---|
| Dear ImGui | commit `b48d1afbe8ee8b238e2961dc363a949dd7304e23` | MIT (`third_party/imgui/LICENSE.txt`) | https://github.com/ocornut/imgui |
| cimgui | `master` (C ABI wrapper for the ImGui pin above) | MIT (`third_party/cimgui/LICENSE`) | https://github.com/cimgui/cimgui |
| SDL3 | `release-3.4.16`, x86_64-w64-mingw32 dev package | Zlib (`third_party/sdl3/LICENSE.txt`) | https://github.com/libsdl-org/SDL |

## How the pins were chosen

* ImGui is pinned to the **exact commit that cimgui's `imgui` submodule points at**. The cimgui C
  API is generated from the ImGui headers, so a mismatched pair fails to compile or silently
  misbehaves. `tools/fetch-third-party.mjs` resolves that commit from the GitHub API instead of
  trusting a hand-typed tag.
* SDL3 is used rather than SDL2: SDL3's text-input/IME path
  (`SDL_EVENT_TEXT_EDITING` + `SDL_SetTextInputArea`) is materially better, which matters because
  the UI ships a Chinese localisation.
* `SDL3.dll` ships next to the executable and is linked through `libSDL3.dll.a`. This is the same
  arrangement already used for `WebView2Loader.dll`, whose MSVC static loader cannot link against
  the mingw toolchain.

## Assets not vendored

No font file is vendored. The GUI loads a CJK-capable **system** font at runtime, so the repository
keeps carrying no binary font blobs.

## Refreshing

```sh
node tools/fetch-third-party.mjs          # SDL3 (current major)
node tools/fetch-third-party.mjs --sdl2   # SDL2 instead, if ever needed
```

The script downloads into `third_party/_dl/`; extract with `tar -xf` and copy the needed subset
into the layout above.
