<!-- 参考资料快照（2026-09-12） -->
<!-- 活文件为准：D:\gitAll\auto-deploy\_lib\TextFile.ps1（权威源，调用前请重读活文件） -->
<!-- 另见 skill：auto-deploy-helpers（同源 helper 的 skill 入口）。本件为巡检脚手架上下文而抄。 -->

# TextFile.ps1 helper API（巡检脚手架的"手术刀"）

巡检链路里凡是"写文件 / 改一段 / 发飞书通知"都走这个 helper，统一 UTF-8 无
BOM、避免 codex 在 pwsh 7 下拼字符串撞 ParserError。活文件：
`D:\gitAll\auto-deploy\_lib\TextFile.ps1`。

## 加载

```powershell
. "D:\gitAll\auto-deploy\_lib\TextFile.ps1"      # dot-source，函数即用
# 或
Import-Module "D:\gitAll\auto-deploy\_lib\TextFile.ps1" -DisableNameChecking
```

内部编码常量：`$Script:TextFileEncoding = [System.Text.UTF8Encoding]::new($false)`
即 **无 BOM**，所有写盘函数默认用它。

## 函数清单

### Set-TextFile（写整文件，首选无 BOM 覆盖）

```powershell
Set-TextFile -LiteralPath $p -Content $body
Set-TextFile -LiteralPath $p -Content $tail -Append   # Append=读旧+重写
```

### Add-TextFile（追加一行，自动补 \n）

```powershell
Add-TextFile -LiteralPath $p -Line "## 巡检 $stamp"
```

### Get-TextFile（读为字符串，自动剥 BOM U+FEFF）

```powershell
$txt = Get-TextFile -LiteralPath $p
```

### Set-TextFilePatch（原地改一段，codex 改文件首选）

```powershell
$n = Set-TextFilePatch -LiteralPath $p -OldText 'foo' -NewText 'bar'
$n = Set-TextFilePatch -LiteralPath $p -OldText 'foo' -NewText 'bar' -Occurrence 1
```

- `OldText` 必须唯一存在，否则报 `-NotFound`；返回 `[int]` 实际替换次数（0=未替换）。
- v0.2 起自动检测文件换行风格（CRLF/LF），首次 `Contains` 失败时归一化重试——
  解决"codex here-string 内存是 LF、目标文件是 CRLF → 多行 OldText NotFound"。
- v0.3 起写盘后自校验（反向读回确认）。
- `-Occurrence`：1-based 替换第 N 次；-1（默认）替换全部。

### Assert-PatchWritten（断言已写入）

校验某次 patch 是否真的落盘（OldText 已不在 / NewText 已在）。配合
`Set-TextFilePatch` 做写后断言。

### Test-TextFileBom / Remove-TextFileBom

```powershell
Test-TextFileBom -LiteralPath $p     # bool：前 3 字节是否 EF BB BF
Remove-TextFileBom -LiteralPath $p   # 去掉 BOM，返回 $true 表示有改动
```

### Invoke-TextFileBomSweep（批量扫 + 去 BOM）

```powershell
$r = Invoke-TextFileBomSweep -Path 'D:\gitAll\auto-deploy' -Extensions .ps1 -Fix -Recurse
# $r = @{ Found; Fixed; Scanned; Files }
```

默认后缀：.ps1 .py .md .json .yml .yaml .toml .xml .java .cs。
`Start-CodexAutoPatrol.ps1` 入口已自动调它（`-Fix`）。

### Send-LarkText（发飞书通知，避开 @file 字面 bug）

```powershell
Send-LarkText -UserId ou_xxx -Text "简短通知"
Send-LarkText -UserId ou_xxx -TextFilePath "$env:TEMP\notify.txt"
Send-LarkText -UserId ou_xxx -Text "# 标题`n`n- 点1" -Markdown
Send-LarkText -UserId ou_xxx -Text "..." -As user
```

- `-UserId` 与 `-ChatId` 互斥；`-Text` 与 `-TextFilePath` 互斥。
- 关键：`lark-cli im +messages-send --text/--markdown` **不支持 `@file`**；本函数先
  `Get-TextFile` 读入变量再透传，避免把 `"@xxx"` 当字面文本发送（2026-09-09 03:03
  那条 `@.lark-msg.txt` 字面消息即此 bug）。
- `-IdempotencyKey` 幂等；`-DryRun` 只打印不真发。

## 巡检脚手架里的典型用法

- worker 回写结果 → `Set-TextFilePatch` 改配置/状态文件的一段。
- 摘要入 Obsidian → `Add-TextFile` 追加 `## 巡检` 段（先 `Get-TextFile` 判存否补头）。
- 完工/受阻通禀 → 把长摘要写 `$env:TEMP\notify.txt`，再 `Send-LarkText -TextFilePath`。
- 任何写盘后 → `Test-TextFileBom` 自查前三字节非 EF BB BF。