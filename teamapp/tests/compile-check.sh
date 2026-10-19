#!/usr/bin/env bash
# Compiles the WHOLE team app, UI included, with Roslyn's csc.dll against the .NET Framework 4.8 reference assemblies (no .NET SDK, no Windows): the check of the
# WinForms and Windows code before a real build on windows-latest (.github/workflows/teamapp-windows.yml). It cannot run the app: see teamapp/README.md "What only a PC can check".
#   bash teamapp/tests/compile-check.sh [out dir]    -> <out dir>/DeathMuffinTeam.exe (default: a temporary folder that is removed); version stamped from the csproj <Version>
# CSC=/path/to/csc.dll picks the compiler (find-csc.sh looks in the usual places).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
app="$here/../windows"
# shellcheck source=find-csc.sh
. "$here/find-csc.sh"
REF=${REF:-$(ls -d "$HOME"/.nuget/packages/microsoft.netframework.referenceassemblies.net48/*/build/.NETFramework/v4.8 2>/dev/null | tail -1 || true)}
[ -d "$REF" ] || { echo "compile-check: no .NET Framework 4.8 reference assemblies (set REF=<dir>; the NuGet package microsoft.netframework.referenceassemblies.net48 has them)" >&2; exit 1; }
if [ -n "${1:-}" ]; then out=$1; mkdir -p "$out"; else out=$(mktemp -d); trap 'rm -rf "$out"' EXIT; fi
ver=$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' "$app/DeathMuffinTeam.csproj" | head -1)
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "compile-check: no three-part <Version> in DeathMuffinTeam.csproj" >&2; exit 1; }
# The stamp does what the SDK's <Version> does in dotnet build: without it the exe reports 0.0.0 and would see every published version as newer.
stamp="$out/AssemblyVersion.cs"
printf '[assembly: System.Reflection.AssemblyVersion("%s.0")]\n[assembly: System.Reflection.AssemblyFileVersion("%s.0")]\n[assembly: System.Reflection.AssemblyInformationalVersion("%s")]\n[assembly: System.Reflection.AssemblyTitle("Death Muffin Team")]\n[assembly: System.Reflection.AssemblyProduct("Death Muffin Team")]\n' "$ver" "$ver" "$ver" > "$stamp"
refs=()
for n in mscorlib System System.Core System.Drawing System.Windows.Forms System.Net.Http System.Security System.Runtime Microsoft.CSharp; do
  [ -f "$REF/$n.dll" ] && refs+=("-r:$REF/$n.dll")
done
refs+=("-r:$REF/Facades/netstandard.dll" "-r:$REF/Facades/System.Runtime.dll")
cd "$app"
nice -n 10 dotnet "$CSC" -nologo -nostdlib+ -langversion:9 -warn:4 -warnaserror+ -platform:x64 -target:winexe -win32icon:Resources/DeathMuffin.ico \
  -out:"$out/DeathMuffinTeam.exe" "${refs[@]}" ./*.cs "$stamp"
echo "compile-check: OK, DeathMuffinTeam.exe $ver ($(stat -c %s "$out/DeathMuffinTeam.exe") bytes)"
