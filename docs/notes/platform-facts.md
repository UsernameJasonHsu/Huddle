# Platform facts (T2)

查證日期：2026-11-05。每一項都附上來源；查不到的項目標示 **NOT CONFIRMED**，並寫出替代做法。
後續任務只能引用這份文件，不能憑印象實作。

環境：Windows 11、PowerShell 7.6.9、glab 1.108.0、Pester 6.2.0。

---

## 1. glab（來源：本機 `glab <cmd> --help`，glab 1.108.0，以及對 `gitlab.example.com` 的唯讀實測）

### 1.1 Intake 讀取用的指令（全部是 GET）

| 用途 | 指令 / endpoint | 實測結果 |
|---|---|---|
| issue 本體 | `glab api --hostname <host> projects/<url-encoded path>/issues/<iid>` | 回傳 object；含 `description`、`labels`、`severity`、`updated_at`、`user_notes_count`、`merge_requests_count`、`blocking_issues_count`、`author` 等欄位 |
| 留言 | `.../issues/<iid>/notes?per_page=100` | 回傳 array；每則有 `body`、`author`、`system`、`internal`、`created_at`、`updated_at`。**`system: true` 的是 GitLab 自動產生的紀錄（例如改 label），Intake 讀需求時要過濾掉** |
| 關聯 issue | `.../issues/<iid>/links` | 回傳 array（樣本 issue 為 `[]`） |
| 關聯 MR | `.../issues/<iid>/related_merge_requests` | 回傳 array（樣本 issue 為 `[]`） |
| 專案 label | `glab label list -R <path> --output json` | 依 團隊規範 L1，結果包含從上層群組繼承的 label |
| 分支是否已有 MR | `glab mr list -R <path> --source-branch <branch>` | 依 `gitlab-mr` G2 使用 |
| clone 未登記專案 | `glab repo clone <path> <dir>` | 使用已設定的通訊協定（SSH 或 HTTPS） |

也可以用 `glab issue view <iid> -R <path> --comments -F json`，但 `glab api` 的欄位比較完整，而且和 `WorkItems.psm1` 現有的寫法一致，**以 `glab api` 為主**。

注意：
- 留言超過 100 則時要分頁（`--paginate`，或依 `WorkItems.psm1` 的方式逐頁抓）。
- 專案路徑要做 URL encode（`[uri]::EscapeDataString('acme/SupportDesk')`）。

### 1.2 gate-guard 要辨識的「寫入」（給 T3）

依 `glab api --help`：
- 預設方法是 GET，但**只要帶了 `-f/--raw-field`、`-F/--field`、`--form` 任一個參數，預設就變成 POST**。
- `--input <file>` 會把檔案當作 request body。
- `-X/--method` 可以明確指定方法。

所以 `glab api` 要判定為寫入的條件是：`-X`/`--method` 不是 GET，**或者**帶了 `-f`、`--raw-field`、`-F`、`--field`、`--form`、`--input` 任一個參數，而且沒有明確指定 `-X GET`。

glab 的寫入子指令（`--help` 確認存在）：`issue note`、`issue create`、`issue update`、`issue close`、`issue reopen`、`issue delete`、`mr create`、`mr update`、`mr note`、`mr merge`、`mr approve`、`label create`。

---

## 2. Claude Code（來源：code.claude.com 官方文件，2026-11-05 讀取）

來源頁面：
- https://code.claude.com/docs/en/sub-agents.md
- https://code.claude.com/docs/en/permissions.md
- https://code.claude.com/docs/en/hooks.md
- https://code.claude.com/docs/en/skills.md
- https://code.claude.com/docs/en/scheduled-tasks.md

`permissions.md` 的引文是逐字讀取的。其他頁面經由摘要工具讀取，引文接近原文但不保證逐字；實作前，關鍵句要回到原頁再確認一次。

### 2.1 Subagent 定義（`.claude/agents/*.md`）
- 必填欄位：`name`、`description`。可用欄位包括 `tools`、`disallowedTools`、`model`、`permissionMode`、`maxTurns`、`skills`、`hooks`、`isolation`、`effort` 等。
- `model` 可以填：`sonnet`、`opus`、`haiku`、`fable`、完整的模型 ID，或 `inherit`。→ **spec 的模型分級做法可行**。
- `skills` 欄位會在 subagent 啟動時，把指定 skill 的完整內容載入它的 context。→ Builder 可以預先載入 `gitlab-issue`、`gitlab-mr`（§3.10）。
- `tools` 是工具名稱的允許清單。在 `tools` 裡寫 `Bash(git:*)` 這種限定指令的語法，**文件沒有提到**。限制 Bash 指令的正規做法，是在 settings 的 `permissions.deny` 加規則，這條規則對主 session 和 subagent 都有效。

### 2.2 ⚠️ 和 spec 假設不同的地方
- **Subagent 可以再派生 subagent**，預設最多往下三層。spec §1、§3.2 寫的「subagent 不能呼叫其他 subagent」是**錯的**，要更正。
  - 設計本身不變：Office Manager 中轉，可以讓所有討論都留下紀錄。
  - 但這個「中轉」現在要**主動強制**，不能再假設平台會擋：**每個 agent 的 `tools` 都不能包含 `Agent`**。
- **AskUserQuestion 在所有 subagent 裡都會被移除**，就算寫在 `tools` 裡也一樣。→ 「只有 Office Manager 能問我」這個設計成立。

### 2.3 Permission 規則
- 格式：`Bash(<pattern>)`。
  - 沒有 `*` 的規則只比對完全相同的一條指令。
  - `*` 可以比對任何文字，包括空白。
  - 結尾的 `:*` 等於結尾的 ` *`。
- 判斷順序：**deny → ask → allow**，第一個符合的規則決定結果，跟規則寫得多精確無關。
- 複合指令（`&&`、`||`、`;`、`|`、`|&`、`&`、換行）會拆開，逐段檢查；子 shell、命令替換、迴圈裡的指令也一樣適用 deny 和 ask。
- **只放行單一一支腳本**：`"Bash(pwsh -NoProfile -File scripts/notify-decision.ps1)"`，不加 `*`。參數只要稍有不同，就不算符合，會跳出確認。這是安全的方向。
- PowerShell 工具的規則寫成 `PowerShell(...)`，格式相同；會把別名正規化，比對時不分大小寫。
- ⚠️ **規則只比對指令的「文字」，文件明確說它「不是安全邊界」**。例如 `Bash(git push *)` 擋不住 `git -C . push origin main`。→ G3 **一定要靠 `gate-guard.ps1` 解析指令**，permissions 規則只是第二層防護。T3 的測試要包含 `git -C <dir> push`、`git --git-dir=... push` 這類寫法。

### 2.4 PreToolUse hook
- stdin 會收到 JSON，常用欄位：`tool_name`、`tool_input`、`cwd`、`hook_event_name`；在 subagent 裡執行時，另外有 `agent_id`、`agent_type`。Bash 的指令字串在 `tool_input.command`。
- 拒絕的輸出格式：
  ```json
  {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"..."}}
  ```
- `permissionDecision` 可以是 `allow`、`deny`、`ask`、`defer`。`ask` 和 `allow` 的格式是從欄位表推論的，**文件沒有完整範例，T3 要實測確認**。
- Exit code：
  - `0`：成功，套用輸出的 JSON；沒有輸出代表不做決定。
  - `2`：阻擋，stderr 會當作訊息。
  - 其他非 0：非阻擋的錯誤，**動作會照常執行**。→ **gate-guard 自己發生錯誤時，必須明確輸出 deny（fail closed），不能用非 0 的 exit code 結束**。
- hook 回傳 `allow`，**不能**蓋過符合條件的 deny 或 ask 規則。
- settings 裡設定的 hook，**在 subagent 裡一樣會執行**。matcher 寫 `Bash|PowerShell` 可以同時涵蓋兩種工具。
- **NOT CONFIRMED**：沒有任何規則符合時，hook 回傳 `allow` 會不會直接放行。gate-guard 不使用 `allow`，只回傳 `deny`、`ask`，或不輸出任何東西，所以不依賴這一點。

### 2.5 Permission mode 與 subagent
- subagent 的 permission mode 會繼承主 session。主 session 是 `bypassPermissions`、`acceptEdits` 或 auto 模式時，subagent 會跟著用同一個模式，忽略它自己設定的 `permissionMode`。
- 背景執行的 subagent，permission 確認提示會顯示在主 session。
- **NOT CONFIRMED**：在 auto 模式或 `bypassPermissions` 模式下，`ask` 規則和 hook 回傳的 `ask` 會不會照樣跳出確認。這直接影響 G3。→ **T3 必須在 Huddle 實際使用的模式下手動驗證**；如果不會跳出確認，Huddle 的 session 就不能用這些模式，要寫進 `CLAUDE.md`。

### 2.6 Slash command 與 `/loop`
- `.claude/commands/*.md` 仍然可以用，但官方建議新的功能改寫成 skill（`.claude/skills/<name>/SKILL.md`），兩者產生的 `/name` 用法相同。
- 參數：`$ARGUMENTS` 是全部參數；`$0`、`$1` 是第幾個參數（從 0 開始，用 shell 的引號規則）。
- `/loop` 是內建的 bundled skill，只在 session 開著而且閒置時才會執行。用法是 `/loop 10m <prompt>`，**重複執行的排程 7 天後會自動失效**。→ Huddle 開場的 brief 應該提醒「`/huddle-tick` 的 loop 有沒有在跑」。


---

## 3. Pester 6（來源：Pester GitHub releases 與官方遷移指南）

來源頁面：
- https://github.com/pester/Pester/releases （6.0.0、6.2.0 的 release notes）
- https://pester.dev/docs/migrations/v5-to-v6

引文經由摘要工具讀取，接近原文，但可能被截短。

### 3.1 版本
- 6.0.0：2026-07-07 發布。6.2.0：2026-09-09 發布。
- 支援 Windows PowerShell 5.1 和 **PowerShell 7.4 以上**。本機是 7.6.9，符合。

### 3.2 對我們有影響的不相容變更
| 變更 | 對 Huddle 測試的規則 |
|---|---|
| `Assert-MockCalled`、`Assert-VerifiableMock` 已移除 | 一律用 `Should -Invoke`、`Should -InvokeVerifiable` |
| **Mock 的 fall-through 已移除**：呼叫一個有 mock 的指令時，如果沒有任何 `-ParameterFilter` 符合，v5 會偷偷改跑真的指令，v6 不會 | 用了 `-ParameterFilter` 的 mock，一定要再加一個沒有 filter 的預設 mock。（這對我們是好事：mock 漏掉時，不會意外連到 GitLab） |
| `-Focus` 已移除；Pending 狀態已移除 | 不使用；要暫時跳過的測試用 `-Skip` |
| `-ForEach $null` 或 `-ForEach @()` 預設會直接報錯 | 資料驅動的測試，資料來源不能是空的 |
| Discovery 改成每個檔案獨立進行 | 每個測試檔都要在自己的 `BeforeAll` 裡 `Import-Module`，不能依賴其他檔案載入過的模組 |
| 測試名稱只會展開 `<...>` 樣板 | 名稱裡的 `$變數` 不會被展開 |
| `Invoke-Pester` 舊的 v4 參數組已移除 | 只用 `-Path`、`-Output`，或 `-Configuration` |
| 同一個區塊放多個 `BeforeAll` 等設定區塊：6.0.x 會報錯，**6.2.0 又允許了** | 維持每個區塊只放一個，6.0.x 和 6.2.0 都能跑 |

### 3.3 Code coverage 與 `New-PesterConfiguration`
- 預設改用 profiler 計算覆蓋率，速度比較快，但**數字可能和 v5 不同**。
- 輸出格式 `CoverageGutters` 已移除；預設是 `JaCoCo`，另外支援 `Cobertura`。
- 設定的型別寫錯會直接報錯；欄位名稱拼錯只會出現警告，**不會報錯**。設定覆蓋率時要注意檢查警告。

### 3.4 T1 測試的符合性檢查
`tests/WorkItems.Tests.ps1` 只使用了 `BeforeAll`、`BeforeEach`、`Describe`、`Context`、`It`、`Should -Be`、`Mock -ModuleName`、`Should -Invoke`，都在支援清單內。所有 mock 都**沒有**使用 `-ParameterFilter`（`Should -Invoke` 裡的 `-ParameterFilter` 只用來篩選要檢查的呼叫，不受 fall-through 影響）。→ **符合 Pester 6，不需要修改**。

---

## 4. 對後續任務的影響（摘要）
| 任務 | 要調整的地方 |
|---|---|
| T3 | gate-guard 自己發生錯誤時，一律輸出 deny（fail closed），不能用非 0 的 exit code 結束；測試要涵蓋 `git -C <dir> push`、`git --git-dir=... push`、`glab api -f ...`（隱含 POST）、`--input`；matcher 用 `Bash|PowerShell`；在 Huddle 實際使用的 permission mode 下，手動驗證 ask 會不會跳出確認 |
| T7、T12～T14 | 每個 agent 的 `tools` 都不包含 `Agent`；用 `model` 欄位做模型分級；Builder 用 `skills` 欄位預先載入 `gitlab-issue`、`gitlab-mr` |
| T5、T7、T9 | 新的指令可以考慮直接寫成 skill（`.claude/skills/<name>/SKILL.md`），`/huddle` 這些名稱的用法不變 |
| T9 | `/loop` 的排程 7 天後失效；`/huddle` 和開場 brief 要提醒 loop 有沒有在跑 |
| 所有測試 | 遵守 §3.2 的規則 |
