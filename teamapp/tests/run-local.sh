#!/usr/bin/env bash
# Runs the team app's logic tests without the .NET SDK: needs a .NET 8 runtime and any Roslyn csc.dll (CSC=/path/to/csc.dll; find-csc.sh looks in the usual places).
# With the SDK installed prefer: dotnet run --project teamapp/tests
# The tests compile the app's logic files (everything but the WinForms and Windows files) and start nothing but a local HTTP server and, on Linux, a tiny stand-in game.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=find-csc.sh
. "$here/find-csc.sh"
RT=$(ls -d /usr/lib/dotnet/shared/Microsoft.NETCore.App/8.* | tail -1)
out=${OUT:-$(mktemp -d)}
mkdir -p "$out"
refs=()
for f in "$RT"/*.dll; do case "$(basename "$f")" in *Native*|mscordaccore*|clrjit*|coreclr*|hostpolicy*|libSystem*) ;; *) refs+=("-r:$f");; esac; done
win="$here/../windows"
logic=("$win/Json.cs" "$win/TeamLogic.cs" "$win/Quiet.cs" "$win/JobPlan.cs" "$win/Settings.cs" "$win/TeamApi.cs" "$win/TeamFolders.cs" "$win/FileFetcher.cs" "$win/GameHost.cs" "$win/VideoEncoder.cs" "$win/Comfy.cs" "$win/JobRunner.cs" "$win/SelfUpdate.cs" "$win/TeamController.cs")
nice -n 10 dotnet "$CSC" -nologo -nostdlib+ -langversion:9 -warn:4 -out:"$out/TeamTests.dll" -target:exe -resource:"$here/../comfy/image-to-model.json",image-to-model.json "${refs[@]}" "$here"/*.cs "${logic[@]}"
cat > "$out/TeamTests.runtimeconfig.json" <<JSON
{"runtimeOptions":{"tfm":"net8.0","framework":{"name":"Microsoft.NETCore.App","version":"${RT##*/}"}}}
JSON
nice -n 10 dotnet "$out/TeamTests.dll"
