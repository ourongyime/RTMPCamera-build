# backup.ps1 - 备份当前源码
$ver = Get-Content "VERSION" -ErrorAction SilentlyContinue
if (-not $ver) { $ver = "unknown" }
$dir = "backups\v$ver"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item -Recurse -Force * -Exclude "backups","RTMPCamera_项目总结.txt",".git" -Destination $dir
Write-Host "已备份 v$ver -> $dir/"
