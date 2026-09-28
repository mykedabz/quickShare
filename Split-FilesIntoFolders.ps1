<#
.SYNOPSIS
    Splits the files in a folder or zip into numbered sub-folders, each totalling less than a size limit (default 10 MB).

.DESCRIPTION
    The source can be a folder of files or a .zip file. A zip is extracted automatically
    to a folder with the same name beside it, and every file inside it is included.

    Files are processed in name order and packed into batch folders one after another.
    When adding the next file would reach or exceed the limit, a new batch folder is
    started, so every batch folder ends up strictly under the limit.

    Any single file that is itself at or over the limit cannot be batched. It is placed
    in a separate oversize folder and reported, so it can be tracked and handled manually.

    Files are copied by default so the source stays intact. Use -Move to move them instead.
    Works with any file type.

.PARAMETER SourceFolder
    Folder containing the files to split, or a .zip file to extract and split. Required.

.PARAMETER DestinationFolder
    Where the batch folders are created. Defaults to a sibling folder named "<SourceName>_Split".

.PARAMETER MaxFolderSizeMB
    Size limit per folder in MB (1 MB = 1,048,576 bytes). Defaults to 10.
    If the receiving system enforces a strict 10 MB cap, consider 9.5 for headroom.

.PARAMETER FolderPrefix
    Prefix for the batch folder names. Defaults to "Batch" (Batch_001, Batch_002, ...).

.PARAMETER Move
    Move files instead of copying them.

.PARAMETER Recurse
    Include files found in sub-folders of the source.

.EXAMPLE
    .\Split-FilesIntoFolders.ps1 -SourceFolder "D:\Drop\Records.zip"

.EXAMPLE
    .\Split-FilesIntoFolders.ps1 -SourceFolder "D:\Drop\Extracted" -DestinationFolder "D:\Outgoing" -MaxFolderSizeMB 9.5 -Move
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceFolder,

    [string]$DestinationFolder,

    [ValidateRange(0.1, 10240)]
    [double]$MaxFolderSizeMB = 10,

    [string]$FolderPrefix = "Batch",

    [switch]$Move,

    [switch]$Recurse
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# Returns a path in $Folder based on $FileName, adding a numeric suffix if the name is taken.
function Get-UniquePath {
    param([string]$Folder, [string]$FileName)

    $candidate = Join-Path $Folder $FileName
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $ext  = [System.IO.Path]::GetExtension($FileName)
    $i = 1
    do {
        $candidate = Join-Path $Folder ("{0}_{1}{2}" -f $base, $i, $ext)
        $i++
    } while (Test-Path -LiteralPath $candidate)
    return $candidate
}

# --- Validate and resolve paths ---
# A .zip source is extracted automatically to a folder with the same name beside it.
if ((Test-Path -LiteralPath $SourceFolder -PathType Leaf) -and
    ([System.IO.Path]::GetExtension($SourceFolder) -ieq ".zip")) {

    $zipPath = (Resolve-Path -LiteralPath $SourceFolder).Path
    $extractTo = Join-Path (Split-Path -Parent $zipPath) ([System.IO.Path]::GetFileNameWithoutExtension($zipPath))

    if (Test-Path -LiteralPath $extractTo) {
        Write-Host ("Using previously extracted folder: {0}" -f $extractTo)
    }
    else {
        Write-Host ("Extracting {0} ..." -f (Split-Path -Leaf $zipPath))
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractTo
    }

    $SourceFolder = $extractTo
    $Recurse = $true   # zips often contain internal folders; include everything
}
elseif (Test-Path -LiteralPath $SourceFolder -PathType Leaf) {
    throw "Source must be a folder or a .zip file: $SourceFolder"
}

if (-not (Test-Path -LiteralPath $SourceFolder -PathType Container)) {
    throw "Source folder not found: $SourceFolder"
}
$resolvedSource = (Resolve-Path -LiteralPath $SourceFolder).Path

if (-not $DestinationFolder) {
    $parent = Split-Path -Parent $resolvedSource
    if ([string]::IsNullOrEmpty($parent)) { $parent = $resolvedSource }
    $leaf = (Split-Path -Leaf $resolvedSource).TrimEnd('\', ':')
    $DestinationFolder = Join-Path $parent ($leaf + "_Split")
}
if (-not (Test-Path -LiteralPath $DestinationFolder)) {
    New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null
}
$resolvedDest = (Resolve-Path -LiteralPath $DestinationFolder).Path

$maxBytes = [long]($MaxFolderSizeMB * 1MB)
$oversizeFolder = Join-Path $resolvedDest ("Over_{0}MB" -f $MaxFolderSizeMB)

# --- Gather files (excluding anything already in the destination) ---
$files = @(Get-ChildItem -LiteralPath $resolvedSource -File -Recurse:$Recurse |
    Where-Object { -not $_.FullName.StartsWith($resolvedDest, [System.StringComparison]::OrdinalIgnoreCase) } |
    Sort-Object Name)

if ($files.Count -eq 0) {
    Write-Warning "No files found in $resolvedSource"
    return
}

# --- Pack files into batch folders ---
$batchIndex = 0
$currentBatchPath = $null
$currentBatchBytes = [long]0
$batchedCount = 0
$oversizeCount = 0
$failedCount = 0

foreach ($file in $files) {

    # A single file at or over the limit cannot go in any batch.
    if ($file.Length -ge $maxBytes) {
        try {
            if (-not (Test-Path -LiteralPath $oversizeFolder)) {
                New-Item -ItemType Directory -Path $oversizeFolder -Force | Out-Null
            }
            $target = Get-UniquePath -Folder $oversizeFolder -FileName $file.Name
            if ($Move) { Move-Item -LiteralPath $file.FullName -Destination $target }
            else       { Copy-Item -LiteralPath $file.FullName -Destination $target }
            $oversizeCount++
            Write-Warning ("{0} is {1:N2} MB, over the {2} MB limit. Placed in the oversize folder." -f $file.Name, ($file.Length / 1MB), $MaxFolderSizeMB)
        }
        catch {
            $failedCount++
            Write-Warning ("Failed to process {0}: {1}" -f $file.FullName, $_.Exception.Message)
        }
        continue
    }

    # Start a new batch folder if this file will not fit in the current one.
    if (($null -eq $currentBatchPath) -or (($currentBatchBytes + $file.Length) -ge $maxBytes)) {
        $batchIndex++
        $currentBatchPath = Join-Path $resolvedDest ("{0}_{1:D3}" -f $FolderPrefix, $batchIndex)
        New-Item -ItemType Directory -Path $currentBatchPath -Force | Out-Null
        $currentBatchBytes = 0
    }

    try {
        $target = Get-UniquePath -Folder $currentBatchPath -FileName $file.Name
        if ($Move) { Move-Item -LiteralPath $file.FullName -Destination $target }
        else       { Copy-Item -LiteralPath $file.FullName -Destination $target }
        $currentBatchBytes += $file.Length
        $batchedCount++
    }
    catch {
        $failedCount++
        Write-Warning ("Failed to process {0}: {1}" -f $file.FullName, $_.Exception.Message)
    }
}

# --- Summary ---
Write-Host ""
Write-Host "Split complete."
Write-Host ("  Batch folders created : {0}" -f $batchIndex)
Write-Host ("  Files batched         : {0}" -f $batchedCount)
Write-Host ("  Oversize files        : {0}" -f $oversizeCount)
Write-Host ("  Failures              : {0}" -f $failedCount)
Write-Host ("  Output location       : {0}" -f $resolvedDest)
