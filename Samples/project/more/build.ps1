# Build script
param([string]$Configuration = "Release")
$items = @(1, 2, 3)
function Get-Greeting {
    param([string]$Name)
    if ($Name -eq "") { return "Hello" }
    return "Hello, $Name"
}
foreach ($i in $items) { Write-Host (Get-Greeting -Name "user $i") }
