# Sourced by run-local.sh and compile-check.sh: sets CSC to a Roslyn csc.dll (CSC=/path/to/csc.dll overrides). Any .NET SDK has one under sdk/<version>/Roslyn/bincore.
for c in "${CSC:-}" \
  /home/ubuntu/Unity/Hub/Editor/6000.4.10f1/Editor/Data/DotNetSdkRoslyn/csc.dll \
  /usr/lib/dotnet/sdk/*/Roslyn/bincore/csc.dll /usr/share/dotnet/sdk/*/Roslyn/bincore/csc.dll \
  "$HOME"/.dotnet/sdk/*/Roslyn/bincore/csc.dll /home/ubuntu/porchlite/.dotnet/sdk/*/Roslyn/bincore/csc.dll; do
  if [ -n "$c" ] && [ -f "$c" ]; then CSC=$c; break; fi
done
[ -f "${CSC:-}" ] || { echo "no Roslyn csc.dll found: set CSC=/path/to/csc.dll (the .NET SDK has one under sdk/<version>/Roslyn/bincore)" >&2; exit 1; }
