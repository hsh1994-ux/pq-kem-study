# One-time setup of the results viewer on Windows (PowerShell).
# Not needed if the platform folders (windows/ etc.) were already committed
# from another machine: then just run `flutter run -d windows`.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Error "flutter not found: install Flutter first, https://docs.flutter.dev/get-started/install/windows"
}
flutter config --enable-windows-desktop | Out-Null
flutter create --platforms=windows,macos,linux --project-name pq_results --org org.pqkemstudy .
flutter pub get
Write-Host ""
Write-Host "Done. Start the viewer with:   flutter run -d windows"
