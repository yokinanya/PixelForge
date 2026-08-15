param(
    [ValidateSet('arm64', 'arm', 'x86_64', 'x86')]
    [string[]]$Abi = @('arm64', 'arm', 'x86_64', 'x86')
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$ndk = $env:ANDROID_NDK_HOME
if ([string]::IsNullOrWhiteSpace($ndk)) {
    $ndk = $env:ANDROID_NDK
}
if ([string]::IsNullOrWhiteSpace($ndk) -or -not (Test-Path -LiteralPath $ndk -PathType Container)) {
    throw '找不到 NDK，请设置 ANDROID_NDK_HOME'
}

$toolchain = Join-Path $ndk 'toolchains\llvm\prebuilt\windows-x86_64'
if (-not (Test-Path -LiteralPath $toolchain -PathType Container)) {
    throw "Windows NDK LLVM 工具链不存在：$toolchain"
}

$builds = @{
    arm64 = @{ Target = 'aarch64-linux-android'; Abi = 'arm64-v8a'; Clang = 'aarch64-linux-android24-clang.cmd' }
    arm = @{ Target = 'armv7-linux-androideabi'; Abi = 'armeabi-v7a'; Clang = 'armv7a-linux-androideabi24-clang.cmd' }
    x86_64 = @{ Target = 'x86_64-linux-android'; Abi = 'x86_64'; Clang = 'x86_64-linux-android24-clang.cmd' }
    x86 = @{ Target = 'i686-linux-android'; Abi = 'x86'; Clang = 'i686-linux-android24-clang.cmd' }
}

$previousRustFlags = $env:RUSTFLAGS
$remapPath = "--remap-path-prefix=$repoRoot=."
$userRoot = [Environment]::GetFolderPath('UserProfile')
$remapUserPath = "--remap-path-prefix=$userRoot=.user"
if ([string]::IsNullOrWhiteSpace($previousRustFlags)) {
    $env:RUSTFLAGS = "$remapPath $remapUserPath"
} else {
    $env:RUSTFLAGS = "$previousRustFlags $remapPath $remapUserPath"
}

Push-Location $repoRoot
try {
    foreach ($name in $Abi) {
        $build = $builds[$name]
        $bin = Join-Path $toolchain 'bin'
        $envKey = $build.Target.ToUpperInvariant().Replace('-', '_')
        Set-Item -Path "Env:CARGO_TARGET_${envKey}_LINKER" -Value (Join-Path $bin $build.Clang)
        Set-Item -Path "Env:CARGO_TARGET_${envKey}_AR" -Value (Join-Path $bin 'llvm-ar.exe')
        Write-Host "==> 构建 $($build.Abi) ($($build.Target))"
        cargo build --manifest-path rust/Cargo.toml -p stitch_bridge --release --target $build.Target
        if ($LASTEXITCODE -ne 0) {
            throw "native 构建失败：$($build.Target)"
        }
        $source = "rust/target/$($build.Target)/release/libstitch_bridge.so"
        $destination = "android/app/src/main/jniLibs/$($build.Abi)/libstitch_bridge.so"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}
finally {
    if ($null -eq $previousRustFlags) {
        Remove-Item Env:RUSTFLAGS -ErrorAction SilentlyContinue
    } else {
        $env:RUSTFLAGS = $previousRustFlags
    }
    Pop-Location
}

Get-ChildItem -Path (Join-Path $repoRoot 'android/app/src/main/jniLibs') -Filter '*.so' -Recurse |
    Sort-Object FullName |
    Select-Object -ExpandProperty FullName
