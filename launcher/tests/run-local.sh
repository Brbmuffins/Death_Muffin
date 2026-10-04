#!/usr/bin/env bash
# Runs the launcher logic tests without the .NET SDK: needs a .NET 8 runtime and any Roslyn csc.dll (CSC=/path/to/csc.dll).
# With the SDK installed prefer: dotnet run --project launcher/tests
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
CSC=${CSC:-/home/ubuntu/Unity/Hub/Editor/6000.4.10f1/Editor/Data/DotNetSdkRoslyn/csc.dll}
RT=$(ls -d /usr/lib/dotnet/shared/Microsoft.NETCore.App/8.* | tail -1)
out=${OUT:-$(mktemp -d)}
refs=()
for f in "$RT"/*.dll; do case "$(basename "$f")" in *Native*|mscordaccore*|clrjit*|coreclr*|hostpolicy*|libSystem*) ;; *) refs+=("-r:$f");; esac; done
dotnet "$CSC" -nologo -nostdlib+ -langversion:9 -out:"$out/LauncherTests.dll" -target:exe "${refs[@]}" \
  "$here/Tests.cs" "$here/../windows/ClientLogic.cs" "$here/../windows/ClientInstaller.cs"
cat > "$out/LauncherTests.runtimeconfig.json" <<JSON
{"runtimeOptions":{"tfm":"net8.0","framework":{"name":"Microsoft.NETCore.App","version":"${RT##*/}"}}}
JSON
dotnet "$out/LauncherTests.dll"
