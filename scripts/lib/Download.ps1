Set-StrictMode -Version Latest

# Shared by scripts and workflows that fetch release files. Not run on its own: callers dot-source it.

# The one place that downloads. Tests mock this function, so they never need a network.
function Invoke-Download {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [string] $OutFile
    )
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -ErrorAction Stop
}

# SHA-256 of a file as lower-case hex.
function Get-FileSha256 {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Path)
    (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Downloads a release file and the checksum file published with it. Keeps the file only when its
# SHA-256 matches the line "<64 hex>  <file name>" (or "<64 hex> *<file name>") in the checksum file.
# Throws, after deleting the download, when that line is missing or the hash differs.
function Save-VerifiedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [string] $ChecksumUri,
        [Parameter(Mandatory)] [string] $Path
    )
    $name = [uri]::UnescapeDataString(([uri] $Uri).Segments[-1])
    $sums = "$Path.sha256"
    try {
        Invoke-Download -Uri $Uri -OutFile $Path
        Invoke-Download -Uri $ChecksumUri -OutFile $sums
        $pattern = "^(?<hash>[0-9a-fA-F]{64})\s+\*?$([regex]::Escape($name))\s*$"
        $line = @(Get-Content -Path $sums) | Where-Object { $_ -match $pattern } | Select-Object -First 1
        if (-not $line) {
            throw "No checksum for $name in $ChecksumUri."
        }
        $expected = ([regex]::Match($line, $pattern)).Groups['hash'].Value.ToLowerInvariant()
        if ((Get-FileSha256 -Path $Path) -ne $expected) {
            throw "Checksum mismatch for $name."
        }
    } catch {
        Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        Remove-Item -Path $sums -Force -ErrorAction SilentlyContinue
    }
}
