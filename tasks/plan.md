# Implementation Plan: Huddle

> 依據：`SPEC.md` v0.7（2026-11-05 核准）
> 狀態：**已核准**（2026-11-05）

## Overview

在既有的 work-item-radar 之上，分成幾個「垂直切片」逐步加上 Huddle 辦公室的功能。每一片完成後，系統都可以實際使用，並且可以驗證。順序如下：
1. 先做**安全地基**：測試框架、G3 硬性關卡。
2. 接著依照 work item 的生命週期往後做：進辦公室 → Intake 做 brief → Builder 寫計畫並通過 G1 → 實作與審查循環 → 交付 → 清理。

有任何 agent 能動到程式碼之前，G3 的攔截一定要先完成並通過測試。

## 環境現況（2026-11-05 實測）

| 項目 | 現況 | 影響 |
|---|---|---|
| PowerShell | 7.6.9 | 符合 |
| Pester | 原本只有 3.4.0（Windows 內建版本）。2026-11-05 安裝時，`-MinimumVersion 5.0` 抓到的是最新版 **6.2.0**，裝在 `C:\Users\jason\Documents\PowerShell\Modules\Pester\6.2.0` | 測試只使用 5 版與 6 版共通的語法（`Describe`、`It`、`Should -Be`、`Mock -ModuleName`、`Should -Invoke`）；決定沿用 6.2.0（2026-11-05），5 與 6 的差異在 T2 查證 |
| glab | 1.108.0 | 符合；讀取 issue 的指令細節在 Task 2 查證 |
| 既有測試 | 無 | Task 1 先補上既有排序邏輯的測試，鎖住現有行為 |

## Architecture Decisions

- **G3 先做**：`gate-guard.ps1` 與 `permissions` 設定排在 Task 3，比任何 agent 定義都早。理由：agent 一旦能執行 Bash，就有機會對外寫入，所以攔截要先存在。
- **純邏輯放 `Office.psm1`，agent 只負責判斷**：狀態轉移、分歧判定、專案解析、路徑命名、清理規則，全部寫成可以用 Pester 測試的 PowerShell 函式。agent prompt 只描述「要讀什麼、要寫什麼、要回傳什麼」。
- **先查證，再寫設定**：spec §11 列出的 Claude Code 與 glab 細節（agent frontmatter、permissions 的比對語法、hook 的輸出格式、glab 讀取指令），在 Task 2 對照官方文件查清楚並記錄下來。後續任務只引用查證結果，不憑印象寫。
- **對外寫入集中成三支腳本**：`notify-decision.ps1`、`post-issue-note.ps1`，以及 Task 14 的 push 與 MR 流程。其他任何地方都不直接呼叫寫入 API。
- **開發分支**：所有變更都在 `feature/huddle` 分支上進行，不直接 commit 到 `main`。

## 相依圖

```
T1 測試框架 ─┬─► T3 G3 gate-guard ─┬─► T10 notify-decision
T2 查證  ────┘                     ├─► T15 交付（push/MR）
                                   └─► T16 post-issue-note（外部相依：bot）
T1 ─► T4 Office 核心 ─┬─► T5 開場狀態 + /huddle
                      ├─► T6 專案解析 ─► T11 worktree
                      ├─► T8 inbox ──────────────┐
                      └─► T7 Intake + /huddle-take ┴─► T9 /huddle-tick + 更新偵測

T7 + T10 + T11 ─► T12 Builder 計畫 + G1 ─► T13 Tester/Security ─► T14 Reviewer + 分歧 G2
             ─► T15 交付 ─► T17 清理
T18 改名：獨立，隨時可以做
```

## Task List

### Phase A：安全地基

#### Task 1：Pester 與既有排序測試
**Description**：安裝 Pester 5（只裝在目前使用者底下），建立 `tests/` 目錄，用固定的 issue JSON fixture 鎖住 `Get-SortedWorkItems` 現有的排序行為，包括專案優先序、severity label、severity 欄位、priority fallback、閒置天數這幾個規則。
**Acceptance criteria**：
- [x] `Invoke-Pester -Path tests` 使用 Pester 5 以上（決定採用 6.2.0）
- [ ] 排序的每一條規則至少有一個測試；測試中 mock `glab`，不會連到網路
- [ ] 沒有修改 `WorkItems.psm1` 的任何行為
**Verification**：`pwsh -NoProfile -Command "Invoke-Pester -Path tests -Output Detailed"` 全部通過
**Dependencies**：None。⚠️ **安裝 Pester 是新增依賴，執行前要先問你**（指令：`Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -SkipPublisherCheck`）
**Files**：`tests/WorkItems.Tests.ps1`、`tests/fixtures/issues.json`
**Scope**：S

#### Task 2：查證 Claude Code 與 glab 的細節
**Description**：對照官方文件查證以下幾點，結果寫成文件。這個任務不寫任何程式碼。
1. `.claude/agents/*.md` 的 frontmatter 欄位，特別是 `model` 能不能填 `sonnet`、`inherit`
2. `permissions.allow`、`ask`、`deny` 的比對語法，能不能精準限定到單一一支腳本
3. PreToolUse hook 回傳 deny 或 ask 的輸出格式
4. subagent 能不能使用 AskUserQuestion
5. `glab` 讀取 issue 內文、留言、關聯 issue 或 MR 的指令
**Acceptance criteria**：
- [ ] 每一點都附上來源連結或指令輸出
- [ ] 查不到的項目明確標示「無法確認」，並寫出替代做法（例如改用 PreToolUse hook）
**Verification**：人工審閱 `docs/notes/platform-facts.md`
**Dependencies**：None
**Files**：`docs/notes/platform-facts.md`
**Scope**：XS

#### Task 3：G3 硬性關卡（gate-guard）
**Description**：實作 PreToolUse hook `gate-guard.ps1`，並在 `.claude/settings.json` 加上 permissions 設定。規則如下：
- **ask（跳出確認）**：`git push`、`glab mr create`、`glab mr update`、`glab issue update`、`glab issue close`、`post-issue-note.ps1`，以及 `glab api` 的任何非 GET 請求
- **deny（直接拒絕）**：agent 直接執行的 `glab issue note`，以及 `glab api` 對 issue notes 的 POST
- **不攔截**：`git push --dry-run`、`glab mr list`、`glab issue view` 等讀取指令
**Acceptance criteria**：
- [x] `tests/gate-guard.Tests.ps1` 列出正例與反例，全部通過
- [x] 加上空白、引號、`&&` 串接、改變參數順序等變形，都不能繞過攔截；也要涵蓋 `git -C <dir> push`、`git --git-dir=... push`、`glab api -f`（隱含 POST）、`--input`（見 `docs/notes/platform-facts.md` §4）
- [x] gate-guard 自己發生錯誤時，輸出 deny（fail closed）；hook 的 matcher 同時涵蓋 `Bash|PowerShell`
- [x] 在 Huddle 實際使用的 permission mode 下，確認 ask 會跳出確認；如果不會，在 `CLAUDE.md` 寫明 Huddle 不能使用該模式（default、auto 都會跳出確認，2026-11-05）
- [x] 在實際的 Claude Code session 裡手動測一次：`glab issue note` 被拒絕，`git push` 跳出確認提示
**Verification**：Pester 測試＋手動驗證（Success Criteria #5）
**Dependencies**：T1、T2
**Files**：`scripts/gate-guard.ps1`、`.claude/settings.json`、`tests/gate-guard.Tests.ps1`
**Scope**：M

### Checkpoint A：安全地基
- [x] 所有 Pester 測試通過（122/122，2026-11-05）
- [x] G3 手動驗證完成
- [x] **跟你一起 review 之後，才繼續往下做**（2026-11-05）

### Phase B：work item 進辦公室、Intake

#### Task 4：Office 核心（Task Board 與狀態機）
**Description**：
- 新增 `config/office.json`，內容是 §3.6 的結構，SupportDesk 的欄位先填 `null`。
- 新增 `Office.psm1`，提供以下功能：
  - 讀取設定
  - 登記 work item：建立 `office/work/<project-slug>-<iid>/`，重複登記時不做事
  - 讀寫 `status.json`，狀態轉移只接受 §3.3 狀態機定義的合法轉移
  - 附加一則 `thread.md` 留言（§5 格式）
  - 產生辦公室狀態摘要
- 把 `office/` 加進 `.gitignore`。
**Acceptance criteria**：
- [x] 不合法的狀態轉移（例如 `NEW` 直接跳到 `BUILDING`）會丟出錯誤
- [x] 同一個 work item 登記兩次，只會有一個資料夾（Success Criteria #13 的基礎）
- [x] `thread.md` 只能附加新留言，不能改寫舊的

**實作時補充的決定（2026-11-05）**：
- PARKED、BLOCKED 只能回到進入前的狀態（`status.json` 的 `resumeTo`）；DELIVERED、PURGED 不能再進入 PARKED 或 BLOCKED。
- BUILDING、TESTING、SEC_REVIEW、REVIEW 彼此可以任意互轉。READY 從 REVIEW 進入；從其他三個狀態進入時，要附上 G2 的 decision id。
- PLANNED → BUILDING 要附上 G1 的 decision id。
- 輪次：從循環中的狀態退回 BUILDING 時加一輪；從 PLANNED 第一次進入，或從 PARKED 恢復，都不算。
- 資料夾名稱 `<project-slug>-<iid>`：專案路徑轉小寫，`/` 與不安全字元換成 `-`（例：`acme-supportdesk-348`）。T6 若調整命名規則，要一起改。
**Verification**：`Invoke-Pester -Path tests/Office.Tests.ps1`
**Dependencies**：T1
**Files**：`scripts/Office.psm1`、`config/office.json`、`tests/Office.Tests.ps1`、`.gitignore`
**Scope**：M

#### Task 5：開場的辦公室狀態與 `/huddle`
**Description**：
- `session-brief.ps1` 在原本的排序清單之後，附加辦公室狀態摘要：每個 work item 目前的狀態、待決策的數量；沒有任何 work item 時顯示「辦公室閒置」。
- 新增 `/huddle` 指令。
- 在 `CLAUDE.md` 加上 Office Manager 的基本規則。
**Acceptance criteria**：
- [x] 原本的排序清單輸出完全不變（用 snapshot 測試比對；snapshot 在修改前產生，存在 `tests/fixtures/session-brief/snapshot.json`）
- [x] 沒有 `office/` 資料夾時，顯示「辦公室閒置」，而且不會出錯（輸出文字為 `Office idle`，與腳本其他英文輸出一致）
**Verification**：Pester 測試＋開一個新的 session 實際看一次（Success Criteria #1）
**Dependencies**：T4
**Files**：`scripts/session-brief.ps1`、`.claude/commands/huddle.md`、`CLAUDE.md`、`tests/session-brief.Tests.ps1`
**Scope**：S

#### Task 6：專案解析與路徑命名
**Description**：在 `Office.psm1` 加上以下純函式：
- `Resolve-OfficeProject`：用 `-like` 比對註冊表，取第一個符合的專案
- 計算未登記專案的 clone 路徑：`<workspaceRoot>\repos\<namespace>\<project>`
- 計算 worktree 路徑與分支名稱：`huddle/<iid>-<title-slug>`
**Acceptance criteria**：
- [x] 涵蓋三種情況：已登記、未登記、萬用字元比對
- [x] 中文或特殊字元的標題，轉成的 slug 是合法的 git 分支名稱
- [x] 這些函式不做任何 I/O（實際 clone 留到 T7、T11）
**Verification**：Pester 測試
**Dependencies**：T4
**Files**：`scripts/Office.psm1`、`tests/Office.Tests.ps1`
**Scope**：S

#### Task 7：Intake agent 與 `/huddle-take`（只做到 brief）
**Description**：
- 新增 `intake` agent 定義，模型用 Sonnet。
- 新增 `/huddle-take` 指令，目前只推進到 BRIEFED。
- 實作 agent 回傳 YAML 的解析函式 `Get-AgentOutcome`。
- 定義 `brief.md` 的段落（§3.8），包含「發現於」與 V4 檢查。
- 遇到未登記的專案時，執行 auto-clone（從 GitLab 讀取），並產出 `project-profile.json` 草稿。
**Acceptance criteria**：
- [x] 用各種 agent 回傳內容的 fixture（`done`、`blocked`、格式錯誤）測試解析器；格式錯誤時，視為 `blocked` 並記錄在 `thread.md`
- [x] 用一張真實的 SupportDesk issue 執行 `/huddle-take`，產出的 `brief.md` 包含 §3.8 列出的所有段落
- [x] 整個過程**沒有任何對外寫入**；所有 glab 指令都是讀取
**Verification**：Pester 測試＋手動跑一張真實 issue
**Dependencies**：T2、T3、T4、T6
**Files**：`.claude/agents/intake.md`、`.claude/commands/huddle-take.md`、`scripts/Office.psm1`、`tests/fixtures/agent-outputs/*`、`tests/Office.Tests.ps1`
**Scope**：M

#### Task 8：notify-new 寫入 inbox
**Description**：`notify-new.ps1` 在推播之外，另外寫入 `office/inbox/<id>.json`，檔名使用 issue 的全域 `id`，重複寫入時直接覆蓋。寫入失敗不影響推播。
**Acceptance criteria**：
- [x] 修改前後，`-DryRun` 的輸出完全相同（Success Criteria #6）
- [x] 第一次執行（還沒有狀態檔）時，不寫 inbox
- [x] Teams 推播失敗、下一輪重試時，inbox 裡仍然只有一個檔案
**Verification**：Pester 測試（mock `Invoke-RestMethod` 與 `glab`）＋執行一次 `-DryRun`
**Dependencies**：T4
**Files**：`scripts/notify-new.ps1`、`scripts/Office.psm1`（`Write-OfficeInboxItem`）、`tests/notify-new.Tests.ps1`、`tests/fixtures/notify-new/*`
**Scope**：S

#### Task 9：`/huddle-tick` 與 issue 更新偵測
**Description**：
- 新增 `/huddle-tick` 指令：讀取 inbox，派 Intake 處理，處理完**停在 BRIEFED**。
- 實作 §3.8 的 `updated_at` 對照表：判斷 issue 被修改時要重新產出 brief、標示需要重新確認，還是發出 G2。
- Huddle 自己留言造成的 `updated_at` 變化，不觸發任何處理。
**Acceptance criteria**：
- [x] inbox 來的 work item 處理完沒有 `plan.md`，也沒有建立 worktree（Success Criteria #12）
- [x] 用 fixture 測試「BRIEFED 時被修改」與「BUILDING 時被修改」兩種情況的行為（Success Criteria #14）
- [x] `/loop 10m /huddle-tick` 實際跑兩輪，沒有重複處理同一筆
**Verification**：Pester 測試＋手動測試
**Dependencies**：T7、T8
**Files**：`.claude/commands/huddle-tick.md`、`scripts/Office.psm1`（更新判定、決策檔、inbox 讀取）、`scripts/Huddle.psm1`（take prep 與 tick，從 `huddle-take.ps1` 抽出）、`scripts/huddle-tick.ps1`、`scripts/resolve-decision.ps1`、`tests/Huddle.Tests.ps1`
**Scope**：M

### Checkpoint B：Intake 端到端
- [x] 一張真實 issue 進來，到產出 brief，全程只有讀取（#348 經 `/huddle-take` 進來；inbox 路徑由 T8、T9 的測試涵蓋，尚未用真實 issue 跑過）
- [x] 關掉 session 再打開，狀態都還在（Success Criteria #7 的一部分；#348 在新 session 仍是 BRIEFED）
- [x] **跟你一起 review 之後，才繼續往下做**（2026-11-06）

### Phase C：計畫與 G1

#### Task 10：決策通知 `notify-decision.ps1`
**Description**：產生 G1、G2 決策，或 work item 進入 BLOCKED（Clarify）時，推播一張 Teams 卡片。卡片只包含 work item reference、Gate 類型、一句摘要。在 `permissions.allow` 裡只放行這一支腳本的完整指令。
**Acceptance criteria**：
- [x] 測試斷言：送出的 body 不包含 diff、issue 內文，也不包含 webhook URL
- [x] 腳本只從環境變數讀取 webhook URL，不接受從參數傳入
- [x] 推播失敗時，記錄在 `thread.md`，流程繼續
**Verification**：Pester 測試＋實際推播一次測試卡片到你的 Teams（Success Criteria #10）
**Dependencies**：T2、T3
**Files**：`scripts/notify-decision.ps1`、`.claude/settings.json`、`tests/notify-decision.Tests.ps1`
**Scope**：S

#### Task 11：worktree 建立
**Description**：實作 `New-OfficeWorktree`：從專案的 `baseBranch` 開出 `huddle/<iid>-<slug>` 分支，worktree 放在 `<workspaceRoot>\worktrees\` 底下。
**Acceptance criteria**：
- [x] 不會修改 `repoPath`（你自己的 clone）的工作目錄或目前所在的分支
- [x] `baseBranch` 是 `null` 時拒絕建立，並提示要先經過 G1 核准專案設定
**Verification**：Pester 測試（用暫存的本機 git repo）
**Dependencies**：T6
**Files**：`scripts/Office.psm1`、`tests/Office.Tests.ps1`
**Scope**：S

#### Task 12：Builder 寫計畫與 G1
**Description**：
- 新增 `builder` agent 定義，這個任務先只做「寫計畫」的模式。
- `/huddle-take` 改為從 BRIEFED 推進到 PLANNED。
- Office Manager 在 `CLAUDE.md` 的 G1 規則：產出 `decisions/<n>.md`，用 AskUserQuestion 詢問，並呼叫 `notify-decision.ps1`。
- 核准後，把專案設定草稿寫進 `office.json`。
- 產出 `analysis-comment.md`，依 `gitlab-issue` 範本撰寫。
**Acceptance criteria**：
- [ ] 核准之前，目標 repo 沒有任何新的 worktree 或 commit（Success Criteria #2）
- [ ] 未登記的專案，核准之前 `config/office.json` 沒有被修改（Success Criteria #9）
- [ ] 已經有一個 work item 在 BUILDING 時，新的 work item 停在 PLANNED 排隊（`maxActiveBuilds`）
**Verification**：手動用一張真實 issue 走到 G1，然後選「不核准」，確認沒有任何副作用
**Dependencies**：T7、T10、T11；需要先安裝 `gitlab-convention` plugin（由你執行）
**Files**：`.claude/agents/builder.md`、`.claude/commands/huddle-take.md`、`CLAUDE.md`、`scripts/Office.psm1`
**Scope**：M

### Checkpoint C：G1
- [ ] G1 的「核准」與「不核准」兩條路徑都手動驗證過
- [ ] **E2E 測試要用的沙盒專案已經準備好**（見 Open Questions）

### Phase D：自主循環

#### Task 13：Tester 與 Security agent
**Description**：
- 新增 `tester` agent（模型用 Sonnet）與 `security` agent。
- Builder 開放「實作」模式，只能在 worktree 裡 commit。
- Office Manager 在 BUILDING、TESTING、SEC_REVIEW 之間派工。
**Acceptance criteria**：
- [ ] 每個 agent 只寫自己負責的報告檔，以及附加 `thread.md`
- [ ] Security 的 finding 格式符合 §5，而且不包含可以直接拿來利用的步驟（S4）
**Verification**：在沙盒專案用一張假 issue，跑完一輪「實作 → 測試 → 資安審查」（Success Criteria #3 的一部分）
**Dependencies**：T11、T12
**Files**：`.claude/agents/tester.md`、`.claude/agents/security.md`、`.claude/agents/builder.md`、`CLAUDE.md`
**Scope**：M

#### Task 14：Reviewer、分歧判定與 G2
**Description**：
- 新增 `reviewer` agent，加入 REVIEW 狀態。
- 實作 `Test-OfficeDivergence`，涵蓋 §3.3 的四種分歧條件，以及 `maxAutoRounds` 上限。
- 分歧成立時，發出 G2 決策並推播。
**Acceptance criteria**：
- [ ] 四種分歧條件各有 fixture 測試（Success Criteria #4）
- [ ] 退回 BUILDING 的次數正確計入輪次；超過 3 輪時一定會進入 G2
**Verification**：Pester 測試＋沙盒專案手動走完完整一輪（Success Criteria #3）
**Dependencies**：T13
**Files**：`.claude/agents/reviewer.md`、`scripts/Office.psm1`、`tests/Office.Tests.ps1`、`CLAUDE.md`
**Scope**：M

### Checkpoint D：自主循環
- [ ] 沙盒專案的 work item 能自主跑到 READY，或者正確地停在 G2
- [ ] **跟你一起 review 之後，才繼續往下做**

### Phase E：交付與收尾

#### Task 15：交付（push 與 MR）
**Description**：
- 從 READY 推進到 DELIVERED：
  - 依 `gitlab-mr` 範本產出 `mr-draft.md`，開頭加 A1 標示
  - 用 `glab label list` 檢查要用的 label 都存在
  - 先查這個分支是不是已經有 MR（`gitlab-mr` G2）
  - 經過 G3 確認後，用你的帳號 push 並建立 MR
- 完成後把新的 `updated_at` 寫回 `status.json`。
**Acceptance criteria**：
- [ ] 指定不存在的 label 時拒絕送出，不會自己建立 label（Success Criteria #16）
- [ ] MR 描述開頭有 A1 標示（Success Criteria #15 的後半）
- [ ] push 和建立 MR 各跳出一次 G3 確認
**Verification**：在沙盒專案實際開一個 MR
**Dependencies**：T3、T14
**Files**：`.claude/agents/builder.md`、`CLAUDE.md`、`scripts/Office.psm1`
**Scope**：M

#### Task 16：`post-issue-note.ps1`（bot 身分）
**Description**：
- 實作 `post-issue-note.ps1`：
  - token 從 Credential Manager 或 `HUDDLE_BOT_TOKEN` 讀取
  - 送出前確認 bot 是該專案的成員
  - 用 bot 身分發出留言，不另外加 AI 標示（A2）
  - 發完後把新的 `updated_at` 寫回 `status.json`
- **bot 不可用時，走做法 (a)：只把草稿顯示給你，不發出任何東西。**
- 用在兩個地方：Clarify 留言、「分析與修正計畫」留言。
**Acceptance criteria**：
- [ ] 測試涵蓋：沒有 token、bot 不是專案成員、正常發送三種情況；token 不會出現在任何輸出裡
- [ ] 每次執行都會跳出 G3 確認
- [ ] 實際用 bot 發出留言的驗證（Success Criteria #15 前半、#17），**等管理員提供 bot 帳號後才能做**
**Verification**：Pester 測試；bot 帳號到位後，在沙盒 issue 實際發一則留言
**Dependencies**：T3、T9、T12；**外部相依：bot 帳號**
**Files**：`scripts/post-issue-note.ps1`、`tests/post-issue-note.Tests.ps1`、`CLAUDE.md`
**Scope**：M

#### Task 17：紀錄清理
**Description**：DELIVERED 滿 30 天時，由 `/huddle-tick` 清理該 work item（§3.7），並寫入 `office/purge.log`。
**Acceptance criteria**：
- [ ] worktree 裡有還沒 commit 的變更時，跳過不刪（Success Criteria #11）
- [ ] 本機分支只在遠端也有同名分支時才刪除
**Verification**：Pester 測試（用暫存的 git repo 與假造的時間）
**Dependencies**：T11、T15
**Files**：`scripts/Office.psm1`、`tests/Office.Tests.ps1`
**Scope**：S

#### Task 18：改名成 Huddle（§0）
**Description**：
- 把 `README.md`、`CLAUDE.md` 的標題改成 Huddle，並註明 radar 是其中的模組。
- **GitLab 上的 path 改名由你自己操作**（對外寫入）。改完之後，我執行 `git remote set-url origin git@gitlab.example.com:jason/huddle.git`，再用 `git fetch origin` 驗證。
- 本機資料夾要不要改名由你決定；如果改名，要重新執行 `register-notify-task.ps1`。
**Acceptance criteria**：
- [ ] `git remote -v` 顯示新的網址，`git fetch origin` 成功
- [ ] 改名之後，Task Scheduler 的推播仍然正常（如果有改資料夾名稱）
**Verification**：執行上面兩個指令，以及一次 `notify-new.ps1 -DryRun`
**Dependencies**：None（隨時可以做）
**Files**：`README.md`、`CLAUDE.md`
**Scope**：XS

#### Task 20：交付後的 MR 追蹤
**Description**：`/huddle-tick` 與 session 開場唯讀讀取 DELIVERED work item 的 MR，記錄 `state`、`mergedAt`、`pipeline`、`checkedAt`，在辦公室狀態多一欄 MR（§3.11）。
**Acceptance criteria**：
- [ ] MR 合併後，下一次 tick 把 `mr.state` 寫成 `merged`、`thread.md` 多一筆、MR 欄顯示 merged（Success Criteria #18）
- [ ] 已是 `merged` 或 `closed` 的 MR 不再呼叫 GitLab
- [ ] pipeline 變成 `failed`，或 MR 被關閉而沒有合併時，辦公室狀態出現 Warning
- [ ] GitLab 讀取失敗時 `status.json` 不變，tick 仍回 `ok`，錯誤在 `errors`；開場 brief 註明沒有更新成功
- [ ] 沒有 `mr` 欄位的 DELIVERED work item 被略過，不報錯
**Verification**：Pester 測試（GitLab 以 mock 取代）；對現有的 DELIVERED work item 跑一次 `/huddle-tick`
**Dependencies**：T15、T9
**Files**：`scripts/Office.psm1`、`scripts/Huddle.psm1`、`scripts/session-brief.ps1`、`tests/Huddle.Tests.ps1`、`tests/session-brief.Tests.ps1`、`.claude/commands/huddle-tick.md`、`CLAUDE.md`
**Scope**：S

#### Task 21：單與單的相依
**Description**：`wait-for.ps1` 登記「等某張 MR 合併」；相依未成立時 `/huddle-tick` 不排 Intake、`/huddle-take` 拒絕開始；成立時由 `/huddle-tick` 提醒（§3.11）。
**Acceptance criteria**：
- [ ] `wait-for.ps1` 登記後 `status.json` 有 `waitsFor`，辦公室狀態顯示等待中
- [ ] 被等的 MR 合併後，下一次 tick 寫入 `metAt`、`thread.md` 多一筆、`unblocked` 有一列（Success Criteria #19）
- [ ] 相依未成立時，tick 不為該 NEW work item 排 Intake
- [ ] 相依未成立時 `/huddle-take` 拒絕開始，並說明在等哪一張 MR
- [ ] `-Clear` 之後該 work item 的行為與沒有相依時相同
- [ ] 同一輪 tick 裡同一張 MR 只讀一次
**Verification**：Pester 測試（GitLab 以 mock 取代）
**Dependencies**：T20
**Files**：`scripts/wait-for.ps1`、`scripts/Office.psm1`、`scripts/Huddle.psm1`、`scripts/huddle-take.ps1`、`tests/Huddle.Tests.ps1`、`.claude/commands/huddle-take.md`、`.claude/commands/huddle-tick.md`、`CLAUDE.md`
**Scope**：M

### Checkpoint E：完成
- [ ] SPEC §9 的 17 條 Success Criteria 逐條勾選（#15 前半、#17 視 bot 帳號是否到位）
- [ ] `Invoke-Pester -Path tests` 全部通過
- [ ] 跟你一起 review 之後，才合併 `feature/huddle`

## Success Criteria 對照

| SC | 驗證於 | SC | 驗證於 |
|---|---|---|---|
| 1 | T5 | 10 | T10 |
| 2 | T12 | 11 | T17 |
| 3 | T13、T14 | 12 | T9 |
| 4 | T14 | 13 | T4、T8 |
| 5 | T3 | 14 | T9 |
| 6 | T8 | 15 | T15（MR 部分）、T16（bot 部分） |
| 7 | Checkpoint B、E | 16 | T15 |
| 8 | 每個 Checkpoint | 17 | T12、T16 |
| 9 | T12 | | |

## Parallelization

- **可以平行做**：T2（查證）和 T1；T8 和 T6；T10 和 T11；T18 和所有任務。
- **必須依序做**：T3 要在任何 agent 定義之前完成；T4 是所有 Office 功能的基礎。
- **需要協調**：agent 回傳的 YAML 格式在 T7 定案。之後 T12～T16 新增的 agent 都沿用同一個格式；如果要改格式，要先回頭改 T7 的解析器與 fixture。

## Risks and Mitigations

| 風險 | 影響 | 緩解 |
|---|---|---|
| Claude Code 的 agent、permissions、hook 行為與 spec 的假設不同 | High | T2 先查證；查不到的部分一律改用 PreToolUse hook 實作，hook 行為一定有測試 |
| `gate-guard` 被指令變形繞過（引號、串接、別名） | High | T3 的測試要包含各種變形；另外疊加 permissions 規則做第二層防護 |
| issue 內文含有 prompt injection | High | Intake 把 issue 內容一律當作資料；所有對外寫入都經過 G3（harness 層，不靠 prompt） |
| subagent 回傳的 YAML 格式不正確 | Med | 解析失敗一律視為 `blocked`，不會往下猜；fixture 涵蓋各種格式錯誤 |
| bot 帳號遲遲申請不下來 | Med | 做法 (a) 讓整個流程不受影響；T16 的實際發送與其他任務脫鉤 |
| 目標 repo 的 build、test 指令不明 | Med | 由 Intake 調查、經 G1 核准才寫入設定；`baseBranch` 是 `null` 時，T11 拒絕建立 worktree |
| Token 成本過高 | Low | 模型分級；inbox 來的只做到 BRIEFED；`maxActiveBuilds: 1` |
| Windows 上 `glab api` 的引號與編碼問題 | Low | 沿用 `WorkItems.psm1` 已經驗證過的寫法（UTF-8 輸出、錯誤輸出分流）；依 `gitlab-issue` G1，描述先寫成檔案再帶入 |

## Open Questions

1. ~~**E2E 沙盒專案**~~：已同意（2026-11-05）使用 `jason/huddle-sandbox`。在 Checkpoint C 時才建立：依 `gitlab-new-project` 規範檢查命名與撞名，visibility 設為 private，建立前會再次跳出 G3 確認。
2. ~~**Pester 安裝**~~：已安裝 6.2.0，決定沿用（2026-11-05）。
