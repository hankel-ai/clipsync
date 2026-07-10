BeforeAll {
    . $PSScriptRoot/cc-handoff.ps1
}

Describe 'Get-HandoffName' {
    It 'returns the leaf folder name' {
        Get-HandoffName -Source 'C:\work\my-project' | Should -Be 'my-project'
    }
    It 'tolerates a trailing backslash' {
        Get-HandoffName -Source 'C:\work\my-project\' | Should -Be 'my-project'
    }
    It 'tolerates a trailing forward slash' {
        Get-HandoffName -Source 'C:/work/my-project/' | Should -Be 'my-project'
    }
}

Describe 'Get-IncludedFiles' {
    BeforeAll {
        function New-TempDir {
            $d = Join-Path $env:TEMP ("cchandoff_" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            return $d
        }
    }

    It 'includes tracked + untracked-not-ignored, excludes ignored and .git' {
        $repo = New-TempDir
        try {
            Push-Location $repo
            git init -q
            git config user.email t@t.t; git config user.name t
            Set-Content -Path (Join-Path $repo '.gitignore') -Value @('secret.env','build/','*.log') -Encoding ascii
            Set-Content -Path (Join-Path $repo 'app.js')     -Value 'x' -Encoding ascii
            Set-Content -Path (Join-Path $repo 'secret.env') -Value 'K=1' -Encoding ascii
            Set-Content -Path (Join-Path $repo 'debug.log')  -Value 'l' -Encoding ascii
            New-Item -ItemType Directory -Force -Path (Join-Path $repo 'build') | Out-Null
            Set-Content -Path (Join-Path $repo 'build\out.o') -Value 'o' -Encoding ascii
            git add app.js .gitignore | Out-Null
            git commit -qm init | Out-Null
            Set-Content -Path (Join-Path $repo 'new-untracked.js') -Value 'y' -Encoding ascii
            Pop-Location

            $got = Get-IncludedFiles -Source $repo
            $got | Should -Contain 'app.js'
            $got | Should -Contain '.gitignore'
            $got | Should -Contain 'new-untracked.js'
            $got | Should -Not -Contain 'secret.env'
            $got | Should -Not -Contain 'debug.log'
            ($got -join '|') | Should -Not -Match 'build/'
            ($got -join '|') | Should -Not -Match '\.git/'
        } finally { Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue }
    }

    It 'falls back to all files except .git for a non-repo' {
        $dir = New-TempDir
        try {
            Set-Content -Path (Join-Path $dir 'a.txt') -Value 'a' -Encoding ascii
            New-Item -ItemType Directory -Force -Path (Join-Path $dir '.git') | Out-Null
            Set-Content -Path (Join-Path $dir '.git\config') -Value 'x' -Encoding ascii
            $got = Get-IncludedFiles -Source $dir
            $got | Should -Contain 'a.txt'
            ($got -join '|') | Should -Not -Match '\.git/'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }
}

Describe 'Copy-IncludeTree' {
    It 'copies only the listed files, preserving structure' {
        $src = Join-Path $env:TEMP ("cchsrc_" + [Guid]::NewGuid().ToString('N'))
        $dst = Join-Path $env:TEMP ("cchdst_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $src 'sub') | Out-Null
        Set-Content (Join-Path $src 'keep.txt')     'k' -Encoding ascii
        Set-Content (Join-Path $src 'sub\deep.txt') 'd' -Encoding ascii
        Set-Content (Join-Path $src 'skip.txt')     's' -Encoding ascii
        try {
            Copy-IncludeTree -Source $src -Files @('keep.txt','sub/deep.txt') -Dest $dst
            Test-Path (Join-Path $dst 'keep.txt')     | Should -BeTrue
            Test-Path (Join-Path $dst 'sub\deep.txt') | Should -BeTrue
            Test-Path (Join-Path $dst 'skip.txt')     | Should -BeFalse
        } finally {
            Remove-Item -Recurse -Force $src,$dst -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Copy-Changes' {
    It 'copies new and changed files without deleting extras in dest' {
        $from = Join-Path $env:TEMP ("cchf_" + [Guid]::NewGuid().ToString('N'))
        $to   = Join-Path $env:TEMP ("ccht_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $from,$to | Out-Null
        Set-Content (Join-Path $from 'a.txt') 'new'  -Encoding ascii   # changed
        Set-Content (Join-Path $from 'b.txt') 'b'    -Encoding ascii   # added
        Set-Content (Join-Path $to   'a.txt') 'old'  -Encoding ascii
        Set-Content (Join-Path $to   '.env')  'K=1'  -Encoding ascii   # extra in dest, must survive
        try {
            $code = Copy-Changes -From $from -To $to
            $code | Should -Be 2   # both source files copied deterministically
            (Get-Content (Join-Path $to 'a.txt')) | Should -Be 'new'
            Test-Path (Join-Path $to 'b.txt') | Should -BeTrue
            Test-Path (Join-Path $to '.env')  | Should -BeTrue   # NOT purged
        } finally { Remove-Item -Recurse -Force $from,$to -ErrorAction SilentlyContinue }
    }

    It 'recreates NEW directories, including empty ones' {
        $from = Join-Path $env:TEMP ("cchfe_" + [Guid]::NewGuid().ToString('N'))
        $to   = Join-Path $env:TEMP ("cchte_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $from,$to | Out-Null
        Set-Content (Join-Path $from 'New Text Document.txt') 'x' -Encoding ascii
        New-Item -ItemType Directory -Force -Path (Join-Path $from 'New folder') | Out-Null           # empty
        New-Item -ItemType Directory -Force -Path (Join-Path $from 'nested\deep') | Out-Null           # empty nested
        try {
            [void](Copy-Changes -From $from -To $to)
            Test-Path (Join-Path $to 'New Text Document.txt') | Should -BeTrue
            Test-Path (Join-Path $to 'New folder')            | Should -BeTrue   # empty dir must sync
            Test-Path (Join-Path $to 'nested\deep')           | Should -BeTrue   # empty nested dir must sync
        } finally { Remove-Item -Recurse -Force $from,$to -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-TreeRelPaths' {
    It 'returns every file as forward-slash relative paths' {
        $root = Join-Path $env:TEMP ("cchtree_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'sub') | Out-Null
        Set-Content (Join-Path $root 'a.txt')     'a' -Encoding ascii
        Set-Content (Join-Path $root 'sub\b.txt') 'b' -Encoding ascii
        try {
            $got = Get-TreeRelPaths -Root $root
            $got | Should -Contain 'a.txt'
            $got | Should -Contain 'sub/b.txt'
            $got.Count | Should -Be 2
        } finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    }
}

Describe 'Remove-DeletedFromManifest' {
    It 'deletes only manifest files missing from the pulled tree' {
        $src    = Join-Path $env:TEMP ("cchs_" + [Guid]::NewGuid().ToString('N'))
        $pulled = Join-Path $env:TEMP ("cchp_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $src,$pulled | Out-Null
        # Source has a tracked file, a deleted-by-Claude file, plus untracked .git/.env
        Set-Content (Join-Path $src 'keep.txt')  'k' -Encoding ascii
        Set-Content (Join-Path $src 'gone.txt')  'g' -Encoding ascii
        Set-Content (Join-Path $src '.env')      'K' -Encoding ascii
        New-Item -ItemType Directory -Force -Path (Join-Path $src '.git') | Out-Null
        Set-Content (Join-Path $src '.git\cfg')  'c' -Encoding ascii
        # Pulled tree still has keep.txt but NOT gone.txt
        Set-Content (Join-Path $pulled 'keep.txt') 'k' -Encoding ascii
        try {
            $removed = Remove-DeletedFromManifest -Source $src -PulledRoot $pulled -Manifest @('keep.txt','gone.txt')
            $removed | Should -Contain 'gone.txt'
            Test-Path (Join-Path $src 'gone.txt') | Should -BeFalse   # propagated deletion
            Test-Path (Join-Path $src 'keep.txt') | Should -BeTrue    # still present
            Test-Path (Join-Path $src '.env')     | Should -BeTrue    # NOT in manifest -> untouched
            Test-Path (Join-Path $src '.git\cfg') | Should -BeTrue    # NOT in manifest -> untouched
        } finally { Remove-Item -Recurse -Force $src,$pulled -ErrorAction SilentlyContinue }
    }
}

Describe 'Remove-IgnoredFiles' {
    It 'removes files ignored by the repo rules, keeps the rest' {
        $repo = Join-Path $env:TEMP ("cchr_" + [Guid]::NewGuid().ToString('N'))
        $root = Join-Path $env:TEMP ("cchpull_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $repo,$root | Out-Null
        Push-Location $repo
        git init -q; git config user.email t@t.t; git config user.name t
        Set-Content (Join-Path $repo '.gitignore') @('*.log','dist/') -Encoding ascii
        Pop-Location
        # Pulled tree: a good file + a newly-created ignored file + ignored dir
        Set-Content (Join-Path $root 'app.js')  'x' -Encoding ascii
        Set-Content (Join-Path $root 'run.log') 'l' -Encoding ascii
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'dist') | Out-Null
        Set-Content (Join-Path $root 'dist\bundle.js') 'b' -Encoding ascii
        try {
            $removed = Remove-IgnoredFiles -Repo $repo -Root $root
            Test-Path (Join-Path $root 'app.js')         | Should -BeTrue
            Test-Path (Join-Path $root 'run.log')        | Should -BeFalse
            Test-Path (Join-Path $root 'dist\bundle.js') | Should -BeFalse
            ($removed -join '|') | Should -Match 'run.log'
        } finally { Remove-Item -Recurse -Force $repo,$root -ErrorAction SilentlyContinue }
    }
}
