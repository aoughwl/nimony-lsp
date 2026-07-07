# Compile settings for nimony-lsp.
switch("path", "$projectDir/src")
# Nimony's reusable NIF libraries (nifstreams/nifcursors/nifindexes/symparser/...)
# used by driver/nifindex.nim for in-process artifact reading.
switch("path", "/home/savant/nimony/src/lib")
switch("path", "/home/savant/nimony/src")
switch("mm", "orc")
switch("threads", "off")
# Keep diagnostics quiet for a clean build log; flip on when debugging.
switch("hints", "off")
switch("warning", "UnusedImport:off")
