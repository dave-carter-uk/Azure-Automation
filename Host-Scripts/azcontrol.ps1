# appcontrol.ps1 wrapper

& $PSScriptRoot\appcontrol.ps1 @Args *>&1 | Tee-Object -FilePath "$PSScriptRoot\logs\azcontrol_$(Get-Date -Format FileDate).log" -Append

# Delete old log files
Get-ChildItem -Path $PSScriptRoot\logs -Filter "azcontrol*.log" | Where {$_.LastWriteTime -lt (Get-Date).AddDays(-7)} |	Remove-Item


