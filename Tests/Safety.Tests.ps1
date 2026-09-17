<#
    Tests/Safety.Tests.ps1 - path safety and policy enforcement.

    These cover the invariants that stop the toolkit destroying something it should not.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    [void](Import-WaForTest)
}

Describe 'Path normalisation' -Tag 'Safety' {

    It 'rejects a relative path' {
        { Invoke-WaInternal { Get-WaNormalizedPath -Path 'Windows\Temp' } } | Should -Throw
    }

    It 'rejects a UNC path' {
        { Invoke-WaInternal { Get-WaNormalizedPath -Path '\\server\share\file' } } | Should -Throw
    }

    It 'rejects wildcards' {
        { Invoke-WaInternal { Get-WaNormalizedPath -Path 'C:\Temp\*' } } | Should -Throw
    }

    It 'rejects an alternate data stream' {
        { Invoke-WaInternal { Get-WaNormalizedPath -Path 'C:\Temp\file.txt:hidden' } } | Should -Throw
    }

    It 'rejects an empty path' {
        { Invoke-WaInternal { Get-WaNormalizedPath -Path '' } } | Should -Throw
    }

    It 'resolves traversal segments so a prefix check cannot be fooled' {
        $result = Invoke-WaInternal { Get-WaNormalizedPath -Path 'C:\Users\Public\..\..\Windows\System32' }
        $result | Should -Be 'C:\Windows\System32'
    }

    It 'preserves a drive root' {
        Invoke-WaInternal { Get-WaNormalizedPath -Path 'C:\' } | Should -Be 'C:\'
    }
}

Describe 'Containment checks' -Tag 'Safety' {

    It 'treats a path inside a root as contained' {
        Invoke-WaInternal { Test-WaPathWithin -Path 'C:\Temp\sub\file.txt' -Root 'C:\Temp' } | Should -BeTrue
    }

    It 'does not treat a sibling with a shared prefix as contained' {
        # C:\TempEvil must not be considered inside C:\Temp.
        Invoke-WaInternal { Test-WaPathWithin -Path 'C:\TempEvil\file.txt' -Root 'C:\Temp' } | Should -BeFalse
    }

    It 'excludes the root itself unless AllowEqual is given' {
        Invoke-WaInternal { Test-WaPathWithin -Path 'C:\Temp' -Root 'C:\Temp' } | Should -BeFalse
        Invoke-WaInternal { Test-WaPathWithin -Path 'C:\Temp' -Root 'C:\Temp' -AllowEqual } | Should -BeTrue
    }

    It 'resolves traversal before comparing, so escape attempts fail' {
        Invoke-WaInternal { Test-WaPathWithin -Path 'C:\Temp\..\Windows\System32' -Root 'C:\Temp' } | Should -BeFalse
    }
}

Describe 'Protected locations' -Tag 'Safety' {

    BeforeAll {
        $script:policy = Invoke-WaInternal { Get-WaPolicy }
        $script:basePaths = Invoke-WaInternal { Get-WaBasePaths }
    }

    It 'protects the Windows directory' {
        Invoke-WaInternal { param($p, $b) Test-WaProtectedPath -Path (Join-Path $b.Windows 'System32') -Policy $p } $script:policy $script:basePaths |
            Should -BeTrue
    }

    It 'protects WinSxS' {
        Invoke-WaInternal { param($p, $b) Test-WaProtectedPath -Path (Join-Path $b.Windows 'WinSxS\somefile.dll') -Policy $p } $script:policy $script:basePaths |
            Should -BeTrue
    }

    It 'protects Prefetch, which is never a cleanup target' {
        Invoke-WaInternal { param($p, $b) Test-WaProtectedPath -Path (Join-Path $b.Windows 'Prefetch') -Policy $p } $script:policy $script:basePaths |
            Should -BeTrue
    }

    It 'protects Documents' {
        Invoke-WaInternal { param($p, $b) Test-WaProtectedPath -Path (Join-Path $b.Documents 'report.docx') -Policy $p } $script:policy $script:basePaths |
            Should -BeTrue
    }

    It 'protects Desktop and Downloads' {
        foreach ($folder in @('Desktop', 'Downloads')) {
            Invoke-WaInternal { param($p, $b, $f) Test-WaProtectedPath -Path (Join-Path $b.UserProfile $f) -Policy $p } $script:policy $script:basePaths $folder |
                Should -BeTrue -Because "$folder holds user data"
        }
    }

    It 'protects the user profile root itself' {
        Invoke-WaInternal { param($p, $b) Test-WaProtectedPath -Path $b.UserProfile -Policy $p } $script:policy $script:basePaths |
            Should -BeTrue
    }

    It 'protects the system drive root itself' {
        Invoke-WaInternal { param($p, $b) Test-WaProtectedPath -Path $b.SystemDrive -Policy $p } $script:policy $script:basePaths |
            Should -BeTrue
    }

    It 'does NOT protect application caches inside the profile, or the toolkit is useless' {
        # Regression guard: protecting the profile recursively silently disabled every
        # per-user cache provider.
        Invoke-WaInternal { param($p, $b) Test-WaProtectedPath -Path (Join-Path $b.LocalAppData 'Temp') -Policy $p } $script:policy $script:basePaths |
            Should -BeFalse
    }

    It 'exempts Windows\Temp, which is an approved cleanup root under a protected parent' {
        Invoke-WaInternal { param($p, $b) Test-WaProtectedPath -Path (Join-Path $b.Windows 'Temp\leftover.tmp') -Policy $p } $script:policy $script:basePaths |
            Should -BeFalse
    }

    It 'still protects siblings of the exempted directory' {
        Invoke-WaInternal { param($p, $b) Test-WaProtectedPath -Path (Join-Path $b.Windows 'System32\drivers') -Policy $p } $script:policy $script:basePaths |
            Should -BeTrue
    }

    It 'protects DPAPI master keys and credential stores' {
        Invoke-WaInternal { param($p, $b) Test-WaProtectedPath -Path (Join-Path $b.RoamingAppData 'Microsoft\Protect\key') -Policy $p } $script:policy $script:basePaths |
            Should -BeTrue
    }
}

Describe 'Protected path segments' -Tag 'Safety' {

    BeforeAll { $script:policy = Invoke-WaInternal { Get-WaPolicy } }

    It 'refuses anything under a .git directory' {
        Invoke-WaInternal { param($p) Test-WaProtectedSegment -Path 'C:\cache\repo\.git\objects\ab\cdef' -Policy $p } $script:policy |
            Should -BeTrue
    }

    It 'refuses node_modules' {
        Invoke-WaInternal { param($p) Test-WaProtectedSegment -Path 'C:\cache\project\node_modules\left-pad\index.js' -Policy $p } $script:policy |
            Should -BeTrue
    }

    It 'refuses virtual environments and site-packages' {
        foreach ($segment in @('.venv', 'site-packages')) {
            Invoke-WaInternal { param($p, $s) Test-WaProtectedSegment -Path "C:\cache\proj\$s\thing" -Policy $p } $script:policy $segment |
                Should -BeTrue -Because "$segment is project state, not cache"
        }
    }

    It 'allows an ordinary cache path' {
        Invoke-WaInternal { param($p) Test-WaProtectedSegment -Path 'C:\Users\x\AppData\Local\Temp\file.tmp' -Policy $p } $script:policy |
            Should -BeFalse
    }
}

Describe 'Never-deleted file types' -Tag 'Safety' {

    BeforeAll { $script:policy = Invoke-WaInternal { Get-WaPolicy } }

    It 'refuses virtual machine disks wherever they are found' {
        foreach ($extension in @('.vhdx', '.vhd', '.vmdk', '.vdi', '.qcow2')) {
            Invoke-WaInternal { param($p, $e) Test-WaProtectedExtension -Path "C:\Users\x\AppData\Local\Temp\disk$e" -Policy $p } $script:policy $extension |
                Should -BeTrue -Because "$extension is a virtual machine disk"
        }
    }

    It 'refuses database files' {
        foreach ($extension in @('.mdf', '.ldf', '.sqlite', '.accdb')) {
            Invoke-WaInternal { param($p, $e) Test-WaProtectedExtension -Path "C:\cache\data$e" -Policy $p } $script:policy $extension |
                Should -BeTrue -Because "$extension is a database"
        }
    }

    It 'refuses key material and mail stores' {
        foreach ($extension in @('.pfx', '.pem', '.key', '.kdbx', '.pst', '.ost')) {
            Invoke-WaInternal { param($p, $e) Test-WaProtectedExtension -Path "C:\cache\thing$e" -Policy $p } $script:policy $extension |
                Should -BeTrue -Because "$extension holds credentials or mail"
        }
    }

    It 'allows an ordinary temporary file' {
        Invoke-WaInternal { param($p) Test-WaProtectedExtension -Path 'C:\cache\thing.tmp' -Policy $p } $script:policy | Should -BeFalse
    }
}

Describe 'Protected services' -Tag 'Safety' {

    BeforeAll { $script:policy = Invoke-WaInternal { Get-WaPolicy } }

    It 'protects security and endpoint protection services' {
        foreach ($name in @('WinDefend', 'MpsSvc', 'Sense', 'SecurityHealthService', 'CSFalconService', 'SentinelAgent')) {
            Invoke-WaInternal { param($p, $n) Test-WaProtectedService -Name $n -Policy $p } $script:policy $name |
                Should -BeTrue -Because "$name is security software"
        }
    }

    It 'protects device management and core platform services' {
        foreach ($name in @('IntuneManagementExtension', 'CcmExec', 'EventLog', 'RpcSs', 'TrustedInstaller', 'wuauserv')) {
            Invoke-WaInternal { param($p, $n) Test-WaProtectedService -Name $n -Policy $p } $script:policy $name |
                Should -BeTrue -Because "$name is load-bearing"
        }
    }

    It 'treats an empty service name as protected, failing closed' {
        Invoke-WaInternal { param($p) Test-WaProtectedService -Name '' -Policy $p } $script:policy | Should -BeTrue
    }

    It 'ships no curated service recommendations' {
        # The project deliberately proposes no service changes.
        @($script:policy.ServiceRecommendations).Count | Should -Be 0
    }
}

Describe 'Protected startup items' -Tag 'Safety' {

    BeforeAll { $script:policy = Invoke-WaInternal { Get-WaPolicy } }

    It 'never proposes disabling security software' {
        foreach ($name in @('SecurityHealthSystray', 'Windows Defender', 'CrowdStrike Sensor')) {
            Invoke-WaInternal { param($p, $n) Test-WaProtectedStartupItem -Name $n -Policy $p } $script:policy $name |
                Should -BeTrue -Because "$name protects the machine"
        }
    }

    It 'never proposes disabling accessibility tooling' {
        Invoke-WaInternal { param($p) Test-WaProtectedStartupItem -Name 'Narrator' -Policy $p } $script:policy | Should -BeTrue
    }

    It 'allows an ordinary optional application' {
        Invoke-WaInternal { param($p) Test-WaProtectedStartupItem -Name 'Spotify' -Policy $p } $script:policy | Should -BeFalse
    }
}

Describe 'Risk and confidence vocabularies' -Tag 'Safety' {

    It 'orders risk from SAFE to MANUAL-ONLY' {
        $ranks = Invoke-WaInternal { @('SAFE', 'LOW', 'MODERATE', 'HIGH', 'MANUAL-ONLY') | ForEach-Object { Get-WaRiskRank -Risk $_ } }
        $ranks | Should -Be @(0, 1, 2, 3, 4)
    }

    It 'rejects an unknown risk level rather than defaulting to something permissive' {
        { Invoke-WaInternal { Get-WaRiskRank -Risk 'TOTALLY-FINE' } } | Should -Throw
    }

    It 'treats risk and confidence as independent' {
        $recommendation = New-WaTestRecommendation -Risk 'HIGH' -Confidence 'LOW'
        $recommendation.Risk | Should -Be 'HIGH'
        $recommendation.Confidence | Should -Be 'LOW'
    }

    It 'rejects an unknown confidence level' {
        { Invoke-WaInternal { Get-WaConfidenceRank -Confidence 'PRETTY-SURE' } } | Should -Throw
    }
}

Describe 'Operation policy floors' -Tag 'Safety' {

    BeforeAll { $script:policy = Invoke-WaInternal { Get-WaPolicy } }

    It 'has a policy entry for every operation kind the engine can perform' {
        $kinds = Invoke-WaInternal { Get-WaOperationKinds }
        foreach ($kind in $kinds) {
            $script:policy.OperationPolicy.Contains($kind) | Should -BeTrue -Because "$kind must be policed"
        }
    }

    It 'refuses a recommendation that understates its risk' {
        # A service change presented as SAFE must be rejected by the policy floor.
        $operation = Invoke-WaInternal {
            New-WaOperation -Kind 'ServiceStartupSet' -Description 'test' `
                -Parameters ([ordered]@{ ServiceName = 'Spooler'; StartupType = 'Disabled' })
        }
        $recommendation = New-WaTestRecommendation -Risk 'SAFE' -Operations @($operation)
        { Invoke-WaInternal { param($r, $p) Assert-WaRecommendationPolicy -Recommendation $r -Policy $p } $recommendation $script:policy } |
            Should -Throw
    }

    It 'accepts a recommendation that meets the floor' {
        $operation = Invoke-WaInternal {
            New-WaOperation -Kind 'FileDelete' -Description 'test' -Parameters ([ordered]@{ RootKey = 'k'; Root = 'C:\Temp'; Files = @() })
        }
        $recommendation = New-WaTestRecommendation -Risk 'LOW' -Operations @($operation)
        Invoke-WaInternal { param($r, $p) Assert-WaRecommendationPolicy -Recommendation $r -Policy $p } $recommendation $script:policy |
            Should -BeTrue
    }

    It 'refuses an unknown operation kind at construction' {
        { Invoke-WaInternal { New-WaOperation -Kind 'FormatDisk' -Description 'nope' } } | Should -Throw
    }
}

Describe 'Executability' -Tag 'Safety' {

    It 'never treats a MANUAL-ONLY recommendation as executable' {
        $recommendation = Invoke-WaInternal {
            New-WaAdvisoryRecommendation -Id 'a' -Title 't' -Category 'c' -Provider 'p' -Description 'd'
        }
        Invoke-WaInternal { param($r) Test-WaExecutableRecommendation -Recommendation $r } $recommendation | Should -BeFalse
    }

    It 'never treats a recommendation with no operations as executable' {
        $recommendation = New-WaTestRecommendation -Risk 'LOW' -Operations @()
        Invoke-WaInternal { param($r) Test-WaExecutableRecommendation -Recommendation $r } $recommendation | Should -BeFalse
    }

    It 'forces individual approval on HIGH risk regardless of what was requested' {
        $recommendation = New-WaTestRecommendation -Risk 'HIGH'
        $recommendation.IndividualApprovalRequired | Should -BeTrue
    }
}
