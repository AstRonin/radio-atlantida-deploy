# Test image of the install.ps1 Pester tests and PSScriptAnalyzer
# (tests/install/run.sh; deploy-init-plan.md D7 9.1 items 8 and 10).
# PowerShell 7 on Linux: the Windows-only cmdlets are mocked, so the tests
# exercise install.ps1's logic, not Windows itself; CI on a Windows runner
# (D7) runs the same tests under Windows PowerShell 5.1. Pinned by digest
# (the image is amd64 only; on Apple Silicon it runs under emulation).
FROM mcr.microsoft.com/powershell:7.5-ubuntu-24.04@sha256:042240d57ec9e47e511033b92625a8d95875ee5860af3015992c248b58a8be81
RUN pwsh -NoProfile -NonInteractive -Command "\
  \$ErrorActionPreference = 'Stop'; \
  Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; \
  Install-Module -Name Pester -RequiredVersion 5.7.1 -Scope AllUsers -Force -SkipPublisherCheck; \
  Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope AllUsers -Force"
