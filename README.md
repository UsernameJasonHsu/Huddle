# Huddle

個人用的「辦公室」：由 Claude Code 主 session 擔任 Office Manager，調度 Intake、Builder、Tester、Security、Reviewer 五個 subagent，接手 `gitlab.example.com` 上指派給我的 GitLab work item：讀 issue 寫 brief、寫實作計畫、在獨立 worktree 裡實作並互相審查，只有碰到決策關卡（G1 核准計畫、G2 裁決分歧、G3 對外寫入）時才停下來問我。

原本的 **work-item-radar**（GitLab 待辦雷達）保留原名，是 Huddle 裡的一個模組，負責抓取與排序 work item，並作為 Intake 的資料來源。

資料一律透過已登入的 `glab` CLI 取得，本 repo 不存任何 token。只有我一個人在自己的 Windows 11 本機使用。

## 需求

- Windows + PowerShell 7（`pwsh`）
- [`glab`](https://gitlab.com/gitlab-org/cli)，並已登入目標 host：
  ```powershell
  glab auth login --hostname gitlab.example.com
  glab auth status --hostname gitlab.example.com
  ```
- Claude Code（Office Manager、開場 brief 與 mod 都在裡面跑）
- Teams Workflows 的 webhook URL（僅 Teams 推播需要）
- Pester 5 以上（跑測試時；目前用 6.2.0）

## 怎麼運作

### 流程與狀態

一個 work item 在辦公室裡的狀態：

```
NEW → BRIEFED → PLANNED →(G1)→ BUILDING → TESTING → SEC_REVIEW → REVIEW → READY →(G3)→ DELIVERED
```

另有 `BLOCKED`（agent 卡住，需要我處理後 `resume`）與 `PARKED`（我決定先放著）。

| 關卡 | 什麼時候 | 誰決定 |
|---|---|---|
| **G1** | 計畫寫好，要開始寫 code 之前 | 我：核准／退回修計畫／暫停。核准時一併儲存該專案的設定（base branch、build／test 指令） |
| **G2** | Builder 與 Tester／Security／Reviewer 意見不同，或自動迭代超過 `maxAutoRounds`；或建 worktree 前發現 base branch 已經移到計畫列的檔案上（`base-moved`） | 我：要修／照 Builder（記 waiver）／暫停；輪次上限時可再給一輪；`base-moved` 時重新 plan／照舊計畫／暫停 |
| **G3** | 任何對外寫入：`git push`、開 MR、`glab` 寫入類指令 | 每一次都由 Claude Code 跳出確認；`scripts/gate-guard.ps1` 作為 PreToolUse hook 攔截 |

G1 或 G2 產生、或 work item 變成 BLOCKED 時，`scripts/notify-decision.ps1` 會推一張 Teams 卡片（只有 reference、關卡、一行摘要），這是唯一不經 G3 的對外寫入。

### 角色

| 角色 | 實作 | 做什麼 |
|---|---|---|
| Office Manager | Claude Code 主 session（`CLAUDE.md`） | 調度、維護 task board、彙整意見；**唯一可以問我問題的角色** |
| Intake | `.claude/agents/intake.md` | 讀 issue 與相關程式碼，寫 `brief.md`；第一次見到的專案另寫 `project-profile.json` 草稿 |
| Builder | `.claude/agents/builder.md` | 寫 `plan.md`；G1 後寫「分析與修正計畫」留言草稿；在 worktree 裡實作並本機 commit；READY 後寫 MR 草稿 |
| Tester | `.claude/agents/tester.md` | 在 worktree 跑測試、對照驗收條件找缺口 |
| Security | `.claude/agents/security.md` | 威脅建模、審 diff、分級回報 finding |
| Reviewer | `.claude/agents/reviewer.md` | 從正確性、可讀性、架構、安全性、效能五個面向做最後審查 |

agent 之間不直接互相呼叫（它們的 `tools` 都不含 `Agent`），一律經 Office Manager 中轉；每個 agent 的回覆由對應的 `*-complete.ps1` 腳本解析後才改狀態，狀態檔不由 agent 直接改。

### 寫到哪裡

- `office/work/<project-slug>-<iid>/`：每個 work item 的 task board，含 `status.json`、`brief.md`、`plan.md`、append-only 的 `thread.md`、各階段報告、`decisions/`、`replies/`。本機狀態，不進版控。
- `C:\Users\jason\huddle-workspace\`（`config/office.json` 的 `workspaceRoot`）：`worktrees\<project-slug>-<iid>\` 是實作用的 git worktree；`repos\<namespace>\<project>\` 放自動 clone 的未登記專案。
- 已登記專案（例如 `acme/SupportDesk`）用我自己的 clone 建 worktree，**不碰那個 clone 的 checkout**：Intake 與計畫讀 `git fetch` 後的 `origin/<base>`，worktree 從同一個 base 長出來。

## 使用方式

### Claude Code

在本 repo 目錄啟動 Claude Code：

- 開場自動產生 work item brief（排序後清單）並附上辦公室狀態（`scripts/session-brief.ps1`）；Claude 依 `CLAUDE.md` 摘要並建議先做哪幾項，待決策的項目列在最前面。
- `/huddle`：辦公室狀態與待決策。
- `/huddle-take <group/project#iid | project#iid | issue URL>`：把 work item 交給辦公室。跑到 G1；核准後產出分析留言草稿，接著直接進 build loop。
- `/huddle-build <ref> [resume]`：執行或繼續 build loop（Builder → Tester → Security → Reviewer），停在 READY、BLOCKED 或 G2。
- `/huddle-deliver <ref>`：READY 之後產出 MR 草稿，經我確認後 push 並用 `glab api` 開 MR（兩個指令各跳一次 G3 確認），記錄為 DELIVERED。
- `/huddle-tick`：單次推進：把推播寫進 inbox 的新 work item 做 brief（停在 BRIEFED），並檢查已登記的 issue 有沒有更新。搭配 `/loop 10m /huddle-tick` 在 session 開著時自動跑。
- `/triage`：重新抓取待辦並再次摘要。
- `/work-items`：Work items 面板（依專案分組）；status line 顯示例如 `📋 3 open · top: SupportDesk#348 (high, idle 37d)`。

還沒有的：以 bot 身分在 issue 留言（`post-issue-note.ps1`，等 bot 帳號）。目前分析留言草稿只顯示給我，要貼由我自己貼。

### Teams 推播（radar 模組）

1. 在 Teams 建立 Workflows webhook，把 URL 存進**使用者環境變數** `SUPERVISOR_TEAMS_WEBHOOK_URL`（名稱由 `config/work-items.json` 的 `teamsWebhookEnvVar` 設定）。URL 不要寫進任何檔案。
2. 先試跑，不送訊息也不寫狀態：
   ```powershell
   pwsh -NoProfile -File scripts/notify-new.ps1 -DryRun
   ```
3. 註冊排程（每 N 分鐘，預設 10；重跑會覆蓋同名工作 `SupervisorAgent-WorkItemNotify`）：
   ```powershell
   pwsh -NoProfile -File scripts/register-notify-task.ps1 -Minutes 10
   ```

第一次執行（尚無狀態檔）只記錄目前的項目、不發送；推播失敗的項目不寫入狀態，下次會重試。狀態存在 `state/seen-work-items.json`。每個新項目同時寫進 `office/inbox/<issue id>.json`，由 `/huddle-tick` 接手。

### 測試

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path tests -Output Detailed"
```

## 排序規則（radar 模組）

來源：`config/work-items.json` 與 `scripts/WorkItems.psm1` 的 `Get-SortedWorkItems`。

1. **來源**：帶有 `jiraLabel`（目前是 `jira`）這個 label 的 work item 視為從 Jira 來的，一律排在其他（GitLab 來的）之前，不看專案與嚴重度；沒設 `jiraLabel` 時不分來源。
2. **專案優先序**（同來源內）：`projectPriority` 中越前面的專案越優先（以 PowerShell `-like` 比對，可用萬用字元）；未列出的專案排在後面。
3. **嚴重度**（同專案內）：依序採用
   1. `severity::<level>` label
   2. GitLab 內建 severity 欄位（值為 `UNKNOWN` 時忽略）
   3. `priority::<level>` label（僅在 `priorityLabelFallback` 為 `true` 時）

   等級對應 `severityRank`：critical > high > medium > low > 未設定。
4. **同分時**：最久沒更新的排前面。

Due date 會顯示，但刻意不參與排序。

## 設定

兩個設定檔含有自己環境的主機、專案與路徑，不進版控。第一次使用時從範例複製再改成自己的值：

```
Copy-Item config/work-items.example.json config/work-items.json
Copy-Item config/office.example.json config/office.json
```

- `config/work-items.json`：GitLab host、Jira 來源 label、專案優先序、嚴重度等級、webhook 環境變數名稱。
- `config/office.json`：`workspaceRoot`、`unknownProject`（`auto-clone`）、`maxAutoRounds`、`maxActiveBuilds`、`retentionDays`，以及專案註冊表 `projects[]`（`match`、`repoPath`、`baseBranch`、`commands.build`／`commands.test`）。專案設定只在 G1 核准時由 `scripts/resolve-decision.ps1` 寫入，不手改。
- `.claude/settings.json`：SessionStart hook、G3 的 `permissions.ask`／`deny` 清單、`gate-guard.ps1` 的 PreToolUse hook。

## 專案結構

```
config/work-items.example.json    radar 設定範例：GitLab host、專案優先序、嚴重度等級、webhook 環境變數名稱（複製成 work-items.json，不進版控）
config/office.example.json        Huddle 設定範例：專案註冊表與限制（複製成 office.json，不進版控）
scripts/WorkItems.psm1            radar：抓取與排序邏輯
scripts/session-brief.ps1         SessionStart hook：排序清單＋辦公室狀態
scripts/brief-json.ps1            排序清單的 JSON 版，給 work-items mod
scripts/notify-new.ps1            偵測新指派、推播到 Teams、寫 office/inbox
scripts/register-notify-task.ps1  註冊工作排程器任務
scripts/Office.psm1               task board：登記、狀態機、thread.md、決策、worktree
scripts/Huddle.psm1               GitLab 讀取類步驟：take 前置、tick、deliver 前置
scripts/office-brief.ps1          辦公室狀態（markdown）
scripts/huddle-take.ps1           /huddle-take 前置：解析 ref、讀 issue、登記、fetch base
scripts/intake-complete.ps1       套用 Intake 回覆
scripts/builder-complete.ps1      套用 Builder 回覆（plan／analysis-comment／mr-draft）
scripts/build-step.ps1            build loop 下一步（第一次 BUILDING 時先核對 base 有沒有移動，再建 worktree）
scripts/loop-complete.ps1         套用 loop agent 回覆，推進狀態或開 G2
scripts/deliver-prep.ps1          /huddle-deliver 前置：label、既有 MR
scripts/deliver-complete.ps1      記錄 MR、READY → DELIVERED
scripts/huddle-tick.ps1           /huddle-tick：inbox → brief、issue 更新檢查、滿 retentionDays 的清理
scripts/office-purge.ps1          手動跑清理（-DryRun 只看不動）；結果在 office/purge.log
scripts/resolve-decision.ps1      記錄我的裁決並套用（G1、G2）
scripts/notify-decision.ps1       待決策／BLOCKED 的 Teams 卡片
scripts/gate-guard.ps1, GateGuard.psm1  PreToolUse hook：G3
.claude/settings.json             hooks 與 permissions
.claude/agents/                   intake、builder、tester、security、reviewer
.claude/commands/                 /huddle、/huddle-take、/huddle-build、/huddle-deliver、/huddle-tick、/triage
.claude/skills/work-items/        work-items mod（status line + /work-items 面板）
tests/                            Pester 測試
CLAUDE.md                         給 Claude 的專案規則（brief 摘要方式、Office 規則）
SPEC.md, tasks/                   Huddle spec 與實作計畫
office/                           Huddle 本機狀態，不進版控
state/                            radar 本機輪詢狀態，不進版控
```

## 疑難排解

- **brief 顯示 unavailable／面板顯示 fetch failed**：多半是 `glab` 登入過期，執行 `glab auth status --hostname gitlab.example.com` 確認。
- **辦公室狀態顯示 unavailable**：看 `office-brief.ps1` 回的錯誤；通常是 `office/work/<id>/status.json` 壞掉或 `config/office.json` 格式錯。
- **status line 沒出現**：確認是在本 repo 目錄啟動 Claude Code，且 `pwsh` 在 PATH 上。
- **排程沒有推播**：確認 `SUPERVISOR_TEAMS_WEBHOOK_URL` 是使用者環境變數（設定後需重新登入或重開排程器），並用 `-DryRun` 檢查抓取是否正常。
- **改了 `.claude/agents/*.md` 沒生效**：subagent 定義要開新 session 才會重新載入。
- **gate-guard 擋了某個指令**：那是 G3 在做事；不要改寫指令繞過，看它回的原因。
- **`/huddle` 顯示 Purge skipped 的 warning**：該 work item 已 DELIVERED 超過 `retentionDays`，但 worktree 裡有未 commit 的變更，清理不會動它。把變更 commit 或丟掉後，下一次 `/huddle-tick`（或 `scripts/office-purge.ps1`）就會清掉。
