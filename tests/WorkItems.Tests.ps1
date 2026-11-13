# Locks in the current fetch + ranking behaviour of scripts/WorkItems.psm1.
# GitLab is never contacted: Get-AssignedWorkItems / Invoke-GitLabApi are mocked.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'scripts' 'WorkItems.psm1') -Force

    function New-TestConfig {
        param(
            [string[]]$ProjectPriority = @('acme/SupportDesk'),
            [bool]$PriorityLabelFallback = $true,
            [string]$JiraLabel = 'jira'
        )
        @{
            jiraLabel             = $JiraLabel
            gitlabHost            = 'gitlab.example'
            projectPriority       = $ProjectPriority
            severityRank          = @{ critical = 0; high = 1; medium = 2; low = 3 }
            priorityLabelFallback = $PriorityLabelFallback
            teamsWebhookEnvVar    = 'UNUSED_IN_TESTS'
        }
    }

    function New-TestIssue {
        param(
            [int]$Id,
            [string]$Project = 'acme/SupportDesk',
            [string[]]$Labels = @(),
            [string]$Severity = 'UNKNOWN',
            [string]$UpdatedAt = '2026-10-01T00:00:00Z',
            [string]$DueDate = $null
        )
        @{
            id         = $Id
            iid        = $Id
            references = @{ full = "$Project#$Id" }
            title      = "Issue $Id"
            issue_type = 'issue'
            labels     = $Labels
            severity   = $Severity
            web_url    = "https://gitlab.example/$Project/-/issues/$Id"
            due_date   = $DueDate
            updated_at = $UpdatedAt
        }
    }

    function Invoke-Ranking {
        param([object[]]$Issues, [hashtable]$Config = (New-TestConfig))
        $script:issuesForMock = $Issues
        Mock Get-AssignedWorkItems -ModuleName WorkItems { $script:issuesForMock }
        @(Get-SortedWorkItems -Config $Config)
    }
}

Describe 'Get-SortedWorkItems' {
    BeforeEach {
        # Safety net: any unmocked path that would reach GitLab fails the test.
        Mock Invoke-GitLabApi -ModuleName WorkItems { throw 'Network access is not allowed in tests' }
    }

    Context 'source' {
        It 'ranks a Jira item above a GitLab one regardless of project and severity' {
            $r = Invoke-Ranking @(
                (New-TestIssue -Id 1 -Labels 'severity::critical')
                (New-TestIssue -Id 2 -Project 'tools/other/tool' -Labels 'jira', 'severity::low')
            )
            $r.Id | Should -Be @(2, 1)
            $r.Source | Should -Be @('jira', 'gitlab')
        }

        It 'keeps project, severity and idle order among Jira items' {
            $r = Invoke-Ranking @(
                (New-TestIssue -Id 1 -Labels 'jira', 'severity::low')
                (New-TestIssue -Id 2 -Labels 'jira', 'severity::high')
                (New-TestIssue -Id 3 -Project 'tools/other/tool' -Labels 'jira', 'severity::critical')
            )
            $r.Id | Should -Be @(2, 1, 3)
        }

        It 'treats every item alike when jiraLabel is not configured' {
            $config = New-TestConfig
            $config.Remove('jiraLabel')
            $r = Invoke-Ranking -Config $config @(
                (New-TestIssue -Id 1 -Labels 'severity::high')
                (New-TestIssue -Id 2 -Labels 'jira', 'severity::low')
            )
            $r.Id | Should -Be @(1, 2)
            $r.SourceRank | Should -Be @(0, 0)
        }
    }

    Context 'project priority' {
        It 'ranks a listed project above an unlisted one regardless of severity' {
            $r = Invoke-Ranking @(
                (New-TestIssue -Id 1 -Project 'tools/other/tool' -Labels 'severity::critical')
                (New-TestIssue -Id 2 -Project 'acme/SupportDesk')
            )
            $r.Reference | Should -Be @('acme/SupportDesk#2', 'tools/other/tool#1')
            $r[0].ProjectRank | Should -Be 0
            $r[1].ProjectRank | Should -Be 1
        }

        It 'matches projectPriority entries with -like wildcards' {
            $config = New-TestConfig -ProjectPriority @('acme/*')
            $r = Invoke-Ranking -Config $config @(
                (New-TestIssue -Id 1 -Project 'tools/other/tool')
                (New-TestIssue -Id 2 -Project 'acme/Anything')
            )
            $r[0].Reference | Should -Be 'acme/Anything#2'
        }

        It 'uses the order of projectPriority entries' {
            $config = New-TestConfig -ProjectPriority @('g/b', 'g/a')
            $r = Invoke-Ranking -Config $config @(
                (New-TestIssue -Id 1 -Project 'g/a')
                (New-TestIssue -Id 2 -Project 'g/b')
            )
            $r.Project | Should -Be @('g/b', 'g/a')
        }
    }

    Context 'severity resolution' {
        It 'prefers the severity:: label over the severity field' {
            $r = Invoke-Ranking @(New-TestIssue -Id 1 -Labels 'severity::low' -Severity 'CRITICAL')
            $r[0].SeveritySource | Should -Be 'severity::low'
            $r[0].SeverityRank | Should -Be 3
        }

        It 'matches the label level case-insensitively' {
            $r = Invoke-Ranking @(New-TestIssue -Id 1 -Labels 'severity::High')
            $r[0].SeverityRank | Should -Be 1
        }

        It 'falls back to the severity field when there is no severity:: label' {
            $r = Invoke-Ranking @(New-TestIssue -Id 1 -Severity 'HIGH')
            $r[0].SeveritySource | Should -Be 'severity field: high'
            $r[0].SeverityRank | Should -Be 1
        }

        It 'ignores a severity field of UNKNOWN and uses the priority:: label fallback' {
            $r = Invoke-Ranking @(New-TestIssue -Id 1 -Labels 'priority::medium' -Severity 'UNKNOWN')
            $r[0].SeveritySource | Should -Be 'priority::medium (fallback)'
            $r[0].SeverityRank | Should -Be 2
        }

        It 'does not use priority:: labels when priorityLabelFallback is false' {
            $config = New-TestConfig -PriorityLabelFallback $false
            $r = Invoke-Ranking -Config $config @(New-TestIssue -Id 1 -Labels 'priority::critical')
            $r[0].SeveritySource | Should -Be 'unset'
            $r[0].SeverityRank | Should -Be 4
        }

        It 'ignores labels whose level is not in severityRank' {
            $r = Invoke-Ranking @(New-TestIssue -Id 1 -Labels 'severity::urgent')
            $r[0].SeveritySource | Should -Be 'unset'
        }

        It 'ranks critical > high > medium > low > unset within a project' {
            $r = Invoke-Ranking @(
                (New-TestIssue -Id 1)
                (New-TestIssue -Id 2 -Labels 'severity::low')
                (New-TestIssue -Id 3 -Labels 'severity::medium')
                (New-TestIssue -Id 4 -Labels 'severity::critical')
                (New-TestIssue -Id 5 -Labels 'severity::high')
            )
            $r.Id | Should -Be @(4, 5, 3, 2, 1)
        }
    }

    Context 'tie-breaker and due date' {
        It 'puts the least recently updated item first on a tie' {
            $r = Invoke-Ranking @(
                (New-TestIssue -Id 1 -Labels 'severity::high' -UpdatedAt '2026-10-20T00:00:00Z')
                (New-TestIssue -Id 2 -Labels 'severity::high' -UpdatedAt '2026-09-01T00:00:00Z')
            )
            $r.Id | Should -Be @(2, 1)
        }

        It 'does not let due date affect the order' {
            $r = Invoke-Ranking @(
                (New-TestIssue -Id 1 -Labels 'severity::high' -UpdatedAt '2026-09-01T00:00:00Z')
                (New-TestIssue -Id 2 -Labels 'severity::high' -UpdatedAt '2026-10-01T00:00:00Z' -DueDate '2026-11-05')
            )
            $r.Id | Should -Be @(1, 2)
            $r[1].DueDate | Should -Be '2026-11-05'
        }
    }

    Context 'output shape' {
        It 'computes IdleDays as whole days since updated_at' {
            $updated = [DateTimeOffset]::UtcNow.AddDays(-5).AddHours(-1).ToString('o')
            $r = Invoke-Ranking @(New-TestIssue -Id 1 -UpdatedAt $updated)
            $r[0].IdleDays | Should -Be 5
        }

        It 'maps GitLab fields onto the ranked row' {
            $r = Invoke-Ranking @(New-TestIssue -Id 7 -Labels 'severity::low', 'bug' -DueDate '2026-12-01')
            $r[0].Id | Should -Be 7
            $r[0].Reference | Should -Be 'acme/SupportDesk#7'
            $r[0].Project | Should -Be 'acme/SupportDesk'
            $r[0].Title | Should -Be 'Issue 7'
            $r[0].Labels | Should -Be @('severity::low', 'bug')
            $r[0].WebUrl | Should -Be 'https://gitlab.example/acme/SupportDesk/-/issues/7'
            $r[0].DueDate | Should -Be '2026-12-01'
        }

        It 'returns an empty array when nothing is assigned' {
            $r = Invoke-Ranking @()
            $r.Count | Should -Be 0
        }
    }

    Context 'fixture: mixed realistic list' {
        It 'ranks tests/fixtures/issues.json in the documented order' {
            $issues = Get-Content -Raw -Encoding utf8 (Join-Path $PSScriptRoot 'fixtures' 'issues.json') |
                ConvertFrom-Json -AsHashtable
            $r = Invoke-Ranking @($issues)
            # SupportDesk first: high (older update) > high > low > unset; then the unlisted project.
            $r.Id | Should -Be @(9005, 9003, 9004, 9002, 9001)
        }
    }
}

Describe 'Get-AssignedWorkItems' {
    It 'requests assigned open issues and follows pages until a short page' {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-GitLabApi -ModuleName WorkItems {
            $script:calls.Add($Endpoint)
            if ($Endpoint -match 'page=1$') { return , @(1..100 | ForEach-Object { @{ id = $_ } }) }
            , @(101..103 | ForEach-Object { @{ id = $_ } })
        }

        $items = @(Get-AssignedWorkItems -Config (New-TestConfig))

        $items.Count | Should -Be 103
        $script:calls | Should -Be @(
            'issues?scope=assigned_to_me&state=opened&per_page=100&page=1'
            'issues?scope=assigned_to_me&state=opened&per_page=100&page=2'
        )
        Should -Invoke Invoke-GitLabApi -ModuleName WorkItems -Times 2 -Exactly -ParameterFilter {
            $GitLabHost -eq 'gitlab.example'
        }
    }
}

Describe 'Select-OpenClosingMrs' {
    It 'keeps only open MRs and carries the draft flag' {
        $mrs = @(
            @{ iid = 549; state = 'merged'; web_url = 'u549'; draft = $false }
            @{ iid = 558; state = 'opened'; web_url = 'u558'; draft = $false }
            @{ iid = 560; state = 'opened'; web_url = 'u560'; draft = $true }
            @{ iid = 561; state = 'closed'; web_url = 'u561'; draft = $false }
        )
        $open = @(Select-OpenClosingMrs -MergeRequests $mrs)
        $open.Iid | Should -Be @(558, 560)
        $open[0].WebUrl | Should -Be 'u558'
        $open[0].Draft | Should -BeFalse
        $open[1].Draft | Should -BeTrue
    }

    It 'returns nothing for an issue no MR closes' {
        @(Select-OpenClosingMrs -MergeRequests @()).Count | Should -Be 0
        @(Select-OpenClosingMrs -MergeRequests $null).Count | Should -Be 0
    }
}

Describe 'Get-WorkItemOpenMrs' {
    It 'reads nothing when there are no items' {
        $r = Get-WorkItemOpenMrs -Config (New-TestConfig) -Items @()
        $r.Map.Count | Should -Be 0
        @($r.Errors).Count | Should -Be 0
    }
}

Describe 'ConvertFrom-ClosedByJson' {
    It 'returns an empty array, not null, for an issue no MR closes' {
        $open = ConvertFrom-ClosedByJson -Json '[]'
        $null -eq $open | Should -BeFalse
        $open.Count | Should -Be 0
    }

    It 'returns the open MRs of a response with merged and open MRs' {
        $json = '[{"iid":549,"state":"merged","web_url":"u549","draft":false},{"iid":558,"state":"opened","web_url":"u558","draft":false}]'
        $open = ConvertFrom-ClosedByJson -Json $json
        $open.Count | Should -Be 1
        $open[0].Iid | Should -Be 558
    }

    It 'throws on a body that is not JSON, so the caller reports the item as not checked' {
        { ConvertFrom-ClosedByJson -Json 'not json' } | Should -Throw
    }
}
