# Patches applied to the WebKit checkout

These are the changes vshell needs from WebKit. Until now they existed **only** in
`C:\Users\Lenovo\projects\WebKit`, a tree that is not part of this repository and can be
recreated at any time — which made them the most fragile thing in the project.

Base commit (all four apply to this tree):

```
8bda93dba4e07256eb0443459eedb1a08c351e82
```

Apply from the root of the WebKit checkout, in order:

```sh
cd /c/Users/Lenovo/projects/WebKit
for p in <repo>/patches/webkit/*.patch; do git apply "$p"; done
```

Each patch was verified with `git apply --reverse --check`, which succeeds only if the
working tree matches the patch exactly — so they are complete, not a best effort.

## What each one is

| patch | file | why |
| --- | --- | --- |
| `0001-PlatformWin-link-dwrite-outside-ENABLE_VIDEO` | `Source/WebCore/PlatformWin.cmake` | `dwrite` was only linked inside the `ENABLE_VIDEO` block, but Skia's font backend calls `DWriteCreateFactory()`. With `ENABLE_VIDEO=OFF` the build fails at link time. |
| `0002-TextExtraction-guard-HTMLVideoElement` | `Source/WebCore/page/text-extraction/TextExtraction.cpp` | an unguarded `is<HTMLVideoElement>` breaks the build with `ENABLE_VIDEO=OFF`. |
| `0003-GPUProcess-guard-NowPlayingOwnerDidChange` | `Source/WebKit/GPUProcess/GPUProcess.cpp` | `NowPlayingOwnerDidChange` is declared under `#if ENABLE(VIDEO) \|\| ENABLE(WEB_AUDIO)` and was used unconditionally. |
| `0004-wincairo-build-adjustments` | `Source/ThirdParty/skia/CMakeLists.txt`, `Source/WebCore/WebCoreMacros.cmake`, `Source/cmake/WebKitMacros.cmake`, `Tools/Scripts/rewrite-compile-commands` | the build-system side of the trim (Skia codec selection and the WebCore/WebKit cmake macros). This one is a catch-all: it is the least precisely attributed of the four and worth reviewing before it is reapplied to a newer WebKit. |

0001–0003 are the upstream bugs found while trimming with `ENABLE_VIDEO=OFF`; they are
described in `docs/perf-trim.md`, which also records the decision rule that a fourth
defect would mean dropping `ENABLE_VIDEO` from `WK_TRIM` instead of patching again.
