#!/usr/bin/env bash
# Builds a Windows test copy of the launcher on the VPS (no .NET SDK: Roslyn's csc.dll against the .NET Framework 4.8 reference assemblies), for a
# team member to try before a release (the real release is CI's `dotnet build`, README "Release"). The version is stamped from the csproj's
# <Version>, as `dotnet build` does: a copy without it reports 0.0.0, sees every published launcher as newer and replaces itself on start (2026-10-16).
#   bash launcher/windows/build-test-copy.sh [out dir]      -> <out dir>/DeathMuffinLauncher.exe (default: a fresh temp dir)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$(mktemp -d)}"
mkdir -p "$out"
ver="$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' "$here/DeathMuffinLauncher.csproj" | head -1)"
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "build-test-copy: no three-part <Version> in DeathMuffinLauncher.csproj" >&2; exit 1; }
REF="$(ls -d "$HOME"/.nuget/packages/microsoft.netframework.referenceassemblies.net48/*/build/.NETFramework/v4.8 | tail -1)"
CSC="${CSC:-/home/ubuntu/Unity/Hub/Editor/6000.4.10f1/Editor/Data/DotNetSdkRoslyn/csc.dll}"
stamp="$out/AssemblyVersion.cs"
printf '[assembly: System.Reflection.AssemblyVersion("%s.0")]\n[assembly: System.Reflection.AssemblyFileVersion("%s.0")]\n[assembly: System.Reflection.AssemblyInformationalVersion("%s")]\n[assembly: System.Reflection.AssemblyTitle("Death Muffin Launcher")]\n[assembly: System.Reflection.AssemblyProduct("Death Muffin Launcher")]\n' "$ver" "$ver" "$ver" > "$stamp"
refs=()
for n in mscorlib System System.Core System.Drawing System.Windows.Forms System.Net.Http System.Web.Extensions System.Runtime Microsoft.CSharp; do
  [ -f "$REF/$n.dll" ] && refs+=("-r:$REF/$n.dll")
done
refs+=("-r:$REF/Facades/netstandard.dll" "-r:$REF/Facades/System.Runtime.dll")
cd "$here"
nice -n 10 dotnet "$CSC" -nologo -nostdlib+ -langversion:9 -warn:4 -target:winexe -win32icon:Resources/DeathMuffin.ico \
  -out:"$out/DeathMuffinLauncher.exe" "${refs[@]}" -resource:Resources/keyart.jpg,keyart.jpg ./*.cs "$stamp"
rm -f "$stamp"
echo "build-test-copy: $out/DeathMuffinLauncher.exe (version $ver)"
