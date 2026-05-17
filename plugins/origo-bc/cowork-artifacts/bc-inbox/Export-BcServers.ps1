# Export-BcServers.ps1
# Les bc-* servers ur Claude Desktop config og vistar i bc-servers.json
# Keyra thegar nyrri tengingu er baett vid Cowork

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$configPath = "$env:APPDATA\Claude\claude_desktop_config.json"
$outputPath = "$PSScriptRoot\bc-servers.json"

if (-not (Test-Path $configPath)) {
    Write-Error "Config skra finnst ekki: $configPath"
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json
$bcServers = $config.mcpServers.PSObject.Properties |
    Where-Object { $_.Name -like "bc-*" } |
    Select-Object @{N="server";E={$_.Name}}

$bcServers | ConvertTo-Json | Set-Content $outputPath -Encoding UTF8
Write-Host "Vistad $($bcServers.Count) bc-* umhverfi i: $outputPath"
$bcServers | ForEach-Object { Write-Host "  - $($_.server)" }
