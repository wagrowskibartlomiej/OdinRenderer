$ShaderDir = "./assets/shaders"
$SpirvDir = "$ShaderDir/spirv"

if (-not (Test-Path $SpirvDir)) {
    New-Item -Path $SpirvDir -ItemType Directory | Out-Null
}

function Compile-Shaders {
    $Shaders = Get-ChildItem -Path $ShaderDir -Include *.vert, *.frag -File

    foreach ($Shader in $Shaders) {
        $FilenameNoExt = $Shader.BaseName
        $OutputFile = Join-Path $SpirvDir "$FilenameNoExt.spv"

        Write-Host "Compiling: $($Shader.Name) -> $FilenameNoExt.spv"

        & glslc "$($Shader.FullName)" -o "$OutputFile" --target-env=vulkan1.0
    }
}

Compile-Shaders

Write-Host "Compiled shaders are in $SpirvDir"
