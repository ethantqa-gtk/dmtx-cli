$ErrorActionPreference = "Stop"

$exe = "zig-out\bin\dmtx-cli.exe"
$img = "2026-06-20_15-44.png"
$expected = "SXI.SG01130932"

# Read the test image
$bytes = [IO.File]::ReadAllBytes((Resolve-Path $img))
Write-Output "Image size: $($bytes.Length) bytes"

# Build protocol frame: [4-byte LE length][image data]
$len = [BitConverter]::GetBytes([uint32]$bytes.Length)
$frame = $len + $bytes

# Start the listener process
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = (Resolve-Path $exe)
$psi.Arguments              = "--listen"
$psi.RedirectStandardInput  = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.UseShellExecute        = $false
$psi.CreateNoWindow         = $true
$p = [System.Diagnostics.Process]::Start($psi)

# Send the frame
$p.StandardInput.BaseStream.Write($frame, 0, $frame.Length)
$p.StandardInput.Flush()

# Send zero-length frame to signal shutdown
$p.StandardInput.BaseStream.Write([byte[]]::new(4), 0, 4)
$p.StandardInput.Flush()
$p.StandardInput.Close()

# Read the response
$stdout = $p.StandardOutput.BaseStream
$respLen = [byte[]]::new(4)
$read = $stdout.Read($respLen, 0, 4)
if ($read -ne 4) { throw "Failed to read response length (got $read bytes)" }

$contentLen = [BitConverter]::ToUInt32($respLen, 0)
Write-Output "Response content length: $contentLen"

if ($contentLen -gt 0) {
    $content = [byte[]]::new($contentLen)
    $read = 0
    while ($read -lt $contentLen) {
        $n = $stdout.Read($content, $read, $contentLen - $read)
        if ($n -eq 0) { throw "Unexpected EOF reading content" }
        $read += $n
    }
    $decoded = [Text.Encoding]::UTF8.GetString($content)
    Write-Output "Decoded: '$decoded'"

    if ($decoded -eq $expected) {
        Write-Output "PASS: decoded value matches expected"
    } else {
        Write-Output "FAIL: expected '$expected', got '$decoded'"
        exit 1
    }
} else {
    Write-Output "FAIL: no barcode found"
    exit 1
}

# Check for any stderr output
$stderr = $p.StandardError.ReadToEnd()
if ($stderr) { Write-Output "Stderr: $stderr" }

$p.WaitForExit(5000) | Out-Null
Write-Output "Exit code: $($p.ExitCode)"
