BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'lib', 'Download.ps1')
}

Describe 'Save-VerifiedFile' {
    BeforeEach {
        $script:dir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir | Out-Null
        $script:target = Join-Path -Path $script:dir -ChildPath 'tool.tar.gz'
        $script:content = 'release bytes'
        $script:hash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($script:content))) -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:sumsText = "$($script:hash)  tool.tar.gz"
        Mock Invoke-Download {
            if ($Uri -like '*.sha256') { Set-Content -Path $OutFile -Value $script:sumsText }
            else { Set-Content -Path $OutFile -Value $script:content -NoNewline }
        }
    }
    AfterEach { Remove-Item -Path $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'keeps the file when the checksum matches' {
        Save-VerifiedFile -Uri 'https://example.test/tool.tar.gz' -ChecksumUri 'https://example.test/tool.tar.gz.sha256' -Path $script:target
        Test-Path -Path $script:target | Should -BeTrue
        Test-Path -Path "$($script:target).sha256" | Should -BeFalse
    }

    It 'accepts a star-prefixed name (binary mode)' {
        $script:sumsText = "$($script:hash.ToUpperInvariant()) *tool.tar.gz"
        { Save-VerifiedFile -Uri 'https://example.test/tool.tar.gz' -ChecksumUri 'https://example.test/tool.tar.gz.sha256' -Path $script:target } | Should -Not -Throw
    }

    It 'finds its line among several' {
        $script:sumsText = "$('a' * 64)  other.zip`n$($script:hash)  tool.tar.gz"
        { Save-VerifiedFile -Uri 'https://example.test/tool.tar.gz' -ChecksumUri 'https://example.test/tool.tar.gz.sha256' -Path $script:target } | Should -Not -Throw
    }

    It 'throws and deletes the download on a mismatch' {
        $script:sumsText = "$('0' * 64)  tool.tar.gz"
        { Save-VerifiedFile -Uri 'https://example.test/tool.tar.gz' -ChecksumUri 'https://example.test/tool.tar.gz.sha256' -Path $script:target } | Should -Throw '*Checksum mismatch*'
        Test-Path -Path $script:target | Should -BeFalse
    }

    It 'throws and deletes the download when the file has no line' {
        $script:sumsText = "$($script:hash)  other.tar.gz"
        { Save-VerifiedFile -Uri 'https://example.test/tool.tar.gz' -ChecksumUri 'https://example.test/tool.tar.gz.sha256' -Path $script:target } | Should -Throw '*No checksum for tool.tar.gz*'
        Test-Path -Path $script:target | Should -BeFalse
    }

    It 'does not treat a longer name as a match' {
        $script:sumsText = "$($script:hash)  tool.tar.gz.asc"
        { Save-VerifiedFile -Uri 'https://example.test/tool.tar.gz' -ChecksumUri 'https://example.test/tool.tar.gz.sha256' -Path $script:target } | Should -Throw '*No checksum*'
    }
}

Describe 'Get-FileSha256' {
    It 'returns the lower-case SHA-256 of the file' {
        $file = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([guid]::NewGuid().ToString('N'))
        Set-Content -Path $file -Value 'abc' -NoNewline
        try {
            Get-FileSha256 -Path $file | Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        } finally {
            Remove-Item -Path $file -Force
        }
    }
}
